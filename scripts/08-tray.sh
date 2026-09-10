#!/usr/bin/env bash
# 08 — Flow State DSIO tray indicator. Puts a Claude/Codex/Ollama status
# icon into the top panel (via Ubuntu's AppIndicator extension), same
# spirit as the Windows tray monitor.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN="$HOME/.local/bin/flow-state-tray"
AUTOSTART_DIR="$HOME/.config/autostart"
DESKTOP="$AUTOSTART_DIR/flow-state-tray.desktop"

mkdir -p "$HOME/.local/bin" "$AUTOSTART_DIR"
install -m 0755 "$HERE/flow-state-tray.py" "$BIN"

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Flow State — DSIO tray
Comment=Claude, Codex, and Ollama quota indicator in the top panel
Exec=$BIN
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=false
StartupNotify=false
EOF

# Launch now if not already running.
if pgrep -f "python3 $BIN\$" >/dev/null 2>&1; then
  echo "  tray already running"
else
  DISPLAY="${DISPLAY:-:0}" nohup "$BIN" >/dev/null 2>&1 & disown
  echo "  launched flow-state-tray in current session"
fi
