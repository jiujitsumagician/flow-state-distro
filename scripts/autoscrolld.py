#!/usr/bin/env python3
"""
Flow State autoscroll daemon.

Middle mouse button + drag = system-wide autoscroll. Works everywhere the
kernel input stack works: X11, Wayland, snap apps, LibreOffice, file managers,
Word docs, PDFs, terminals.

Behavior (v1, hold-drag):

    - Press middle button and hold, then move the mouse:
          → cursor freezes at the press point
          → vertical motion scrolls the page
          → horizontal motion emits horizontal scroll
          → release middle button to exit
    - Press and release middle button quickly with no motion:
          → normal middle-click is passed through (paste, open-in-new-tab)

Implementation: read raw events from every mouse's event nodes with
evdev.grab(), forward everything through a single uinput virtual device,
and intercept middle-button state to convert motion into REL_WHEEL_HI_RES.

Multi-interface HID mice (mice that enumerate as two event nodes on the
same physical device — Razer, Logitech G, some MX Master models) share
one state object keyed on the physical root, so pressing middle on one
interface while motion arrives on the other is handled correctly. All
event nodes for a mouse are grabbed so no raw events leak past the
daemon.

Runs as root — needs raw access to /dev/input/event* and /dev/uinput.
See scripts/install-autoscroll.sh for the one-shot installer.
"""

from __future__ import annotations

import selectors
import signal
import sys
import time
import traceback
from dataclasses import dataclass, field
from typing import Optional

try:
    import evdev
    from evdev import UInput, InputDevice, ecodes as e
except ImportError:
    sys.stderr.write(
        "python3-evdev is not installed. Run: sudo apt install -y python3-evdev\n"
    )
    sys.exit(2)


MOTION_THRESHOLD_PX = 3      # movement in pixels before autoscroll engages
SCROLL_ACCUM_PX = 8          # pixels of accumulated dy per vertical scroll notch
HSCROLL_ACCUM_PX = 12        # pixels of accumulated dx per horizontal notch
HI_RES_STEP = 120            # standard REL_*_HI_RES unit per notch
LOG_PREFIX = "flow-state-autoscroll:"


def log(msg: str) -> None:
    sys.stderr.write(f"{LOG_PREFIX} {msg}\n")
    sys.stderr.flush()


def is_mouse(dev: InputDevice) -> bool:
    caps = dev.capabilities()
    keys = caps.get(e.EV_KEY, [])
    rels = caps.get(e.EV_REL, [])
    return (
        e.BTN_LEFT in keys
        and e.BTN_MIDDLE in keys
        and e.REL_X in rels
        and e.REL_Y in rels
    )


def _phys_root(phys: str) -> str:
    """Strip trailing /inputN so two HID interfaces on the same device compare equal."""
    if not phys:
        return "unknown"
    idx = phys.rfind("/input")
    return phys[:idx] if idx >= 0 else phys


def find_mice() -> list[InputDevice]:
    """Every mouse-like event node under /dev/input/, no dedupe.

    Grabbing every node (rather than one per physical mouse) is required so
    that a secondary HID interface's raw middle-click cannot leak past the
    daemon to the compositor. State is grouped by physical root elsewhere.
    """
    mice: list[InputDevice] = []
    for path in evdev.list_devices():
        try:
            d = InputDevice(path)
        except (OSError, PermissionError):
            continue
        if is_mouse(d):
            mice.append(d)
    return mice


def virtual_caps_from(devs: list[InputDevice]) -> dict:
    """Union of relevant capabilities so forwarding any real event succeeds."""
    caps: dict[int, set] = {}
    for d in devs:
        for ev_type, codes in d.capabilities().items():
            if ev_type == e.EV_SYN:
                continue  # implicit for uinput; adding it explicitly errors
            if ev_type == e.EV_ABS:
                continue  # a plain mouse has no absolute axes worth mirroring
            # `codes` for EV_KEY / EV_REL / EV_MSC is a plain list of ints.
            if isinstance(codes, list):
                bucket = caps.setdefault(ev_type, set())
                for c in codes:
                    if isinstance(c, int):
                        bucket.add(c)
    # Ensure hi-res + coarse wheel are emittable even if a source mouse omits them.
    rels = caps.setdefault(e.EV_REL, set())
    rels.update({e.REL_WHEEL, e.REL_HWHEEL, e.REL_WHEEL_HI_RES, e.REL_HWHEEL_HI_RES})
    return {ev_type: sorted(codes) for ev_type, codes in caps.items()}


@dataclass
class PhysMouseState:
    """State per physical mouse, shared across all its interface event nodes."""

    phys_root: str
    middle_held: bool = False
    scrolling: bool = False
    accum_x: float = 0.0
    accum_y: float = 0.0
    press_time: float = 0.0


def run() -> int:
    mice = find_mice()
    if not mice:
        log("no mice found under /dev/input/event* — is this user in the input group?")
        return 1

    # Build allowed-forward set from what the virtual device advertises. Any
    # event type/code not in this set is dropped rather than forwarded — a
    # write of an unadvertised type kills the daemon (Codex A.1).
    caps = virtual_caps_from(mice)
    allowed: dict[int, set[int]] = {t: set(codes) for t, codes in caps.items()}

    ui = UInput(caps, name="flow-state-autoscroll", version=1)
    log(f"virtual device 'flow-state-autoscroll' created ({sum(len(v) for v in allowed.values())} codes)")

    # Group by physical root so multi-interface HID mice share one state.
    shared: dict[str, PhysMouseState] = {}
    dev_state: dict[int, PhysMouseState] = {}
    for m in mice:
        pr = _phys_root(m.phys or "")
        shared.setdefault(pr, PhysMouseState(phys_root=pr))
        dev_state[m.fd] = shared[pr]
        log(f"grabbing {m.path}  {m.name!r}  phys={m.phys}  → group '{pr}'")
        try:
            m.grab()
        except OSError as exc:
            log(f"  grab failed for {m.path}: {exc}; continuing")

    sel = selectors.DefaultSelector()
    for m in mice:
        sel.register(m, selectors.EVENT_READ)

    # SIGTERM handler: releases grabs cleanly so a systemctl stop doesn't leave
    # the mouse dead.
    stopped = [False]
    def _stop(*_a):
        stopped[0] = True
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    try:
        while not stopped[0]:
            for key, _mask in sel.select(timeout=1.0):
                dev: InputDevice = key.fileobj  # type: ignore[assignment]
                try:
                    events = list(dev.read())
                except BlockingIOError:
                    continue
                except OSError as exc:
                    log(f"read error on {dev.path}: {exc}; dropping device")
                    try:
                        sel.unregister(dev)
                        dev.ungrab()
                        dev.close()
                    except Exception:
                        pass
                    continue
                try:
                    dispatch(events, dev_state[dev.fd], ui, allowed)
                except Exception as exc:
                    # Log-and-continue: a single bad event must not kill the daemon.
                    log(f"dispatch error: {exc}\n{traceback.format_exc()}")
    finally:
        for m in mice:
            try:
                m.ungrab()
            except Exception:
                pass
            try:
                m.close()
            except Exception:
                pass
        try:
            ui.close()
        except Exception:
            pass
        log("daemon exit")
    return 0


def dispatch(events, st: PhysMouseState, ui, allowed: dict[int, set[int]]) -> None:
    """Process one batch of events from one mouse interface.

    Single-pass so that press → motion → release inside the same batch is
    handled in order.
    """
    emitted_any = False
    for ev in events:
        if ev.type == e.EV_KEY and ev.code == e.BTN_MIDDLE:
            if ev.value == 1:
                st.middle_held = True
                st.scrolling = False
                st.accum_x = 0.0
                st.accum_y = 0.0
                st.press_time = time.monotonic()
            elif ev.value == 0:
                if st.middle_held and not st.scrolling:
                    # A short press+release with no motion crossing the
                    # threshold: pass through as a normal middle-click.
                    ui.write(e.EV_KEY, e.BTN_MIDDLE, 1)
                    ui.syn()
                    ui.write(e.EV_KEY, e.BTN_MIDDLE, 0)
                    ui.syn()
                    emitted_any = True
                st.middle_held = False
                st.scrolling = False
                st.accum_x = 0.0
                st.accum_y = 0.0
            continue  # never forward the raw middle press/release

        if st.middle_held:
            if ev.type == e.EV_REL and ev.code in (e.REL_X, e.REL_Y):
                if ev.code == e.REL_Y:
                    st.accum_y += ev.value
                else:
                    st.accum_x += ev.value
                if not st.scrolling and (abs(st.accum_x) + abs(st.accum_y)) >= MOTION_THRESHOLD_PX:
                    st.scrolling = True
                if st.scrolling:
                    while st.accum_y >= SCROLL_ACCUM_PX:
                        st.accum_y -= SCROLL_ACCUM_PX
                        ui.write(e.EV_REL, e.REL_WHEEL_HI_RES, -HI_RES_STEP)
                        ui.write(e.EV_REL, e.REL_WHEEL, -1)
                        emitted_any = True
                    while st.accum_y <= -SCROLL_ACCUM_PX:
                        st.accum_y += SCROLL_ACCUM_PX
                        ui.write(e.EV_REL, e.REL_WHEEL_HI_RES, HI_RES_STEP)
                        ui.write(e.EV_REL, e.REL_WHEEL, 1)
                        emitted_any = True
                    while st.accum_x >= HSCROLL_ACCUM_PX:
                        st.accum_x -= HSCROLL_ACCUM_PX
                        ui.write(e.EV_REL, e.REL_HWHEEL_HI_RES, HI_RES_STEP)
                        ui.write(e.EV_REL, e.REL_HWHEEL, 1)
                        emitted_any = True
                    while st.accum_x <= -HSCROLL_ACCUM_PX:
                        st.accum_x += HSCROLL_ACCUM_PX
                        ui.write(e.EV_REL, e.REL_HWHEEL_HI_RES, -HI_RES_STEP)
                        ui.write(e.EV_REL, e.REL_HWHEEL, -1)
                        emitted_any = True
                # Do NOT forward REL_X/Y while middle is held — cursor stays anchored.
                continue
            if ev.type == e.EV_SYN:
                continue  # swallow the SYN that followed the swallowed motion

        # Fallthrough: forward the event only if the virtual device advertises it.
        if ev.type == e.EV_SYN:
            # Real SYNs delimit event frames; we emit our own at the end so
            # multiple pass-throughs in one read are batched consistently.
            continue
        codes = allowed.get(ev.type)
        if codes is not None and ev.code in codes:
            ui.write(ev.type, ev.code, ev.value)
            emitted_any = True
        # Silently drop anything the virtual device does not advertise (avoids
        # the uinput-write crash Codex flagged, at the cost of never seeing
        # exotic events; a plain mouse never generates any that matter for us).

    if emitted_any:
        try:
            ui.syn()
        except Exception as exc:
            log(f"syn error: {exc}")


if __name__ == "__main__":
    sys.exit(run())
