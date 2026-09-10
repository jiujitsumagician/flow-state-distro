#!/usr/bin/env bash
# 05 — Flow State branding.
#
# Installs the three official Flow State wallpapers (Aurora, Nebula, Ember)
# both system-wide (available to every user in GNOME Settings > Background)
# and picks Aurora as the current user's active wallpaper.
#
# System-wide install needs sudo; if this script is not root and sudo is not
# available, it degrades to a user-only install. On the ISO chroot in
# Phase 2 this runs as root and the sudo prefix is a no-op.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAND_DIR="$(cd "$HERE/../branding" && pwd)"
WP_SRC="$BRAND_DIR/wallpapers"

SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
fi

# --- System-wide wallpaper install ---------------------------------------
if [[ -d "$WP_SRC" ]] && [[ -n "$SUDO" || $EUID -eq 0 ]]; then
  $SUDO install -d -m 0755 /usr/share/backgrounds/flow-state
  for w in flow-state-aurora.jpg flow-state-nebula.jpg flow-state-ember.jpg; do
    if [[ -f "$WP_SRC/$w" ]]; then
      $SUDO install -m 0644 "$WP_SRC/$w" /usr/share/backgrounds/flow-state/
    fi
  done

  $SUDO install -d -m 0755 /usr/share/gnome-background-properties
  $SUDO tee /usr/share/gnome-background-properties/flow-state-wallpapers.xml > /dev/null <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
  <wallpaper>
    <name>Flow State — Aurora</name>
    <filename>/usr/share/backgrounds/flow-state/flow-state-aurora.jpg</filename>
    <options>zoom</options>
    <pcolor>#0b1d3f</pcolor>
    <scolor>#0b1d3f</scolor>
    <shade_type>solid</shade_type>
  </wallpaper>
  <wallpaper>
    <name>Flow State — Nebula</name>
    <filename>/usr/share/backgrounds/flow-state/flow-state-nebula.jpg</filename>
    <options>zoom</options>
    <pcolor>#2b0a3f</pcolor>
    <scolor>#2b0a3f</scolor>
    <shade_type>solid</shade_type>
  </wallpaper>
  <wallpaper>
    <name>Flow State — Ember</name>
    <filename>/usr/share/backgrounds/flow-state/flow-state-ember.jpg</filename>
    <options>zoom</options>
    <pcolor>#3f0b18</pcolor>
    <scolor>#3f0b18</scolor>
    <shade_type>solid</shade_type>
  </wallpaper>
</wallpapers>
XML
  echo "  system wallpapers installed to /usr/share/backgrounds/flow-state/"
fi

# --- Current user's wallpaper --------------------------------------------
if command -v gsettings >/dev/null 2>&1; then
  # Prefer the system-installed Aurora; fall back to the repo copy if the
  # system install did not happen (no sudo).
  WP=""
  if [[ -f /usr/share/backgrounds/flow-state/flow-state-aurora.jpg ]]; then
    WP=/usr/share/backgrounds/flow-state/flow-state-aurora.jpg
  elif [[ -f "$WP_SRC/flow-state-aurora.jpg" ]]; then
    WP="$WP_SRC/flow-state-aurora.jpg"
  fi
  if [[ -n "$WP" ]]; then
    gsettings set org.gnome.desktop.background picture-uri "file://$WP"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$WP"
    gsettings set org.gnome.desktop.background picture-options "zoom"
    echo "  active wallpaper set to $(basename "$WP")"
  fi
  gsettings set org.gnome.desktop.interface accent-color "blue" 2>/dev/null || true
fi

# User avatar for GDM. On modern GNOME, ~/.face is honored on next login.
if [[ -f "$BRAND_DIR/flowstate-logo.png" ]]; then
  cp -f "$BRAND_DIR/flowstate-logo.png" "$HOME/.face"
fi
