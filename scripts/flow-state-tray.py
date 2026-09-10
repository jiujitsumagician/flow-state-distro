#!/usr/bin/env python3
"""
Flow State — DSIO status tray icon.

Sits in the top panel (Ubuntu AppIndicator extension supplies the tray).
Pulls `dsio quota --json` every 15 seconds and renders it as a compact
label ("Claude 12% · Codex ✓ · Ollama 0%") on hover plus a dropdown
menu with the full per-provider breakdown.

Click the icon for a Refresh / Copy-status-to-clipboard / Open-DSIO
menu. Icon color hints:

    green  — everything the router relies on is healthy
    amber  — Claude Max above 80% of the 5-hour cap
    red    — Claude Max at 95% or a provider is throttled/down

X11 or Wayland (AppIndicator is toolkit-agnostic). Ships as an autostart
entry from scripts/08-tray.sh.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import Gtk, GLib, AyatanaAppIndicator3 as AppIndicator3  # noqa: E402


DSIO_HARNESS = os.path.expanduser("~/dsio-harness")
CLI = os.path.join(DSIO_HARNESS, "dist/src/cli/index.js")
BRAND_LOGO = os.path.expanduser("~/flow-state-distro/branding/flowstate-logo.png")
POLL_SECONDS = 15


def dsio_quota() -> dict:
    """Run `node cli.js quota --json` and parse the result."""
    if not os.path.exists(CLI):
        return {"error": f"dsio not built at {CLI}"}
    try:
        out = subprocess.check_output(
            ["node", "--no-warnings", CLI, "quota", "--json"],
            timeout=10, text=True,
        )
        return json.loads(out)
    except subprocess.TimeoutExpired:
        return {"error": "dsio quota timed out"}
    except subprocess.CalledProcessError as exc:
        return {"error": f"dsio exit {exc.returncode}"}
    except (json.JSONDecodeError, ValueError) as exc:
        return {"error": f"parse: {exc}"}


def _pct5h(p: dict) -> float | None:
    """Extract the 5-hour bucket percentage (0-100) from a provider entry."""
    for w in p.get("windows") or []:
        if w.get("label") == "5h":
            pct = w.get("pct")
            if pct is not None:
                return float(pct) * 100
    top = p.get("pct")
    if top is not None:
        return float(top) * 100
    return None


def _pctweek(p: dict) -> float | None:
    for w in p.get("windows") or []:
        if w.get("label") in ("1 week", "week"):
            pct = w.get("pct")
            if pct is not None:
                return float(pct) * 100
    return None


def health_hint(data: dict) -> str:
    """green / amber / red based on Claude Max usage + provider availability."""
    if "error" in data:
        return "red"
    worst = "green"
    for p in data.get("providers") or []:
        name = p.get("provider")
        if name == "claude-sub":
            pct5 = _pct5h(p) or 0
            if pct5 >= 95:
                return "red"
            if pct5 >= 80:
                worst = "amber"
        if p.get("confidence") in ("throttled", "cooldown") and worst == "green":
            worst = "amber"
    return worst


class Tray:
    def __init__(self):
        icon = BRAND_LOGO if os.path.exists(BRAND_LOGO) else "utilities-system-monitor"
        self.indicator = AppIndicator3.Indicator.new(
            "flow-state-dsio",
            icon,
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self.indicator.set_title("Flow State — DSIO status")
        self.menu = Gtk.Menu()
        self._menu_items: list[Gtk.MenuItem] = []
        self._rebuild_menu({"loading": True})
        self.indicator.set_menu(self.menu)
        self._refresh()
        GLib.timeout_add_seconds(POLL_SECONDS, self._tick)

    def _tick(self) -> bool:
        self._refresh()
        return True

    def _refresh(self) -> None:
        data = dsio_quota()
        self._render_label(data)
        self._rebuild_menu(data)

    def _render_label(self, data: dict) -> None:
        if "error" in data:
            self.indicator.set_label("DSIO ⚠", "flow-state-dsio")
            return
        parts: list[str] = []
        for p in data.get("providers") or []:
            name = p.get("provider")
            available = p.get("available")
            if name == "claude-sub":
                pct5 = _pct5h(p)
                if pct5 is not None:
                    parts.append(f"C {int(round(pct5))}%")
                else:
                    parts.append("C ok" if available else "C ⚠")
            elif name == "codex":
                parts.append("X ok" if available else "X ⚠")
            elif name == "ollama":
                parts.append("O ok" if available else "O ⚠")
        if not parts:
            parts = ["DSIO"]
        self.indicator.set_label("  ".join(parts[:3]), "flow-state-dsio")

    def _rebuild_menu(self, data: dict) -> None:
        for it in self._menu_items:
            self.menu.remove(it)
        self._menu_items.clear()

        header = Gtk.MenuItem(label="DSIO providers")
        header.set_sensitive(False)
        self._append(header)
        self._append(Gtk.SeparatorMenuItem())

        if "error" in data:
            err = Gtk.MenuItem(label=f"error: {data['error']}")
            err.set_sensitive(False)
            self._append(err)
        elif "loading" in data:
            self._append(Gtk.MenuItem(label="loading…"))
        else:
            for p in data.get("providers") or []:
                name = p.get("provider") or "?"
                available = p.get("available")
                confidence = p.get("confidence") or ""
                pct5 = _pct5h(p)
                pctw = _pctweek(p)
                bits = [f"{'●' if available else '○'} {name}"]
                if pct5 is not None:
                    bits.append(f"5h {int(round(pct5))}%")
                if pctw is not None:
                    bits.append(f"week {int(round(pctw))}%")
                if confidence and not available:
                    bits.append(str(confidence))
                self._append(Gtk.MenuItem(label="  ".join(bits)))

        self._append(Gtk.SeparatorMenuItem())

        refresh = Gtk.MenuItem(label="↻ Refresh")
        refresh.connect("activate", lambda _i: self._refresh())
        self._append(refresh)

        copy = Gtk.MenuItem(label="⧉ Copy status to clipboard")
        copy.connect("activate", lambda _i: self._copy_to_clipboard(data))
        self._append(copy)

        open_dsio = Gtk.MenuItem(label="⚡ Open DSIO in a terminal")
        open_dsio.connect("activate", lambda _i: self._open_terminal())
        self._append(open_dsio)

        quit_i = Gtk.MenuItem(label="✕ Quit")
        quit_i.connect("activate", lambda _i: Gtk.main_quit())
        self._append(quit_i)

        self.menu.show_all()

    def _append(self, item: Gtk.MenuItem) -> None:
        self.menu.append(item)
        self._menu_items.append(item)

    def _copy_to_clipboard(self, data: dict) -> None:
        text = json.dumps(data, indent=2) if data else "{}"
        try:
            subprocess.run(["xclip", "-selection", "clipboard"], input=text, text=True, timeout=3)
        except (FileNotFoundError, subprocess.SubprocessError):
            # xclip missing; try wl-copy for Wayland.
            try:
                subprocess.run(["wl-copy"], input=text, text=True, timeout=3)
            except (FileNotFoundError, subprocess.SubprocessError):
                print("flow-state-tray: no clipboard tool (install xclip)", file=sys.stderr)

    def _open_terminal(self) -> None:
        for candidate in ("gnome-terminal", "kitty", "alacritty", "xterm"):
            if subprocess.run(["which", candidate], capture_output=True).returncode == 0:
                subprocess.Popen([candidate, "--", "bash", "-lc", "dsio; exec bash"])
                return


def main() -> int:
    _ = Tray()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
