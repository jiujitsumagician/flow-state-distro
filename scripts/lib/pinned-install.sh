#!/usr/bin/env bash
# Shared helpers for installing third-party software with verification.
# Sourced (not executed) by bootstrap-system.sh, scripts/01-apt-packages.sh
# and scripts/02-nodejs.sh.
#
# Callers set SUDO="" when already root, or SUDO="sudo" otherwise.

SUDO="${SUDO-sudo}"
FS_APT_KEYRINGS_DIR="${FS_APT_KEYRINGS_DIR:-/etc/apt/keyrings}"
FS_APT_SOURCES_DIR="${FS_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"

# NodeSource signing key (https://github.com/nodesource/distributions).
FS_NODESOURCE_KEY_FPR="6F71F525282841EEDAF851B42F59B5F99B1BE0B4"
# GitHub CLI signing keys (https://github.com/cli/cli/blob/trunk/docs/install_linux.md).
# The keyring currently carries the older key (2C61...) and its successor
# (7F38...). Any other key in the keyring is rejected.
FS_GH_KEY_FPRS=(
  "2C6106201985B60E6C7AC87323F3D4EA75716059"
  "7F38BBB59D064DBCB3D84D725612B36462313325"
)

# Print the fingerprint of every primary key in a key file (armored or binary).
fs_primary_fprs() {
  local file="$1" home
  command -v gpg >/dev/null 2>&1 || { echo "gpg is required to verify signing keys" >&2; return 1; }
  home="$(mktemp -d)"
  GNUPGHOME="$home" gpg --batch --show-keys --with-colons "$file" 2>/dev/null \
    | awk -F: '$1=="pub"{p=1;next} p&&$1=="fpr"{print $10;p=0}'
  local rc=${PIPESTATUS[0]}
  rm -rf "$home"
  return "$rc"
}

# fs_require_key_fprs FILE FPR...
# Succeeds only if FILE holds at least one key and EVERY primary key in it
# has one of the allowed fingerprints (apt would trust all of them).
fs_require_key_fprs() {
  local file="$1"; shift
  local found fpr a ok
  found="$(fs_primary_fprs "$file")" || return 1
  [[ -n "$found" ]] || { echo "no key found in downloaded keyring" >&2; return 1; }
  while IFS= read -r fpr; do
    ok=0
    for a in "$@"; do [[ "$fpr" == "$a" ]] && ok=1; done
    if (( ! ok )); then
      echo "unexpected signing key $fpr (allowed: $*)" >&2
      return 1
    fi
  done <<<"$found"
}

# Add the NodeSource apt repository with a fingerprint-checked key and install
# Node.js from it (replaces `curl ... setup_NN.x | bash`).
fs_install_nodesource() {
  local major="${1:-24}" tmp home
  tmp="$(mktemp)"
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o "$tmp"
  if ! fs_require_key_fprs "$tmp" "$FS_NODESOURCE_KEY_FPR"; then
    rm -f "$tmp"
    echo "NodeSource signing key does not match the pinned fingerprint $FS_NODESOURCE_KEY_FPR; refusing to add the repository." >&2
    return 1
  fi
  home="$(mktemp -d)"
  $SUDO install -d -m 0755 "$FS_APT_KEYRINGS_DIR"
  GNUPGHOME="$home" gpg --batch --dearmor <"$tmp" | $SUDO tee "$FS_APT_KEYRINGS_DIR/nodesource.gpg" >/dev/null
  $SUDO chmod 0644 "$FS_APT_KEYRINGS_DIR/nodesource.gpg"
  rm -rf "$home" "$tmp"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=$FS_APT_KEYRINGS_DIR/nodesource.gpg] https://deb.nodesource.com/node_${major}.x nodistro main" \
    | $SUDO tee "$FS_APT_SOURCES_DIR/nodesource.list" >/dev/null
  $SUDO apt-get update -qq
  $SUDO apt-get install -y nodejs
}

# Add the cli.github.com apt repository with a fingerprint-checked keyring and
# install gh.
fs_install_gh() {
  local tmp
  tmp="$(mktemp)"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$tmp"
  if ! fs_require_key_fprs "$tmp" "${FS_GH_KEY_FPRS[@]}"; then
    rm -f "$tmp"
    echo "GitHub CLI keyring contains an unexpected key; refusing to add the repository. If GitHub rotated its key, verify it at https://github.com/cli/cli/blob/trunk/docs/install_linux.md and update FS_GH_KEY_FPRS in scripts/lib/pinned-install.sh." >&2
    return 1
  fi
  $SUDO install -d -m 0755 "$FS_APT_KEYRINGS_DIR"
  $SUDO install -m 0644 "$tmp" "$FS_APT_KEYRINGS_DIR/githubcli-archive-keyring.gpg"
  rm -f "$tmp"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=$FS_APT_KEYRINGS_DIR/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | $SUDO tee "$FS_APT_SOURCES_DIR/github-cli.list" >/dev/null
  $SUDO apt-get update -qq
  $SUDO apt-get install -y gh
}

# fs_install_ollama VERSION INSTALL_SH_SHA256
# Download Ollama's installer, require it to match a pinned SHA-256, and run it
# pinned to VERSION. Returns non-zero (without running anything) on mismatch.
fs_install_ollama() {
  local version="$1" sha="$2" tmp
  tmp="$(mktemp)"
  if ! curl -fsSL https://ollama.com/install.sh -o "$tmp"; then
    rm -f "$tmp"; echo "could not download the Ollama installer" >&2; return 1
  fi
  if ! echo "$sha  $tmp" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "Ollama install.sh does not match the pinned SHA-256 ($sha); not running it. Review the new script, then update OLLAMA_INSTALL_SHA256 in bootstrap-system.sh." >&2
    return 1
  fi
  local rc=0
  $SUDO env OLLAMA_VERSION="$version" sh "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}
