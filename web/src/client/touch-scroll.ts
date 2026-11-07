import { FlingTracker } from "./fling-tracker";
import { CLICK_SWALLOW_MS } from "./press-hold";
import type { SmoothScroll } from "./smooth-scroll";
import { wheelIsDiscrete, type WheelLinesTerm } from "./wheel-lines";

/// The pixels xterm.js 6 scrolls for one wheel NOTCH: its Viewport is VS Code's scrollable element,
/// which multiplies the normalised delta (`wheelDeltaY / 120`) by 50 px (SCROLL_WHEEL_SENSITIVITY,
/// times `mouseWheelScrollSensitivity`, which rdev leaves at 1). Measured: `wheelDeltaY: 120` per event
/// scrolled 62-63 rows for 20 events at 16 px rows — 50 px each.
export const XTERM_PX_PER_NOTCH = 50;

/// The synthetic wheel event for ONE ROW of finger drag over the terminal (`rows` is +1 for a finger
/// moving down, which scrolls BACK). xterm.js decides what a wheel event means per mode, which is why the
/// touch handler speaks wheel at all: a mouse-tracking app (Claude Code, htop, vim) gets one wheel report
/// per event, the alt screen gets one arrow key per event, and the normal buffer scrolls its scrollback —
/// the only one of the three that reads the event's MAGNITUDE.
///
/// That magnitude comes from the LEGACY `wheelDeltaY` whenever it exists (VS Code's StandardWheelEvent),
/// NOT from `deltaY`/`deltaMode`. Left unset, the engine derives it — WebKit as `-deltaY` = -1, i.e. 1/120
/// of a notch — so twenty rows of drag scrolled ONE row on an iPhone. It is set here to exactly one row.
export function touchScrollWheel(rows: 1 | -1, rowHeightPx: number, clientX: number, clientY: number): WheelEventInit & { wheelDeltaY: number } {
  const notchesPerRow = (120 * rowHeightPx) / XTERM_PX_PER_NOTCH;
  const magnitude = Math.max(1, Math.round(notchesPerRow));
  return {
    deltaY: -rows, deltaMode: 1,
    wheelDeltaY: rows * magnitude,          // legacy sign: positive scrolls up (back)
    clientX, clientY, bubbles: true, cancelable: true,
  };
}

/// The visible instance, as the touch handler needs it.
export interface TouchScrollView {
  term: Pick<WheelLinesTerm, "modes" | "buffer">;
  smooth: Pick<SmoothScroll, "enabled" | "gliding" | "hold" | "drag" | "release"> | null;
}

/// ONE-FINGER SCROLLING of the terminal on a touch screen. xterm.js 6's own touch scrolling is unreliable
/// in iOS Safari, so the page OWNS the gesture (preventDefault on every move, so the native page and
/// visual-viewport scroll cannot fight it — most visible with the keyboard up). A tap (no movement)
/// never scrolls. Two paths:
///
///   - SMOOTH (`smooth-scroll.ts`, the option on) over the normal buffer's scrollback: the position
///     follows the finger PIXEL FOR PIXEL, and a flick GLIDES on after the lift, at the finger's speed
///     (`FlingTracker`, the same trail the window gestures use). A touch stops a glide — and a TAP that
///     stopped one does nothing else (below).
///   - ROWS otherwise, and always while an app owns the wheel (a mouse-tracking TUI, the alt screen):
///     one synthetic wheel event per row of drag into xterm's own handler, so it does the right thing
///     per mode — Claude Code, htop and vim get mouse-wheel reports, less and man mode-aware arrows,
///     the normal buffer its scrollback (`touchScrollWheel`). Hand-rolled arrows were wrong for mouse
///     apps (Claude Code read Up/Down as history). Dispatched on the touch target, which is inside the
///     VISIBLE instance, so it bubbles to whatever element xterm bound its wheel handler to.
///
/// **THE TAP THAT STOPS A GLIDE ONLY STOPS IT** (2026-10-05, asked for: "the tap that stops it should not activate
/// keyboard"). xterm.js focuses its textarea on the `mousedown` iOS synthesizes after a tap — the soft keyboard came
/// up for a finger that only meant to catch the scrollback, as a native scroll view's content never would. A
/// finger landing while the scrollback GLIDES (`SmoothScroll.gliding`): its `touchend` is PREVENTED (no click, no
/// native focus) and the `mousedown`, `mouseup` and `click` iOS synthesizes for it are swallowed in `el`'s capture
/// phase, ahead of xterm.js, for `CLICK_SWALLOW_MS` (iOS dispatches them after the touch sequence — press-hold.ts
/// measured it); the next press ends that window at once. The same finger may still drag on, or hold for the menu.
///
/// Returns the detach.
/// A press on the terminal's SCROLLBAR — the rail `terminal-scrollbar.ts` mounts in every instance's container
/// (inside `#xterm`), or xterm.js's own where no rail is (it hides xterm.js's): the scrollbar drags itself. Neither
/// the finger scroll below nor the HOLD (press-hold.ts — the paste menu, a selection) may take that gesture. The
/// rail stops its touch events, but the hold listens to POINTER events in `#xterm`'s CAPTURE phase, ahead of the
/// rail: a finger resting on the thumb for half a second opened the menu, and the held gesture's moves never
/// reached the rail again (2026-10-04, reported: "scrolling using the scrollbar activates long press menu").
export function onTerminalScrollbar(target: EventTarget | null): boolean {
  return !!(target as Element | null)?.closest?.(".terminal-scrollbar, .xterm-scrollable-element > .scrollbar");
}

export function attachTouchScroll(el: HTMLElement, deps: {
  view: () => TouchScrollView | null;
  rowHeight: () => number;
  now?: () => number;
  /// First claim on a drag that drives ROWS (an app owns the wheel): px in the finger's sense (down positive), returns
  /// what is left for the app — the keyboard's shifted view pans first over a full-screen app (keyboard-shift.ts).
  pan?: (dy: number) => number;
}): () => void {
  const now = deps.now ?? (() => performance.now());
  const fling = new FlingTracker();
  const ac = new AbortController();
  const on = { signal: ac.signal };
  let lastY: number | null = null;
  let accum = 0;
  /// The finger being followed. `touches` counts every finger on the SCREEN — one resting on the key
  /// strip, a palm on an iPad — so the gesture ends when THIS one lifts, not when the screen is clear.
  let tracked: number | null = null;
  /// The controller holding the gesture, from its touchstart to its release.
  let held: TouchScrollView["smooth"] = null;
  /// The finger that landed on a GLIDE, while it is down; then until when its synthesized mouse events are swallowed.
  let stopper: number | null = null;
  let swallowUntil = 0;
  const smoothFor = (v: TouchScrollView | null) =>
    v?.smooth?.enabled && !wheelIsDiscrete(v.term) ? v.smooth : null;

  el.addEventListener("touchstart", (e) => {
    // The scrollbar's drag is xterm.js's own.
    const t = e.touches.length === 1 && !onTerminalScrollbar(e.target) ? e.touches[0] : undefined;
    lastY = t ? t.clientY : null;
    tracked = t ? t.identifier : null;
    accum = 0;
    fling.reset();
    // Any finger stops a glide where it is (tap to stop), whatever it goes on to do.
    const s = deps.view()?.smooth;
    swallowUntil = 0;
    stopper = t && s?.enabled && !held && s.gliding ? t.identifier : null;
    if (s?.enabled && !held) { s.hold(); held = s; }
  }, { passive: true, ...on });

  el.addEventListener("touchmove", (e) => {
    const t = e.touches.length === 1 ? e.touches[0] : undefined;
    if (lastY === null || !t) return;
    e.preventDefault();
    e.stopPropagation();
    const v = deps.view();
    // The instance changed under the finger (a snapshot swapped a fresh one in, the tab changed): the
    // controller the gesture started on is released where it is, and the finger carries on with the new
    // one — held, so nothing settles under it. Never a drag of one that was not held, nor a later release
    // of a hidden or disposed one; and a finger driving rows (an app owns the wheel) keeps driving them.
    if (held && v?.smooth !== held) {
      held.release(null);
      held = null;
      fling.reset();
      const s = v?.smooth;
      if (s?.enabled) { s.hold(); held = s; }
    }
    const dy = t.clientY - lastY;
    lastY = t.clientY;
    const smooth = smoothFor(v);
    if (smooth) {
      fling.push(now(), 0, dy);
      smooth.drag(-dy);                          // finger DOWN (dy > 0) scrolls BACK
      return;
    }
    accum += deps.pan ? deps.pan(dy) : dy;
    const h = deps.rowHeight();
    const lines = Math.trunc(accum / h);
    if (lines === 0) return;
    accum -= lines * h;
    const target = (e.target as Element | null) ?? el;
    const rows = lines > 0 ? 1 : -1;
    for (let i = 0; i < Math.abs(lines); i++) {
      target.dispatchEvent(new WheelEvent("wheel", touchScrollWheel(rows, h, t.clientX, t.clientY)));
    }
  }, { passive: false, ...on });

  const end = (flick: boolean) => {
    lastY = null;
    tracked = null;
    if (!held) return;
    const v = flick ? fling.velocity(now()) : null;
    held.release(v ? -v.vy / 1000 : null);       // px/s of finger → px/ms of scroll position
    held = null;
    fling.reset();
  };
  el.addEventListener("touchend", (e) => {
    const changed = Array.from(e.changedTouches);
    if (stopper !== null && changed.some((c) => c.identifier === stopper)) {
      e.preventDefault();
      stopper = null;
      swallowUntil = Date.now() + CLICK_SWALLOW_MS;
    }
    const lifted = tracked !== null && changed.some((c) => c.identifier === tracked);
    if (lifted || e.touches.length === 0) end(true);
  }, { passive: false, ...on });
  el.addEventListener("touchcancel", () => { stopper = null; end(false); }, { passive: true, ...on });
  const swallow = (e: Event) => {
    if (Date.now() >= swallowUntil) return;
    if (e.type === "click") swallowUntil = 0;
    e.preventDefault();
    e.stopImmediatePropagation();
  };
  for (const type of ["mousedown", "mouseup", "click"] as const) el.addEventListener(type, swallow, { capture: true, ...on });
  return () => ac.abort();
}
