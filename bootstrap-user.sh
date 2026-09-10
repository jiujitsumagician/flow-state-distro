#!/usr/bin/env bash
# Flow State bootstrap — USER layer.
#
# Everything that runs as the login user: DSIO harness clone/build, `dsio`
# shim on PATH, MCP registration, user-scope branding (wallpaper, accent,
# ~/.face), first-login welcome. Same script runs at first-login on a Flow
# State ISO install, so it must be idempotent.
#
#     bash bootstrap-user.sh
#
# Refuses to run as root; must be the login user.

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "bootstrap-user.sh must run as your login user, not root." >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HERE/scripts"

BLUE=$'\033[38;2;24;95;165m'; RESET=$'\033[0m'
say() { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }

say "03: DSIO harness (clone / build / shim / MCP)"
bash "$SCRIPTS/03-dsio-harness.sh"

# Browser-level fallbacks are OFF by default. Codex flagged two overlapping
# autoscroll behaviors (system daemon + browser prefs) as a debug hazard.
# Set FLOWSTATE_BROWSER_AUTOSCROLL=1 to re-enable the browser writes.
if [[ "${FLOWSTATE_BROWSER_AUTOSCROLL:-0}" == "1" ]]; then
  say "04: browser-level autoscroll fallbacks (opt-in)"
  bash "$SCRIPTS/04-autoscroll.sh"
else
  say "04: browser-level autoscroll fallbacks skipped (daemon covers this)"
fi

say "05: user branding (wallpaper, accent, ~/.face)"
bash "$SCRIPTS/05-branding.sh"

say "06: first-login welcome"
bash "$SCRIPTS/06-terminal-welcome.sh"

say "user layer complete. Open a fresh terminal and type: dsio"
