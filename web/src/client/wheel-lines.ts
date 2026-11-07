/// Trackpad scrolling for a terminal whose wheel becomes DISCRETE LINES: a mouse-tracking app (Claude
/// Code's fullscreen mode, htop, vim) gets one wheel report per line, the alt screen one arrow key per line.
///
/// Stock xterm.js 6 made that conversion too slow for a trackpad, twice over
/// (`CoreMouseService.consumeWheelEvent` + `CoreBrowserTerminal.bindMouse`):
///   - any pixel event under 50 px is "isLikelyTrackpad" and multiplied by 0.3, so one report took
///     ~3.3 cell heights of finger travel;
///   - each event sends AT MOST ONE report, whatever its size — a 120 px momentum event is 6.7 cells
///     of motion and became 1 report, the rest discarded.
/// MEASURED (e2e/term-wheel-check.mjs, Chromium and WebKit alike): a 902 px swipe at an 18 px cell
/// (50 cells) gave 15 reports; a 640 px fast flick (35.6 cells) gave 7.
///
/// A native macOS terminal sends one report per CELL HEIGHT of precise-scroll motion and keeps the
/// sub-cell remainder: Ghostty's `Surface.scrollCallback` accumulates `pending_scroll_y` against the
/// cell height (its AppKit view doubles `scrollingDeltaY`, points, against a cell measured in backing
/// pixels, i.e. one report per cell height in POINTS — a CSS px here) and sends `|delta|` reports for
/// one event. That is what this does, in CSS px against the CSS cell height.
///
/// Only PIXEL-mode events are converted (`deltaMode 0`, every macOS trackpad and mouse in Chromium and
/// WebKit). LINE-mode events — Firefox's mouse wheel, and the touch path's own synthetic rows
/// (`touch-scroll.ts`) — already mean one line each and go to xterm.js untouched; so do the normal
/// buffer's scrollback (xterm's Viewport reads the magnitude itself and was not slow) and Shift+wheel
/// (xterm ignores it for reports).
export class WheelLines {
  private carry = 0;

  /// Whole lines (signed; negative is up/back) to emit for one pixel wheel event. `maxLines` bounds one
  /// event (the terminal's rows — a page); motion past it is dropped, not carried into later events.
  push(deltaY: number, cellPx: number, maxLines: number): number {
    if (!Number.isFinite(deltaY) || deltaY === 0 || !(cellPx > 0)) return 0;
    if (this.carry !== 0 && Math.sign(this.carry) !== Math.sign(deltaY)) this.carry = 0;   // reversal
    this.carry += deltaY / cellPx;
    // The epsilon keeps 2/3 + 1/3 from landing a hair under 1 in floating point.
    const whole = Math.trunc(this.carry + Math.sign(this.carry) * 1e-9);
    if (whole === 0) return 0;
    this.carry -= whole;
    if (Math.abs(this.carry) < 1e-9) this.carry = 0;
    const cap = Math.max(1, Math.floor(maxLines));
    if (Math.abs(whole) > cap) { this.carry = 0; return Math.sign(whole) * cap; }
    return whole;
  }

  reset(): void { this.carry = 0; }
}

/// The event xterm.js turns into exactly ONE report (or arrow): a LINE-mode delta of ±1 — its
/// `consumeWheelEvent` returns a non-zero amount for any line-mode delta, and `bindMouse` sends one
/// report per event. Position and modifiers are the original's, because the report encodes both.
export function lineWheelInit(
  dir: 1 | -1,
  from: { clientX: number; clientY: number; ctrlKey: boolean; altKey: boolean; metaKey: boolean },
): WheelEventInit {
  return {
    deltaY: dir, deltaMode: 1,
    clientX: from.clientX, clientY: from.clientY,
    ctrlKey: from.ctrlKey, altKey: from.altKey, metaKey: from.metaKey,
    bubbles: true, cancelable: true,
  };
}

/// The xterm.js surface `attachWheelLines` needs — the public API plus one measurement.
export interface WheelLinesTerm {
  readonly rows: number;
  readonly modes: { readonly mouseTrackingMode: string };
  readonly buffer: { readonly active: { readonly type: string } };
  attachCustomWheelEventHandler(handler: (ev: WheelEvent) => boolean): void;
}

/// The protocols whose wheel becomes REPORTS (xterm.js's WHEEL event type: VT200, drag, any). X10
/// (`?9`) reports presses only — its wheel scrolls the Viewport, which has already happened by the time
/// the handler runs, so converting it would add nothing but stray synthetic events.
const WHEEL_REPORTING = new Set(["vt200", "drag", "any"]);

/// Whether xterm.js turns a wheel into discrete lines right now: a wheel-reporting mouse protocol, or
/// the alt screen (no scrollback — xterm.js sends arrow keys).
export function wheelIsDiscrete(term: Pick<WheelLinesTerm, "modes" | "buffer">): boolean {
  return WHEEL_REPORTING.has(term.modes.mouseTrackingMode) || term.buffer.active.type === "alternate";
}

/// Route pixel wheels through `WheelLines` whenever xterm.js would turn them into lines (mouse
/// tracking on, or the alt screen, which has no scrollback). The original event is consumed and ONE
/// line-mode event per line is dispatched on its target, so xterm.js still encodes every report
/// (protocol, SGR/X10, modifiers, DECCKM arrows) itself.
export function attachWheelLines(term: WheelLinesTerm, cellCssHeight: () => number): WheelLines {
  const lines = new WheelLines();
  term.attachCustomWheelEventHandler((ev) => {
    if (ev.deltaMode !== 0 || ev.deltaY === 0 || ev.shiftKey) return true;
    if (!wheelIsDiscrete(term)) { lines.reset(); return true; }
    // Consumed: xterm.js cancels (preventDefault + stopPropagation) a wheel it reports, so this does
    // too — on the alt screen xterm.js cancels nothing once the handler has said false.
    ev.preventDefault();
    ev.stopPropagation();
    const n = lines.push(ev.deltaY, cellCssHeight(), term.rows);
    const target = ev.target instanceof EventTarget ? ev.target : null;
    if (n === 0 || !target) return false;
    const dir: 1 | -1 = n > 0 ? 1 : -1;
    for (let i = 0; i < Math.abs(n); i++) target.dispatchEvent(new WheelEvent("wheel", lineWheelInit(dir, ev)));
    return false;
  });
  return lines;
}
