# Flow State — Linux distro design

**Date:** 2026-09-09
**Base:** Ubuntu 24.04.4 LTS (Noble Numbat) — matches this machine
**Author:** Claude Opus 4.7, with Will
**Status:** Draft (pending Codex review)

## 1. Goal

A Will-flavored Ubuntu remix that boots into a working DSIO agent environment
out of the box. One flash-to-USB → install → login → type `dsio`. No manual
setup after install.

Concretely, Flow State must:

1. Ship Ubuntu 24.04 with a Flow State identity (name, logo, wallpaper, splash,
   accent color) instead of the Ubuntu-orange defaults.
2. Come with the DSIO agent harness preinstalled — the same repo Will uses on
   Windows via `irm https://dsio.io/install.ps1 | iex`, but built into the OS
   image so the first `dsio` command works after a `dsio login`.
3. Fix middle-click **autoscroll** (hold middle mouse button, drag to scroll)
   on webpages by default. Broken today on this machine.
4. Reuse the Flow State brand from `jiujitsumagician/flowstate` — same logo,
   same blue as the tournament app, so all Flow State surfaces feel like one
   product line.

Non-goals (v1): custom kernel patches, custom package manager, custom desktop
environment. Stay on stock GNOME + snapd + apt to keep the maintenance surface
small.

## 2. Two-phase strategy

Phase 1 ships fast and de-risks Phase 2. Phase 2 is the shareable artifact.

**Phase 1 — reprovisioning scripts.** A single `bootstrap.sh` that turns a
fresh Ubuntu 24.04 install into Flow State. No ISO yet. This gets us:

- A repeatable, versioned definition of "what Flow State is."
- Fast iteration — every change is one script run away.
- The exact recipe we later bake into an ISO.
- Immediate value: Will can rerun it on this machine to keep the harness
  fresh, and re-run it on any Ubuntu box.

**Phase 2 — ISO build.** Wrap Phase 1 into an installable `.iso` using
Cubic (see §5). The ISO is a shareable Ubuntu-based remix that anyone can
flash and install; the installer's first-boot hook runs `bootstrap.sh` to
personalize per user.

## 3. Phase 1 — `bootstrap.sh`

**Repo layout** (new: `~/flow-state-distro/`, later `jiujitsumagician/flow-state-distro`):

```
flow-state-distro/
  bootstrap.sh              # entrypoint; idempotent; safe to re-run
  scripts/
    01-apt-packages.sh      # base packages (nodejs, git, gh, curl, jq, ...)
    02-nodejs.sh            # Node 24 via NodeSource (harness engines >=24)
    03-dsio-harness.sh      # clone + build + shim + MCP register
    04-autoscroll.sh        # Firefox user.js + Chrome .desktop override
    05-branding.sh          # wallpaper, gsettings accent, avatar
    06-terminal-welcome.sh  # first-login "type `dsio` here" nudge
  branding/
    flowstate-logo.png      # from jiujitsumagician/flowstate/public
    wallpaper-1440p.png     # generated
    wallpaper-4k.png        # generated
    os-release              # ID=flowstate PRETTY_NAME="Flow State"
    plymouth/               # boot splash (Phase 2 uses this)
    grub/                   # boot menu theme (Phase 2)
  README.md
```

**What `bootstrap.sh` does, in order:**

1. **Preflight:** confirm Ubuntu 24.04, refuse otherwise. Refresh `apt`.
2. **APT packages:** `git`, `gh`, `curl`, `jq`, `build-essential`, `xdotool`,
   `dconf-cli`, `imagemagick` (for branding), `neovim`, `htop`, `tmux`.
3. **Node 24:** install from NodeSource (`setup_24.x`) if `node -v` is not
   `>=24`. Today's machine has Node 22 and the harness builds fine on 22, so
   this is defensive — the harness declares `engines: >=24` and future
   dependencies may enforce it.
4. **Global npm CLIs:** `@anthropic-ai/claude-code`, `@openai/codex` (skip if
   already present).
5. **Ollama:** install via the upstream script (`curl https://ollama.com/install.sh | sh`)
   unless already present. Pull `qwen2.5-coder:14b` if VRAM ≥16GB, else `:7b`.
   Enable systemd service.
6. **DSIO harness:**
   - Clone `git@github.com:jiujitsumagician/dsio.git` (or `gh repo clone`) to
     `~/dsio-harness`. Update via `git pull` if already cloned.
   - `npm install --no-audit --no-fund && npm run build`.
   - Copy `.env.example` → `.env` if missing.
   - Write `~/.local/bin/dsio` shim (bash exec node …/dsio/index.js).
   - Register user-scope MCP: `claude mcp add --scope user dsio -- node --no-warnings /home/$USER/dsio-harness/dist/src/cli/index.js serve`.
7. **Autoscroll fix:**
   - Firefox: write `user.js` with `general.autoScroll=true` into every profile
     under `~/snap/firefox/common/.mozilla/firefox/*.default*/` and
     `~/.mozilla/firefox/*.default*/`.
   - Chrome: place `~/.local/share/applications/google-chrome.desktop` with
     `--enable-features=MiddleClickAutoscroll` in the Exec line.
   - Both changes require a browser restart to take effect; script prints a
     one-line hint.
8. **Branding:**
   - Copy `branding/wallpaper-*.png` to `~/.local/share/backgrounds/`.
   - `gsettings set org.gnome.desktop.background picture-uri` → new wallpaper.
   - `gsettings set org.gnome.desktop.interface accent-color` → Flow State blue.
   - Replace `~/.face` with the Flow State logo so GDM shows it.
   - (System-level `/etc/os-release`, GRUB, Plymouth: deferred to Phase 2.)
9. **First-login welcome:** an autostart `.desktop` in
   `~/.config/autostart/flow-state-welcome.desktop` that opens a GNOME Terminal
   the first time the user logs in, prints a Flow-State-blue banner, and drops
   the user at a shell with `dsio login` suggested. Marker file
   `~/.config/flow-state-welcomed` prevents it firing twice.
10. **Log everything** to `~/flow-state-distro/bootstrap.log`. Exit non-zero on
    any step failure so the user notices.

**Idempotency:** every step checks state first. Re-running the script is a
no-op if nothing has changed. That matters because Phase 2's ISO first-boot
hook will run it once, and Will may re-run it manually to update.

**Testing Phase 1 today:**

- Run it on this machine — most of it is already applied by tonight's session,
  so the script should mostly be no-op. Anything not idempotent is a bug.
- Spin up a fresh Ubuntu 24.04 VM (KVM/qemu, disk 30GB, 4 vCPU, 8GB RAM), run
  `bootstrap.sh`, verify: `dsio` runs, `dsio status` shows Claude+Codex+Ollama
  OK, Firefox autoscrolls, Chrome autoscrolls, wallpaper is Flow State blue.

## 4. Middle-click autoscroll — the details

**Goal restated:** the same *function* as Windows autoscroll, everywhere —
browsers, Word/LibreOffice docs, file managers, PDF viewers, text editors,
terminals. Not "browser-only", which is what a per-app pref pass gets you.

**Approach: an evdev+uinput daemon (`flow-state-autoscroll.service`).** A
small Python daemon runs as a system service. On start it:

1. Enumerates `/dev/input/event*`, filters to devices that look like mice
   (`BTN_LEFT + BTN_MIDDLE + REL_X + REL_Y`), and dedupes multi-interface
   HID devices by physical root so a single mouse is only grabbed once.
2. Grabs those devices exclusively.
3. Creates one virtual mouse via `uinput` with the union of the real mice's
   capabilities, plus `REL_WHEEL_HI_RES` / `REL_HWHEEL_HI_RES`.
4. Forwards every event through to the virtual device *except* the middle
   button and (while it is held) motion.

The intercept:

- Press middle button → daemon starts buffering. Cursor freezes (motion no
  longer forwarded), just like a Windows autoscroll anchor.
- Motion of > 3 px total: enter "scrolling" mode. Accumulated vertical
  motion drains into `REL_WHEEL` / `REL_WHEEL_HI_RES` notches at 1 notch
  per 8 px; horizontal into `REL_HWHEEL` at 1 notch per 12 px.
- Release middle button. If scrolling was entered, no click is emitted (the
  release was the exit gesture, not a click). If no motion crossed the 3 px
  threshold, the daemon emits a synthetic middle-press + middle-release so
  quick middle-clicks (paste, open-in-new-tab, terminal tab, etc.) still work.

Because the compositor sees only the virtual device's stream, this works
identically for X11 and Wayland and for every toolkit: GTK, Qt, Electron,
Chromium, Firefox (snap), LibreOffice, JetBrains, Godot, terminals, and
random legacy X apps. It works because every one of them reads scroll events
the same way — from the input subsystem's wheel codes.

**Cost of this approach:**

- Runs as root (needs raw access to `/dev/input/event*` and `/dev/uinput`).
  Systemd unit is hardened with `NoNewPrivileges=true`,
  `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`.
- Middle-click normal function is preserved via the "click without motion"
  branch — a real user gesture (press, release without moving) still
  reaches apps as a plain middle-click.
- Cursor freeze is inherent to grabbing motion during autoscroll. This
  matches Windows behavior (Windows freezes the cursor at the click point
  and shows a four-arrow icon).

**What is out of scope for v1:**

- The four-arrow autoscroll cursor overlay. Adding this cleanly requires a
  compositor-level effect (GNOME extension on Wayland, a small X11 overlay
  window on X11). Deferred.
- Windows-style "click-once toggle-glide" mode (single middle-click enters
  perpetual autoscroll until any next click). Trivial to add on top of the
  current daemon — swap the hold-drag state machine for a toggle one — but
  it would consume normal middle-click functionality, which Linux users
  rely on. Keep hold-drag as the default; a config flag can flip to toggle
  later.

**Files produced (`flow-state-distro/scripts/`):**

- `autoscrolld.py` — the daemon.
- `flow-state-autoscroll.service` — systemd unit.
- `install-autoscroll.sh` — one-shot installer (`apt install python3-evdev`,
  `modprobe uinput` + persistent load, deploy to `/opt/flow-state/`, enable
  + start service). Requires `sudo` on first run.

**Testing:**

- Verify service runs: `systemctl status flow-state-autoscroll`.
- Verify virtual device exists: `xinput list | grep flow-state-autoscroll`.
- In Firefox, Chrome, LibreOffice Writer, GNOME Files (Nautilus), Evince,
  and GNOME Terminal: hold middle mouse button on any scrollable content,
  drag, page scrolls. Release, page stops. Quick middle-click still pastes
  or opens links in a new tab.
- Regression check: normal cursor motion, left/right click, scroll wheel,
  side buttons all still work identically to before.

**Fallback for browser-only surface (retained):** the Firefox `user.js`
and the Chrome `.desktop` `--enable-features=MiddleClickAutoscroll` written
during this session stay in place. They are redundant with the daemon but
harmless — the daemon grabs middle-clicks before Firefox/Chrome ever see
them, so their internal autoscroll never activates.

## 5. Phase 2 — ISO build

**Direction: scripted ISO build, not GUI-driven.** Codex's review pushed
back on Cubic as the primary tool because a GUI/chroot-driven build is hard
to review, diff, CI, or reproduce. That review is correct once Flow State
becomes a shippable artifact rather than a personal remix.

**Recommended pipeline (Phase 2.0):** a bash script that follows the same
shape as `livecd-rootfs`:

1. Pull the official `ubuntu-24.04.4-desktop-amd64.iso` at a pinned
   checksum. Fail if the checksum drifts.
2. `unsquashfs` the live filesystem to a build dir.
3. `chroot` in, run `bootstrap-system.sh` (see §7) against a controlled
   apt state: pinned NodeSource keyring + repo, pinned harness commit
   (via `.deb` — see §7), pinned Ollama version. Everything the ISO
   installs comes from a signed source with a recorded checksum.
4. Bake branding at system level (paths, files below).
5. `mksquashfs` the modified rootfs. Rebuild the ISO with `xorriso`
   preserving GPT + BIOS/UEFI boot records.
6. Emit a build manifest: input ISO checksum, package list, `.deb`
   checksums, resulting ISO checksum.
7. Boot the ISO in `qemu` as part of the same script (`--test`) so a
   build that produces a non-booting ISO is caught before publish.

**Cubic is fine as a prototype** for iterating on branding assets and
first-boot UX (unpack once in the GUI, tweak visually, repack). Once the
result is what we want, the recipe gets ported into the scripted build.
Cubic is not the release build tool.

**Alternatives kept in reserve:**

- `live-build` (Debian's tool). Well-trodden; the tradeoff is that it
  wants a full config tree of its own rather than "here is a rootfs,
  respin it." Adopt if the ad-hoc script grows past ~300 lines.
- Ubuntu autoinstall / subiquity. Wrong shape — produces server installs,
  not a live-desktop ISO.

**System-level branding baked into the ISO:**

- `/etc/os-release`: `PRETTY_NAME="Flow State 1.0 (Noble Numbat remix)"`,
  `VARIANT="Flow State"`, `VARIANT_ID=flowstate`,
  `HOME_URL="https://dsio.io"`. **Leave `ID=ubuntu`, `ID_LIKE="debian"`,
  and `VERSION_CODENAME=noble` in place.** Vendor install scripts (Chrome,
  NodeSource, ROCm, VS Code, Docker) branch on `ID`/`VERSION_CODENAME`;
  changing them to `flowstate` breaks those scripts silently. Codex C.3.
- `/usr/share/backgrounds/flow-state/*.png` + a
  `/usr/share/glib-2.0/schemas/90-flow-state.gschema.override` that sets
  the default wallpaper and accent color for new user accounts.
- Plymouth theme in `/usr/share/plymouth/themes/flow-state/`, activated
  with `update-alternatives`. Boot splash = Flow State logo on blue.
- GRUB theme in `/boot/grub/themes/flow-state/`, referenced from
  `/etc/default/grub` `GRUB_THEME=`.
- GDM logo/background via `/etc/dconf/db/gdm.d/00-flow-state`.

**ISO output:** `flow-state-1.0-amd64.iso`, hosted (Phase 2.5) at
`dsio.io/download/flow-state-1.0.iso` or a Cloudflare R2 bucket.

**Signing / integrity:** SHA256SUMS + a detached GPG signature with Will's
key. Not code-signed for Secure Boot in v1 — users installing this will need
Secure Boot off or use the standard "Install anyway" flow. Add shim-signed
Secure Boot support later if it matters.

## 6. Branding pass

- **Logo:** `jiujitsumagician/flowstate/public/flowstate-logo.png` (500x500
  RGBA). Vectorize into an SVG for scaling if we don't already have one;
  ImageMagick + `potrace` can do a first pass.
- **Accent color:** DSIO uses `#3D8FD4` (from `install.ps1`). Flow State
  should be its own hue — pull from the flowstate logo directly. Placeholder:
  `#185FA5` (DSIO deep blue) until we sample.
- **Wallpaper:** designed 1440p + 4K. Simple: logo bottom-right, radial
  gradient of Flow-State-blue, subtle grid or particle field. Generated by
  Will's design tools, not this spec.
- **Distro name string:** "Flow State" everywhere the user sees the OS name.
  `lsb_release -d` → `Flow State 1.0 (Noble Numbat remix)`.
- **Terminal:** GNOME Terminal remains default. Ship a `flow-state-blue.gschema`
  color profile as the default so a fresh terminal opens in Flow State colors.

## 7. DSIO harness — what "preinstalled" means

**Codex C.2 is a hard blocker on baking the harness into the ISO.** The
harness lives at `jiujitsumagician/dsio`, a private repo. If a shipped ISO
contains the source, everyone who downloads Flow State has that source —
the "private" status becomes fiction. Same problem baking a checkout into
`/opt/`. Fix: **the ISO ships the harness's *prerequisites and installer*,
not the harness source**.

**What the ISO bakes system-wide:**

- Node 24 (NodeSource apt source, pinned).
- Ollama (upstream install, pinned) + `qwen2.5-coder:14b` weights so
  first-boot doesn't wait on an 8 GB download.
- `@anthropic-ai/claude-code` and `@openai/codex` installed globally via
  npm.
- The `flow-state-autoscroll` daemon as a `.deb` (see §8) so the systemd
  unit, uinput module config, and daemon source are one package.
- The Flow State branding (Plymouth, GRUB, GDM, wallpapers, os-release
  overlay).
- The `flow-state-dsio` first-login helper (`~/.local/share/flow-state/`)
  that runs at first shell open per user, prompts `dsio login`, and lets
  the DSIO harness bootstrap itself from GitHub with the user's own `gh`
  auth. This is the same flow as
  `irm https://dsio.io/install.ps1 | iex` on Windows — hosted, versioned,
  authored in the DSIO repo, not baked into Flow State's ISO.

**What the ISO does NOT bake:**

- The DSIO repo itself (private).
- Any DSIO credentials, model tokens, or vault contents.

**Trade-off:** first login on a fresh Flow State install still requires
network access + a `gh auth login` browser flow. That's the correct
behavior for a distro whose harness is per-user-authenticated. Users who
run Flow State air-gapped can pre-clone the harness into `~/dsio-harness`
themselves; the first-login helper detects it and skips the online step.

**Update path:** `dsio update` (already in the harness) pulls, rebuilds,
relaunches. No distro-level updater needed for the harness. Ubuntu's own
`apt update` handles system packages.

## 8. Open questions / risks

1. **Chrome + license:** shipping Chrome in the ISO requires Google's
   redistribution terms. Chromium is fine but Will's setup uses Chrome. Either
   ship Chromium and let users install Chrome themselves, or ship a stub
   installer.
2. **Snap Firefox reproducibility:** Firefox on Ubuntu 24.04 is snap-only by
   default. Snap versioning drifts. If ISO reproducibility matters,
   consider swapping to Firefox ESR from Mozilla's official APT repo.
3. **HWE kernel drift:** this machine runs 6.17-HWE; stock 24.04.4 ships
   6.8. HWE is opt-in via `linux-generic-hwe-24.04`. Decide whether Flow
   State bakes HWE by default (safer for newer hardware like Will's 9060 XT).
4. **AMD ROCm:** Will's `amdgpu-install_7.2.3.70203-1_all.deb` isn't part of
   stock Ubuntu. If we want Ollama-on-GPU by default, bake ROCm 7.2. If we
   don't, Qwen runs on CPU and is much slower. Recommend baking ROCm for the
   AMD-GPU install variant; keep a CPU-only ISO as fallback.
5. **Middle-click autoscroll on Chrome/Linux:** the flag may not actually
   surface autoscroll on Linux builds. Empirically verify on this machine
   before promising it in the ISO. If it doesn't work, use the extension
   fallback via `ExtensionInstallForcelist` policy.
6. **Secure Boot:** unsigned ISOs are a friction point. Not blocking v1.
7. **First-login flow:** need to decide UX. Options: (a) drop user at a
   normal GNOME desktop, autostart shows a Flow State terminal running
   `dsio login`; (b) run a GNOME Initial Setup replacement branded as
   Flow State that walks through Ubuntu setup + `dsio login` in one flow.
   (a) is much less work.
8. **Update cadence:** Flow State needs its own release track. Recommend
   Flow State X.Y where X is major (rebase to newer Ubuntu LTS) and Y is
   minor (config/harness bumps). v1 targets Ubuntu 24.04; v2 targets 26.04
   when it ships.

## 9. Milestones

- **M0** (this session): DSIO harness installed on Will's current machine,
  middle-click autoscroll patched for Firefox + Chrome. DONE.
- **M1:** `bootstrap.sh` extracted from what we did tonight, versioned in a
  new `jiujitsumagician/flow-state-distro` repo. Re-run on this machine
  should be a no-op.
- **M2:** Fresh Ubuntu 24.04 VM + `bootstrap.sh` → verified Flow State
  environment. Screenshot for the record.
- **M3:** First Cubic ISO build, boots in qemu, `dsio` works after first-
  login flow.
- **M4:** ISO burned to USB, installed on a real second machine, works.
  This is when Flow State is "shippable."
- **M5** (stretch): Signed release published, dsio.io/download link live.

## 10. Immediate next step

Approve or redirect this design. On approval, next skill is `writing-plans`
to produce an implementation plan for M1 (extract `bootstrap.sh` from
tonight's work, structure the repo, prove idempotency on this machine).
