#!/usr/bin/env python3
"""
Flow State: display sleep button.

A single small button pinned to the desktop layer (behind every normal
window) on the top-right corner of every monitor. Clicking any button
puts every display to sleep with `xset dpms force off`. Wake with any
keyboard or mouse input — Linux's DPMS handles that automatically.

Because the buttons are `_NET_WM_WINDOW_TYPE_DESKTOP`, they only show
when nothing is stacked over them: on your empty desktop, but not on
top of a maximized editor or browser. The moment a window covers the
corner, the button is hidden by the window manager's own stacking.

X11 only in v1 (uses xset/xrandr and absolute window positioning). On
Wayland this same UX ships as a GNOME Shell extension in Phase 2.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from dataclasses import dataclass

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib  # noqa: E402


BUTTON_SIZE = 44
CORNER_OFFSET = 12  # px from the bottom-right of the monitor
POLL_INTERVAL_MS = 3000
OCCLUSION_POLL_MS = 400  # how often to check if a window covers a button
CSS = b"""
.flowstate-sleep-btn {
    background: rgba(24, 95, 165, 0.65);
    color: #f5f7fa;
    border-radius: 22px;
    padding: 0;
    border: none;
    box-shadow: 0 2px 6px rgba(0,0,0,0.35);
    font-size: 20px;
    min-width: 44px;
    min-height: 44px;
}
.flowstate-sleep-btn:hover {
    background: rgba(24, 95, 165, 0.95);
    box-shadow: 0 4px 12px rgba(0,0,0,0.55);
}
"""


@dataclass
class MonitorInfo:
    name: str
    x: int
    y: int
    width: int
    height: int


def xrandr_active_monitors() -> list[MonitorInfo]:
    try:
        out = subprocess.check_output(["xrandr", "--query"], text=True, timeout=5)
    except (subprocess.SubprocessError, FileNotFoundError) as exc:
        print(f"flow-state-monitor-sleep: xrandr failed: {exc}", file=sys.stderr)
        return []
    mons: list[MonitorInfo] = []
    for line in out.splitlines():
        m = re.match(
            r"^(\S+)\s+connected(?:\s+primary)?\s+(\d+)x(\d+)\+(-?\d+)\+(-?\d+)",
            line,
        )
        if m:
            mons.append(MonitorInfo(
                name=m.group(1),
                width=int(m.group(2)),
                height=int(m.group(3)),
                x=int(m.group(4)),
                y=int(m.group(5)),
            ))
    return mons


def sleep_all_displays() -> None:
    """Every display off via DPMS. Any keyboard/mouse input wakes them."""
    subprocess.Popen(["xset", "dpms", "force", "off"])


def visible_normal_windows() -> list[tuple[int, int, int, int]]:
    """Return (x, y, w, h) of every visible non-desktop window from wmctrl.

    Falls back to an empty list if wmctrl is missing.
    """
    try:
        out = subprocess.check_output(["wmctrl", "-lG"], text=True, timeout=1)
    except (FileNotFoundError, subprocess.SubprocessError):
        return []
    rects: list[tuple[int, int, int, int]] = []
    for line in out.splitlines():
        # id workspace x y w h host title...
        parts = line.split(None, 7)
        if len(parts) < 8:
            continue
        try:
            workspace = int(parts[1])
            x = int(parts[2]); y = int(parts[3])
            w = int(parts[4]); h = int(parts[5])
        except ValueError:
            continue
        # Skip zero-sized entries.
        if w <= 1 or h <= 1:
            continue
        # Skip windows on workspace -1: sticky / virtual workspace windows
        # that the WM shows on every workspace and that DING (desktop icons
        # extension) uses as its full-screen backdrops. We only care about
        # regular windows the user actually put in front of the button.
        if workspace < 0:
            continue
        title = parts[7]
        if title.startswith("flow-state-monitor-sleep"):
            continue
        low = title.lower()
        if "desktop" in low and "icons" in low:
            continue
        rects.append((x, y, w, h))
    return rects


def rects_overlap(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> bool:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return not (ax + aw <= bx or bx + bw <= ax or ay + ah <= by or by + bh <= ay)


class SleepButton(Gtk.Window):
    """Borderless desktop-layer button in one monitor's top-right corner."""

    def __init__(self, monitor: MonitorInfo, on_click):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.monitor = monitor
        self.on_click = on_click
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        # UTILITY + keep_below keeps the window below normal app windows in
        # stacking; explicit hide()/show() in _occlusion_tick then removes
        # it entirely from anywhere a window actually covers, so the button
        # only appears where the empty desktop is visible.
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        self.set_keep_below(True)
        self.set_size_request(BUTTON_SIZE, BUTTON_SIZE)
        self.set_default_size(BUTTON_SIZE, BUTTON_SIZE)
        self.set_resizable(False)
        self.set_app_paintable(True)
        self._apply_transparency()

        btn = Gtk.Button(label="💤")
        btn.set_relief(Gtk.ReliefStyle.NONE)
        btn.get_style_context().add_class("flowstate-sleep-btn")
        btn.connect("clicked", lambda _b: self.on_click())
        self.add(btn)

        self.move(
            monitor.x + monitor.width - BUTTON_SIZE - CORNER_OFFSET,
            monitor.y + monitor.height - BUTTON_SIZE - CORNER_OFFSET,
        )
        self.show_all()
        self._visible = True
        GLib.timeout_add(OCCLUSION_POLL_MS, self._occlusion_tick)

    def _button_rect(self) -> tuple[int, int, int, int]:
        return (
            self.monitor.x + self.monitor.width - BUTTON_SIZE - CORNER_OFFSET,
            self.monitor.y + self.monitor.height - BUTTON_SIZE - CORNER_OFFSET,
            BUTTON_SIZE,
            BUTTON_SIZE,
        )

    def _occlusion_tick(self) -> bool:
        # If any regular window covers our rect, hide; otherwise show. This
        # gives the "only on the desktop" behavior — the button disappears
        # the moment a normal window arrives over it and comes back when
        # every window moves/minimizes away.
        rect = self._button_rect()
        covered = any(rects_overlap(rect, r) for r in visible_normal_windows())
        if covered and self._visible:
            self.hide()
            self._visible = False
        elif (not covered) and (not self._visible):
            self.show_all()
            self._visible = True
        return True

    def _apply_transparency(self) -> None:
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual and screen.is_composited():
            self.set_visual(visual)

    def move_to(self, mon: MonitorInfo) -> None:
        self.monitor = mon
        self.move(
            mon.x + mon.width - BUTTON_SIZE - CORNER_OFFSET,
            mon.y + CORNER_OFFSET,
        )


class App:
    def __init__(self):
        self.windows: dict[str, SleepButton] = {}
        self._install_css()
        self._sync()
        GLib.timeout_add(POLL_INTERVAL_MS, self._sync_tick)

    def _install_css(self) -> None:
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def _sync_tick(self) -> bool:
        self._sync()
        return True

    def _sync(self) -> None:
        want = {m.name: m for m in xrandr_active_monitors()}
        # Add or reposition.
        for name, m in want.items():
            if name in self.windows:
                self.windows[name].move_to(m)
            else:
                self.windows[name] = SleepButton(m, on_click=sleep_all_displays)
        # Drop offline.
        for name in list(self.windows.keys()):
            if name not in want:
                self.windows[name].destroy()
                del self.windows[name]


def main() -> int:
    # `--sleep-all` is used by the optional keyboard shortcut installed by
    # scripts/07-monitor-sleep.sh (Super+Shift+S).
    if len(sys.argv) > 1 and sys.argv[1] == "--sleep-all":
        if not os.environ.get("DISPLAY"):
            os.environ["DISPLAY"] = ":0"
        sleep_all_displays()
        return 0
    if not os.environ.get("DISPLAY"):
        print("flow-state-monitor-sleep: no DISPLAY; exiting", file=sys.stderr)
        return 0
    _ = App()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
