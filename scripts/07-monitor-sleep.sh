#!/usr/bin/env bash
# 07 — Per-monitor sleep buttons. Installs the GTK app to the user's local
# bin, sets up an autostart entry so it appears on every login, and — if
# possible — binds Super+Shift+W to `xrandr` wake-all as a keyboard fallback.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN="$HOME/.local/bin/flow-state-monitor-sleep"
AUTOSTART_DIR="$HOME/.config/autostart"
DESKTOP="$AUTOSTART_DIR/flow-state-monitor-sleep.desktop"

mkdir -p "$HOME/.local/bin" "$AUTOSTART_DIR"
install -m 0755 "$HERE/flow-state-monitor-sleep.py" "$BIN"

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Flow State — monitor sleep buttons
Comment=Corner buttons to put individual displays to sleep
Exec=$BIN
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=false
StartupNotify=false
EOF

# GNOME custom keyboard shortcut for Super+Shift+W → wake all displays.
if command -v gsettings >/dev/null 2>&1; then
  BASE=org.gnome.settings-daemon.plugins.media-keys
  PATH0=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/flow-state-wake-all/
  cur=$(gsettings get "$BASE" custom-keybindings 2>/dev/null || echo "@as []")
  case "$cur" in
    *"$PATH0"*) ;;
    *)
      # Append our binding to the list.
      if [[ "$cur" == "@as []" || "$cur" == "[]" ]]; then
        gsettings set "$BASE" custom-keybindings "['$PATH0']"
      else
        gsettings set "$BASE" custom-keybindings "${cur%]}, '$PATH0']"
      fi
      ;;
  esac
  SCHEMA=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding
  gsettings set "$SCHEMA:$PATH0" name "Flow State — wake all displays"
  gsettings set "$SCHEMA:$PATH0" command "$BIN --wake-all-cli"
  gsettings set "$SCHEMA:$PATH0" binding "<Super><Shift>w"
fi

# Try to launch the app right now for the current session (so Will sees the
# button without needing to log out and back in).
if pgrep -fx "python3 $BIN" >/dev/null 2>&1; then
  echo "  already running"
else
  (DISPLAY="${DISPLAY:-:0}" nohup "$BIN" >/dev/null 2>&1 & disown) || true
  echo "  launched flow-state-monitor-sleep in current session"
fi
