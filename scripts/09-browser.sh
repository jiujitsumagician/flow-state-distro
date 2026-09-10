#!/usr/bin/env bash
# 09 — Flow State Browser. Installs the Chrome-wrapper launcher and its
# desktop entry so it shows up alongside Firefox/Chrome in the launcher
# with the Flow State icon. The launcher itself uses the system's
# google-chrome-stable if installed, or falls back to chromium.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -d -m 0755 "$HOME/.local/bin"
install -m 0755 "$HERE/flow-state-browser" "$HOME/.local/bin/flow-state-browser"

install -d -m 0755 "$HOME/.local/share/applications"
install -m 0644 "$HERE/flow-state-browser.desktop" \
                "$HOME/.local/share/applications/flow-state-browser.desktop"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

# Ensure google-chrome is installed; if not, offer to install it via Google's
# apt repo. Chromium via snap is the fallback if Chrome is out of reach.
if ! command -v google-chrome-stable >/dev/null 2>&1 && ! command -v chromium >/dev/null 2>&1; then
  echo "  neither google-chrome-stable nor chromium is installed"
  echo "  install one to use flow-state-browser: sudo apt install chromium-browser"
fi

echo "  Flow State Browser installed. Launch: flow-state-browser  (or the launcher entry)"
