#!/usr/bin/env bash
# Flow State bootstrap — turn a fresh Ubuntu 24.04 install into Flow State.
#
# Idempotent. Safe to re-run. Each step reads the current state and no-ops
# when nothing needs to change.
#
#     bash bootstrap.sh                          # everything
#     bash bootstrap.sh 03-dsio-harness          # just one step
#     FLOWSTATE_ONLY="03-dsio-harness 04-autoscroll" bash bootstrap.sh
#
# Steps that need root will re-invoke themselves under sudo. Everything else
# runs as $USER.

set -euo pipefail

FS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FS_SCRIPTS="$FS_ROOT/scripts"
FS_LOG="$FS_ROOT/bootstrap.log"

# Colors for the banner. Flow State blue (approx).
BLUE=$'\033[38;2;24;95;165m'
DIM=$'\033[2m'
RESET=$'\033[0m'
BOLD=$'\033[1m'

log()   { printf '%s%s%s\n' "$DIM" "$*" "$RESET" | tee -a "$FS_LOG"; }
say()   { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*" | tee -a "$FS_LOG"; }
title() { printf '\n%s%s  Flow State bootstrap%s  —  %s\n\n' "$BOLD" "$BLUE" "$RESET" "$*"; }

require_ubuntu_24_04() {
  if [[ ! -r /etc/os-release ]]; then
    echo "This installer needs /etc/os-release; are you on Ubuntu?" >&2; exit 1
  fi
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    echo "Flow State bootstrap requires Ubuntu 24.04. Detected: ${PRETTY_NAME:-unknown}" >&2
    exit 1
  fi
}

# Steps live as separate scripts under scripts/. Numeric prefix determines
# order. Any script matching FLOWSTATE_ONLY (space-separated tokens) is
# selected; empty = all.
run_step() {
  local script="$1"
  local name
  name="$(basename "$script")"
  if [[ -n "${FLOWSTATE_ONLY:-}" ]]; then
    local match=0
    for token in $FLOWSTATE_ONLY; do
      [[ "$name" == *"$token"* ]] && match=1
    done
    (( match )) || { log "  skip $name"; return 0; }
  fi
  say "$name"
  bash "$script" 2>&1 | tee -a "$FS_LOG"
}

main() {
  mkdir -p "$(dirname "$FS_LOG")"
  : > "$FS_LOG"
  title "Ubuntu 24.04 → Flow State"
  require_ubuntu_24_04

  local args=("$@")
  if (( ${#args[@]} > 0 )); then
    export FLOWSTATE_ONLY="${args[*]}"
  fi

  local steps=(
    "$FS_SCRIPTS/01-apt-packages.sh"
    "$FS_SCRIPTS/02-nodejs.sh"
    "$FS_SCRIPTS/03-dsio-harness.sh"
    "$FS_SCRIPTS/04-autoscroll.sh"
    "$FS_SCRIPTS/05-branding.sh"
    "$FS_SCRIPTS/06-terminal-welcome.sh"
  )

  for step in "${steps[@]}"; do
    if [[ ! -x "$step" ]]; then
      say "chmod +x $step"; chmod +x "$step"
    fi
    run_step "$step"
  done

  printf '\n%s  Flow State is ready.%s  Open a new terminal, type: %sdsio%s\n\n' \
    "$BLUE" "$RESET" "$BOLD" "$RESET"
}

main "$@"
