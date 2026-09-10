#!/usr/bin/env bash
# Flow State — scripted ISO build.
#
# Ubuntu 24.04 desktop ships a layered live-boot filesystem
# (minimal.squashfs + minimal.standard.squashfs + minimal.<lang>.squashfs).
# We merge them into one rootfs, run Flow State's system layer + the
# Ubuntu-strip step inside a chroot, then repack the merged rootfs as
# a monolithic casper/filesystem.squashfs (casper falls back to that
# name automatically) and remove the split layers.
#
#   sudo bash iso/build-iso.sh                # normal build
#   sudo bash iso/build-iso.sh --clean        # blow away workdir first
#   sudo bash iso/build-iso.sh --test         # boot the ISO in qemu after build
#
# Needs ~40 GB free under /home and ~30–45 minutes. Cache directory is
# preserved so the upstream ISO isn't re-downloaded on re-run.
#
# Output: iso/build/flow-state-<version>-amd64.iso + .sha256

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "iso/build-iso.sh must run as root (chroot needs it). Try: sudo bash $0" >&2
  exit 1
fi

VERSION="${FLOW_STATE_VERSION:-0.1}"
UBUNTU_ISO_URL="${UBUNTU_ISO_URL:-https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-desktop-amd64.iso}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$HERE/build"
CACHE="$HERE/cache"
UBUNTU_ISO="$CACHE/ubuntu-24.04.4-desktop-amd64.iso"
ISO_MOUNT="$WORK/iso-mount"
ISO_ROOT="$WORK/iso-root"
CHROOT="$WORK/rootfs"
OUT_ISO="$WORK/flow-state-${VERSION}-amd64.iso"

BLUE='\033[38;2;255;40;40m'; BOLD='\033[1m'; RESET='\033[0m'
say() { printf "${BOLD}${BLUE}==>${RESET} %s\n" "$*"; }

for cmd in xorriso unsquashfs mksquashfs wget rsync chroot mount umount curl sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing: $cmd (sudo apt install -y xorriso squashfs-tools wget rsync isolinux)" >&2
    exit 1
  }
done

if [[ "${1:-}" == "--clean" ]]; then
  say "clean: removing $WORK"
  rm -rf "$WORK"
fi
mkdir -p "$CACHE" "$WORK" "$ISO_ROOT" "$ISO_MOUNT" "$CHROOT"

# Track mounts for cleanup.
CLEANUP_MOUNTS=()
cleanup() {
  set +e
  for m in "${CLEANUP_MOUNTS[@]}"; do umount "$m" 2>/dev/null; done
  umount "$ISO_MOUNT" 2>/dev/null
}
trap cleanup EXIT

# --- 1. Fetch upstream ISO ----------------------------------------------
if [[ ! -f "$UBUNTU_ISO" ]]; then
  say "downloading $UBUNTU_ISO_URL"
  wget --show-progress -c -O "$UBUNTU_ISO.part" "$UBUNTU_ISO_URL"
  mv "$UBUNTU_ISO.part" "$UBUNTU_ISO"
fi

# --- 2. Extract the ISO to iso-root -------------------------------------
say "extracting ISO to $ISO_ROOT"
mount -o loop,ro "$UBUNTU_ISO" "$ISO_MOUNT"
rsync -aH --delete --exclude=/casper "$ISO_MOUNT/" "$ISO_ROOT/"
mkdir -p "$ISO_ROOT/casper"
# Copy everything from casper EXCEPT the squashfs layers (we're replacing those).
rsync -aH --exclude='*.squashfs' "$ISO_MOUNT/casper/" "$ISO_ROOT/casper/"

# --- 3. Merge all squashfs layers into one rootfs -----------------------
say "unsquashing layered filesystem (this takes 5–10 min)"
rm -rf "$CHROOT"
LAYERS=()
# Ubuntu 24.04 desktop ships a base + standard + language layer chain.
# The English language layer's hardlinks collide with minimal.squashfs's
# during a plain layered unsquashfs. Skip it: minimal.standard.squashfs
# already contains English locale data, so the resulting rootfs is
# fully usable in English without minimal.en.
for lyr in minimal.squashfs minimal.standard.squashfs; do
  if [[ -f "$ISO_MOUNT/casper/$lyr" ]]; then
    LAYERS+=("$lyr")
  fi
done
if (( ${#LAYERS[@]} == 0 )); then
  # Older/simpler ISOs just have filesystem.squashfs.
  if [[ -f "$ISO_MOUNT/casper/filesystem.squashfs" ]]; then
    LAYERS=("filesystem.squashfs")
  else
    echo "no squashfs layers found in the ISO" >&2; exit 2
  fi
fi
for lyr in "${LAYERS[@]}"; do
  say "  layer: $lyr"
  # `-ignore-errors` continues past hardlink collisions between layers,
  # and `-no-xattrs` sidesteps some ubuntu-specific xattr edge cases.
  unsquashfs -f -ignore-errors -d "$CHROOT" "$ISO_MOUNT/casper/$lyr"
done
umount "$ISO_MOUNT"

# --- 4. Copy Flow State repo into chroot for the system layer -----------
mkdir -p "$CHROOT/opt/flow-state-distro"
rsync -a --exclude='.git' --exclude='iso/build' --exclude='iso/cache' \
  "$REPO/" "$CHROOT/opt/flow-state-distro/"

# --- 5. Bind-mount runtime inside the chroot ---------------------------
for m in dev dev/pts proc sys run; do mkdir -p "$CHROOT/$m"; done
mount --bind /dev "$CHROOT/dev"; CLEANUP_MOUNTS+=("$CHROOT/dev")
mount --bind /dev/pts "$CHROOT/dev/pts"; CLEANUP_MOUNTS+=("$CHROOT/dev/pts")
mount -t proc proc "$CHROOT/proc"; CLEANUP_MOUNTS+=("$CHROOT/proc")
mount -t sysfs sysfs "$CHROOT/sys"; CLEANUP_MOUNTS+=("$CHROOT/sys")
mount -t tmpfs tmpfs "$CHROOT/run"; CLEANUP_MOUNTS+=("$CHROOT/run")
cp -f /etc/resolv.conf "$CHROOT/etc/resolv.conf"

# --- 6. Run bootstrap-system.sh + 99-strip-ubuntu inside the chroot ----
say "running bootstrap-system.sh + strip-ubuntu inside chroot"
cat > "$CHROOT/tmp/flow-state-chroot.sh" <<CHROOT_EOF
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
cd /opt/flow-state-distro
bash bootstrap-system.sh
bash scripts/99-strip-ubuntu.sh
# First-login autostart via /etc/skel — every new user runs
# bootstrap-user.sh exactly once.
install -d /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/flow-state-first-login.desktop <<DTOP
[Desktop Entry]
Type=Application
Name=Flow State — first-login setup
Exec=/bin/bash -c "if [ ! -f \\\$HOME/.config/flow-state-provisioned ]; then gnome-terminal -- bash -c 'bash /opt/flow-state-distro/bootstrap-user.sh; touch \\\$HOME/.config/flow-state-provisioned; echo Enter to close; read'; fi"
Terminal=false
X-GNOME-Autostart-enabled=true
StartupNotify=false
DTOP
# Trim caches so the resulting squashfs is smaller.
apt-get clean
rm -rf /var/lib/apt/lists/* /var/log/*.log /var/log/apt/*.log /var/log/dpkg.log
CHROOT_EOF
chmod +x "$CHROOT/tmp/flow-state-chroot.sh"
chroot "$CHROOT" /tmp/flow-state-chroot.sh
rm -f "$CHROOT/tmp/flow-state-chroot.sh"

# Restore a live-boot-friendly resolv.conf.
rm -f "$CHROOT/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf" 2>/dev/null || true

# --- 7. Unmount chroot binds --------------------------------------------
for m in "${CLEANUP_MOUNTS[@]}"; do umount "$m" 2>/dev/null || true; done
CLEANUP_MOUNTS=()

# --- 8. Repack into a single filesystem.squashfs ------------------------
say "rebuilding filesystem.squashfs (this takes 8–15 min)"
mksquashfs "$CHROOT" "$ISO_ROOT/casper/filesystem.squashfs" \
  -comp xz -Xdict-size 100% -b 1M -no-progress

# Sizes and manifest.
du -sx --block-size=1 "$CHROOT" | cut -f1 > "$ISO_ROOT/casper/filesystem.size"
chroot "$CHROOT" dpkg-query -W --showformat='${Package} ${Version}\n' \
  > "$ISO_ROOT/casper/filesystem.manifest" 2>/dev/null || true
# Copy the manifest as the desktop manifest too — casper looks at both.
cp "$ISO_ROOT/casper/filesystem.manifest" "$ISO_ROOT/casper/filesystem.manifest-remove" 2>/dev/null || true

# --- 9. Disk info -------------------------------------------------------
mkdir -p "$ISO_ROOT/.disk"
cat > "$ISO_ROOT/.disk/info" <<EOF
Flow State ${VERSION} "Noble Numbat remix" - Release amd64 ($(date +%Y%m%d))
EOF
echo "Flow State ${VERSION}" > "$ISO_ROOT/.disk/release_notes_url" 2>/dev/null || true

# --- 10. Repack ISO with xorriso ---------------------------------------
say "packing $OUT_ISO"
# Use xorriso in "isohybrid" mode compatible with Ubuntu 24.04's boot layout.
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
  "$ISO_ROOT" 2>&1 | tail -25

# --- 11. Checksum + versioned aliases ----------------------------------
say "checksum"
( cd "$(dirname "$OUT_ISO")" && sha256sum "$(basename "$OUT_ISO")" > "${OUT_ISO}.sha256" )
# Also drop a "latest" alias for the dsio.io rewrites.
cp -f "$OUT_ISO" "$WORK/flow-state-latest-amd64.iso"
cp -f "${OUT_ISO}.sha256" "$WORK/flow-state-latest-amd64.iso.sha256"
cat "${OUT_ISO}.sha256"
ls -lah "$OUT_ISO" "$WORK/flow-state-latest-amd64.iso"

if [[ "${1:-}" == "--test" ]]; then
  say "booting in qemu (Ctrl+A x to quit)"
  qemu-system-x86_64 -m 4096 -smp 2 -cdrom "$OUT_ISO" -boot d
fi

say "done: $OUT_ISO"
