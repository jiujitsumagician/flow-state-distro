#!/usr/bin/env bash
# 01 — APT packages the harness + autoscroll daemon + branding pass rely on.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUDO="${SUDO-sudo}"
# shellcheck source=scripts/lib/pinned-install.sh
source "$HERE/lib/pinned-install.sh"

PKGS=(
  git
  curl
  jq
  build-essential
  python3
  python3-evdev      # autoscroll daemon
  imagemagick        # wallpaper + logo pipeline
  dconf-cli          # gsettings from scripts
  xdotool            # useful for X11 automation; harmless on Wayland
)

MISSING=()
for p in "${PKGS[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done

if (( ${#MISSING[@]} == 0 )); then
  echo "  all apt packages already present"
  exit 0
fi

echo "  installing: ${MISSING[*]}"
sudo apt-get update -qq
sudo apt-get install -y "${MISSING[@]}"

# GitHub CLI (`gh`) — needed to clone the private dsio harness; ships via a
# separate apt source. Follows the official install instructions.
if ! command -v gh >/dev/null 2>&1; then
  echo "  installing gh from cli.github.com apt source"
  # Keyring is fingerprint-checked before apt is allowed to trust it.
  fs_install_gh
fi
