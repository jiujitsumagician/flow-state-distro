#!/usr/bin/env bash
# 02 — Node.js. DSIO harness declares engines >=24, but currently builds on
# 22 as well; we install Node 24 LTS (NodeSource) if node is missing or
# below 22, otherwise we leave the system Node alone.
set -euo pipefail

need_install() {
  if ! command -v node >/dev/null 2>&1; then return 0; fi
  local ver
  ver="$(node -v | sed 's/^v//;s/\..*$//')"
  # If Node < 22, install NodeSource 24.
  (( ver < 22 ))
}

if need_install; then
  echo "  installing Node 24 LTS from NodeSource"
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
  sudo apt-get install -y nodejs
else
  echo "  Node $(node -v) already present; leaving it alone"
fi

# Ensure global npm binaries in the user's PATH via ~/.local/bin isn't needed
# when npm's global prefix is /usr/... — but if npm ever gets reconfigured to
# ~/.npm-global we want ~/.local/bin on PATH. That's already true on Ubuntu.
