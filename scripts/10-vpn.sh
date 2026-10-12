#!/usr/bin/env bash
# 10 — ProtonVPN client. Adds ProtonVPN's official APT repo and installs
# the GNOME client. First launch: user logs in with their Proton account
# once, then the Flow State tray's "Connect ProtonVPN" toggle works.
#
# NOTE: ProtonVPN Free is available. Toggle uses `--fastest -p wireguard`
# so the connection is Wireguard, not OpenVPN — much faster on Linux.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "10-vpn.sh needs root; re-running under sudo"
  exec sudo bash "$0" "$@"
fi

# Repo-release package. Pinned to a single version AND SHA-256 (published on
# https://protonvpn.com/support/official-linux-vpn-ubuntu/); there is no
# fallback to older versions. When Proton publishes a new release package,
# bump both values (or override via PROTON_DEB_URL / PROTON_DEB_SHA256).
PROTON_DEB_URL="${PROTON_DEB_URL:-https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_1.0.8_all.deb}"
PROTON_DEB_SHA256="${PROTON_DEB_SHA256:-0b14e71586b22e498eb20926c48c7b434b751149b1f2af9902ef1cfe6b03e180}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "  fetch: $PROTON_DEB_URL"
if ! curl -fsSL --max-time 30 -o "$TMP/proton-repo.deb" "$PROTON_DEB_URL" || [[ ! -s "$TMP/proton-repo.deb" ]]; then
  echo "  could not fetch the ProtonVPN repo package." >&2
  echo "  go to https://protonvpn.com/support/official-linux-vpn-ubuntu/ and follow the install steps manually." >&2
  exit 1
fi

if ! echo "$PROTON_DEB_SHA256  $TMP/proton-repo.deb" | sha256sum -c - >/dev/null 2>&1; then
  echo "  ProtonVPN repo package does not match the pinned SHA-256 ($PROTON_DEB_SHA256); not installing it." >&2
  echo "  If Proton published a new release, check the hash at https://protonvpn.com/support/official-linux-vpn-ubuntu/" >&2
  echo "  and re-run with PROTON_DEB_URL / PROTON_DEB_SHA256 set, or follow the install steps there manually." >&2
  exit 1
fi

echo "  installing repo bootstrap"
dpkg -i "$TMP/proton-repo.deb"
apt-get update -qq
apt-get install -y proton-vpn-gnome-desktop

echo
echo "==> Done."
echo "   Launch the ProtonVPN app once (Activities → search 'ProtonVPN') and sign in."
echo "   After that the Flow State tray's 🔓 button connects/disconnects on click."
