# Flow State

A Will-flavored Ubuntu 24.04 remix. Everything below ships built-in.

**Install on a fresh Ubuntu 24.04 machine:**

```bash
curl -fsSL https://dsio.io/install.sh | bash
```

Idempotent — re-run to update.

## What ships

- **DSIO agent harness** — Claude, Codex, Ollama, and the DSIO multi-AI
  router preinstalled. In any folder in any terminal, type `dsio`.
- **System-wide middle-click autoscroll** — Windows-style click-and-glide.
  Middle-click on anything, move the mouse, page scrolls at a speed
  proportional to how far you moved. Any next click exits. Fast tap
  still passes through as a normal middle-click (paste, open-link-in-
  new-tab).
- **Per-monitor sleep buttons** — a 💤 in the bottom-right corner of
  every monitor, plus **Win+Esc** to sleep all displays. Any mouse or
  keyboard input wakes them. Buttons hide the moment a window covers
  them, come back the moment the desktop is visible.
- **AI status tray** (beaker icon in the top panel) — Claude Max
  quota, Codex health, Ollama status, refresh, and open-DSIO-in-a-
  terminal.
- **Network tray** (wired / WiFi / offline icon in the top panel) —
  local IP, public IP, gateway, DNS, per-interface MAC + IPv4, current
  WiFi SSID + signal. Menu item opens a detail window that immediately
  runs a speedtest-cli speed test, and includes a "Choose a WiFi"
  launcher and a ProtonVPN connect/disconnect toggle.
- **Flow State Browser** — Google Chrome with a pinned Flow State
  profile, `session.restore_on_startup=1` baked in so tabs *always*
  come back, plus every Chrome feature intact (incognito, Google Sync,
  extensions).
- **ProtonVPN** — installed via ProtonVPN's official APT repo; the
  Network tray's shield icon connects and disconnects.
- **File-manager thumbnails** — `ffmpegthumbnailer`, `heif`, `webp`,
  `libavcodec-extra`, and the full gstreamer plugin set installed;
  Nautilus preferences set to `show-image-thumbnails=always` with a
  512 MB limit so phone videos still get thumbs.
- **Phone integration** — GSConnect (GNOME port of KDE Connect) enabled
  for Android pairing. Shared clipboard, SMS, notifications, file
  send, media control. Native Flow State bridge (based on `tether`'s
  emoji-pairing UX) is Phase 2.
- **Nine built-in Flow State wallpapers** — Stripe (default), Horizon,
  Crystal, Glass, Grid, Drift, Aurora, Nebula, Ember. All appear in
  Settings → Appearance → Background alongside the Ubuntu stock ones.

## Repo layout

```
flow-state-distro/
  bootstrap.sh              # top-level, calls the two below
  bootstrap-system.sh       # root layer (apt, node, ollama, autoscroll, vpn, thumbnails)
  bootstrap-user.sh         # user layer (harness, dsio, browser, trays, branding)
  scripts/
    01-apt-packages.sh
    02-nodejs.sh
    03-dsio-harness.sh
    04-autoscroll.sh
    05-branding.sh          # wallpapers + accent + avatar
    06-terminal-welcome.sh
    07-monitor-sleep.sh
    08-tray.sh              # AI/DSIO status tray
    09-browser.sh           # Flow State Browser
    10-vpn.sh               # ProtonVPN (root)
    11-thumbnails.sh
    12-network.sh           # Network tray + speed test panel
    autoscrolld.py                # evdev+uinput autoscroll daemon
    flow-state-autoscroll.service
    install-autoscroll.sh         # sudo installer for the daemon
    flow-state-monitor-sleep.py
    flow-state-tray.py            # DSIO/AI tray
    flow-state-network.py         # Network tray + detail panel
    flow-state-browser            # Chrome wrapper
    flow-state-browser.desktop
    build-iso.sh                  # Phase 2: scripted ISO build
  branding/
    wallpapers/*.{jpg,png}        # 9 official Flow State wallpapers
    icons/flow-state-*.png        # 22–256 px for the hicolor theme
    flowstate-logo.png            # from jiujitsumagician/flowstate
  docs/
    specs/2026-09-09-flow-state-distro-design.md
```

## Verify after install

```bash
# DSIO
dsio status

# Autoscroll — should print "active"
systemctl is-active flow-state-autoscroll.service
xinput list | grep flow-state-autoscroll

# Trays — top panel should show a beaker (AI) + a network icon
pgrep -af "flow-state-(tray|network|monitor-sleep)"

# Browser
flow-state-browser about:blank
```

## Update

Re-run the one-liner:

```bash
curl -fsSL https://dsio.io/install.sh | bash
```

Or, if you already have the repo:

```bash
cd ~/flow-state-distro && git pull && bash bootstrap.sh
```

## Design

Full architecture spec (Codex-reviewed) at
[`docs/specs/2026-09-09-flow-state-distro-design.md`](docs/specs/2026-09-09-flow-state-distro-design.md).

## License

Personal remix; no license file yet. Ask before redistributing the
branding assets (wallpapers, icons).
