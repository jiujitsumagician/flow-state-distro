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
DEFAULT_UBUNTU_ISO_URL="https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-desktop-amd64.iso"
UBUNTU_ISO_URL="${UBUNTU_ISO_URL:-$DEFAULT_UBUNTU_ISO_URL}"
# A different download URL means a different file, so the pinned default
# hash below cannot apply: the caller must supply the matching hash.
if [[ "$UBUNTU_ISO_URL" != "$DEFAULT_UBUNTU_ISO_URL" && -z "${UBUNTU_ISO_SHA256:-}" ]]; then
  echo "UBUNTU_ISO_URL is overridden: also set UBUNTU_ISO_SHA256 to the SHA-256 of that ISO (see the release's SHA256SUMS)." >&2
  exit 1
fi
# Pinned SHA-256 of the upstream base ISO. Source: Canonical's
# https://releases.ubuntu.com/24.04.4/SHA256SUMS (GPG-verified against
# SHA256SUMS.gpg, key 843938DF228D22F7B3742BC0D94AA3F0EFE21092).
# Override with UBUNTU_ISO_SHA256 when bumping the base image.
UBUNTU_ISO_SHA256="${UBUNTU_ISO_SHA256:-3a4c9877b483ab46d7c3fbe165a0db275e1ae3cfe56a5657e5a47c2f99a99d1e}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$HERE/build"
CACHE="$HERE/cache"
UBUNTU_ISO="$CACHE/ubuntu-24.04.4-desktop-amd64.iso"
ISO_MOUNT="$WORK/iso-mount"
ISO_ROOT="$WORK/iso-root"
CHROOT="$WORK/rootfs"
# Safety: every rm -rf below is aimed at $WORK / $CHROOT. Refuse to run if
# the build tree is not exactly <repo>/iso/build.
if [[ "$WORK" != "$REPO/iso/build" ]]; then
  echo "refusing to continue: unexpected build dir '$WORK' (expected '$REPO/iso/build')" >&2
  exit 1
fi
OUT_ISO="$WORK/flow-state-${VERSION}-amd64.iso"

BLUE='\033[38;2;255;40;40m'; BOLD='\033[1m'; RESET='\033[0m'
say() { printf "${BOLD}${BLUE}==>${RESET} %s\n" "$*"; }

for cmd in xorriso unsquashfs mksquashfs wget rsync chroot mount umount curl sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing: $cmd (sudo apt install -y xorriso squashfs-tools wget rsync isolinux)" >&2
    exit 1
  }
done

# --- Defensive: always umount anything still mounted under $WORK BEFORE
# --- doing any rm. A previous killed build can leave /dev bind-mounted
# --- under the rootfs; `rm -rf` walking into a live bind mount will
# --- delete /dev/null (or worse) on the host.
purge_work_mounts() {
  local mp
  # Reverse order — inner mounts first (dev/pts before dev, etc.)
  # findmnt lists mount points as descendants of a target.
  while IFS= read -r mp; do
    [[ -n "$mp" ]] && umount -R "$mp" 2>/dev/null || umount "$mp" 2>/dev/null || true
  done < <(findmnt -R -n -o TARGET "$WORK" 2>/dev/null | tac)
  # Belt-and-suspenders: try the paths we know we mount.
  for m in "$CHROOT/dev/pts" "$CHROOT/dev/shm" "$CHROOT/dev/mqueue" \
           "$CHROOT/dev/hugepages" "$CHROOT/dev" \
           "$CHROOT/proc" "$CHROOT/sys" "$CHROOT/run" \
           "$ISO_MOUNT"; do
    umount "$m" 2>/dev/null || true
  done
}

# Refuse to continue (rather than rm -rf through a live bind mount) if any
# mount is still present at or under the given directory. Lists every mount
# on the host and filters by path prefix, so it works even when the
# directory itself is not a mount point.
assert_no_mounts_under() {
  local dir="$1" mp w found="" esc_space='\x20'
  w="${dir// /$esc_space}"   # findmnt -r prints spaces as \x20
  while IFS= read -r mp; do
    if [[ "$mp" == "$w" || "$mp" == "$w"/* ]]; then found+="$mp"$'\n'; fi
  done < <(findmnt -rn -o TARGET 2>/dev/null)
  if [[ -n "$found" ]]; then
    echo "refusing to continue: mounts still present under $dir:" >&2
    printf '%s' "$found" >&2
    echo "unmount them (umount -R) and re-run." >&2
    exit 1
  fi
}

purge_work_mounts
assert_no_mounts_under "$WORK"

if [[ "${1:-}" == "--clean" ]]; then
  say "clean: removing $WORK"
  rm -rf --one-file-system "$WORK"
fi
mkdir -p "$CACHE" "$WORK" "$ISO_ROOT" "$ISO_MOUNT" "$CHROOT"

# Track mounts for cleanup.
CLEANUP_MOUNTS=()
cleanup() {
  set +e
  # In reverse (LIFO).
  local i
  for (( i=${#CLEANUP_MOUNTS[@]}-1 ; i>=0 ; i-- )) ; do
    umount "${CLEANUP_MOUNTS[i]}" 2>/dev/null || umount -l "${CLEANUP_MOUNTS[i]}" 2>/dev/null || true
  done
  umount "$ISO_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- 1. Fetch upstream ISO ----------------------------------------------
if [[ ! -f "$UBUNTU_ISO" ]]; then
  say "downloading $UBUNTU_ISO_URL"
  wget --show-progress -c -O "$UBUNTU_ISO.part" "$UBUNTU_ISO_URL"
  mv "$UBUNTU_ISO.part" "$UBUNTU_ISO"
fi
# Verify the base image (fresh download OR cached file) against the pinned
# SHA-256 before it is mounted. A mismatch deletes the file and aborts.
say "verifying base ISO checksum"
echo "$UBUNTU_ISO_SHA256  $UBUNTU_ISO" | sha256sum -c - || {
  echo "base ISO checksum mismatch" >&2
  rm -f "$UBUNTU_ISO" "$UBUNTU_ISO.part"
  exit 1
}

# --- 2. Extract the ISO to iso-root -------------------------------------
say "extracting ISO to $ISO_ROOT"
mount -o loop,ro "$UBUNTU_ISO" "$ISO_MOUNT"
rsync -aH --delete --exclude=/casper "$ISO_MOUNT/" "$ISO_ROOT/"
mkdir -p "$ISO_ROOT/casper"
# Copy everything from casper EXCEPT the squashfs layers (we're replacing those).
rsync -aH --exclude='*.squashfs' "$ISO_MOUNT/casper/" "$ISO_ROOT/casper/"

# --- 3. Merge all squashfs layers into one rootfs -----------------------
say "unsquashing layered filesystem (this takes 5–10 min)"
assert_no_mounts_under "$CHROOT"
rm -rf --one-file-system "$CHROOT"
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
# - root-owned and not group/world-writable: root-run scripts are later
#   executed from here, so a regular user must not be able to edit them.
# - never ship untracked/ignored files or secret-looking files from the
#   builder's checkout (rsync does not read .gitignore unless told to).
rsync -a --chown=root:root --chmod=Dgo-w,Fgo-w \
  --filter=':- .gitignore' \
  --exclude='.git' --exclude='iso/build' --exclude='iso/cache' \
  --exclude='.env*' --exclude='*.pem' --exclude='*.key' --exclude='*.log' \
  --exclude='__pycache__' \
  "$REPO/" "$CHROOT/opt/flow-state-distro/"

# --- 5. Bind-mount runtime inside the chroot ---------------------------
for m in dev dev/pts proc sys run; do mkdir -p "$CHROOT/$m"; done
mount --bind /dev "$CHROOT/dev"; CLEANUP_MOUNTS+=("$CHROOT/dev")
mount --bind /dev/pts "$CHROOT/dev/pts"; CLEANUP_MOUNTS+=("$CHROOT/dev/pts")
mount -t proc proc "$CHROOT/proc"; CLEANUP_MOUNTS+=("$CHROOT/proc")
mount -t sysfs sysfs "$CHROOT/sys"; CLEANUP_MOUNTS+=("$CHROOT/sys")
mount -t tmpfs tmpfs "$CHROOT/run"; CLEANUP_MOUNTS+=("$CHROOT/run")
# The rootfs ships /etc/resolv.conf as a symlink into /run/systemd/resolve/
# which the tmpfs mount above turned into a dangling link. `cp -f` refuses
# to write through a dangling symlink, so delete it first, then drop the
# host's resolv.conf in as a real file. It gets restored to the symlink
# after the chroot pass so the live boot uses systemd-resolved normally.
rm -f "$CHROOT/etc/resolv.conf"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

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
