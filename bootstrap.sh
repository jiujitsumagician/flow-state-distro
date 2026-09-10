#!/usr/bin/env bash
# Flow State bootstrap — top-level entrypoint.
#
# Turns a fresh Ubuntu 24.04 install into Flow State by running the two
# layers in order: system (needs root) then user (login user).
#
#     bash bootstrap.sh
#
# Handles the sudo-elevation for the system layer itself. Safe to re-run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -eq 0 ]]; then
  echo "Run bootstrap.sh as your login user; it will sudo when it needs to." >&2
  exit 1
fi

BLUE=$'\033[38;2;24;95;165m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
printf '\n%s%s  Flow State bootstrap%s  —  Ubuntu 24.04 → Flow State\n\n' \
  "$BOLD" "$BLUE" "$RESET"

echo "==> System layer (needs sudo)"
sudo bash "$HERE/bootstrap-system.sh"

echo
echo "==> User layer"
bash "$HERE/bootstrap-user.sh"

printf '\n%s  Flow State is ready.%s  Open a new terminal, type: %sdsio%s\n\n' \
  "$BLUE" "$RESET" "$BOLD" "$RESET"
