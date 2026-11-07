/// THE TOUCH HOLD (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §2.2) — the terminal's, a
/// window titlebar's and full screen's `⌨`. A touch or pen press that stays within `TOUCH_SLOP_PX` for
/// `HOLD_MS` holds; a move past the slop first CANCELS it (a scroll stays a scroll, a titlebar drag a drag).
///
/// ONCE HELD, THE REST OF THE GESTURE IS THE MENU'S: a move reaches nothing under it (the terminal's touch
/// scroll, the window drag — `stopImmediatePropagation`, because the drag's own listener is on the very
/// element, under pointer capture), and the release is PREVENTED, so iOS synthesizes no mouse events — in a
/// mouse-tracking app those would be a CLICK REPORT. A mouse never holds: it right-clicks.
///
/// MEASURED on iOS 26.5 (iPhone and iPad): a hold raises no callout, no selection and no `contextmenu`, and
/// ends `pointerdown` then `pointerup` with NO `pointercancel` — and iOS still synthesizes
/// `mousedown`/`mouseup`/`click` after any hold shorter than ~1.3–1.6 s, whatever the touchend did. So the
/// trailing `mousedown` and `mouseup` are swallowed too (xterm.js turns a `mousedown` into a mouse report),
/// for `CLICK_SWALLOW_MS` after the release; the next real press ends the window at once.

/// A finger held this long without moving holds — the platforms' own long press is ~500 ms.
export const HOLD_MS = 500;
/// How far a finger may wander and still be holding.
export const TOUCH_SLOP_PX = 10;
/// How long after a hold its synthesized mouse events and click are swallowed. NOT one task: iOS dispatches
/// them through its gesture system, after the touch sequence.
export const CLICK_SWALLOW_MS = 600;

export interface PressHoldOpts {
  /// Whether this press may become a hold (outside the controls, the driver, …).
  accepts(e: PointerEvent): boolean;
  onHold(at: { x: number; y: number }): void;
}
export interface PressHold { readonly held: boolean; cancel(): void }

export function attachPressHold(el: HTMLElement, opts: PressHoldOpts, signal: AbortSignal): PressHold {
  let g: { id: number; x0: number; y0: number; timer: number } | null = null;
  /// From the hold firing to the gesture's touchend: the window in which motion and the release are the menu's.
  let menuGesture = false;
  let swallowUntil = 0;
  const on = { signal };
  const clear = () => { if (g) window.clearTimeout(g.timer); g = null; };

  el.addEventListener("pointerdown", (e) => {
    swallowUntil = 0;
    if (e.isPrimary === false) { clear(); return; }      // a second finger is a gesture of its own
    menuGesture = false;
    clear();
    if (e.pointerType === "mouse" || !opts.accepts(e)) return;
    const x0 = e.clientX, y0 = e.clientY;
    g = { id: e.pointerId, x0, y0, timer: window.setTimeout(() => {
      if (!g || signal.aborted) return;
      g = null;
      menuGesture = true;
      opts.onHold({ x: x0, y: y0 });
    }, HOLD_MS) };
  }, { signal, capture: true });

  window.addEventListener("pointermove", (e) => {
    if (g && e.pointerId === g.id && Math.hypot(e.clientX - g.x0, e.clientY - g.y0) > TOUCH_SLOP_PX) clear();
  }, on);
  const end = (e: PointerEvent) => {
    if (g && e.pointerId === g.id) clear();
    if (menuGesture) swallowUntil = Date.now() + CLICK_SWALLOW_MS;
  };
  window.addEventListener("pointerup", end, on);
  window.addEventListener("pointercancel", end, on);

  el.addEventListener("pointermove", (e) => { if (menuGesture) e.stopImmediatePropagation(); }, { signal, capture: true });
  el.addEventListener("touchmove", (e) => {
    if (menuGesture) { e.preventDefault(); e.stopImmediatePropagation(); }
  }, { signal, capture: true, passive: false });
  el.addEventListener("touchend", (e) => {
    if (!menuGesture) return;
    e.preventDefault();
    menuGesture = false;
    swallowUntil = Date.now() + CLICK_SWALLOW_MS;
  }, { signal, capture: true, passive: false });
  el.addEventListener("click", (e) => {
    if (Date.now() >= swallowUntil) return;
    swallowUntil = 0;
    e.preventDefault();
    e.stopImmediatePropagation();
  }, { signal, capture: true });
  const swallowMouse = (e: Event) => { if (Date.now() < swallowUntil) { e.preventDefault(); e.stopImmediatePropagation(); } };
  el.addEventListener("mousedown", swallowMouse, { signal, capture: true });
  el.addEventListener("mouseup", swallowMouse, { signal, capture: true });
  window.addEventListener("blur", () => { clear(); menuGesture = false; }, on);
  signal.addEventListener("abort", clear);
  return { get held() { return menuGesture; }, cancel: () => { clear(); menuGesture = false; } };
}
