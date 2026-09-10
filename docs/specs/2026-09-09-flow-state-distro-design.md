# Flow State — Linux distro design

**Date:** 2026-09-09
**Base:** Ubuntu 24.04.4 LTS (Noble Numbat) — matches this machine
**Author:** Claude Opus 4.7, with Will
**Status:** Draft v2 (Codex-reviewed)

## 1. Goal

A Will-flavored Ubuntu remix that boots into a working DSIO agent environment
out of the box. One flash-to-USB → install → login → type `dsio`. No manual
setup after install.

Concretely, Flow State must:

1. Ship Ubuntu 24.04 with a Flow State identity (name, logo, wallpaper, splash,
   accent color) instead of the Ubuntu-orange defaults.
2. Come with the DSIO agent harness bootstrapper preinstalled — the same shape
   as `irm https://dsio.io/install.ps1 | iex` on Windows, but hosted at
   `dsio.io/install.sh` and invoked from a first-login helper on Flow State.
   Post-install: type `dsio login` once, everything comes down.
3. Fix middle-click **autoscroll** (hold middle mouse button, drag to scroll)
   *system-wide* — browsers, LibreOffice, Nautilus, terminals, snap apps.
4. Reuse the Flow State brand from `jiujitsumagician/flowstate` — same logo,
   same blue as the tournament app, so all Flow State surfaces feel like one
   product line.

Non-goals (v1): custom kernel patches, custom package manager, custom desktop
environment. Stay on stock GNOME + snapd + apt to keep the maintenance surface
small.

## 2. Two-phase strategy

Phase 1 ships fast and de-risks Phase 2. Phase 2 is the shareable artifact.

**Phase 1 — reprovisioning scripts.** A `bootstrap.sh` that turns a fresh
Ubuntu 24.04 install into Flow State. No ISO yet. This gets us:

- A repeatable, versioned definition of "what Flow State is."
- Fast iteration — every change is one script run away.
- The exact recipe we later bake into an ISO.
- Immediate value: Will can rerun it on this machine to keep the harness
  fresh, and re-run it on any Ubuntu box.

**Phase 2 — ISO build.** Wrap Phase 1 into an installable `.iso` using a
scripted `unsquashfs → chroot → mksquashfs → xorriso` pipeline (see §5).
The ISO is a shareable Ubuntu-based remix that anyone can flash and
install; the installer's first-boot hook runs the user-scope part of
`bootstrap.sh` to personalize per user.

**Split now, not later** (Codex C.6). Phase 1 is authored as two
entrypoints from the start, both invoked by the top-level `bootstrap.sh`:

- `bootstrap-system.sh` — apt packages, Node source, Ollama service,
  daemon `.deb` install, system-wide branding hooks. Runs as root.
  Same script the ISO chroot will run.
- `bootstrap-user.sh` — DSIO harness clone/build under `$HOME`, `dsio`
  shim on PATH, MCP register, per-user branding (wallpaper, accent),
  welcome banner. Runs as the login user. Same script the ISO's
  first-login hook will run.

## 3. Phase 1 — repo layout

```
flow-state-distro/
  bootstrap.sh              # top-level entrypoint; calls the two below
  bootstrap-system.sh       # root-scope work (Phase 1 + ISO chroot re-use this)
  bootstrap-user.sh         # user-scope work (Phase 1 + first-login re-use this)
  scripts/                  # step scripts sourced by both entrypoints
    01-apt-packages.sh
    02-nodejs.sh
    03-dsio-harness.sh
    04-autoscroll.sh
    05-branding.sh
    06-terminal-welcome.sh
  packages/                 # Debian packaging tree (Phase 1.5)
    flow-state-autoscroll/  # .deb wrapping the daemon + systemd unit
    flow-state-branding/    # .deb wrapping wallpapers + Plymouth + GRUB theme
  branding/
    flowstate-logo.png
    wallpaper-*.png
    plymouth/
    grub/
  iso/                      # Phase 2 build recipe
    build-iso.sh
    manifest.yaml
  README.md
```

**Ordered steps** (each script idempotent; re-run is a no-op):

1. **Preflight** — confirm Ubuntu 24.04, refuse otherwise.
2. **APT packages** — `git`, `gh`, `curl`, `jq`, `build-essential`,
   `python3-evdev` (autoscroll daemon), `imagemagick` (wallpaper pipeline),
   `dconf-cli`, `xdotool`.
3. **Node 24** — install from NodeSource if `node -v` is below 22.
4. **Global CLIs** — `@anthropic-ai/claude-code`, `@openai/codex` via `npm -g`.
5. **Ollama** — upstream install script, service enabled, `qwen2.5-coder:14b`
   pulled (7B on machines with < 16 GB VRAM).
6. **DSIO harness** — user-scope (`03-dsio-harness.sh`). `gh` login if
   missing → `gh repo clone jiujitsumagician/dsio ~/dsio-harness` →
   `npm install && npm run build` → `~/.local/bin/dsio` shim → user-scope
   MCP register via `claude mcp add`.
7. **Autoscroll** — installs the `flow-state-autoscroll` daemon system-wide
   (via `install-autoscroll.sh` for Phase 1; via the `.deb` for Phase 2).
   Browser-level fallbacks (Firefox `general.autoScroll`, Chrome
   `MiddleClickAutoscroll` flag) are opt-in via `FLOWSTATE_BROWSER_AUTOSCROLL=1`
   and OFF by default — the daemon covers the same ground and Codex flagged
   two overlapping behaviors as a debug hazard (C.4).
8. **Branding** — user-scope wallpaper + accent color + `~/.face`. System
   branding (Plymouth, GRUB, GDM, os-release VARIANT overlay) is Phase 2.
9. **First-login welcome** — one-shot autostart terminal that runs `dsio
   login` on the first shell open per user account.
10. **Log** everything to `bootstrap.log`; non-zero exit on any step failure.

**Testing Phase 1 today:**

- Re-run on this machine — most work from tonight is already applied, so
  the script should mostly no-op. Anything not idempotent is a bug.
- Fresh Ubuntu 24.04 VM (KVM/qemu, 30 GB disk, 4 vCPU, 8 GB RAM), run
  `bootstrap.sh`, verify: `dsio` works, `dsio status` shows Claude+Codex+
  Ollama OK, middle-mouse-drag scrolls in Firefox, LibreOffice Writer,
  Nautilus, and a plain terminal.

## 4. Middle-click autoscroll — the details

**Goal restated:** the same *function* as Windows autoscroll, everywhere —
browsers, Word/LibreOffice docs, file managers, PDF viewers, text editors,
terminals. Not "browser-only", which is what a per-app pref pass gets you.

**Approach: an evdev+uinput daemon (`flow-state-autoscroll.service`).** A
small Python daemon runs as a system service. On start it:

1. Enumerates `/dev/input/event*`, filters to devices that look like mice
   (`BTN_LEFT + BTN_MIDDLE + REL_X + REL_Y`).
2. **Grabs every mouse-like event node** (not just one per physical mouse),
   so a secondary HID interface's raw middle-click cannot leak past the
   daemon to the compositor. State is grouped by physical root, so a
   two-interface Razer / Logitech G shares one state object.
3. Creates one virtual mouse via `uinput` with the union of the real mice's
   capabilities (EV_KEY, EV_REL, EV_MSC), plus `REL_WHEEL_HI_RES` /
   `REL_HWHEEL_HI_RES` even if a source mouse omits them.
4. Forwards every event through to the virtual device *except*: (a) the raw
   middle button, and (b) motion while middle is held. Only event codes the
   virtual device advertises are forwarded — anything else is dropped so a
   `uinput.write` never crashes the daemon (Codex A.1).

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
random legacy X apps.

**Resilience:**

- Every mouse event node is grabbed. A hot-plugged mouse triggers a udev
  rule (`70-flow-state-autoscroll.rules`) that runs `systemctl try-restart
  flow-state-autoscroll.service`, causing the daemon to re-enumerate.
  (Codex A.2 recommended rescan-on-hotplug; udev-triggered restart is the
  simplest correct implementation.)
- `dispatch()` runs inside a `try/except` — a single bad event logs and
  continues rather than killing the daemon (Codex A.4).
- SIGTERM handler releases every grab cleanly before exit, so `systemctl
  stop` never leaves the mouse dead.
- Systemd unit uses `Restart=on-failure`, `NoNewPrivileges=true`,
  `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`,
  `DevicePolicy=closed` with `DeviceAllow` narrowed to `/dev/uinput` and
  `char-input`, and `ExecStartPre=/sbin/modprobe uinput`.

**Cost of this approach:**

- Runs as root (needs raw access to `/dev/input/event*` and `/dev/uinput`).
- Cursor freeze is inherent to grabbing motion during autoscroll. Matches
  Windows behavior (Windows freezes the cursor at the click point and
  shows a four-arrow icon).

**Deferred to v2:**

- The four-arrow autoscroll cursor overlay. Correct implementation is
  compositor-level: a small override-redirect window on X11 (drawn by a
  user-session helper that receives state from the root daemon over a Unix
  socket or D-Bus), and a GNOME Shell extension on Wayland. The root
  daemon does not draw. (Codex A. overlay recommendation.)
- Windows-style "click-once toggle-glide" mode. Trivial state-machine
  swap on top of the current daemon, but consumes normal middle-click.
  Ship hold-drag by default; add a config flag if Will wants it.

**Files:** `scripts/autoscrolld.py`, `scripts/install-autoscroll.sh`,
`scripts/flow-state-autoscroll.service`. Phase 1.5 wraps these into
`packages/flow-state-autoscroll/*.deb` so Phase 2 ISO and Phase 1
bootstrap install the same artifact (Codex B.5).

**Testing:**

- Verify service runs: `systemctl status flow-state-autoscroll`.
- Verify virtual device exists: `xinput list | grep flow-state-autoscroll`.
- In Firefox, Chrome, LibreOffice Writer, Nautilus, Evince, and GNOME
  Terminal: hold middle mouse button on any scrollable content, drag,
  page scrolls. Release, page stops.
- Regression: normal cursor motion, left/right click, scroll wheel, side
  buttons all still work identically.
- Horizontal direction (Codex A.9): verify in LibreOffice Calc, Nautilus
  column view, and any GTK ScrolledWindow — sign convention has drifted
  historically. Flip in one place (`autoscrolld.py` REL_HWHEEL branch) if
  it feels wrong.

## 5. Phase 2 — ISO build

**Direction: scripted ISO build, not GUI-driven.** Codex's review pushed
back on Cubic as the primary tool because a GUI/chroot-driven build is
hard to review, diff, CI, or reproduce. That review is correct once Flow
State becomes a shippable artifact rather than a personal remix.

**Recommended pipeline (Phase 2.0):** a bash script (`iso/build-iso.sh`)
that follows the same shape as `livecd-rootfs`:

1. Pull the official `ubuntu-24.04.4-desktop-amd64.iso` at a pinned
   checksum. Fail if the checksum drifts.
2. `unsquashfs` the live filesystem to a build dir.
3. `chroot` in, run `bootstrap-system.sh` against a controlled apt state:
   pinned NodeSource keyring + repo, pinned Ollama version, pinned
   `flow-state-autoscroll_*.deb`, pinned `flow-state-branding_*.deb`.
   Everything the ISO installs comes from a signed source with a
   recorded checksum.
4. Bake branding at system level (paths below).
5. `mksquashfs` the modified rootfs. Rebuild the ISO with `xorriso`
   preserving GPT + BIOS/UEFI boot records.
6. Emit a build manifest: input ISO checksum, apt package list, `.deb`
   checksums, resulting ISO checksum.
7. Boot the ISO in `qemu` as part of the same script (`--test`) so a
   build that produces a non-booting ISO is caught before publish.

**Cubic is fine as a prototype** for iterating on branding assets and
first-boot UX. Once the result is what we want, the recipe gets ported
into the scripted build. Cubic is not the release build tool.

**Alternatives kept in reserve:**

- `live-build`. Well-trodden; the tradeoff is that it wants a full config
  tree of its own rather than "here is a rootfs, respin it." Adopt if the
  ad-hoc script grows past ~300 lines.
- Ubuntu autoinstall / subiquity. Wrong shape — produces server installs,
  not a live-desktop ISO.

**System-level branding baked into the ISO:**

- `/etc/os-release`: `PRETTY_NAME="Flow State 1.0 (Noble Numbat remix)"`,
  `VARIANT="Flow State"`, `VARIANT_ID=flowstate`,
  `HOME_URL="https://dsio.io"`. **Leave `ID=ubuntu`, `ID_LIKE="debian"`,
  `VERSION_CODENAME=noble` in place.** Vendor install scripts (Chrome,
  NodeSource, ROCm, VS Code, Docker) branch on `ID`/`VERSION_CODENAME`;
  changing them to `flowstate` breaks those scripts silently (Codex C.3).
- `/usr/share/backgrounds/flow-state/*.png` + a
  `/usr/share/glib-2.0/schemas/90-flow-state.gschema.override` that sets
  the default wallpaper and accent color for new user accounts.
- Plymouth theme in `/usr/share/plymouth/themes/flow-state/`, activated
  with `update-alternatives`. Boot splash = Flow State logo on blue.
- GRUB theme in `/boot/grub/themes/flow-state/`, referenced from
  `/etc/default/grub` `GRUB_THEME=`.
- GDM logo/background via `/etc/dconf/db/gdm.d/00-flow-state`.

**ISO output:** `flow-state-1.0-amd64.iso`, downloadable directly from
`dsio.io`. Phase 2.5 wires this up:

- Landing page at `dsio.io/flow-state` — screenshot of Aurora wallpaper,
  30-second pitch (Ubuntu + DSIO harness + system-wide autoscroll +
  per-monitor sleep + Claude/Codex tray), "Download" CTA.
- `dsio.io/download/flow-state-<version>-amd64.iso` — direct download
  URL, stable per-version. Latest also aliased at
  `dsio.io/download/flow-state-latest.iso`.
- `dsio.io/download/flow-state-<version>.sha256` — checksum file next
  to the ISO.
- `dsio.io/download/flow-state-<version>.sig` — detached GPG signature
  by Will's key (public key at `dsio.io/keys/flow-state-signing.asc`).
- Storage backend: Cloudflare R2 (or an equivalent object store with
  cheap egress). The Vercel site that already lives at dsio.io points
  the download URLs at the R2 bucket via a signed rewrite or a plain
  302, so paying-per-GB S3 egress is not the shape.
- Release cadence: whenever Flow State bumps a minor. Old versions stay
  reachable at their versioned URLs so a specific build is always
  installable.

**Signing / integrity:** SHA256SUMS + a detached GPG signature with Will's
key. Not code-signed for Secure Boot in v1 — users installing this will
need Secure Boot off or use the standard "Install anyway" flow. Add
shim-signed Secure Boot support later if it matters.

## 6. Branding pass

**Visual identity (canonical, as of 2026-09-10):**

- **Wordmark & symbol:** the *Penrose triangle* — a red-outlined
  impossible-triangle silhouette with subtle blue highlight — over the
  words **FLOW STATE** in a heavy modern sans. Both live in
  `branding/wallpapers/flow-state-{aurora,nebula,ember}.jpg` as the
  intended presentation (the Penrose mark centered, the wordmark
  underneath, energy field behind).
- **Three official desktop backgrounds**, all 1280×720 source (upscale
  to 1440p/4K for the ISO):
  - `flow-state-aurora.jpg` — blue/teal cosmic (default; matches the
    calmer "focus" mood of the name).
  - `flow-state-nebula.jpg` — pink/purple/blue nebula.
  - `flow-state-ember.jpg` — orange/red/pink fire.
- **Wallpaper install path (system):**
  `/usr/share/backgrounds/flow-state/*.jpg`, registered for GNOME's
  Backgrounds picker via
  `/usr/share/gnome-background-properties/flow-state-wallpapers.xml`.
  This makes them show up alongside the stock Ubuntu wallpapers in
  Settings → Appearance → Background for every user on the machine.
- **Default active wallpaper for a new user:** `flow-state-aurora.jpg`.
- **Accent color:** GNOME `accent-color=blue`. Sample directly from the
  Aurora background (`#0b1d3f` deep, `#2a5fa4` mid) for anywhere that
  needs an exact hex — Plymouth boot splash, GRUB theme, GDM
  background, etc.
- **Icon everywhere else:** extract the Penrose logo from
  `flow-state-aurora.jpg` (crop → transparent PNG) and use it for the
  application/tray icon (`flow-state-tray`), the GDM user avatar
  (`~/.face`), and any other place a small square icon is asked for.

**Rebrand every user-facing surface** (per Will's explicit request):

- Grub boot menu (theme in `/boot/grub/themes/flow-state/`).
- Plymouth boot splash (`/usr/share/plymouth/themes/flow-state/`).
- GDM login screen (`/etc/dconf/db/gdm.d/00-flow-state`).
- Ubuntu installer (Ubiquity/subiquity slideshow — replace the Ubuntu
  slides with a Flow State walkthrough naming the harness and the
  autoscroll/monitor-sleep/tray features).
- `/etc/issue`, `/etc/motd`, first-login welcome banner.
- Distro name string: `PRETTY_NAME="Flow State 1.0 (Noble Numbat remix)"`
  everywhere `os-release` is read. (Keep `ID=ubuntu` — see §5.)
- **Terminal:** GNOME Terminal remains default. A `flow-state-blue`
  gschema color profile ships as the default so a fresh terminal opens
  in Flow State colors.

## 7. DSIO harness — what "preinstalled" means

**Codex C.2 is a hard blocker on baking the harness into the ISO.** The
harness lives at `jiujitsumagician/dsio`, a private repo. If a shipped
ISO contains the source, everyone who downloads Flow State has that
source — the "private" status becomes fiction. Fix: **the ISO ships the
harness's *prerequisites and installer*, not the harness source**.

**What the ISO bakes system-wide:**

- Node 24 (NodeSource apt source, pinned).
- Ollama (upstream install, pinned) + `qwen2.5-coder:14b` weights so
  first-boot doesn't wait on an 8 GB download.
- `@anthropic-ai/claude-code` and `@openai/codex` installed globally via
  npm.
- The `flow-state-autoscroll` daemon as a `.deb` — systemd unit, uinput
  module config, daemon source in one signed package.
- The Flow State branding (Plymouth, GRUB, GDM, wallpapers, os-release
  overlay) as `flow-state-branding_*.deb`.
- A first-login helper (`~/.local/share/flow-state/`) that on first shell
  open per user prompts `dsio login`, and lets the DSIO harness bootstrap
  itself from GitHub with the user's own `gh` auth. Same shape as
  `irm https://dsio.io/install.ps1 | iex` on Windows.

**What the ISO does NOT bake:**

- The DSIO repo itself (private).
- Any DSIO credentials, model tokens, or vault contents.

**Trade-off:** first login on a fresh Flow State install still requires
network access + a `gh auth login` browser flow. Correct behavior for a
distro whose harness is per-user-authenticated. Users who run Flow State
air-gapped can pre-clone the harness into `~/dsio-harness` themselves;
the first-login helper detects it and skips the online step.

**Update path:** `dsio update` (already in the harness) pulls, rebuilds,
relaunches. Ubuntu's own `apt update` handles system packages.

## 8. Open questions / risks

Distro-engineering basics named here so Phase 2 doesn't collide with
them:

1. **Signed apt repo** at e.g. `apt.dsio.io` so Flow State can ship
   `flow-state-*` packages with automatic security updates via
   `unattended-upgrades`. Without this, users have to `apt install
   ./flow-state-autoscroll_*.deb` from a local file. Not v1 blocking;
   name and design now.
2. **`flow-state-desktop` metapackage** — depends on every distro-owned
   package (`flow-state-autoscroll`, `flow-state-branding`,
   `flow-state-welcome`, `flow-state-defaults`). `apt install
   flow-state-desktop` on a stock Ubuntu machine effectively converts
   it to Flow State from apt alone. (Codex C.10.)
3. **Chrome licensing.** Google Chrome's redistribution terms probably
   forbid shipping Chrome in a public ISO. Ship Chromium (or a first-run
   installer that offers to fetch Chrome from Google's own repo) rather
   than baking Chrome (Codex C.8).
4. **Snap Firefox reproducibility.** Firefox on Ubuntu 24.04 is snap-only
   by default. Snap versioning drifts. If ISO reproducibility matters,
   swap to Firefox ESR from Mozilla's official APT repo.
5. **HWE kernel drift.** This machine runs 6.17-HWE; stock 24.04.4 ships
   6.8. Recommend `linux-generic-hwe-24.04` in the metapackage — safer
   for newer hardware like Will's 9060 XT.
6. **AMD ROCm / hardware profiles.** ROCm 7.2 adds kernel/driver/package
   fragility. Keep the base ISO CPU-safe; ship `flow-state-amdgpu` and
   later `flow-state-nvidia` profiles that layer ROCm/CUDA on top.
   (Codex C.7.)
7. **Secure Boot.** Unsigned ISOs are a friction point. Not blocking v1.
   Shim-signed later.
8. **First-login flow.** Options: (a) drop user at a normal GNOME
   desktop; a Flow-State-branded terminal autoruns `dsio login`; (b)
   replace GNOME Initial Setup with a Flow-State-branded onboarding that
   walks through Ubuntu setup + `dsio login` together. (a) ships now;
   (b) is a v2 polish item.
9. **QA matrix.** Enumerate the hardware + install-path combinations
   Flow State claims to support (this machine's Radeon RX 9060 XT, a
   generic Intel iGPU laptop, an NVIDIA laptop, qemu/UEFI, qemu/BIOS).
   No promises for combinations that aren't tested.
10. **Recovery path.** Grub recovery entry that boots a Flow-State-clean
    session (no autostart, no autoscroll grab) for triage. Ships in v1.
11. **License / SBOM.** Publish the full package manifest and license
    inventory alongside each ISO. `dpkg -l` inside the chroot at build
    time is the minimum viable SBOM. Full CycloneDX later.

## 9. Milestones

- **M0** (this session): DSIO harness installed on Will's current machine;
  system-wide autoscroll daemon written, reviewed against Codex, and
  committed in `flow-state-distro/`. Bootstrap scripts extracted.
- **M1:** re-run `bootstrap.sh` on this machine — must be a no-op.
  Package the autoscroll daemon as a real `.deb` and install it that way
  instead of the raw `install-autoscroll.sh`. (Codex B.5.)
- **M2:** fresh Ubuntu 24.04 VM + `bootstrap.sh` → verified Flow State
  environment. Screenshot for the record.
- **M3:** first scripted `build-iso.sh` produces a bootable Flow State
  ISO in qemu; first-login flow works.
- **M4:** ISO burned to USB, installed on a real second machine, works.
  This is when Flow State is "shippable" to friends.
- **M5** (stretch): signed release published at dsio.io, `apt.dsio.io`
  apt repo for auto-updates, `flow-state-desktop` metapackage in that
  repo.

## 10. Immediate next step

- Split `bootstrap.sh` into `bootstrap-system.sh` + `bootstrap-user.sh`
  as the Phase 1 shape (Codex C.6).
- Build the first `.deb` for `flow-state-autoscroll` (Codex B.5) so M1
  installs it as a package, not via ad-hoc `install-autoscroll.sh`.
- After Will approves, `writing-plans` skill produces the M1
  implementation plan.
