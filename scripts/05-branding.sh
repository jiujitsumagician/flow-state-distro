#!/usr/bin/env bash
# 05 — Flow State branding at the user level. System-level branding (Plymouth,
# GRUB, /etc/os-release, GDM) lands during Phase 2 (ISO build), not here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAND_DIR="$(cd "$HERE/../branding" && pwd)"
BG_DIR="$HOME/.local/share/backgrounds/flow-state"

mkdir -p "$BG_DIR"

# Wallpapers: for v1, if we have no bespoke wallpaper yet, drop the logo in
# the center on a Flow State blue field. ImageMagick handles this.
if command -v convert >/dev/null 2>&1 && [[ -f "$BRAND_DIR/flowstate-logo.png" ]]; then
  for res in "1920x1080" "2560x1440" "3840x2160"; do
    out="$BG_DIR/flow-state-$res.png"
    [[ -f "$out" ]] && continue
    convert -size "$res" gradient:"#185FA5-#0c3a66" \
      \( "$BRAND_DIR/flowstate-logo.png" -resize 500x500 \) \
      -gravity center -compose over -composite \
      "$out"
    echo "  generated $out"
  done
fi

# GNOME wallpaper (light + dark keys). picture-uri accepts file:// URIs.
if command -v gsettings >/dev/null 2>&1; then
  wp="$BG_DIR/flow-state-2560x1440.png"
  if [[ -f "$wp" ]]; then
    gsettings set org.gnome.desktop.background picture-uri "file://$wp"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$wp"
    gsettings set org.gnome.desktop.background picture-options "zoom"
    echo "  wallpaper set"
  fi
  # Accent color (GNOME 46+): "blue" is the closest built-in accent.
  gsettings set org.gnome.desktop.interface accent-color "blue" 2>/dev/null || true
fi

# User avatar for GDM. This asks accountsservice which requires an authorized
# helper; on modern GNOME the file at ~/.face is honored on next login.
if [[ -f "$BRAND_DIR/flowstate-logo.png" ]]; then
  cp -f "$BRAND_DIR/flowstate-logo.png" "$HOME/.face"
  echo "  ~/.face updated"
fi
