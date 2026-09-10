#!/usr/bin/env bash
# Flow State — scripted ISO build.
#
# Takes the official Ubuntu 24.04 desktop ISO, drops Flow State's
# bootstrap-system.sh into a chroot on the live rootfs, repacks the
# squashfs, and produces flow-state-<version>-amd64.iso.
#
#   sudo bash iso/build-iso.sh                # normal build
#   sudo bash iso/build-iso.sh --clean        # blow away workdir first
#   sudo bash iso/build-iso.sh --test         # boot the ISO in qemu after build
#
# Needs ~30 GB free under /var and 20-30 minutes. Requires: xorriso,
# squashfs-tools, wget, isolinux (for BIOS boot).
#
# Output: iso/build/flow-state-<version>-amd64.iso + .sha256

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "iso/build-iso.sh must run as root (chroot needs it). Try: sudo bash $0" >&2
  exit 1
fi

VERSION="${FLOW_STATE_VERSION:-0.1}"
UBUNTU_ISO_URL="${UBUNTU_ISO_URL:-https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-desktop-amd64.iso}"
UBUNTU_ISO_SHA256="${UBUNTU_ISO_SHA256:-}"  # optional pin

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$HERE/build"
CACHE="$HERE/cache"
UBUNTU_ISO="$CACHE/ubuntu-24.04.4-desktop-amd64.iso"
ISO_MOUNT="$WORK/iso-mount"
ISO_ROOT="$WORK/iso-root"
SQUASH_MNT="$WORK/squash-mnt"
CHROOT="$WORK/rootfs"
OUT_ISO="$WORK/flow-state-${VERSION}-amd64.iso"

BLUE='\033[38;2;255;40;40m'; BOLD='\033[1m'; RESET='\033[0m'
say() { printf "${BOLD}${BLUE}==>${RESET} %s\n" "$*"; }

# --- Sanity + prep -------------------------------------------------------
for cmd in xorriso unsquashfs mksquashfs wget rsync chroot mount umount curl sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing: $cmd" >&2
    echo "install with: sudo apt install -y xorriso squashfs-tools wget rsync isolinux" >&2
    exit 1
  }
done

if [[ "${1:-}" == "--clean" ]]; then
  say "clean: removing $WORK"
  rm -rf "$WORK"
fi

mkdir -p "$CACHE" "$WORK" "$ISO_ROOT" "$ISO_MOUNT" "$SQUASH_MNT" "$CHROOT"
trap 'set +e; umount "$SQUASH_MNT" 2>/dev/null; umount "$ISO_MOUNT" 2>/dev/null;
      umount "$CHROOT/dev/pts" 2>/dev/null; umount "$CHROOT/dev" 2>/dev/null;
      umount "$CHROOT/proc" 2>/dev/null; umount "$CHROOT/sys" 2>/dev/null;
      umount "$CHROOT/run" 2>/dev/null' EXIT

# --- 1. Fetch upstream ISO ----------------------------------------------
if [[ ! -f "$UBUNTU_ISO" ]]; then
  say "downloading $UBUNTU_ISO_URL"
  wget --show-progress -c -O "$UBUNTU_ISO.part" "$UBUNTU_ISO_URL"
  mv "$UBUNTU_ISO.part" "$UBUNTU_ISO"
fi
if [[ -n "$UBUNTU_ISO_SHA256" ]]; then
  say "verifying checksum"
  echo "$UBUNTU_ISO_SHA256  $UBUNTU_ISO" | sha256sum -c -
fi

# --- 2. Mount the ISO, mirror it to iso-root ----------------------------
say "extracting ISO to $ISO_ROOT"
mount -o loop,ro "$UBUNTU_ISO" "$ISO_MOUNT"
rsync -aH --delete --exclude=/casper/filesystem.squashfs \
  "$ISO_MOUNT/" "$ISO_ROOT/"
# Copy the squashfs separately (it will get replaced).
cp -a "$ISO_MOUNT/casper/filesystem.squashfs" "$WORK/filesystem.squashfs"
umount "$ISO_MOUNT"

# --- 3. Unsquash + prep chroot ------------------------------------------
say "unsquashing filesystem (this takes 3–5 min)"
rm -rf "$CHROOT"
unsquashfs -f -d "$CHROOT" "$WORK/filesystem.squashfs"

# Copy the whole flow-state-distro repo into the chroot so bootstrap-system.sh
# can call its own step scripts.
mkdir -p "$CHROOT/opt/flow-state-distro"
rsync -a --exclude='.git' --exclude='iso/build' --exclude='iso/cache' \
  "$REPO/" "$CHROOT/opt/flow-state-distro/"

# Bind-mount the runtime the chroot needs.
mount --bind /dev "$CHROOT/dev"
mount --bind /dev/pts "$CHROOT/dev/pts"
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sysfs "$CHROOT/sys"
mount -t tmpfs tmpfs "$CHROOT/run"
# Working DNS inside the chroot.
cp -f /etc/resolv.conf "$CHROOT/etc/resolv.conf"

# --- 4. Run bootstrap-system.sh inside the chroot -----------------------
say "running bootstrap-system.sh inside chroot"
cat > "$CHROOT/tmp/flow-state-chroot.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
cd /opt/flow-state-distro
bash bootstrap-system.sh
# Register bootstrap-user.sh as a first-login command via a tiny system
# helper — every new user runs it exactly once.
install -d /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/flow-state-first-login.desktop <<DTOP
[Desktop Entry]
Type=Application
Name=Flow State — first-login setup
Exec=/bin/bash -c "if [ ! -f \$HOME/.config/flow-state-provisioned ]; then bash /opt/flow-state-distro/bootstrap-user.sh; touch \$HOME/.config/flow-state-provisioned; fi"
Terminal=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
DTOP
# Stamp the os-release with the Flow State variant (keeps ID=ubuntu).
awk '/^PRETTY_NAME/ {print "PRETTY_NAME=\"Flow State '"$FLOW_STATE_VERSION"' (Noble Numbat remix)\""; next} {print}' \
  /etc/os-release > /etc/os-release.new
{
  echo "VARIANT=\"Flow State\""
  echo "VARIANT_ID=flowstate"
  echo "HOME_URL=\"https://dsio.io/flow-state\""
} >> /etc/os-release.new
mv /etc/os-release.new /etc/os-release
# Trim apt caches so the resulting squashfs is smaller.
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT_EOF
chmod +x "$CHROOT/tmp/flow-state-chroot.sh"
FLOW_STATE_VERSION="$VERSION" chroot "$CHROOT" /tmp/flow-state-chroot.sh
rm -f "$CHROOT/tmp/flow-state-chroot.sh"

# Restore a fresh resolv.conf placeholder for the ISO (systemd-resolved
# manages it live).
rm -f "$CHROOT/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"

# --- 5. Unmount chroot bind mounts before squashing ---------------------
umount "$CHROOT/run" || true
umount "$CHROOT/sys" || true
umount "$CHROOT/proc" || true
umount "$CHROOT/dev/pts" || true
umount "$CHROOT/dev" || true

# --- 6. Rebuild the squashfs --------------------------------------------
say "rebuilding filesystem.squashfs (this takes 5–10 min)"
rm -f "$ISO_ROOT/casper/filesystem.squashfs"
mksquashfs "$CHROOT" "$ISO_ROOT/casper/filesystem.squashfs" \
  -comp xz -Xdict-size 100% -b 1M -no-progress

# Update the size + manifest.
printf '%s' "$(du -sx --block-size=1 "$CHROOT" | cut -f1)" \
  > "$ISO_ROOT/casper/filesystem.size"
chroot "$CHROOT" dpkg-query -W --showformat='${Package} ${Version}\n' \
  > "$ISO_ROOT/casper/filesystem.manifest" 2>/dev/null || true

# --- 7. Replace the ISO's disk info --------------------------------------
mkdir -p "$ISO_ROOT/.disk"
cat > "$ISO_ROOT/.disk/info" <<EOF
Flow State ${VERSION} "Noble Numbat remix" - Release amd64 ($(date +%Y%m%d))
EOF

# --- 8. Repack the ISO with xorriso -------------------------------------
say "packing $OUT_ISO"
xorriso -as mkisofs \
  -r -V "Flow State ${VERSION}" \
  -o "$OUT_ISO" \
  -J -joliet-long -l \
  -iso-level 3 \
  -partition_offset 16 \
  --grub2-mbr "$ISO_ROOT/boot/grub/i386-pc/boot_hybrid.img" \
  --mbr-force-bootable \
  -append_partition 2 0xef "$ISO_ROOT/EFI/boot/grubx64.efi" \
  -appended_part_as_gpt \
  -c boot.catalog \
  -b boot/grub/i386-pc/eltorito.img \
  -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot \
  -e '--interval:appended_partition_2:all::' \
  -no-emul-boot \
  -boot-load-size 4 -boot-info-table \
  "$ISO_ROOT" 2>&1 | tail -20

# --- 9. Checksum --------------------------------------------------------
say "checksum"
( cd "$(dirname "$OUT_ISO")" && sha256sum "$(basename "$OUT_ISO")" > "${OUT_ISO}.sha256" )
cat "${OUT_ISO}.sha256"
ls -lah "$OUT_ISO"

# --- 10. Optional: boot in qemu -----------------------------------------
if [[ "${1:-}" == "--test" ]]; then
  say "booting in qemu (Ctrl+A x to quit)"
  qemu-system-x86_64 -m 4096 -smp 2 -cdrom "$OUT_ISO" -boot d
fi

say "done: $OUT_ISO"
