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

REPO_DEB_URLS=(
  "https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_1.0.8_all.deb"
  "https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_1.0.6-2_all.deb"
  "https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_1.0.4_all.deb"
)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Try each candidate URL; the exact filename shifts as Proton bumps the
# repo package. Break on the first successful download of >4kB.
for u in "${REPO_DEB_URLS[@]}"; do
  echo "  fetch: $u"
  if curl -fsSL --max-time 30 -o "$TMP/proton-repo.deb" "$u" \
    && [[ $(stat -c '%s' "$TMP/proton-repo.deb" 2>/dev/null || echo 0) -gt 4000 ]]; then
    break
  fi
done

if [[ ! -s "$TMP/proton-repo.deb" ]]; then
  echo "  could not fetch the ProtonVPN repo package from any known URL." >&2
  echo "  go to https://protonvpn.com/support/official-linux-vpn-ubuntu/ and follow the install steps manually." >&2
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
