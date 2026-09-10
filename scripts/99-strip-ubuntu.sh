#!/usr/bin/env bash
# 99 — Strip Ubuntu identity: wallpapers, branding, Plymouth theme, GRUB.
#
# Runs as root. Removes every Ubuntu-branded wallpaper the distro ships
# with, plus the artwork packages that add Ubuntu Plymouth/GRUB themes.
# Replaces user-facing name strings with "Flow State" while keeping
# ID=ubuntu / VERSION_CODENAME=noble intact so third-party vendor
# install scripts still recognise the base.
#
# Non-destructive to installed apps — this only strips artwork.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "99-strip-ubuntu.sh needs root; try: sudo bash $0" >&2
  exit 1
fi

BLUE='\033[38;2;255;40;40m'; RESET='\033[0m'
say() { printf "${BLUE}==>${RESET} %s\n" "$*"; }

# 1. Purge Ubuntu wallpaper packages.
say "purging Ubuntu wallpaper packages"
DEBIAN_FRONTEND=noninteractive apt-get purge -y \
  ubuntu-wallpapers ubuntu-wallpapers-* \
  2>/dev/null || true
# NOTE: ubuntu-artwork is intentionally NOT purged — it pulls a lot of
# essential icons and themes. Instead we just override its wallpaper XML
# in step 3, and Plymouth/GRUB in steps 8/9.

# 2. Nuke any leftover wallpaper files that come from other packages.
say "removing stray wallpaper files under /usr/share/backgrounds/"
# The `ubuntu-wallpapers` purge may have removed the directory entirely.
# Recreate it so subsequent steps have a stable target, then clean it.
install -d -m 0755 /usr/share/backgrounds
find /usr/share/backgrounds -maxdepth 1 -type f \
  \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \) \
  ! -path '*/flow-state/*' -delete 2>/dev/null || true
# Delete every Ubuntu wallpaper subdirectory (warty-final-ubuntu, noble, etc.)
find /usr/share/backgrounds -maxdepth 1 -type d ! -name flow-state ! -name backgrounds -mindepth 1 -exec rm -rf {} + 2>/dev/null || true

# 2b. Install the Flow State wallpapers system-wide (05-branding.sh's
# system half). During an ISO build no user session exists, so the
# system layer is where wallpapers must land.
BRAND_WPS=""
for candidate in /opt/flow-state-distro/branding/wallpapers \
                 /home/*/flow-state-distro/branding/wallpapers; do
  if [[ -d "$candidate" ]]; then BRAND_WPS="$candidate"; break; fi
done
if [[ -n "$BRAND_WPS" ]]; then
  install -d -m 0755 /usr/share/backgrounds/flow-state
  for w in "$BRAND_WPS"/*.jpg "$BRAND_WPS"/*.png; do
    [[ -f "$w" ]] || continue
    install -m 0644 "$w" /usr/share/backgrounds/flow-state/
  done
  install -d -m 0755 /usr/share/gnome-background-properties
  cat > /usr/share/gnome-background-properties/flow-state-wallpapers.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
  <wallpaper><name>Flow State — Stripe</name><filename>/usr/share/backgrounds/flow-state/flow-state-stripe.png</filename><options>zoom</options><pcolor>#050505</pcolor><scolor>#050505</scolor><shade_type>solid</shade_type></wallpaper>
  <wallpaper><name>Flow State — Horizon</name><filename>/usr/share/backgrounds/flow-state/flow-state-horizon.png</filename><options>zoom</options><pcolor>#0a0a0a</pcolor><scolor>#0a0a0a</scolor><shade_type>solid</shade_type></wallpaper>
  <wallpaper><name>Flow State — Crystal</name><filename>/usr/share/backgrounds/flow-state/flow-state-crystal.png</filename><options>zoom</options><pcolor>#1a1a1a</pcolor><scolor>#1a1a1a</scolor><shade_type>solid</shade_type></wallpaper>
  <wallpaper><name>Flow State — Glass</name><filename>/usr/share/backgrounds/flow-state/flow-state-glass.png</filename><options>zoom</options><pcolor>#c8c8c8</pcolor><scolor>#c8c8c8</scolor><shade_type>solid</shade_type></wallpaper>
  <wallpaper><name>Flow State — Grid</name><filename>/usr/share/backgrounds/flow-state/flow-state-grid.png</filename><options>zoom</options><pcolor>#080808</pcolor><scolor>#080808</scolor><shade_type>solid</shade_type></wallpaper>
  <wallpaper><name>Flow State — Drift</name><filename>/usr/share/backgrounds/flow-state/flow-state-drift.png</filename><options>zoom</options><pcolor>#0d0d0d</pcolor><scolor>#0d0d0d</scolor><shade_type>solid</shade_type></wallpaper>
  <wallpaper><name>Flow State — Aurora</name><filename>/usr/share/backgrounds/flow-state/flow-state-aurora.jpg</filename><options>zoom</options><pcolor>#0b1d3f</pcolor><scolor>#0b1d3f</scolor><shade_type>solid</shade_type></wallpaper>
  <wallpaper><name>Flow State — Nebula</name><filename>/usr/share/backgrounds/flow-state/flow-state-nebula.jpg</filename><options>zoom</options><pcolor>#2b0a3f</pcolor><scolor>#2b0a3f</scolor><shade_type>solid</shade_type></wallpaper>
  <wallpaper><name>Flow State — Ember</name><filename>/usr/share/backgrounds/flow-state/flow-state-ember.jpg</filename><options>zoom</options><pcolor>#3f0b18</pcolor><scolor>#3f0b18</scolor><shade_type>solid</shade_type></wallpaper>
</wallpapers>
XML

  # Also make Stripe the system-wide default wallpaper via a gschema
  # override, so every new user gets Flow State on first login.
  install -d -m 0755 /usr/share/glib-2.0/schemas
  cat > /usr/share/glib-2.0/schemas/90-flow-state-defaults.gschema.override <<'OVR'
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/flow-state/flow-state-stripe.png'
picture-uri-dark='file:///usr/share/backgrounds/flow-state/flow-state-stripe.png'
picture-options='zoom'

[org.gnome.desktop.screensaver]
picture-uri='file:///usr/share/backgrounds/flow-state/flow-state-stripe.png'

[org.gnome.desktop.interface]
color-scheme='prefer-dark'
accent-color='blue'
OVR
  glib-compile-schemas /usr/share/glib-2.0/schemas 2>&1 | head -1 || true
fi

# 3. Remove every non-Flow-State gnome-background-properties XML so the
# picker only shows Flow State.
say "removing non-Flow-State gnome-background-properties"
for xml in /usr/share/gnome-background-properties/*.xml; do
  [[ -f "$xml" ]] || continue
  case "$(basename "$xml")" in
    flow-state-*) continue ;;
    *) rm -f "$xml" ;;
  esac
done

# 4. os-release — user-facing names swap to Flow State; ID stays 'ubuntu'
# so vendor apt scripts still work (Codex C.3).
say "stamping /etc/os-release with Flow State strings"
python3 - <<'PY'
path = "/etc/os-release"
kv = {}
with open(path) as f:
    for line in f:
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            kv[k] = v.strip('"')
# Preserve ID / VERSION_CODENAME / ID_LIKE.
kv["NAME"] = "Flow State"
kv["PRETTY_NAME"] = "Flow State 0.1 (Noble Numbat remix)"
kv["VARIANT"] = "Flow State"
kv["VARIANT_ID"] = "flowstate"
kv["HOME_URL"] = "https://dsio.io/flow-state"
kv["SUPPORT_URL"] = "https://github.com/jiujitsumagician/flow-state-distro/issues"
kv["BUG_REPORT_URL"] = "https://github.com/jiujitsumagician/flow-state-distro/issues"
kv["PRIVACY_POLICY_URL"] = "https://dsio.io"
kv["LOGO"] = "flow-state"
with open(path, "w") as f:
    for k in ("NAME","VERSION","ID","ID_LIKE","PRETTY_NAME","VERSION_ID",
              "HOME_URL","SUPPORT_URL","BUG_REPORT_URL","PRIVACY_POLICY_URL",
              "VERSION_CODENAME","UBUNTU_CODENAME","VARIANT","VARIANT_ID","LOGO"):
        if k in kv:
            f.write(f'{k}="{kv[k]}"\n')
PY

# 5. /etc/issue + /etc/issue.net — the message on TTY login.
say "rewriting /etc/issue and /etc/issue.net"
printf 'Flow State 0.1 \\l\n\n' > /etc/issue
printf 'Flow State 0.1\n' > /etc/issue.net

# 6. /etc/lsb-release — some scripts read this instead of os-release.
say "rewriting /etc/lsb-release"
cat > /etc/lsb-release <<EOF
DISTRIB_ID=Ubuntu
DISTRIB_RELEASE=24.04
DISTRIB_CODENAME=noble
DISTRIB_DESCRIPTION="Flow State 0.1 (Noble Numbat remix)"
EOF

# 7. Motd — the login banner. Ubuntu's is dynamic (update-motd.d). Keep
# system-info modules; kill just the "Welcome to Ubuntu" header.
say "trimming motd of Ubuntu greeter"
rm -f /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news /etc/update-motd.d/00-header
cat > /etc/update-motd.d/00-flow-state-header <<'EOF'
#!/usr/bin/env bash
BLUE=$'\033[38;2;255;40;40m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
printf '\n%sFlow State%s — where the machine gets out of your way.\n\n' "$BOLD$BLUE" "$RESET"
EOF
chmod +x /etc/update-motd.d/00-flow-state-header

# 8. Plymouth boot splash — replace Ubuntu's with a minimal Flow State
# theme that just shows the Flow State logo on a black background.
say "installing Flow State Plymouth theme"
THEME=/usr/share/plymouth/themes/flow-state
install -d -m 0755 "$THEME"
# Copy the icon (installed by earlier steps under hicolor).
for size in 256 128 64; do
  src=/usr/share/icons/hicolor/${size}x${size}/apps/flow-state.png
  [[ -f "$src" ]] && { cp "$src" "$THEME/logo.png"; break; }
done
cat > "$THEME/flow-state.plymouth" <<EOF
[Plymouth Theme]
Name=Flow State
Description=Flow State boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/flow-state
ScriptFile=/usr/share/plymouth/themes/flow-state/flow-state.script
EOF
cat > "$THEME/flow-state.script" <<'EOF'
Window.SetBackgroundTopColor(0, 0, 0);
Window.SetBackgroundBottomColor(0, 0, 0);
logo.image = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(Window.GetX() + (Window.GetWidth() - logo.image.GetWidth()) / 2);
logo.sprite.SetY(Window.GetY() + (Window.GetHeight() - logo.image.GetHeight()) / 2);
EOF
# Activate as the default Plymouth theme.
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
  plymouth-set-default-theme -R flow-state 2>/dev/null || \
    plymouth-set-default-theme flow-state || true
fi
# Refresh initrd so Plymouth picks up the change on next boot.
if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u 2>/dev/null || true
fi

# 9. GRUB — drop the Ubuntu distributor string; boot menu says Flow State.
say "rewriting /etc/default/grub distributor string"
if [[ -f /etc/default/grub ]]; then
  sed -i \
    -e 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Flow State"/' \
    /etc/default/grub
  if command -v update-grub >/dev/null 2>&1; then
    update-grub 2>/dev/null || true
  fi
fi

echo
echo "==> Ubuntu identity stripped. Flow State branding is the only default."
