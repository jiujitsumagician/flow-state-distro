#!/usr/bin/env bash
# 06 — First-login welcome: opens a GNOME Terminal, prints a Flow State
# banner, and drops the user at a shell with `dsio login` suggested. Fires
# exactly once per user; a marker file prevents repeats.
set -euo pipefail

MARKER="$HOME/.config/flow-state-welcomed"
AUTOSTART_DIR="$HOME/.config/autostart"
DESKTOP="$AUTOSTART_DIR/flow-state-welcome.desktop"
SCRIPT="$HOME/.local/share/flow-state/welcome.sh"

mkdir -p "$AUTOSTART_DIR" "$(dirname "$SCRIPT")"

cat >"$SCRIPT" <<'SH'
#!/usr/bin/env bash
MARKER="$HOME/.config/flow-state-welcomed"
if [[ -f "$MARKER" ]]; then exit 0; fi
touch "$MARKER"

BLUE=$'\033[38;2;24;95;165m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
cat <<BANNER
${BLUE}${BOLD}
  ██████    Flow State
  ██  ██    ${RESET}${BLUE}where else would you go?${RESET}
${BLUE}${BOLD}  ██████${RESET}

  You are running the Flow State agent environment.

  1. ${BOLD}dsio login${RESET}   -   sign in with GitHub to restore keys + model logins
  2. ${BOLD}dsio${RESET}         -   start a DSIO session in this folder

  Middle-click and drag to scroll anywhere.
BANNER

exec bash --login
SH
chmod +x "$SCRIPT"

cat >"$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Flow State Welcome
Comment=Runs once, opens a terminal with the Flow State banner
Exec=gnome-terminal --title="Flow State" -- bash -c "$SCRIPT"
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=false
StartupNotify=false
EOF

echo "  welcome autostart installed (fires once on next login)"
