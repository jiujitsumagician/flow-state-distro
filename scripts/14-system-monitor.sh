#!/usr/bin/env bash
# 14 — GPU-aware system monitor.
#
# GNOME's default gnome-system-monitor shows CPU, RAM, and disk but no
# GPU. Flow State swaps in Mission Center — a modern GNOME-native monitor
# that shows GPU utilisation, VRAM, encode/decode load, per-process GPU
# usage, and per-drive throughput — for Intel, NVIDIA, and AMD. As a
# backstop we also install radeontop (AMD-specific ncurses top).
set -euo pipefail

# Root part: install packages, register mission-center as the preferred
# system monitor via update-alternatives.
if [[ $EUID -eq 0 ]]; then
  echo "==> System-side GPU monitor"

  # ncurses / CLI tools are in Ubuntu apt: install those first.
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    radeontop \
    intel-gpu-tools \
    nvtop \
    htop \
    flatpak \
    2>&1 | tail -3

  # Add flathub for Mission Center (not shipped in Ubuntu 24.04's apt repo).
  flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo 2>&1 | tail -1 || true

  # Install Mission Center system-wide from flathub.
  flatpak install -y --noninteractive flathub io.missioncenter.MissionCenter \
    2>&1 | tail -5 || echo "  (Mission Center flatpak install failed; nvtop + radeontop are still available)"

  # Provide a convenient wrapper on PATH so `mission-center` works even
  # when the app is a flatpak.
  cat > /usr/local/bin/mission-center <<'EOF'
#!/usr/bin/env bash
exec flatpak run io.missioncenter.MissionCenter "$@"
EOF
  chmod +x /usr/local/bin/mission-center
  exit 0
fi

# User part: point the Files menu → "Open System Monitor" at Mission
# Center by placing a launcher with the org.gnome.SystemMonitor id.
echo "==> User-side GPU monitor"
install -d -m 0755 "$HOME/.local/share/applications"
# Override any hard-coded org.gnome.SystemMonitor launcher: point Exec
# at mission-center, keep the same StartupWMClass so GNOME finds it.
cat > "$HOME/.local/share/applications/org.gnome.SystemMonitor.desktop" <<'EOF'
[Desktop Entry]
Name=System Monitor
GenericName=System Monitor
Comment=CPU, RAM, GPU, disk, network — all in one panel
Exec=mission-center %U
Icon=org.gnome.SystemMonitor
Terminal=false
Type=Application
Categories=GNOME;GTK;System;Monitor;
StartupNotify=true
StartupWMClass=io.missioncenter.MissionCenter
EOF
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

# Also drop a distinct "Flow State — System (GPU)" launcher so the app
# grid clearly advertises the GPU-aware option.
cat > "$HOME/.local/share/applications/flow-state-system.desktop" <<'EOF'
[Desktop Entry]
Name=Flow State — System (GPU)
GenericName=System Monitor
Comment=CPU, RAM, GPU, disk, network — the Ubuntu System Monitor with GPU support
Exec=mission-center
Icon=flow-state
Terminal=false
Type=Application
Categories=System;Monitor;GTK;
Keywords=gpu;system;monitor;task;
StartupWMClass=io.missioncenter.MissionCenter
EOF
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo "  System Monitor now shows GPU. Open Activities → 'System Monitor' or"
echo "  'Flow State — System (GPU)'."
