#!/usr/bin/env python3
"""
Flow State autoscroll daemon — Windows-style click-and-glide.

Behavior (v2, glide model):

    * IDLE + middle press → enter TAP_PENDING.
    * TAP_PENDING: motion still passes through, but is also accumulated.
        - If middle is released within TAP_MAX_MS with less than
          TAP_MAX_PX of movement, we treat the whole thing as a plain
          middle-click and forward a synthetic middle press+release.
          That preserves Linux muscle memory (middle-click paste,
          open-link-in-new-tab).
        - Otherwise we enter GLIDE on release (or immediately when
          motion crosses TAP_MAX_PX, whichever happens first).
    * GLIDE:
        - Cursor motion is swallowed (cursor freezes at the anchor,
          matching Windows).
        - The daemon's periodic tick computes scroll velocity from the
          distance from anchor and emits REL_WHEEL / REL_HWHEEL events
          scaled proportionally.  The deeper you push the mouse, the
          faster the page scrolls; centre = still.
        - Any next mouse button press (left, right, middle, side) exits
          GLIDE and is not forwarded — that click was meant to end the
          scroll, not to trigger something.

Middle-button events are always intercepted; nothing raw reaches the
compositor.  Everything else passes through the virtual mouse device.
Multi-interface HID mice are grouped by physical root so pressing a
button on one interface while motion arrives on the other is handled
correctly.

Runs as root under the flow-state-autoscroll systemd unit.
"""

from __future__ import annotations

import selectors
import signal
import sys
import time
import traceback
from dataclasses import dataclass, field

try:
    import evdev
    from evdev import UInput, InputDevice, ecodes as e
except ImportError:
    sys.stderr.write(
        "python3-evdev is not installed. Run: sudo apt install -y python3-evdev\n"
    )
    sys.exit(2)


# --- Tuning knobs --------------------------------------------------------

TAP_MAX_MS = 180                # a middle press+release inside this many ms with
TAP_MAX_PX = 5                  # under this many px of motion is a normal middle-click.

GLIDE_TICK_SECONDS = 0.03       # how often we emit scroll notches while gliding.
DEADZONE_PX = 8                 # motion inside ±DEADZONE_PX from the anchor doesn't scroll.
V_POWER = 1.7                   # acceleration curve exponent (>1 = slow start, faster far away)
H_POWER = 1.5                   # slightly gentler curve for horizontal.
V_SCALE = 15.0                  # dividing constant: raise → slower overall.
H_SCALE = 25.0
V_MAX_NOTCHES_PER_SEC = 260.0   # top scroll speed (vertical), notches per second.
H_MAX_NOTCHES_PER_SEC = 160.0   # top scroll speed (horizontal).
HI_RES_STEP = 120               # standard REL_*_HI_RES step size per notch.

LOG_PREFIX = "flow-state-autoscroll:"


def log(msg: str) -> None:
    sys.stderr.write(f"{LOG_PREFIX} {msg}\n")
    sys.stderr.flush()


# --- Mouse discovery -----------------------------------------------------

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
    if not phys:
        return "unknown"
    idx = phys.rfind("/input")
    return phys[:idx] if idx >= 0 else phys


def find_mice() -> list[InputDevice]:
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
    caps: dict[int, set] = {}
    for d in devs:
        for ev_type, codes in d.capabilities().items():
            if ev_type in (e.EV_SYN, e.EV_ABS):
                continue
            if isinstance(codes, list):
                bucket = caps.setdefault(ev_type, set())
                for c in codes:
                    if isinstance(c, int):
                        bucket.add(c)
    rels = caps.setdefault(e.EV_REL, set())
    rels.update({e.REL_WHEEL, e.REL_HWHEEL, e.REL_WHEEL_HI_RES, e.REL_HWHEEL_HI_RES})
    return {ev_type: sorted(codes) for ev_type, codes in caps.items()}


# --- Per-physical-mouse state --------------------------------------------

class Mode:
    IDLE = 0
    TAP_PENDING = 1
    GLIDE = 2


# Buttons that exit GLIDE when pressed. Left, right, middle, side buttons —
# essentially any real mouse button press.
EXIT_BUTTONS = {
    e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE,
    e.BTN_SIDE, e.BTN_EXTRA, e.BTN_FORWARD, e.BTN_BACK, e.BTN_TASK,
}


@dataclass
class MouseState:
    phys_root: str
    mode: int = Mode.IDLE
    press_time: float = 0.0
    tap_accum_x: float = 0.0
    tap_accum_y: float = 0.0
    # Distance-from-anchor while gliding (mouse units).
    anchor_dx: float = 0.0
    anchor_dy: float = 0.0
    last_tick: float = 0.0
    # Fractional-notch accumulators so slow speeds don't stutter — a
    # per-tick rate of 0.3 notches emits 1 notch every ~3 ticks smoothly.
    v_credit: float = 0.0
    h_credit: float = 0.0


# --- The daemon ---------------------------------------------------------

def run() -> int:
    mice = find_mice()
    if not mice:
        log("no mice found under /dev/input/event* — is this user in the input group?")
        return 1

    caps = virtual_caps_from(mice)
    allowed: dict[int, set[int]] = {t: set(codes) for t, codes in caps.items()}

    ui = UInput(caps, name="flow-state-autoscroll", version=1)
    log(f"virtual device 'flow-state-autoscroll' created ({sum(len(v) for v in allowed.values())} codes)")

    # Group each event device by its physical root so multi-interface HID
    # mice share one state.
    shared: dict[str, MouseState] = {}
    dev_state: dict[int, MouseState] = {}
    for m in mice:
        pr = _phys_root(m.phys or "")
        shared.setdefault(pr, MouseState(phys_root=pr))
        dev_state[m.fd] = shared[pr]
        log(f"grabbing {m.path}  {m.name!r}  phys={m.phys}  → group '{pr}'")
        try:
            m.grab()
        except OSError as exc:
            log(f"  grab failed for {m.path}: {exc}; continuing")

    sel = selectors.DefaultSelector()
    for m in mice:
        sel.register(m, selectors.EVENT_READ)

    stopped = [False]
    def _stop(*_a):
        stopped[0] = True
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    try:
        while not stopped[0]:
            events_ready = sel.select(timeout=GLIDE_TICK_SECONDS)
            for key, _mask in events_ready:
                dev: InputDevice = key.fileobj  # type: ignore[assignment]
                st = dev_state[dev.fd]
                try:
                    events = list(dev.read())
                except BlockingIOError:
                    continue
                except OSError as exc:
                    log(f"read error on {dev.path}: {exc}; dropping")
                    try:
                        sel.unregister(dev); dev.ungrab(); dev.close()
                    except Exception:
                        pass
                    continue
                try:
                    dispatch(events, st, ui, allowed)
                except Exception as exc:
                    log(f"dispatch error: {exc}\n{traceback.format_exc()}")

            # Periodic glide tick, regardless of whether events fired.
            # `shared.values()` is already deduped by phys_root key.
            now = time.monotonic()
            for st in shared.values():
                if st.mode == Mode.GLIDE and (now - st.last_tick) >= GLIDE_TICK_SECONDS:
                    _glide_tick(st, ui)
                    st.last_tick = now

    finally:
        for m in mice:
            try: m.ungrab()
            except Exception: pass
            try: m.close()
            except Exception: pass
        try: ui.close()
        except Exception: pass
        log("daemon exit")
    return 0


def _rate_from_distance(dist_abs: float, scale: float, power: float, max_rate: float) -> float:
    """Convert distance-from-anchor (px, positive) to notches per second.

    Slow start / fast-far-away curve: (excess/scale)^power, capped at
    max_rate. In the deadzone this returns 0.
    """
    excess = dist_abs - DEADZONE_PX
    if excess <= 0:
        return 0.0
    rate = (excess / scale) ** power
    if rate > max_rate:
        rate = max_rate
    return rate


def _glide_tick(st: MouseState, ui) -> None:
    """Emit scroll notches based on distance-from-anchor with an
    accelerating curve — starts slow inside a small distance, ramps up
    quickly as you push the mouse further from the click point.
    """
    dy = st.anchor_dy
    dx = st.anchor_dx
    emitted = False

    # Vertical.
    rate_v = _rate_from_distance(abs(dy), V_SCALE, V_POWER, V_MAX_NOTCHES_PER_SEC)
    if rate_v > 0:
        st.v_credit += rate_v * GLIDE_TICK_SECONDS
        whole = int(st.v_credit)
        if whole >= 1:
            st.v_credit -= whole
            # Cap this tick so a huge burst doesn't warp the whole page.
            whole = min(whole, 10)
            sign = -1 if dy > 0 else 1
            for _ in range(whole):
                ui.write(e.EV_REL, e.REL_WHEEL_HI_RES, sign * HI_RES_STEP)
                ui.write(e.EV_REL, e.REL_WHEEL, sign)
            emitted = True
    else:
        st.v_credit = 0.0  # reset in deadzone

    # Horizontal.
    rate_h = _rate_from_distance(abs(dx), H_SCALE, H_POWER, H_MAX_NOTCHES_PER_SEC)
    if rate_h > 0:
        st.h_credit += rate_h * GLIDE_TICK_SECONDS
        whole = int(st.h_credit)
        if whole >= 1:
            st.h_credit -= whole
            whole = min(whole, 8)
            sign = 1 if dx > 0 else -1
            for _ in range(whole):
                ui.write(e.EV_REL, e.REL_HWHEEL_HI_RES, sign * HI_RES_STEP)
                ui.write(e.EV_REL, e.REL_HWHEEL, sign)
            emitted = True
    else:
        st.h_credit = 0.0

    if emitted:
        try:
            ui.syn()
        except Exception:
            pass


def _emit_synthetic_middle_click(ui) -> None:
    ui.write(e.EV_KEY, e.BTN_MIDDLE, 1)
    ui.syn()
    ui.write(e.EV_KEY, e.BTN_MIDDLE, 0)
    ui.syn()


def dispatch(events, st: MouseState, ui, allowed: dict[int, set[int]]) -> None:
    """Process one batch of events, single-pass, updating state and emitting."""
    emitted_any = False

    for ev in events:
        # Middle button transitions drive the state machine.
        if ev.type == e.EV_KEY and ev.code == e.BTN_MIDDLE:
            if ev.value == 1:  # press
                if st.mode == Mode.IDLE:
                    st.mode = Mode.TAP_PENDING
                    st.press_time = time.monotonic()
                    st.tap_accum_x = 0.0
                    st.tap_accum_y = 0.0
                    st.anchor_dx = 0.0
                    st.anchor_dy = 0.0
                elif st.mode == Mode.GLIDE:
                    # Exit GLIDE on any button press.
                    st.mode = Mode.IDLE
                    st.anchor_dx = st.anchor_dy = 0.0
                # TAP_PENDING re-press: ignore, stay pending.
            elif ev.value == 0:  # release
                if st.mode == Mode.TAP_PENDING:
                    held_ms = (time.monotonic() - st.press_time) * 1000
                    moved_px = abs(st.tap_accum_x) + abs(st.tap_accum_y)
                    if held_ms < TAP_MAX_MS and moved_px < TAP_MAX_PX:
                        # Genuine tap: emit a synthetic middle-click.
                        _emit_synthetic_middle_click(ui)
                        emitted_any = True
                        st.mode = Mode.IDLE
                    else:
                        # Longer press → enter GLIDE. Anchor is *now*: reset
                        # motion accumulator so the next motion is measured
                        # from the current cursor position.
                        st.mode = Mode.GLIDE
                        st.anchor_dx = 0.0
                        st.anchor_dy = 0.0
                        st.last_tick = time.monotonic()
                # Release in IDLE or GLIDE: ignore.
            continue

        # Any other button PRESS while gliding exits glide, and the button
        # press is swallowed (the user meant to stop scrolling, not click).
        if (st.mode == Mode.GLIDE
                and ev.type == e.EV_KEY
                and ev.value == 1
                and ev.code in EXIT_BUTTONS):
            st.mode = Mode.IDLE
            st.anchor_dx = st.anchor_dy = 0.0
            continue

        # Motion handling.
        if ev.type == e.EV_REL and ev.code in (e.REL_X, e.REL_Y):
            if st.mode == Mode.TAP_PENDING:
                # Accumulate for the tap-threshold check; still forward the
                # motion so the cursor moves normally in the tiny window
                # between press and release.
                if ev.code == e.REL_Y:
                    st.tap_accum_y += ev.value
                else:
                    st.tap_accum_x += ev.value
                if abs(st.tap_accum_x) + abs(st.tap_accum_y) > TAP_MAX_PX:
                    # Motion crossed the threshold before release: promote
                    # directly to GLIDE. The mouse is where it is; that's
                    # the anchor.
                    st.mode = Mode.GLIDE
                    st.anchor_dx = 0.0
                    st.anchor_dy = 0.0
                    st.last_tick = time.monotonic()
                    # Do NOT forward this motion — the anchor is being set.
                    continue
                # Otherwise forward the motion.
                ui.write(ev.type, ev.code, ev.value)
                emitted_any = True
                continue
            if st.mode == Mode.GLIDE:
                # Accumulate distance-from-anchor; cursor is frozen.
                if ev.code == e.REL_Y:
                    st.anchor_dy += ev.value
                else:
                    st.anchor_dx += ev.value
                continue

        # EV_SYN handling: when we're in GLIDE we suppress SYNs (glide tick
        # emits its own). Otherwise let them through.
        if ev.type == e.EV_SYN:
            if st.mode == Mode.GLIDE:
                continue
            continue  # end-of-batch SYN handled by the ui.syn() below.

        # Any other event: pass through if the virtual device advertises it.
        codes = allowed.get(ev.type)
        if codes is not None and ev.code in codes:
            ui.write(ev.type, ev.code, ev.value)
            emitted_any = True

    if emitted_any:
        try:
            ui.syn()
        except Exception as exc:
            log(f"syn error: {exc}")


if __name__ == "__main__":
    sys.exit(run())
