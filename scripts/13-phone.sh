#!/usr/bin/env bash
# 13 — Phone integration (Android). Wraps GSConnect (GNOME port of KDE
# Connect) so Flow State ships phone pairing out of the box: shared
# clipboard, SMS from the desktop, notification mirror, file transfer,
# media control, remote input, "find my phone" ring.
#
# Root layer installs the extension, opens the KDE Connect ports on the
# firewall, and sets Flow State's system-wide dconf default so every
# new user has GSConnect enabled without touching Extensions Manager.
#
# User layer just launches GSConnect for the current session and drops
# a launcher entry ("Flow State Phone") next to it in the app grid.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- System side (root) --------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  echo "==> System-side phone integration"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    gnome-shell-extension-gsconnect \
    openssl \
    python3-nautilus \
    2>&1 | tail -3

  # KDE Connect uses TCP+UDP 1714-1764 for discovery + pairing.
  if command -v ufw >/dev/null 2>&1 && ufw status >/dev/null 2>&1; then
    ufw allow 1714:1764/tcp comment "GSConnect / KDE Connect" 2>&1 | tail -1
    ufw allow 1714:1764/udp comment "GSConnect / KDE Connect" 2>&1 | tail -1
  fi

  # System-wide default: enable GSConnect + AppIndicators via dconf so
  # every new Flow State user has them on at first login without an
  # extra click.
  install -d /etc/dconf/db/local.d /etc/dconf/profile
  cat > /etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
  cat > /etc/dconf/db/local.d/00-flow-state-extensions <<'EOF'
[org/gnome/shell]
enabled-extensions=['ding@rastersoft.com', 'ubuntu-dock@ubuntu.com', 'tiling-assistant@ubuntu.com', 'ubuntu-appindicators@ubuntu.com', 'gsconnect@andyholmes.github.io']
EOF
  dconf update 2>&1 | tail -3

  # Ship the tether protocol spec in the distro's docs for later work.
  if [[ -d /opt/flow-state-distro ]]; then
    install -d -m 0755 /opt/flow-state-distro/docs/phone
    if [[ -d "$HOME/tether-src/protocol" ]]; then
      cp -a "$HOME/tether-src/protocol/." /opt/flow-state-distro/docs/phone/ 2>/dev/null || true
    fi
  fi

  exit 0
fi

# --- User side -----------------------------------------------------------
echo "==> User-side phone integration"

# App-grid launcher: "Flow State Phone" opens the GSConnect preferences,
# which is where pairing lives.
LAUNCHER="$HOME/.local/share/applications/flow-state-phone.desktop"
install -d -m 0755 "$HOME/.local/share/applications"
cat > "$LAUNCHER" <<'EOF'
[Desktop Entry]
Name=Flow State Phone
GenericName=Android bridge
Comment=Pair your Android phone with Flow State — clipboard, SMS, notifications, files
Exec=gapplication launch org.gnome.Shell.Extensions.GSConnect
Icon=phone-symbolic
Terminal=false
Type=Application
Categories=Network;RemoteAccess;GTK;
Keywords=phone;android;kdeconnect;gsconnect;pair;
EOF
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

# Ensure GSConnect is in this user's enabled-extensions list too (the
# dconf system default handles new users; existing users need the user
# override too because their gsettings already exists).
if command -v gsettings >/dev/null 2>&1; then
  CUR=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")
  if ! echo "$CUR" | grep -q "gsconnect@andyholmes.github.io"; then
    if [[ "$CUR" == "@as []" || "$CUR" == "[]" ]]; then
      gsettings set org.gnome.shell enabled-extensions "['gsconnect@andyholmes.github.io']"
    else
      gsettings set org.gnome.shell enabled-extensions \
        "${CUR%]}, 'gsconnect@andyholmes.github.io']"
    fi
  fi
fi

# Nudge GSConnect awake so it registers with the daemon (it's dbus-
# activated; this triggers the SessionBus service).
if command -v gapplication >/dev/null 2>&1; then
  gapplication launch org.gnome.Shell.Extensions.GSConnect 2>/dev/null || true
fi

echo "  Flow State Phone launcher installed."
echo "  On your Android phone install 'KDE Connect' from the Play Store, then"
echo "  open Flow State Phone to pair. Requires you to log out + back in once"
echo "  for the GNOME extension to activate."
