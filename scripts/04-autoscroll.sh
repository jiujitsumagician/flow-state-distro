#!/usr/bin/env bash
# 04 — Middle-click autoscroll, system-wide. Delegates to install-autoscroll.sh
# which needs sudo (evdev + uinput). Also lays down the browser-level fallback
# prefs so a fresh browser install still autoscrolls even if the daemon is
# temporarily stopped.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- System-wide daemon (root install) ---
if systemctl is-active --quiet flow-state-autoscroll.service; then
  echo "  flow-state-autoscroll.service already active"
else
  echo "  installing system-wide autoscroll daemon (needs sudo)"
  sudo bash "$HERE/install-autoscroll.sh"
fi

# --- Firefox: general.autoScroll on both snap and non-snap profiles ---
apply_firefox_user_js() {
  local profile="$1"
  [[ -d "$profile" ]] || return 0
  local userjs="$profile/user.js"
  # Idempotent write.
  if ! grep -q '^user_pref("general.autoScroll"' "$userjs" 2>/dev/null; then
    {
      echo '// Flow State: middle-click autoscroll (daemon-independent fallback)'
      echo 'user_pref("general.autoScroll", true);'
    } >>"$userjs"
    echo "  wrote $userjs"
  fi
}

for base in "$HOME/snap/firefox/common/.mozilla/firefox" "$HOME/.mozilla/firefox"; do
  [[ -d "$base" ]] || continue
  for prof in "$base"/*.default*; do
    [[ -d "$prof" ]] && apply_firefox_user_js "$prof"
  done
done

# --- Chrome / Chromium: user-scope .desktop override with feature flag ---
if command -v google-chrome-stable >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/share/applications"
  local_desktop="$HOME/.local/share/applications/google-chrome.desktop"
  system_desktop="/usr/share/applications/google-chrome.desktop"
  if [[ -f "$system_desktop" && ! -f "$local_desktop" ]]; then
    cp "$system_desktop" "$local_desktop"
    sed -i \
      -e 's|Exec=/usr/bin/google-chrome-stable %U|Exec=/usr/bin/google-chrome-stable --enable-features=MiddleClickAutoscroll %U|' \
      -e 's|Exec=/usr/bin/google-chrome-stable$|Exec=/usr/bin/google-chrome-stable --enable-features=MiddleClickAutoscroll|' \
      -e 's|Exec=/usr/bin/google-chrome-stable --incognito|Exec=/usr/bin/google-chrome-stable --enable-features=MiddleClickAutoscroll --incognito|' \
      "$local_desktop"
    update-desktop-database "$HOME/.local/share/applications/" >/dev/null 2>&1 || true
    echo "  wrote $local_desktop with MiddleClickAutoscroll flag"
  fi
fi
