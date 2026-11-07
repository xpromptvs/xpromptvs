import type { Terminal } from "@xterm/xterm";
import { FramePacer, WheelResampler } from "./wheel-resample";

/// SMOOTH SCROLLING of a terminal's scrollback — OPTIONAL, ON unless saved off (`smooth-scroll-pref.ts`,
/// since 2026-10-03).
///
/// xterm.js 6 already keeps the scroll position in FRACTIONAL pixels (its Viewport is VS Code's
/// scrollable element over a `Scrollable` with `forceIntegerValues: false`) and only ROUNDS it when it
/// picks the first row to draw (`Viewport._handleScroll`: `Math.round(scrollTop / cellHeight)`). So the
/// scrollback moves a whole row at a time on screen while the position underneath moves by the pixel.
/// This shifts `.xterm-screen` by the fraction the rounding threw away — upstream's proposal for exactly
/// this (xtermjs/xterm.js#6039, issue #6040), applied from outside instead of forking xterm.js.
///
/// xterm.js draws exactly one screen of rows; the lines beyond it, which a shift brings into view, are
/// drawn into the terminal's inset by `overscan-rows.ts`. At REST the view SETTLES to the row xterm.js
/// drew, so selection, copy and the prediction overlay only ever see a row-aligned screen.
///
/// Only the NORMAL buffer's scrollback is smooth. A mouse-tracking app or the alt screen turns a wheel
/// into discrete reports or arrow keys (`wheel-lines.ts`) and redraws whole rows itself.
///
/// THE ROWS AND THE SHIFT CHANGE TOGETHER (2026-09-29). A scroll moves xterm.js's row at once, but it
/// DRAWS the rows only at its next animation frame: a paint in between would show the shift for the new
/// row over the old rows, the text a whole row off at every row crossing. So a scroll has xterm.js draw
/// its pending rows NOW (`drawNow`), before the shift is written, and no paint can fall between the two.
/// (Built for Safari, which it turned out not to explain — its default mode paints only with an animation
/// frame; the wheel's delivery did, below.) `?scrollsync=0` turns it off to compare.
///
/// A TRACKPAD'S WHEEL IS RESAMPLED (`wheel`, wheel-resample.ts): events landing 1, 2 or 3 to a frame moved
/// the text in uneven steps however even the gesture; the view follows the gesture's stream, averaged, a
/// frame at a time. `xterm-view.ts` takes the wheel from xterm.js; `?wheelresample=0` compares.

/// The translation, in CSS px, that puts the rows xterm draws from `viewportY` where the fractional
/// `scrollTop` belongs: negative moves them up. Rounded to DEVICE pixels (a glyph on a half-device-pixel
/// boundary blurs). Zero when the two disagree by a row or more — that is xterm not having caught up, not
/// a fraction. **The bound is load-bearing**: measured against the row xterm had last DRAWN instead
/// (second review, C1), a hidden tab's shift grew a row per line of output until the screen sat outside
/// the stage, xterm.js's IntersectionObserver kept its renderer paused, and the tab came back BLANK for
/// good. The glide's frame lag that tried to answer is answered by the clock instead (`FrameClock`).
export function screenOffset(scrollTop: number, viewportY: number, cellPx: number, dpr: number): number {
  if (!(cellPx > 0) || !Number.isFinite(scrollTop) || !Number.isFinite(viewportY)) return 0;
  const raw = viewportY * cellPx - scrollTop;
  if (Math.abs(raw) >= cellPx) return 0;
  const d = dpr > 0 ? dpr : 1;
  const px = Math.round(raw * d) / d;
  return px === 0 ? 0 : px;   // never -0: it is written into a style
}

/// iOS's normal deceleration (`UIScrollView.DecelerationRate.normal`, 0.998 per ms) as a time constant:
/// the velocity falls by e every τ ms, and a flick travels v·τ in all.
export const GLIDE_TAU_MS = 1 / -Math.log(0.998);
/// Below this speed (px per ms) a glide is over.
export const GLIDE_STOP_PX_PER_MS = 0.02;
/// A gap between two glide frames longer than this is not a frame: the page was hidden (its animation
/// frames stop) or the main thread was busy that long. The glide ENDS there instead of travelling the
/// whole gap's distance in one frame.
export const GLIDE_MAX_FRAME_GAP_MS = 250;

/// A flick's momentum after the finger lifts. PURE: the caller supplies each frame's interval, and each
/// step is the exact integral of v·e^(−t/τ) over it — so the distance is the same at any frame rate
/// (the host's `ScrollMomentum` integrates the same way).
export class Glide {
  private v: number;

  /// `velocity` in px per ms, signed as the scroll position moves (positive scrolls forward, down).
  constructor(velocity: number) {
    this.v = Number.isFinite(velocity) ? velocity : 0;
  }

  get done(): boolean { return Math.abs(this.v) < GLIDE_STOP_PX_PER_MS; }

  /// The distance to move over the next `dtMs`.
  step(dtMs: number): number {
    if (this.done || !(dtMs > 0)) return 0;
    const decay = Math.exp(-dtMs / GLIDE_TAU_MS);
    const d = this.v * GLIDE_TAU_MS * (1 - decay);
    this.v *= decay;
    return d;
  }
}

type Disposable = { dispose(): void };

/// One xterm.js instance's scroll position, as the controller needs it. `xtermScrollSurface` builds it
/// over xterm.js's private Viewport; tests pass a fake.
export interface ScrollSurface {
  /// The fractional position, in CSS px.
  scrollTop(): number;
  /// Move there. xterm.js CLAMPS to the scrollback, and notifies `onScroll` only on a change.
  setScrollTop(top: number): void;
  maxScrollTop(): number;
  /// Every change of position or of the scrollback's size, whoever made it — a wheel, xterm itself, or
  /// this controller. Called AFTER xterm.js has picked its row for it (its own listener came first).
  onScroll(fn: (top: number) => void): Disposable;
  /// xterm.js redrew rows.
  onRender(fn: () => void): Disposable;
  /// The terminal was resized — xterm.js has moved its row already; its Viewport re-syncs the position
  /// only at its next redraw.
  onResize(fn: () => void): Disposable;
  /// A FULL scrollback trimmed `rows` lines while the viewer is scrolled back: xterm.js keeps the TEXT
  /// still by moving its row up that much, then snaps the position to that WHOLE row. Called BEFORE the
  /// snap, while the position still holds the fraction.
  onShift(fn: (rows: number) => void): Disposable;
  /// xterm.js's row — the first row of the buffer it shows (or will, at its next redraw).
  viewportY(): number;
  /// Draw NOW the rows xterm.js has pending for its next animation frame (the rows a scroll moved it to),
  /// so they and the shift written next are one state whenever the browser paints. A no-op when nothing
  /// is pending — or its renderer is paused, which pends nothing.
  drawNow(): void;
  cellHeight(): number;
  dpr(): number;
  setScreenOffset(px: number): void;
}

/// xterm.js's `RenderDebouncer`, the members `drawNow` reads. PRIVATE.
interface PendingDraw { _rowStart?: number; _animationFrame?: number; _innerRefresh?(): void }

/// xterm.js's Viewport is VS Code's scrollable element; these are the members of it this reads.
interface XtermScrollable {
  getScrollPosition(): { scrollTop: number };
  setScrollPosition(update: { scrollTop: number }): void;
  getScrollDimensions(): { height: number; scrollHeight: number };
  onScroll(fn: (e: { scrollTop: number }) => void): Disposable;
}

/// The surface over a REAL xterm.js 6: its PRIVATE `_core._viewport._scrollableElement` (names kept in
/// the shipped bundle; `smooth-scroll-xterm.test.ts` asserts them against it) and `.xterm-screen`. Null
/// before `open()`, or when an xterm.js upgrade has moved them — the option then does nothing, rather
/// than breaking scrolling. `cellHeight` is the CSS cell height (`xterm-view.ts` measures it). `sync: false`
/// leaves the rows to xterm.js's own frame (`drawNow` does nothing) — `?scrollsync=0`, to compare.
// Weak ownership: demo choreography can use the actual measured surface without retaining terminals.
const mountedSurfaces = new WeakMap<HTMLElement, ScrollSurface>();
export function mountedScrollSurface(element: HTMLElement): ScrollSurface | undefined {
  return mountedSurfaces.get(element);
}

/// `end`: the last line the view may start at, when that is above the bottom — an agent's trailing blank lines are
/// not there (trailing-blanks.ts) — and `maxScrollTop` stops there, so a wheel, a glide and a drag end at the
/// content as they end at the bottom: never past it to be put back (trailing-blanks-check T7).
export function xtermScrollSurface(term: Terminal, cellHeight: () => number, sync = true, end?: () => number): ScrollSurface | null {
  const viewport = (term as unknown as { _core?: { _viewport?: { _scrollableElement?: Partial<XtermScrollable> } } })._core?._viewport;
  const el = viewport?._scrollableElement;
  const screen = term.element?.querySelector<HTMLElement>(".xterm-screen");
  if (!el || !screen || typeof el.getScrollPosition !== "function" || typeof el.setScrollPosition !== "function"
    || typeof el.getScrollDimensions !== "function" || typeof el.onScroll !== "function") return null;
  const sc = el as XtermScrollable;
  let written = 0;
  // xterm.js's renderer draws at its next animation frame (`RenderDebouncer`, PRIVATE and asserted against
  // the shipped bundle by `smooth-scroll-xterm.test.ts`): `_rowStart` is set while rows are pending,
  // `_animationFrame` is the frame that will draw them, `_innerRefresh` is that frame's whole work.
  const pending = (term as unknown as { _core?: { _renderService?: { _renderDebouncer?: PendingDraw } } })
    ._core?._renderService?._renderDebouncer;
  const win = screen.ownerDocument.defaultView;
  const surface: ScrollSurface = {
    scrollTop: () => sc.getScrollPosition().scrollTop,
    setScrollTop: (top) => sc.setScrollPosition({ scrollTop: top }),
    maxScrollTop: () => {
      const d = sc.getScrollDimensions(), max = Math.max(0, d.scrollHeight - d.height), h = cellHeight();
      return end && h > 0 ? Math.min(max, Math.max(0, end() * h)) : max;
    },
    onScroll: (fn) => sc.onScroll((e) => fn(e.scrollTop)),
    onRender: (fn) => term.onRender(() => fn()),
    onResize: (fn) => term.onResize(() => fn()),
    // A TRIM is the one change of xterm's row that the POSITION has not made yet: `BufferService.scroll`
    // moves the row up one and fires `onScroll` (the public event, registered in xterm's constructor)
    // BEFORE the Viewport's own listener snaps the position to it. A scroll the Viewport made has already
    // moved the position, so its row is the position's rounded row; a jump to the bottom is not one row up.
    onShift: (fn) => term.onScroll(() => {
      const h = cellHeight(), b = term.buffer.active;
      if (!(h > 0) || b.type !== "normal") return;
      const full = b.length >= term.rows + (term.options.scrollback ?? 0);
      if (full && b.viewportY === Math.round(sc.getScrollPosition().scrollTop / h) - 1) fn(1);
    }),
    viewportY: () => term.buffer.active.viewportY,
    drawNow: () => {
      if (!sync || !pending || typeof pending._innerRefresh !== "function"
        || pending._rowStart === undefined || pending._animationFrame === undefined) return;
      // Its frame, run now — the same work, the same order (callbacks after the rows) — and not again.
      win?.cancelAnimationFrame(pending._animationFrame);
      pending._innerRefresh();
    },
    cellHeight,
    dpr: () => screen.ownerDocument.defaultView?.devicePixelRatio || 1,
    // Every redraw re-states the offset (a blinking cursor is one); a style write that changes nothing
    // is skipped rather than left to the engine to notice.
    setScreenOffset: (px) => {
      if (px === written) return;
      written = px;
      screen.style.transform = px ? `translateY(${px}px)` : "";
    },
  };
  if (term.element) mountedSurfaces.set(term.element, surface);
  return surface;
}

/// Frames and timers, injected so the tests own time.
export interface FrameClock {
  now(): number;
  /// Once per display frame. The product runs it just AFTER the animation frame (`xterm-view.ts`), so a
  /// scroll written there has xterm.js redraw in the NEXT frame, before its paint.
  frame(cb: (now: number) => void): number;
  cancelFrame(id: number): void;
  timeout(cb: () => void, ms: number): number;
  clearTimeout(id: number): void;
}

/// How long scrolling must have been quiet before the view settles onto a row. A trackpad's own momentum
/// arrives every frame until it ends, so this only fires once the motion has really stopped.
export const SETTLE_IDLE_MS = 200;

/// A wheel gesture ends — and the settle is armed — once its stream has all arrived and no event has come
/// for this long. An event within it belongs to the SAME gesture even when the stream had caught up, so
/// its window and frame clock carry on rather than starting over (a 16 ms window and raw frame times) —
/// which a stream can do between its first events, when they come a frame apart.
export const WHEEL_GESTURE_GAP_MS = 100;
/// A wheel gesture whose stream has not settled this long after its last event is finished outright.
export const WHEEL_GIVE_UP_MS = 1000;
/// How long the settle takes: under half a row, eased out.
export const SETTLE_MS = 100;

/// A position this controller wrote and a notification carrying it may differ by rounding in the
/// scrollable; anything further away was somebody else's scroll.
const OWN_SCROLL_SLOP_PX = 0.5;

/// Smooth scrolling for ONE xterm.js instance: the sub-row offset, the settle at rest, a trackpad's wheel
/// RESAMPLED a frame at a time (`wheel`, wheel-resample.ts), and — driven by the touch handler
/// (`touch-scroll.ts`) — a finger's drag and the glide after it.
export class SmoothScroll {
  private on: boolean;
  private disposed = false;
  private held = false;
  private settleTimer: number | null = null;
  private frameId: number | null = null;
  /// The running animation: a glide, a settle, or a wheel gesture being followed — its stream, its frame
  /// clock, and the position its distance counts from.
  private anim: { kind: "glide"; glide: Glide; last: number } | { kind: "settle"; from: number; to: number; start: number }
    | { kind: "wheel"; stream: WheelResampler; pacer: FramePacer; base: number; arrived: number } | null = null;
  /// The position this controller last wrote: a notification far from it was somebody else's scroll.
  private expected = 0;
  /// A trim's snap is on its way (`onShift`): the whole-row position the Viewport will snap to, and the
  /// position to put back instead — that row plus the fraction. Only THAT notification takes it.
  private restore: { snapTo: number; to: number } | null = null;
  /// The write in progress is a trim's restore: it is not the person scrolling, so it must not postpone
  /// a settle — or a still view streams output between rows for as long as output comes.
  private restoring = false;
  private readonly subs: Disposable[];

  constructor(private readonly s: ScrollSurface, private readonly clock: FrameClock, enabled: boolean) {
    this.on = enabled;
    this.subs = [
      s.onScroll((top) => this.scrolled(top)),
      s.onRender(() => this.checkStale()),
      s.onResize(() => this.checkStale()),
      s.onShift((rows) => this.shifted(rows)),
    ];
    if (enabled) this.applyOffset();
  }

  get enabled(): boolean { return this.on; }
  /// A finger is on the terminal (`hold` until `release`): its drag draws as the touch events come
  /// (gpu-frame-draws.ts keeps those immediate).
  get holding(): boolean { return this.held; }
  /// A flick's glide is running (`release`) — what a finger landing now STOPS (touch-scroll.ts: that tap does
  /// nothing else). A settle's snap onto the row is not one.
  get gliding(): boolean { return this.anim?.kind === "glide"; }

  setEnabled(on: boolean): void {
    if (this.disposed || on === this.on) return;
    this.on = on;
    if (on) {
      this.applyOffset();
      if (!this.held) this.armSettle();   // a position left between rows while off settles too
      return;
    }
    this.cancel();
    this.held = false;
    this.restore = null;
    // Off is exactly today's behaviour: a row-aligned screen and no offset.
    this.s.setScreenOffset(0);
    const row = this.rowTop();
    if (row !== null) this.s.setScrollTop(row);
  }

  /// A finger is down on the terminal: a glide or settle in progress stops where it is (tap to stop),
  /// and nothing settles until it lifts.
  hold(): void {
    if (!this.on) return;
    this.cancel();
    this.held = true;
  }

  /// The finger moved: follow it exactly. `dy` in CSS px, positive scrolls forward (toward the bottom).
  drag(dy: number): void {
    if (!this.on || !Number.isFinite(dy) || dy === 0) return;
    this.cancel();
    this.s.setScrollTop(Math.min(this.s.maxScrollTop(), Math.max(0, this.s.scrollTop() + dy)));
  }

  /// The finger lifted. `velocity` (px per ms, signed as `drag`) glides on; null or too slow settles.
  release(velocity: number | null): void {
    if (!this.on) return;
    this.held = false;
    const glide = new Glide(velocity ?? 0);
    if (glide.done) { this.armSettle(); return; }
    this.anim = { kind: "glide", glide, last: this.clock.now() };
    this.expected = this.s.scrollTop();
    this.requestFrame();
  }

  /// A wheel event over the scrollback, taken from xterm.js (`xterm-view.ts`): `px` toward the bottom,
  /// as far as xterm.js would have moved it (`wheelPixels`), at `time` (the event's, on the frame clock's
  /// timebase). The view follows the gesture's stream once per frame — averaged, so events landing 1, 2
  /// or 3 to a frame still move it evenly — until it has all arrived; somebody else's scroll, a finger or
  /// the tab going out of sight ends it.
  wheel(px: number, time: number): void {
    if (!this.on || !Number.isFinite(px) || px === 0 || !Number.isFinite(time)) return;
    let a = this.anim;
    if (a?.kind !== "wheel") {
      this.cancel();
      a = this.anim = { kind: "wheel", stream: new WheelResampler(), pacer: new FramePacer(), base: this.s.scrollTop(), arrived: 0 };
      this.expected = a.base;
    }
    a.stream.add(time, px);
    a.arrived = this.clock.now();
    this.requestFrame();
  }

  /// Stop any glide or settle and put the view on its row at once — the tab is going out of sight.
  stop(): void {
    if (!this.on) return;
    this.cancel();
    this.held = false;
    const row = this.rowTop();
    if (row !== null) this.write(row);
    this.cancel();   // the aligned position's own notification armed a settle with nothing left to do
    this.applyOffset();
  }

  dispose(): void {
    if (this.disposed) return;
    this.cancel();
    for (const d of this.subs) d.dispose();
    this.s.setScreenOffset(0);
    this.on = false;
    this.disposed = true;
  }

  private scrolled(top: number): void {
    if (!this.on) return;
    // The rows this position needs, drawn before any shift is written for them (the module header).
    this.s.drawNow();
    // A trim's snap: put the fraction back on the row it snapped to. The restore's own notification
    // does the rest. Any other notification voids a restore — it was never this one's.
    const r = this.restore;
    this.restore = null;
    if (r && Math.abs(top - r.snapTo) <= OWN_SCROLL_SLOP_PX) {
      if (Math.abs(r.to - top) > 0.01) {
        this.restoring = true;
        try { this.write(r.to); } finally { this.restoring = false; }
        return;
      }
      this.expected = top;
      this.applyOffset();
      if (!this.anim && !this.held) this.armSettle(false);
      return;
    }
    // xterm.js moved its row without the position (a resize: `Buffer.resize` moves it and the Viewport
    // keeps the user's last row). Re-sync at once — a settle would animate across the whole gap, and
    // every step of it would drag xterm's row along (review I2).
    if (this.stale(top)) { this.resync(); return; }
    // Somebody else's scroll — a wheel, xterm jumping to the bottom on a keystroke — wins over a glide
    // or settle in progress.
    if (this.anim && Math.abs(top - this.expected) > OWN_SCROLL_SLOP_PX) this.cancel();
    this.applyOffset();
    if (!this.anim && !this.held) this.armSettle(!this.restoring);
  }

  /// A redraw or a resize: xterm.js may have moved its row with no scroll notification (a resize; a
  /// trim whose snap the Viewport skipped). Re-sync before anything steps from the stale position —
  /// a step run from it would drag xterm's row back for a frame (second review, M-a).
  private checkStale(): void {
    if (this.on && this.stale(this.s.scrollTop())) this.resync();
  }

  /// A trim: xterm.js moved its row up `rows` to keep the text still and is about to snap the position
  /// to that WHOLE row. What to put back is that row plus the position's fraction of a row — measured
  /// from the nearest row, not from the old position, which a trim whose snap was skipped left stale
  /// (second review, M-b). A settle in progress moves with the text (second review, I-A).
  private shifted(rows: number): void {
    if (!this.on) return;
    const h = this.s.cellHeight(), y = this.s.viewportY();
    if (!(h > 0) || !Number.isFinite(y)) return;
    const top = this.s.scrollTop();
    const fraction = top - Math.round(top / h) * h;
    const r = { snapTo: y * h, to: Math.max(0, y * h + fraction) };
    this.restore = r;
    const a = this.anim;
    if (a?.kind === "settle") { a.from = Math.max(0, a.from - rows * h); a.to = Math.max(0, a.to - rows * h); }
    if (a?.kind === "wheel") a.base -= rows * h;   // the same text is that many rows higher now
    // The snap follows synchronously; a restore it never claimed must not land on a later scroll.
    queueMicrotask(() => { if (this.restore === r) this.restore = null; });
  }

  /// xterm.js's row and the position disagree by more than the rounding between them.
  private stale(top: number): boolean {
    const h = this.s.cellHeight(), y = this.s.viewportY();
    return h > 0 && Number.isFinite(y) && Math.abs(y * h - top) > h / 2 + OWN_SCROLL_SLOP_PX;
  }

  private resync(): void {
    this.cancel();
    const row = this.rowTop();
    if (row !== null) this.write(row);
  }

  private applyOffset(): void {
    this.s.setScreenOffset(screenOffset(this.s.scrollTop(), this.s.viewportY(), this.s.cellHeight(), this.s.dpr()));
  }

  /// (Re)start the quiet period before a settle. `restart: false` only arms one if none is pending.
  private armSettle(restart = true): void {
    if (this.settleTimer !== null && !restart) return;
    if (this.settleTimer !== null) this.clock.clearTimeout(this.settleTimer);
    this.settleTimer = this.clock.timeout(() => { this.settleTimer = null; this.settle(); }, SETTLE_IDLE_MS);
  }

  /// Ease onto xterm.js's row — under half a row away, since its row is the ROUNDED position.
  private settle(): void {
    const from = this.s.scrollTop();
    if (this.stale(from)) { this.resync(); return; }
    const to = this.rowTop();
    if (to === null || Math.abs(to - from) < 0.01) return;
    this.anim = { kind: "settle", from, to, start: this.clock.now() };
    this.expected = from;
    this.requestFrame();
  }

  /// The position of xterm.js's row, or null with no cell measured (a hidden instance): row 0
  /// computed from a zero height would throw the view to the top of the scrollback.
  private rowTop(): number | null {
    const h = this.s.cellHeight(), y = this.s.viewportY();
    if (!(h > 0) || !Number.isFinite(y)) return null;
    return Math.min(this.s.maxScrollTop(), Math.max(0, y * h));
  }

  private requestFrame(): void {
    if (this.frameId === null) this.frameId = this.clock.frame((now) => { this.frameId = null; this.tick(now); });
  }

  private tick(now: number): void {
    const a = this.anim;
    if (!a) return;
    if (a.kind === "wheel") {
      const t = a.pacer.tick(now);
      // A second after the last event ARRIVED (this controller's clock) the whole distance is where the
      // view goes, whatever the stamps say — a frame time off the events' clock must never leave the
      // scroll unfinished.
      const quiet = this.clock.now() - a.arrived;
      const giveUp = quiet > WHEEL_GIVE_UP_MS, arrived = giveUp || a.stream.settled(t);
      const want = a.base + (arrived ? a.stream.total() : a.stream.at(t));
      const target = Math.min(this.s.maxScrollTop(), Math.max(0, want));
      // Past an end the stream's excess is dropped, so turning back there moves at once.
      a.base += target - want;
      this.write(target);
      if (this.anim !== a) return;             // somebody else's scroll overtook it
      if (giveUp || (arrived && quiet > WHEEL_GESTURE_GAP_MS)) { this.anim = null; this.armSettle(); return; }
      this.requestFrame();
      return;
    }
    if (a.kind === "settle") {
      const t = Math.min(1, (now - a.start) / SETTLE_MS);
      const eased = 1 - (1 - t) ** 3;
      this.write(t >= 1 ? a.to : a.from + (a.to - a.from) * eased);
      if (this.anim !== a) return;             // the write was overtaken
      if (t >= 1) { this.anim = null; return; }
      this.requestFrame();
      return;
    }
    const dt = now - a.last;
    a.last = now;
    if (dt > GLIDE_MAX_FRAME_GAP_MS) { this.anim = null; this.settle(); return; }
    const dy = a.glide.step(dt);
    const max = this.s.maxScrollTop();
    const target = Math.min(max, Math.max(0, this.s.scrollTop() + dy));
    this.write(target);
    if (this.anim !== a) return;
    if (a.glide.done || target <= 0 || target >= max) { this.anim = null; this.settle(); return; }
    this.requestFrame();
  }

  /// Move to `top` as this controller's own scroll.
  private write(top: number): void {
    this.expected = top;
    this.s.setScrollTop(top);
  }

  private cancel(): void {
    this.anim = null;
    if (this.frameId !== null) { this.clock.cancelFrame(this.frameId); this.frameId = null; }
    if (this.settleTimer !== null) { this.clock.clearTimeout(this.settleTimer); this.settleTimer = null; }
  }
}
