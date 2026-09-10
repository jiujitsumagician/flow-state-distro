#!/usr/bin/env python3
"""
Flow State Network — tray + detail panel.

Runs as a permanent tray icon in the top panel. The menu shows local IP,
public IP, MAC (per interface), gateway, DNS servers, current WiFi and
signal, plus quick actions. "Open detail panel" opens a large window
with everything at once and immediately kicks off a speed test.

All discovery uses standard Linux tools (ip, nmcli, resolvectl,
speedtest-cli) so no root or extra services are needed.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
from dataclasses import dataclass, field

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import Gtk, GLib, Gdk, AyatanaAppIndicator3 as AppIndicator3  # noqa: E402


ICON_NAME = "network-wired-symbolic"       # ethernet icon, obvious in the panel
ICON_NAME_WIFI = "network-wireless-symbolic"
ICON_NAME_OFFLINE = "network-offline-symbolic"
REFRESH_MS = 10_000  # background metadata refresh
PUBLIC_IP_TIMEOUT = 4
SPEEDTEST_TIMEOUT = 90


# ---- ProtonVPN toggle helpers ------------------------------------------
def _which(cmd: str) -> str | None:
    for p in os.environ.get("PATH", "").split(":"):
        full = os.path.join(p, cmd)
        if os.access(full, os.X_OK):
            return full
    return None


def vpn_probe() -> dict:
    proton = _which("protonvpn") or _which("protonvpn-cli") or _which("proton-vpn-cli")
    if proton:
        try:
            r = subprocess.run([proton, "status"], timeout=4,
                               capture_output=True, text=True)
            connected = "Connected" in (r.stdout or "") or "connected to" in (r.stdout or "").lower()
            return {"backend": "protonvpn", "bin": proton, "connected": connected, "installed": True}
        except Exception:
            return {"backend": "protonvpn", "bin": proton, "connected": False, "installed": True}
    nmcli = _which("nmcli")
    if nmcli:
        try:
            r = subprocess.run([nmcli, "-t", "-f", "NAME,TYPE,STATE", "con", "show", "--active"],
                               timeout=3, capture_output=True, text=True)
            for line in (r.stdout or "").splitlines():
                if "proton" in line.lower() and (":vpn:" in line or ":wireguard:" in line):
                    return {"backend": "nmcli", "bin": nmcli, "connected": True, "installed": True}
        except Exception:
            pass
        return {"backend": "nmcli", "bin": nmcli, "connected": False, "installed": True}
    return {"backend": None, "bin": None, "connected": False, "installed": False}


def vpn_toggle() -> None:
    state = vpn_probe()
    if not state["installed"]:
        subprocess.Popen([
            "notify-send", "-u", "critical",
            "Flow State VPN",
            "ProtonVPN is not installed yet. Run:\n  sudo bash /home/will/flow-state-distro/scripts/10-vpn.sh",
        ])
        return
    if state["backend"] == "protonvpn":
        if state["connected"]:
            subprocess.Popen([state["bin"], "disconnect"])
        else:
            subprocess.Popen([state["bin"], "connect", "--fastest", "-p", "wireguard"])
    elif state["backend"] == "nmcli":
        if state["connected"]:
            subprocess.run([state["bin"], "con", "down", "id", "protonvpn"], check=False)
        else:
            subprocess.run([state["bin"], "con", "up", "id", "protonvpn"], check=False)


@dataclass
class NetInfo:
    local_ip: str = ""
    public_ip: str = ""
    gateway: str = ""
    dns: list[str] = field(default_factory=list)
    interfaces: list[dict] = field(default_factory=list)  # {name, mac, ipv4}
    wifi_ssid: str = ""
    wifi_signal: str = ""
    ping_ms: float | None = None
    download_mbps: float | None = None
    upload_mbps: float | None = None
    speedtest_server: str = ""
    speedtest_at: str = ""
    speedtest_running: bool = False


def _run(cmd: list[str], timeout: float = 4) -> str:
    try:
        return subprocess.check_output(cmd, text=True, timeout=timeout, stderr=subprocess.DEVNULL)
    except (subprocess.SubprocessError, FileNotFoundError):
        return ""


def gather() -> NetInfo:
    ni = NetInfo()

    # Local IP: first non-loopback ipv4 with a default route.
    ip_route = _run(["ip", "route"])
    for line in ip_route.splitlines():
        parts = line.split()
        if parts and parts[0] == "default":
            # e.g. "default via 192.168.1.1 dev enp0s31f6 proto dhcp metric 100"
            if "via" in parts:
                ni.gateway = parts[parts.index("via") + 1]
            if "dev" in parts:
                dev = parts[parts.index("dev") + 1]
                # Find IPv4 of that dev.
                addr = _run(["ip", "-4", "-o", "addr", "show", "dev", dev])
                m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", addr)
                if m:
                    ni.local_ip = m.group(1)
            break

    # All non-loopback interfaces with MAC and IPv4.
    interfaces_raw = _run(["ip", "-o", "link", "show"])
    ipv4_raw = _run(["ip", "-o", "-4", "addr", "show"])
    ipv4_map: dict[str, str] = {}
    for line in ipv4_raw.splitlines():
        m = re.match(r"\d+:\s+(\S+)\s+inet (\d+\.\d+\.\d+\.\d+)", line)
        if m:
            ipv4_map[m.group(1)] = m.group(2)
    for line in interfaces_raw.splitlines():
        m = re.match(r"\d+:\s+(\S+):.*link/ether\s+([0-9a-f:]+)", line)
        if m and m.group(1) != "lo":
            iface = m.group(1)
            ni.interfaces.append({
                "name": iface,
                "mac": m.group(2),
                "ipv4": ipv4_map.get(iface, ""),
            })

    # DNS servers from resolvectl.
    dns_raw = _run(["resolvectl", "dns"])
    for line in dns_raw.splitlines():
        m = re.search(r":\s+(.+)$", line)
        if m and m.group(1).strip():
            for server in m.group(1).split():
                if server not in ni.dns:
                    ni.dns.append(server)

    # WiFi status (SSID + signal) via nmcli.
    wifi = _run(["nmcli", "-t", "-f", "active,ssid,signal", "dev", "wifi"])
    for line in wifi.splitlines():
        parts = line.split(":")
        if parts and parts[0] == "yes" and len(parts) >= 3:
            ni.wifi_ssid = parts[1]
            ni.wifi_signal = f"{parts[2]}%"
            break

    return ni


def fetch_public_ip() -> str:
    for url in ("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com"):
        out = _run(["curl", "-sS", "--max-time", str(PUBLIC_IP_TIMEOUT), url])
        out = out.strip()
        if re.match(r"^\d+\.\d+\.\d+\.\d+$", out):
            return out
    return ""


def run_speedtest() -> tuple[float | None, float | None, float | None, str]:
    """Return (download_mbps, upload_mbps, ping_ms, server_name)."""
    raw = _run(["speedtest-cli", "--json"], timeout=SPEEDTEST_TIMEOUT)
    if not raw:
        return None, None, None, ""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None, None, None, ""
    d = data.get("download")
    u = data.get("upload")
    p = data.get("ping")
    srv = data.get("server", {}) or {}
    return (
        (d / 1_000_000) if d is not None else None,
        (u / 1_000_000) if u is not None else None,
        float(p) if p is not None else None,
        f"{srv.get('sponsor','')} · {srv.get('name','')} ({srv.get('country','')})".strip(" ·"),
    )


class DetailWindow(Gtk.Window):
    def __init__(self, info: NetInfo, on_close):
        super().__init__(title="Flow State Network")
        self.info = info
        self.on_close = on_close
        self.set_default_size(560, 620)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_icon_name(ICON_NAME)
        self.connect("destroy", self._on_destroy)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(outer)

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.set_title("Flow State Network")
        self.set_titlebar(header)

        scroll = Gtk.ScrolledWindow()
        scroll.set_hexpand(True); scroll.set_vexpand(True)
        outer.pack_start(scroll, True, True, 0)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        vbox.set_margin_top(16); vbox.set_margin_bottom(16)
        vbox.set_margin_start(20); vbox.set_margin_end(20)
        scroll.add(vbox)

        # Speed test tile at the top.
        speed_frame = Gtk.Frame(label="Speed")
        vbox.pack_start(speed_frame, False, False, 0)
        speed_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        speed_box.set_margin_top(10); speed_box.set_margin_bottom(10)
        speed_box.set_margin_start(14); speed_box.set_margin_end(14)
        speed_frame.add(speed_box)
        big = Gtk.Label()
        big.set_markup("<span size='xx-large' weight='bold'>starting…</span>")
        big.set_xalign(0)
        speed_box.pack_start(big, False, False, 0)
        self.speed_big = big
        self.speed_meta = Gtk.Label(xalign=0)
        self.speed_meta.set_line_wrap(True)
        speed_box.pack_start(self.speed_meta, False, False, 0)
        speed_btn_row = Gtk.Box(spacing=8)
        self.rerun_btn = Gtk.Button(label="▶ Run again")
        self.rerun_btn.connect("clicked", lambda _b: self._start_speedtest())
        speed_btn_row.pack_start(self.rerun_btn, False, False, 0)
        speed_box.pack_start(speed_btn_row, False, False, 0)

        # Network info grid.
        info_frame = Gtk.Frame(label="Network")
        vbox.pack_start(info_frame, False, False, 0)
        grid = Gtk.Grid(column_spacing=14, row_spacing=6)
        grid.set_margin_top(10); grid.set_margin_bottom(10)
        grid.set_margin_start(14); grid.set_margin_end(14)
        info_frame.add(grid)
        self._grid = grid
        self._grid_rows: dict[str, Gtk.Widget] = {}
        for row, (label, key) in enumerate([
            ("Local IP", "local_ip"),
            ("Public IP", "public_ip"),
            ("Gateway", "gateway"),
            ("DNS", "dns_str"),
            ("WiFi", "wifi_str"),
        ]):
            lbl = Gtk.Label(xalign=0)
            lbl.set_markup(f"<span size='small' weight='bold'>{label}</span>")
            grid.attach(lbl, 0, row, 1, 1)
            val = Gtk.Label(xalign=0, selectable=True)
            grid.attach(val, 1, row, 1, 1)
            self._grid_rows[key] = val

        # Interfaces list.
        ifaces_frame = Gtk.Frame(label="Interfaces")
        vbox.pack_start(ifaces_frame, False, False, 0)
        self.ifaces_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.ifaces_box.set_margin_top(10); self.ifaces_box.set_margin_bottom(10)
        self.ifaces_box.set_margin_start(14); self.ifaces_box.set_margin_end(14)
        ifaces_frame.add(self.ifaces_box)

        # Action row.
        action_row = Gtk.Box(spacing=8)
        vbox.pack_start(action_row, False, False, 0)
        wifi_btn = Gtk.Button(label="📶 Choose a WiFi")
        wifi_btn.connect("clicked", lambda _b: subprocess.Popen(["nm-connection-editor"]))
        action_row.pack_start(wifi_btn, False, False, 0)
        copy_btn = Gtk.Button(label="📋 Copy report")
        copy_btn.connect("clicked", lambda _b: self._copy_report())
        action_row.pack_start(copy_btn, False, False, 0)

        self._render_info()
        self.show_all()
        self._start_speedtest()

    def _on_destroy(self, *_):
        self.on_close()

    def update_info(self, info: NetInfo) -> None:
        self.info = info
        self._render_info()

    def _render_info(self) -> None:
        i = self.info
        dns_str = ", ".join(i.dns) if i.dns else "(none)"
        wifi_str = f"{i.wifi_ssid or '(ethernet)'} " + (f"· {i.wifi_signal}" if i.wifi_signal else "")
        for key, text in (
            ("local_ip", i.local_ip or "(unknown)"),
            ("public_ip", i.public_ip or "(fetching…)"),
            ("gateway", i.gateway or "(unknown)"),
            ("dns_str", dns_str),
            ("wifi_str", wifi_str),
        ):
            self._grid_rows[key].set_text(text)
        # Interfaces block.
        for child in list(self.ifaces_box.get_children()):
            self.ifaces_box.remove(child)
        for iface in i.interfaces:
            row = Gtk.Label(xalign=0, selectable=True)
            ipv4 = iface["ipv4"] or "(no IPv4)"
            row.set_markup(
                f"<b>{iface['name']}</b>   MAC {iface['mac']}   {ipv4}"
            )
            self.ifaces_box.pack_start(row, False, False, 0)
        self.ifaces_box.show_all()

    def _start_speedtest(self) -> None:
        self.rerun_btn.set_sensitive(False)
        self.speed_big.set_markup("<span size='xx-large' weight='bold'>running…</span>")
        self.speed_meta.set_text("connecting to the nearest server")

        def worker():
            d, u, p, srv = run_speedtest()
            def apply():
                if d is None:
                    self.speed_big.set_markup("<span size='large' color='#c94a4a'>speed test failed</span>")
                    self.speed_meta.set_text("Is speedtest-cli installed and the network up?")
                else:
                    self.speed_big.set_markup(
                        f"<span size='xx-large' weight='bold'>{d:.1f} ↓ / {u:.1f} ↑ Mbps</span>"
                    )
                    self.speed_meta.set_text(
                        f"ping {p:.0f} ms   ·   {srv or 'ookla'}"
                    )
                self.rerun_btn.set_sensitive(True)
            GLib.idle_add(apply)

        threading.Thread(target=worker, daemon=True).start()

    def _copy_report(self) -> None:
        i = self.info
        lines = [
            "Flow State Network",
            f"Local IP    {i.local_ip}",
            f"Public IP   {i.public_ip}",
            f"Gateway     {i.gateway}",
            f"DNS         {', '.join(i.dns)}",
            f"WiFi        {i.wifi_ssid or 'ethernet'}  {i.wifi_signal}",
            "",
            "Interfaces:",
        ]
        for iface in i.interfaces:
            lines.append(f"  {iface['name']:12}  MAC {iface['mac']}  {iface['ipv4']}")
        text = "\n".join(lines) + "\n"
        clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        clip.set_text(text, -1)
        clip.store()


class NetTray:
    def __init__(self):
        self.info = NetInfo()
        self.detail: DetailWindow | None = None
        self.indicator = AppIndicator3.Indicator.new(
            "flow-state-network",
            ICON_NAME,
            AppIndicator3.IndicatorCategory.SYSTEM_SERVICES,
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self.indicator.set_title("Flow State Network")
        self.menu = Gtk.Menu()
        self._menu_items: list[Gtk.MenuItem] = []
        self._rebuild_menu()
        self.indicator.set_menu(self.menu)

        self._refresh_sync()
        # Public IP might be slow; do it in the background once, then
        # refresh with the rest on a timer.
        threading.Thread(target=self._fetch_pub_once, daemon=True).start()
        GLib.timeout_add(REFRESH_MS, self._tick)

    def _fetch_pub_once(self):
        pub = fetch_public_ip()
        def apply():
            self.info.public_ip = pub
            self._rebuild_menu()
            if self.detail is not None:
                self.detail.update_info(self.info)
        GLib.idle_add(apply)

    def _tick(self) -> bool:
        self._refresh_sync()
        return True

    def _refresh_sync(self) -> None:
        new = gather()
        # Preserve public IP + speedtest across refreshes (they don't come
        # from gather()).
        new.public_ip = self.info.public_ip
        new.download_mbps = self.info.download_mbps
        new.upload_mbps = self.info.upload_mbps
        new.ping_ms = self.info.ping_ms
        new.speedtest_server = self.info.speedtest_server
        self.info = new
        self._rebuild_menu()
        # Label + icon flip based on WiFi vs. Ethernet vs. offline.
        vpn = vpn_probe()
        vpn_prefix = "🛡 " if vpn["connected"] else ""
        if new.wifi_ssid:
            head = f"{vpn_prefix}📶 {new.wifi_ssid}"
            self.indicator.set_icon_full(ICON_NAME_WIFI, "wifi")
        elif new.local_ip:
            head = f"{vpn_prefix}Net {new.local_ip}"
            self.indicator.set_icon_full(ICON_NAME, "wired")
        else:
            head = "⚠ offline"
            self.indicator.set_icon_full(ICON_NAME_OFFLINE, "offline")
        self.indicator.set_label(head, "flow-state-network")
        if self.detail is not None:
            self.detail.update_info(self.info)

    def _rebuild_menu(self) -> None:
        for it in self._menu_items:
            self.menu.remove(it)
        self._menu_items.clear()

        i = self.info

        def _row(label: str, value: str) -> Gtk.MenuItem:
            item = Gtk.MenuItem(label=f"{label}   {value}")
            item.set_sensitive(False)
            return item

        header = Gtk.MenuItem(label="Flow State Network")
        header.set_sensitive(False)
        self._append(header)
        self._append(Gtk.SeparatorMenuItem())
        self._append(_row("Local IP", i.local_ip or "(unknown)"))
        self._append(_row("Public IP", i.public_ip or "(fetching…)"))
        self._append(_row("Gateway", i.gateway or "(unknown)"))
        self._append(_row("DNS", ", ".join(i.dns) if i.dns else "(none)"))
        if i.wifi_ssid:
            self._append(_row("WiFi", f"{i.wifi_ssid}  {i.wifi_signal}"))
        for iface in i.interfaces[:4]:
            ipv4 = iface["ipv4"] or "—"
            self._append(_row(iface["name"], f"MAC {iface['mac']}  {ipv4}"))

        self._append(Gtk.SeparatorMenuItem())

        detail = Gtk.MenuItem(label="🔍 Open detail panel (with speed test)")
        detail.connect("activate", lambda _i: self._open_detail())
        self._append(detail)

        wifi = Gtk.MenuItem(label="📶 Choose a WiFi…")
        wifi.connect("activate", lambda _i: subprocess.Popen(["nm-connection-editor"]))
        self._append(wifi)

        # ProtonVPN toggle lives here — this tray is about networking, so
        # the VPN belongs to it, not to the DSIO/AI tray.
        vpn = vpn_probe()
        if not vpn["installed"]:
            vpn_item = Gtk.MenuItem(label="🛡 Install ProtonVPN…")
        elif vpn["connected"]:
            vpn_item = Gtk.MenuItem(label="🛡 Disconnect ProtonVPN")
        else:
            vpn_item = Gtk.MenuItem(label="🛡 Connect ProtonVPN (fastest)")
        vpn_item.connect("activate", lambda _i: vpn_toggle())
        self._append(vpn_item)

        copy = Gtk.MenuItem(label="📋 Copy network report")
        copy.connect("activate", lambda _i: self._copy_from_menu())
        self._append(copy)

        quit_i = Gtk.MenuItem(label="✕ Quit")
        quit_i.connect("activate", lambda _i: Gtk.main_quit())
        self._append(quit_i)

        self.menu.show_all()

    def _append(self, item: Gtk.MenuItem) -> None:
        self.menu.append(item)
        self._menu_items.append(item)

    def _open_detail(self) -> None:
        if self.detail is not None:
            self.detail.present()
            return
        self.detail = DetailWindow(self.info, on_close=self._on_detail_closed)

    def _on_detail_closed(self) -> None:
        self.detail = None

    def _copy_from_menu(self) -> None:
        i = self.info
        text = (
            "Flow State Network\n"
            f"Local IP    {i.local_ip}\n"
            f"Public IP   {i.public_ip}\n"
            f"Gateway     {i.gateway}\n"
            f"DNS         {', '.join(i.dns)}\n"
            f"WiFi        {i.wifi_ssid or 'ethernet'}  {i.wifi_signal}\n"
        )
        subprocess.run(["xclip", "-selection", "clipboard"], input=text, text=True, check=False)


def main() -> int:
    _ = NetTray()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
