#!/usr/bin/env python3
"""
Flow State: per-monitor sleep buttons.

Draws a small always-on-top borderless button in the top-right corner of
every connected monitor. Click the button on a monitor → that display goes
to sleep (xrandr --output <NAME> --off). The PC and other monitors stay
awake. When at least one monitor is off, the buttons on the still-active
monitors flip to a "wake all" mode; a right-click on any button, or
Super+Shift+W (installed by the companion .desktop), wakes every display.

X11 only in v1 (uses xrandr and absolute window positioning). On Wayland
this same UX ships as a GNOME Shell extension in Phase 2.
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
CORNER_OFFSET = 8  # px from the top-right of the monitor
POLL_INTERVAL_MS = 2000
CSS = b"""
/* Idle: dim so it doesn't fight the desktop; hover: pops. */
.flowstate-monitor-btn {
    background: rgba(24, 95, 165, 0.55);
    color: #f5f7fa;
    border-radius: 22px;
    padding: 0;
    border: none;
    box-shadow: 0 2px 6px rgba(0,0,0,0.4);
    font-size: 20px;
    min-width: 44px;
    min-height: 44px;
}
.flowstate-monitor-btn:hover {
    background: rgba(24, 95, 165, 0.92);
    box-shadow: 0 4px 12px rgba(0,0,0,0.55);
}
.flowstate-monitor-btn.wake {
    background: rgba(210, 90, 24, 0.62);
}
.flowstate-monitor-btn.wake:hover {
    background: rgba(210, 90, 24, 0.95);
}
"""


@dataclass
class MonitorInfo:
    name: str          # xrandr output name, e.g. "DisplayPort-0"
    x: int
    y: int
    width: int
    height: int
    active: bool       # currently powered on (has a mode)


def xrandr_query() -> list[MonitorInfo]:
    """Parse `xrandr --query` and return every connected output."""
    try:
        out = subprocess.check_output(
            ["xrandr", "--query"], text=True, timeout=5
        )
    except (subprocess.SubprocessError, FileNotFoundError) as exc:
        print(f"flow-state-monitor-sleep: xrandr failed: {exc}", file=sys.stderr)
        return []

    monitors: list[MonitorInfo] = []
    current: str | None = None
    for line in out.splitlines():
        m = re.match(
            r"^(\S+)\s+connected(?:\s+primary)?\s+(?:(\d+)x(\d+)\+(-?\d+)\+(-?\d+))?",
            line,
        )
        if m:
            name = m.group(1)
            if m.group(2):
                w, h, x, y = (int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)))
                monitors.append(MonitorInfo(name=name, x=x, y=y, width=w, height=h, active=True))
            else:
                monitors.append(MonitorInfo(name=name, x=0, y=0, width=0, height=0, active=False))
            current = name
    return monitors


def xrandr_off(name: str) -> None:
    subprocess.Popen(["xrandr", "--output", name, "--off"])


def xrandr_wake_all() -> None:
    """Turn on every connected but currently-off output at its preferred mode."""
    for m in xrandr_query():
        if not m.active:
            subprocess.Popen(["xrandr", "--output", m.name, "--auto"])


class MonitorButton(Gtk.Window):
    def __init__(self, monitor: MonitorInfo, on_click, on_wake_all):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.monitor = monitor
        self.on_click = on_click
        self.on_wake_all = on_wake_all
        self.wake_mode = False  # flips when >0 monitors are asleep
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        self.set_type_hint(Gdk.WindowTypeHint.DOCK)
        self.set_size_request(BUTTON_SIZE, BUTTON_SIZE)
        self.set_default_size(BUTTON_SIZE, BUTTON_SIZE)
        self.set_resizable(False)
        self.set_app_paintable(True)
        self._apply_transparency()

        self.button = Gtk.Button(label="💤")
        self.button.set_relief(Gtk.ReliefStyle.NONE)
        ctx = self.button.get_style_context()
        ctx.add_class("flowstate-monitor-btn")
        self.button.connect("clicked", self._on_left_click)

        # Right-click → wake all (a discoverable fallback if the physical
        # button on an off monitor is out of reach).
        evbox = Gtk.EventBox()
        evbox.add(self.button)
        evbox.set_visible_window(False)
        evbox.connect("button-press-event", self._on_button_press)
        self.add(evbox)

        self.move(
            monitor.x + monitor.width - BUTTON_SIZE - CORNER_OFFSET,
            monitor.y + CORNER_OFFSET,
        )
        self.show_all()
        # After realize, tell the WM this is a utility window
        w = self.get_window()
        if w:
            w.set_override_redirect(False)

    def _apply_transparency(self) -> None:
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual and screen.is_composited():
            self.set_visual(visual)

    def _on_left_click(self, _btn) -> None:
        if self.wake_mode:
            self.on_wake_all()
        else:
            self.on_click(self.monitor.name)

    def _on_button_press(self, _widget, event) -> bool:
        # Right-click == wake all regardless of mode.
        if event.button == 3:
            self.on_wake_all()
            return True
        return False

    def set_wake_mode(self, on: bool) -> None:
        if on == self.wake_mode:
            return
        self.wake_mode = on
        self.button.set_label("☀" if on else "💤")
        ctx = self.button.get_style_context()
        if on:
            ctx.add_class("wake")
        else:
            ctx.remove_class("wake")


class App:
    def __init__(self):
        self.windows: dict[str, MonitorButton] = {}
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
        return True  # keep the GLib timeout alive

    def _sync(self) -> None:
        monitors = xrandr_query()
        want_active = {m.name: m for m in monitors if m.active}
        any_asleep = any(not m.active for m in monitors)

        # Add windows for newly-active monitors.
        for name, m in want_active.items():
            if name in self.windows:
                # Reposition in case the layout changed.
                win = self.windows[name]
                win.move(
                    m.x + m.width - BUTTON_SIZE - CORNER_OFFSET,
                    m.y + CORNER_OFFSET,
                )
                win.set_wake_mode(any_asleep)
            else:
                win = MonitorButton(
                    m,
                    on_click=self._sleep_monitor,
                    on_wake_all=self._wake_all,
                )
                win.set_wake_mode(any_asleep)
                self.windows[name] = win

        # Drop windows for monitors that went offline.
        for name in list(self.windows.keys()):
            if name not in want_active:
                self.windows[name].destroy()
                del self.windows[name]

    def _sleep_monitor(self, name: str) -> None:
        # If this monitor is the last one active, refuse — otherwise Will
        # would have to blindly hit the wake shortcut.
        active_count = sum(1 for m in xrandr_query() if m.active)
        if active_count <= 1:
            print(f"flow-state-monitor-sleep: refusing to sleep {name}, it is the only active display", file=sys.stderr)
            return
        xrandr_off(name)
        # Force a sync so remaining buttons flip to wake mode immediately.
        GLib.idle_add(self._sync)

    def _wake_all(self) -> None:
        xrandr_wake_all()
        GLib.idle_add(self._sync)


def main() -> int:
    # One-shot: wake every currently-off display and exit. Used by the
    # Super+Shift+W keyboard shortcut so a fully-off setup can be recovered.
    if len(sys.argv) > 1 and sys.argv[1] == '--wake-all-cli':
        if not os.environ.get('DISPLAY'):
            os.environ['DISPLAY'] = ':0'
        xrandr_wake_all()
        return 0

    # No DISPLAY = nothing to do.
    if not os.environ.get("DISPLAY"):
        print("flow-state-monitor-sleep: no DISPLAY; exiting", file=sys.stderr)
        return 0
    _ = App()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
