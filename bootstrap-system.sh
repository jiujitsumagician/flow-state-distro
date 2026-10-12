#!/usr/bin/env bash
# Flow State bootstrap — SYSTEM layer.
#
# Everything that needs root: apt packages, Node source, Ollama service,
# autoscroll daemon. Same script runs in the ISO chroot at Phase 2 build
# time, so keep it self-contained and idempotent.
#
#     sudo bash bootstrap-system.sh
#
# Never asks the user any questions.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pinned third-party versions. Bump deliberately (and re-test an install/ISO
# build) rather than tracking "latest" as root. Override via the environment.
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.296}"
CODEX_VERSION="${CODEX_VERSION:-0.162.1}"
OLLAMA_VERSION="${OLLAMA_VERSION:-0.40.3}"
# SHA-256 of https://ollama.com/install.sh as reviewed for the version above.
OLLAMA_INSTALL_SHA256="${OLLAMA_INSTALL_SHA256:-25f64b810b947145095956533e1bdf56eacea2673c55a7e586be4515fc882c9f}"

if [[ $EUID -ne 0 ]]; then
  echo "bootstrap-system.sh must run as root. Try: sudo bash $0" >&2
  exit 1
fi

SUDO=""   # already root; scripts/lib/pinned-install.sh prefixes privileged commands with this
# shellcheck source=scripts/lib/pinned-install.sh
source "$HERE/scripts/lib/pinned-install.sh"

BLUE=$'\033[38;2;24;95;165m'; RESET=$'\033[0m'
say() { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }

require_ubuntu_24_04() {
  [[ -r /etc/os-release ]] || { echo "no /etc/os-release" >&2; exit 1; }
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    echo "bootstrap-system.sh requires Ubuntu 24.04 (got: ${PRETTY_NAME:-unknown})" >&2
    exit 1
  fi
}

say "preflight"
require_ubuntu_24_04

say "01: apt packages (system)"
apt-get update -qq
apt-get install -y \
  git curl jq build-essential \
  python3 python3-evdev \
  imagemagick dconf-cli \
  xdotool

# gh: needed later by the user-scope script to clone the private DSIO repo.
if ! command -v gh >/dev/null 2>&1; then
  say "01: adding cli.github.com apt source and installing gh"
  # Keyring is fingerprint-checked before apt is allowed to trust it.
  fs_install_gh
fi

# Node 24 from NodeSource, but only if the system Node is older than 22.
need_node() {
  command -v node >/dev/null 2>&1 || return 0
  local v; v="$(node -v | sed 's/^v//;s/\..*$//')"
  (( v < 22 ))
}
if need_node; then
  say "02: installing Node 24 LTS from NodeSource"
  # Signed apt repo with a fingerprint-checked key (no curl | bash).
  fs_install_nodesource 24
else
  say "02: node $(node -v) already present"
fi

# Global npm CLIs, pinned to exact versions. @openai/codex has no install
# scripts, so they are disabled for it. @anthropic-ai/claude-code needs its
# postinstall step (it links the native binary), so scripts stay enabled there.
if ! command -v claude >/dev/null 2>&1; then
  say "02: npm i -g @anthropic-ai/claude-code@$CLAUDE_CODE_VERSION"
  npm install -g "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" >/dev/null
fi
if ! command -v codex >/dev/null 2>&1; then
  say "02: npm i -g @openai/codex@$CODEX_VERSION"
  npm install -g --ignore-scripts "@openai/codex@$CODEX_VERSION" >/dev/null
fi

# Ollama service, optional but recommended.
if ! command -v ollama >/dev/null 2>&1; then
  say "05: installing Ollama"
  # Installer is hash-pinned and run pinned to OLLAMA_VERSION; on mismatch it
  # is NOT executed (optional component: warn and continue).
  fs_install_ollama "$OLLAMA_VERSION" "$OLLAMA_INSTALL_SHA256" \
    || echo "  (Ollama install skipped; see message above)"
fi

# Middle-click autoscroll: use the installer script for now. Phase 1.5
# swaps this for `apt install flow-state-autoscroll`.
say "04: installing flow-state-autoscroll daemon"
bash "$HERE/scripts/install-autoscroll.sh"

say "system layer complete"

say "10: ProtonVPN client (best-effort)"
bash "$HERE/scripts/10-vpn.sh" || echo "  (ProtonVPN install skipped; install later with: sudo bash scripts/10-vpn.sh)"

say "11: file-manager thumbnails (system)"
bash "$HERE/scripts/11-thumbnails.sh"

say "13: phone integration (system)"
bash "$HERE/scripts/13-phone.sh"

say "14: GPU-aware system monitor"
bash "$HERE/scripts/14-system-monitor.sh"

say "15: Thingwhere-style launcher (Ulauncher)"
bash "$HERE/scripts/15-thingwhere.sh"

say "16: dock hover previews"
bash "$HERE/scripts/16-dock-preview.sh"

say "99: strip Ubuntu artwork + brand as Flow State"
bash "$HERE/scripts/99-strip-ubuntu.sh"
