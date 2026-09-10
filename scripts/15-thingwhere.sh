#!/usr/bin/env bash
# 15 — Thingwhere-style natural-language app launcher.
#
# Thingwhere is a Windows launcher: hit a hotkey, describe what you want
# in plain English, get the installed program that does it. It's not
# ready for Linux yet, so Flow State ships Ulauncher configured to
# behave the same way — global hotkey (Super+Space), fuzzy search over
# every installed .desktop, plugin ecosystem for calculator / dictionary
# / snippets / web-search / etc.
#
# The Thingwhere source is copied to /opt/thingwhere-src so we can port
# its natural-language matching engine to Linux in a future release.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -eq 0 ]]; then
  echo "==> System-side Thingwhere-style launcher"
  # Ulauncher isn't in Noble's default repos; add its official PPA.
  if ! grep -rq "agornostal/ulauncher" /etc/apt/sources.list.d/ 2>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
    add-apt-repository -y ppa:agornostal/ulauncher 2>&1 | tail -3
    apt-get update -qq
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ulauncher \
    2>&1 | tail -3

  # Bundle the Thingwhere source for the future Linux port.
  if [[ -d "$HOME/thingwhere-src" ]]; then
    install -d -m 0755 /opt/thingwhere-src
    rsync -a --exclude='.git' --exclude='target/' \
      "$HOME/thingwhere-src/" /opt/thingwhere-src/ 2>&1 | tail -1 || true
  fi
  exit 0
fi

# User side: enable Ulauncher autostart + rebind default hotkey to
# Super+Space (like Alfred/Spotlight/Wox) instead of Ctrl+Space.
install -d -m 0755 "$HOME/.config/autostart" "$HOME/.config/ulauncher"
cat > "$HOME/.config/autostart/ulauncher.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Ulauncher
Comment=Application launcher (Super+Space)
Exec=ulauncher --hide-window
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
StartupNotify=false
EOF

# Ulauncher stores its hotkey in settings.json. Seed it so first launch
# uses Super+Space.
cat > "$HOME/.config/ulauncher/settings.json" <<'EOF'
{
  "clear-previous-query": true,
  "grab-mouse-pointer": false,
  "hotkey-show-app": "<Super>space",
  "render-on-screen": "mouse-pointer-monitor",
  "show-indicator-icon": true,
  "show-recent-apps": "3",
  "terminal-command": "",
  "theme-name": "dark"
}
EOF

# Launch now if it's not already running.
if ! pgrep -x ulauncher >/dev/null 2>&1; then
  DISPLAY="${DISPLAY:-:0}" nohup ulauncher --hide-window >/dev/null 2>&1 & disown
fi

echo "  Ulauncher installed. Press Super+Space to open the launcher."
echo "  (Thingwhere source cached at /opt/thingwhere-src for the future Linux port)"
