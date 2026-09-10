#!/usr/bin/env bash
# 16 — Dock hover previews (Windows-11-style).
#
# Ubuntu Dock is dash-to-dock. Its `hover-action` schema key controls
# what happens when you hover on an icon that has open windows. Setting
# it to `show-previews` gives every dock icon Windows-11-style
# thumbnails of every open window when the mouse rests on it — click a
# thumbnail to raise that specific window.
#
# User-scope: gsettings tweaks are per-user; system-scope side sets a
# dconf default so every new Flow State user gets it out of the box.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "==> System-side dock preview default"
  install -d /etc/dconf/db/local.d
  cat > /etc/dconf/db/local.d/00-flow-state-dock <<'EOF'
[org/gnome/shell/extensions/dash-to-dock]
show-windows-preview=true
preview-size-scale=0.6
click-action='previews'
scroll-action='cycle-windows'
default-windows-preview-to-open=true
running-indicator-style='DOTS'
EOF
  dconf update 2>&1 | tail -3
  exit 0
fi

echo "==> Enabling dock hover previews for this user"
if command -v gsettings >/dev/null 2>&1; then
  S=org.gnome.shell.extensions.dash-to-dock
  gsettings set $S show-windows-preview true 2>/dev/null || true
  gsettings set $S preview-size-scale 0.6 2>/dev/null || true
  gsettings set $S click-action 'previews' 2>/dev/null || true
  gsettings set $S scroll-action 'cycle-windows' 2>/dev/null || true
  gsettings set $S default-windows-preview-to-open true 2>/dev/null || true
  echo "  hover a dock icon with multiple windows — Windows-11-style thumbnails appear"
fi
