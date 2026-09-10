#!/usr/bin/env bash
# 01 — APT packages the harness + autoscroll daemon + branding pass rely on.
set -euo pipefail

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
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y gh
fi
