#!/usr/bin/env bash
# 12 — Flow State Network tray. Installs the tray widget and autostart.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN="$HOME/.local/bin/flow-state-network"
AUTOSTART="$HOME/.config/autostart/flow-state-network.desktop"

install -d -m 0755 "$HOME/.local/bin" "$HOME/.config/autostart"
install -m 0755 "$HERE/flow-state-network.py" "$BIN"

cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Flow State — Network
Comment=Local IP, public IP, DNS, WiFi, speed test — always in the top panel
Exec=$BIN
Icon=flow-state
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=false
StartupNotify=false
EOF

# Also make it launchable from the app grid.
APP="$HOME/.local/share/applications/flow-state-network.desktop"
install -d -m 0755 "$HOME/.local/share/applications"
cp "$AUTOSTART" "$APP"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

if pgrep -f "python3 $BIN\$" >/dev/null 2>&1; then
  echo "  flow-state-network already running"
else
  DISPLAY="${DISPLAY:-:0}" nohup "$BIN" >/dev/null 2>&1 & disown
  echo "  launched flow-state-network in current session"
fi
