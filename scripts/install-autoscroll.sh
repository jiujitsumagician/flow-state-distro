#!/usr/bin/env bash
# Flow State autoscroll — one-shot installer.
#
#     sudo bash /home/will/flow-state-distro/scripts/install-autoscroll.sh
#
# 1. apt-installs python3-evdev
# 2. Ensures the uinput kernel module is loaded now AND on every boot
# 3. Copies autoscrolld.py to /opt/flow-state/ and its systemd unit into place
# 4. Installs a udev rule so mouse hotplug restarts the service
# 5. Enables + starts (or restarts, if already running) the service
#
# Idempotent — safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This installer must run as root. Try: sudo bash $0" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing python3-evdev"
apt-get update -qq
apt-get install -y python3-evdev

echo "==> Ensuring uinput kernel module is loaded"
modprobe uinput || true
install -d -m 0755 /etc/modules-load.d
printf 'uinput\n' > /etc/modules-load.d/flow-state-autoscroll.conf

echo "==> Deploying daemon to /opt/flow-state/"
install -d -m 0755 /opt/flow-state
install -m 0755 "$SRC_DIR/autoscrolld.py" /opt/flow-state/autoscrolld.py

echo "==> Installing systemd unit"
install -m 0644 "$SRC_DIR/flow-state-autoscroll.service" \
                /etc/systemd/system/flow-state-autoscroll.service

echo "==> Installing udev rule for mouse hotplug"
cat > /etc/udev/rules.d/70-flow-state-autoscroll.rules <<'EOF'
# When any mouse-like input event device appears, ask systemd to restart the
# autoscroll daemon so it grabs the newcomer. Uses --no-block so udev does not
# stall waiting on the restart.
#
# IMPORTANT: exclude the daemon's own virtual device — matching it would
# trigger a restart-storm every time the daemon starts and re-creates its
# uinput mouse.
ACTION=="add|remove", KERNEL=="event[0-9]*", SUBSYSTEM=="input", \
  ENV{ID_INPUT_MOUSE}=="1", ATTRS{name}!="flow-state-autoscroll", \
  RUN+="/bin/systemctl --no-block try-restart flow-state-autoscroll.service"
EOF
udevadm control --reload-rules || true

echo "==> Enabling + (re)starting service"
# Detect a chroot (no PID 1 systemd) — the ISO build reaches this from
# inside `chroot` where systemctl start would fail. Enable is fine (writes
# symlinks); start is skipped and the service comes up on first boot.
if [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl enable flow-state-autoscroll.service
  if systemctl is-active --quiet flow-state-autoscroll.service; then
    systemctl restart flow-state-autoscroll.service
  else
    systemctl start flow-state-autoscroll.service
  fi
  echo
  echo "==> Status"
  systemctl --no-pager --lines=8 status flow-state-autoscroll.service || true
else
  echo "  no live systemd (chroot?); just enabling via symlink"
  # Manual "enable" — equivalent to `systemctl enable` when systemd isn't PID 1.
  install -d /etc/systemd/system/multi-user.target.wants
  ln -sf /etc/systemd/system/flow-state-autoscroll.service \
        /etc/systemd/system/multi-user.target.wants/flow-state-autoscroll.service
fi

echo
echo "Done. Middle-mouse-hold + drag now scrolls system-wide."
echo "Log:  journalctl -u flow-state-autoscroll.service -f"
echo "Stop: sudo systemctl stop flow-state-autoscroll.service"
