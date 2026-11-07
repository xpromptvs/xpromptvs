import { describe, expect, it } from "vitest";
import {
  Glide, GLIDE_STOP_PX_PER_MS, GLIDE_TAU_MS, screenOffset, SETTLE_IDLE_MS, SETTLE_MS, SmoothScroll,
  type FrameClock, type ScrollSurface,
} from "../src/client/smooth-scroll";

describe("screenOffset", () => {
  const h = 17;
  it("shifts the drawn rows UP by the fraction scrolled past the row xterm drew", () => {
    // scrollTop 10.3 rows: xterm drew from row 10, the content belongs 0.3 row higher.
    expect(screenOffset(10.3 * h, 10, h, 1)).toBe(Math.round(-0.3 * h));
  });

  it("shifts them DOWN when xterm rounded up to the next row", () => {
    expect(screenOffset(10.7 * h, 11, h, 1)).toBe(Math.round(0.3 * h));
  });

  it("is exactly zero (never -0) on a row boundary", () => {
    expect(Object.is(screenOffset(10 * h, 10, h, 2), 0)).toBe(true);
  });

  it("rounds to DEVICE pixels, not CSS pixels", () => {
    // 5.3 CSS px at dpr 2 is 10.6 device px → 11 → 5.5 CSS px.
    expect(screenOffset(10 * h + 5.3, 10, h, 2)).toBe(-5.5);
    expect(screenOffset(10 * h + 5.3, 10, h, 1)).toBe(-5);
  });

  it("is zero when xterm's row and the position disagree by a row or more", () => {
    // Not a fraction: xterm has not caught up (a stale position, re-synced by the controller). Shifting
    // by it moved a hidden terminal's screen out of view for good (second review, C1).
    expect(screenOffset(10 * h, 12, h, 1)).toBe(0);
    expect(screenOffset(10 * h + h, 10, h, 1)).toBe(0);
  });

  it("is zero for an unmeasured cell or a non-finite position", () => {
    expect(screenOffset(100, 5, 0, 1)).toBe(0);
    expect(screenOffset(Number.NaN, 5, h, 1)).toBe(0);
    expect(screenOffset(100, 5, h, 0)).toBe(-15);   // dpr 0 is treated as 1
  });
});

describe("Glide", () => {
  const run = (v: number, dt: number) => {
    const g = new Glide(v);
    let total = 0, steps = 0;
    while (!g.done && steps < 100_000) { total += g.step(dt); steps++; }
    return { total, steps };
  };

  it("travels v·τ in all — the integral of an exponentially decaying velocity", () => {
    const v = 3;   // px/ms: a brisk phone flick
    const { total } = run(v, 1000 / 60);
    // It stops at the stop speed, so it falls short of v·τ by exactly stop·τ.
    expect(total).toBeCloseTo((v - GLIDE_STOP_PX_PER_MS) * GLIDE_TAU_MS, -1);
    expect(total).toBeGreaterThan(0.98 * v * GLIDE_TAU_MS);
  });

  it("covers the same distance at 60 Hz and at 120 Hz", () => {
    const a = run(2, 1000 / 60).total, b = run(2, 1000 / 120).total;
    expect(Math.abs(a - b)).toBeLessThan(0.5 + 2 * GLIDE_STOP_PX_PER_MS * 1000 / 60);
  });

  it("slows every frame and keeps its direction", () => {
    const g = new Glide(-2);
    const steps = Array.from({ length: 30 }, () => g.step(16));
    for (const s of steps) expect(s).toBeLessThan(0);
    for (let i = 1; i < steps.length; i++) expect(Math.abs(steps[i]!)).toBeLessThan(Math.abs(steps[i - 1]!));
  });

  it("is done at once, and moves nothing, below the stop speed", () => {
    const g = new Glide(GLIDE_STOP_PX_PER_MS / 2);
    expect(g.done).toBe(true);
    expect(g.step(16)).toBe(0);
  });

  it("ignores a non-finite or non-positive frame interval", () => {
    const g = new Glide(1);
    expect(g.step(0)).toBe(0);
    expect(g.step(-5)).toBe(0);
    expect(g.step(Number.NaN)).toBe(0);
    expect(g.done).toBe(false);
  });
});

/// xterm.js's Viewport as the controller sees it. `y` is the buffer's row (`ydisp`), which the Viewport
/// sets to the ROUNDED position on every scroll (`_handleScroll`); a notification comes only on a CHANGE
/// (VS Code's Scrollable); the redraw follows each scroll before the paint (`autoRender`, as it does for a
/// wheel or a finger) or waits for `render()`.
class FakeSurface implements ScrollSurface {
  top = 0;
  y = 0;
  offset = 0;
  offsetWrites = 0;
  autoRender = true;
  /// What the controller asked of the surface, in order: `draw` (xterm.js's pending rows, now) and each
  /// offset written.
  readonly log: string[] = [];
  private readonly scrollL = new Set<(top: number) => void>();
  private readonly renderL = new Set<() => void>();
  private readonly shiftL = new Set<(rows: number) => void>();
  private readonly resizeL = new Set<() => void>();
  constructor(readonly h = 20, public max = 2000) {}
  scrollTop() { return this.top; }
  maxScrollTop() { return this.max; }
  setScrollTop(top: number) {
    const t = Math.min(this.max, Math.max(0, top));
    if (t === this.top) return;
    this.top = t;
    if (this.h > 0) this.y = Math.round(t / this.h);
    this.notify();
  }
  /// Each event carries ITS position, as VS Code's emitter does, even when a listener scrolls again.
  private notify() {
    const top = this.top;
    for (const f of [...this.scrollL]) f(top);
    if (this.autoRender) this.render();
  }
  render() { for (const f of [...this.renderL]) f(); }
  /// A FULL scrollback trims a line while scrolled back (`BufferService.scroll`): the row moves up one to
  /// keep the text still, the public `onScroll` announces it, then the Viewport snaps the position to it.
  trim() {
    this.y = Math.max(0, this.y - 1);
    for (const f of [...this.shiftL]) f(1);
    const t = this.y * this.h;
    if (t !== this.top) { this.top = t; this.notify(); }
  }
  /// A trim whose snap never comes: the Viewport skips `setScrollPosition` when xterm's row equals the
  /// row it last recorded (`_sync`: `ydisp !== _latestYDisp`).
  trimNoSnap() {
    this.y = Math.max(0, this.y - 1);
    for (const f of [...this.shiftL]) f(1);
  }
  /// A resize moves the row and leaves the position STALE (`Buffer.resize`, then a `_sync` that keeps the
  /// user's last row): the dimension change notifies with the same position.
  resizeStale(rows: number) { this.y += rows; this.notify(); }
  /// The same resize as `term.onResize` sees it: the row has moved, and the Viewport's own sync — the
  /// dimension notification — is still queued for its next redraw.
  resizeQuiet(rows: number) { this.y += rows; for (const f of [...this.resizeL]) f(); }
  /// Output at the bottom of a GROWING buffer: the row follows the bottom, the dimension event comes
  /// with the old position, then the Viewport moves the position to the row (`_sync`).
  lineAtBottom() {
    this.max += this.h;
    this.y += 1;
    this.notify();
    const t = this.y * this.h;
    if (t !== this.top) { this.top = t; this.notify(); }
  }
  onScroll(fn: (top: number) => void) { this.scrollL.add(fn); return { dispose: () => { this.scrollL.delete(fn); } }; }
  onRender(fn: () => void) { this.renderL.add(fn); return { dispose: () => { this.renderL.delete(fn); } }; }
  onShift(fn: (rows: number) => void) { this.shiftL.add(fn); return { dispose: () => { this.shiftL.delete(fn); } }; }
  onResize(fn: () => void) { this.resizeL.add(fn); return { dispose: () => { this.resizeL.delete(fn); } }; }
  viewportY() { return this.y; }
  cellHeight() { return this.h; }
  dpr() { return 1; }
  setScreenOffset(px: number) { this.offset = px; this.offsetWrites++; this.log.push(`offset ${px}`); }
  drawNow() { this.log.push("draw"); }
  get listening() { return this.scrollL.size + this.renderL.size + this.shiftL.size + this.resizeL.size; }
}

class FakeClock implements FrameClock {
  t = 0;
  /// The frame period: 16 ms (60 Hz) unless a test asks for 120 Hz.
  constructor(readonly period = 16) {}
  private seq = 1;
  private readonly frames = new Map<number, (now: number) => void>();
  private readonly timers = new Map<number, { at: number; cb: () => void }>();
  now() { return this.t; }
  frame(cb: (now: number) => void) { const id = this.seq++; this.frames.set(id, cb); return id; }
  cancelFrame(id: number) { this.frames.delete(id); }
  timeout(cb: () => void, ms: number) { const id = this.seq++; this.timers.set(id, { at: this.t + ms, cb }); return id; }
  clearTimeout(id: number) { this.timers.delete(id); }
  /// Advance in frames; each frame fires the timers now due, then the frames requested before it.
  advance(ms: number) {
    const end = this.t + ms;
    while (this.t < end) {
      this.t = Math.min(end, this.t + this.period);
      for (const [id, x] of [...this.timers]) if (x.at <= this.t) { this.timers.delete(id); x.cb(); }
      const due = [...this.frames];
      this.frames.clear();
      for (const [, cb] of due) cb(this.t);
    }
  }
  get idle() { return this.frames.size === 0 && this.timers.size === 0; }
  /// Time passes with no frame at all — a hidden page's animation frames stop.
  pause(ms: number) { this.t += ms; }
}

describe("SmoothScroll", () => {
  const setup = (enabled = true) => {
    const s = new FakeSurface(), c = new FakeClock();
    const ctl = new SmoothScroll(s, c, enabled);
    return { s, c, ctl };
  };

  it("shifts the screen by the fraction of a row a scroll leaves", () => {
    const { s } = setup();
    s.setScrollTop(10 * 20 + 6);   // a trackpad's pixel scroll
    expect(s.offset).toBe(-6);
    s.setScrollTop(10 * 20 + 14);  // xterm drew row 11: the rows belong 6 px lower
    expect(s.offset).toBe(6);
  });

  it("has xterm.js draw the rows a scroll moves to BEFORE it writes the shift for them", () => {
    // WebKit paints what an input handler changed at its next display refresh, which need not run
    // animation frames (Safari holds them to 60 Hz on a 120 Hz display): a shift written for rows xterm.js
    // draws only at its next frame was painted against the OLD rows — the text a whole row off.
    const s = new FakeSurface();
    s.autoRender = false;
    const ss = new SmoothScroll(s, new FakeClock(), true);
    s.log.length = 0;
    s.setScrollTop(3 * 20 + 5);
    expect(s.log).toEqual(["draw", "offset -5"]);
    ss.dispose();
  });

  it("writes no offset at all while off", () => {
    const { s, c } = setup(false);
    s.setScrollTop(206);
    c.advance(1000);
    expect(s.offsetWrites).toBe(0);
    expect(s.top).toBe(206);   // and settles nothing: off is today's behaviour
  });

  it("settles to the row it drew once scrolling has been quiet for SETTLE_IDLE_MS", () => {
    const { s, c } = setup();
    s.setScrollTop(206);
    c.advance(SETTLE_IDLE_MS - 20);
    expect(s.top).toBe(206);
    c.advance(20 + SETTLE_MS + 32);
    expect(s.top).toBe(200);
    expect(s.offset).toBe(0);
    expect(c.idle).toBe(true);
  });

  it("settles in steps, not a jump", () => {
    const { s, c } = setup();
    s.setScrollTop(209);
    const seen = new Set<number>();
    s.onScroll((t) => seen.add(t));
    c.advance(SETTLE_IDLE_MS + SETTLE_MS + 32);
    expect(s.top).toBe(200);
    expect(seen.size).toBeGreaterThan(2);
  });

  it("never settles against an unmeasured cell (it would compute row 0 and jump to the top)", () => {
    const s = new FakeSurface(0), c = new FakeClock();
    new SmoothScroll(s, c, true);
    s.setScrollTop(206);
    c.advance(SETTLE_IDLE_MS + SETTLE_MS + 64);
    expect(s.top).toBe(206);
  });

  it("postpones the settle while scrolling continues", () => {
    const { s, c } = setup();
    for (let i = 1; i <= 10; i++) { s.setScrollTop(200 + i * 3.1); c.advance(SETTLE_IDLE_MS / 2); }
    expect(s.top).toBeCloseTo(231);           // no settle in between: every scroll re-armed it
    c.advance(SETTLE_IDLE_MS + SETTLE_MS + 32);
    expect(s.top).toBe(240);                   // 231 / 20 = 11.55: xterm drew row 12
  });

  it("abandons a settle when something else scrolls meanwhile", () => {
    const { s, c } = setup();
    s.setScrollTop(207);
    c.advance(SETTLE_IDLE_MS + 32);            // settling
    s.setScrollTop(503);                       // the person scrolled again
    c.advance(48);
    expect(s.top).toBe(503);                   // the old settle does not drag it back toward 200
    c.advance(SETTLE_IDLE_MS + SETTLE_MS + 32);
    expect(s.top).toBe(500);
  });

  it("moves by exactly the finger's travel, and settles nothing while the finger is down", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(400);
    ctl.hold();
    ctl.drag(-7);
    expect(s.top).toBe(393);
    c.advance(5 * SETTLE_IDLE_MS);
    expect(s.top).toBe(393);
    expect(s.offset).toBe(7);
  });

  it("keeps gliding after the finger lifts, then comes to rest on a row", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    ctl.hold();
    ctl.release(-1.5);   // px per ms, backwards
    c.advance(100);
    const after100 = s.top;
    expect(after100).toBeLessThan(1000);
    c.advance(100);
    expect(s.top).toBeLessThan(after100);
    c.advance(10_000);
    expect(c.idle).toBe(true);
    expect(s.top % 20).toBe(0);
    expect(s.offset).toBe(0);
    // It went about v·τ (the settle moves it by under half a row).
    expect(1000 - s.top).toBeGreaterThan(1.5 * GLIDE_TAU_MS * 0.9);
  });

  it("says it is GLIDING only while a flick's glide runs — not held, not settling, not at rest", () => {
    // What a finger landing now stops — and touch-scroll.ts makes that tap do nothing else.
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    expect(ctl.gliding).toBe(false);
    ctl.hold();
    expect(ctl.gliding).toBe(false);
    ctl.release(-1.5);
    c.advance(50);
    expect(ctl.gliding).toBe(true);
    ctl.hold();                       // a finger lands: it stops
    expect(ctl.gliding).toBe(false);
    ctl.release(null);                // a lift with no flick settles onto the row
    expect(ctl.gliding).toBe(false);
    ctl.release(-1.5);
    c.advance(10_000);                // the glide ran out
    expect(ctl.gliding).toBe(false);
  });

  // ---- The wheel, RESAMPLED (wheel-resample.ts): the view follows the stream a frame at a time. ----

  /// How uneven a run of per-frame steps is (the scroll probe's measure: 0 even, ≳ 0.3 visibly uneven).
  const unevenness = (d: number[]) => {
    let j = 0;
    for (let i = 1; i + 1 < d.length; i++) j += Math.abs(d[i]! - (d[i - 1]! + d[i + 1]!) / 2);
    return j / (d.length - 2) / (d.reduce((a, v) => a + Math.abs(v), 0) / d.length);
  };

  it("moves for a wheel only at frames, and arrives at all of it, then settles onto a row", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    c.advance(1000);
    ctl.wheel(45, c.t);
    expect(s.top).toBe(1000);                  // not in the event: at the next frame
    c.advance(16);
    expect(s.top).toBeGreaterThan(1000);
    expect(s.top).toBeLessThanOrEqual(1045);
    c.advance(100);
    expect(s.top).toBeCloseTo(1045, 6);        // the whole of it
    c.advance(1000);
    expect(s.top).toBe(1040);                  // then the settle, onto xterm.js's row
    expect(c.idle).toBe(true);
  });

  it("steps evenly for events DELIVERED 1, 2 or 3 to a frame", () => {
    // As Safari delivered a flick at its 60 fps limit: events reaching the page in pairs about 4 ms apart,
    // the pairs drifting against the frames — so a frame gets 1, 2 or 3 of them. Each is timed
    // when it ARRIVES, as the probe recorded them (a creation stamp would leave the newest part of the
    // window incomplete by however late the events still on their way are).
    const { s, c, ctl } = setup();
    s.setScrollTop(200);
    c.advance(1000);
    const t0 = c.t;
    const arrive = Array.from({ length: 90 }, (_, j) => t0 + j * 9.6 + (j % 2 === 0 ? 5 : 1));
    const tops: number[] = [], landed: number[] = [];
    let next = 0, sum = 0;
    for (let k = 0; k < 38; k++) {
      while (next < arrive.length && arrive[next]! <= c.t + 16) { ctl.wheel(12, arrive[next++]!); sum += 12; }
      c.advance(16);
      tops.push(s.top);
      landed.push(sum);
    }
    const steps = (xs: number[]) => xs.slice(1).map((t, i) => t - xs[i]!);
    expect(unevenness(steps(landed).slice(4, 36))).toBeGreaterThan(0.3);   // moved by what arrived: today
    expect(unevenness(steps(tops).slice(4, 36))).toBeLessThan(0.1);
  });

  it("steps evenly for a 60 Hz stream whose arrivals wobble: its window spans two of its events", () => {
    // An event every ~16 ms, wobbling (13–20 ms), against 60 Hz frames: the window grows to two of the
    // stream's gaps (~33 ms) and the wobble averages out.
    const { s, c, ctl } = setup();
    s.setScrollTop(200);
    c.advance(1000);
    const gaps = [13, 20, 16, 19, 14, 18, 15, 17];
    const tops: number[] = [];
    let at = c.t + 3, k = 0;
    for (let f = 0; f < 60; f++) {
      while (at <= c.t + 16) { ctl.wheel(24, at); at += gaps[k++ % gaps.length]!; }
      c.advance(16);
      tops.push(s.top);
    }
    const steps = tops.slice(1).map((t, i) => t - tops[i]!);
    expect(unevenness(steps.slice(10, 55))).toBeLessThan(0.15);
  });

  it("moves back AT ONCE after pushing past the end of the scrollback, mid-gesture", () => {
    const { s, c, ctl } = setup();
    s.max = 400;
    s.setScrollTop(300);
    c.advance(1000);
    for (let k = 0; k < 12; k++) { ctl.wheel(40, c.t); c.advance(16); }   // 480 px toward a 100 px end
    expect(s.top).toBe(400);
    ctl.wheel(-20, c.t); c.advance(16);                                   // the same gesture turns back
    ctl.wheel(-20, c.t); c.advance(16);
    expect(s.top).toBeLessThan(400);           // not after working off the 380 px pushed past the end
  });

  it("gives way to somebody else's scroll (xterm.js jumping to the bottom on a keystroke)", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(500);
    c.advance(1000);
    ctl.wheel(200, c.t);
    c.advance(16);
    s.setScrollTop(1800);
    c.advance(200);
    expect(s.top).toBe(1800);
  });

  it("stops where it is for a finger on the terminal, and does nothing while off", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(500);
    c.advance(1000);
    ctl.wheel(200, c.t);
    c.advance(16);
    ctl.hold();
    const held = s.top;
    c.advance(200);
    expect(s.top).toBe(held);
    const off = setup(false);
    off.s.setScrollTop(500);
    off.ctl.wheel(200, off.c.t);
    off.c.advance(200);
    expect(off.s.top).toBe(500);
  });

  it("finishes a gesture outright a second after its last event, whatever the frames' clock says", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(500);
    c.advance(1000);
    ctl.wheel(60, c.t + 1e6);                  // stamped on a clock the frames are nowhere near
    c.advance(500);
    expect(s.top).toBe(500);
    c.advance(1000);
    expect(s.top).toBe(560);
  });

  it("keeps the text still through a line trimmed from a full scrollback mid-gesture", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    c.advance(1000);
    for (let k = 0; k < 5; k++) { ctl.wheel(20, c.t); c.advance(16); }
    s.trim();                                  // the text moved up a row in the buffer
    for (let k = 0; k < 5; k++) { ctl.wheel(20, c.t); c.advance(16); }
    c.advance(1000);
    expect(s.top).toBe(1180);                  // 1000 + 200 − the trimmed row, never a row off
  });

  it("stops a glide at the end of the scrollback", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1990);
    ctl.hold();
    ctl.release(3);
    c.advance(10_000);
    expect(s.top).toBe(2000);
    expect(c.idle).toBe(true);
  });

  it("stops a glide on a touch (tap to stop)", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    ctl.hold();
    ctl.release(-2);
    c.advance(64);
    ctl.hold();
    const at = s.top;
    c.advance(1000);
    expect(s.top).toBe(at);
  });

  it("stops a glide when something else scrolls (xterm jumping to the bottom on a keystroke)", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    ctl.hold();
    ctl.release(-2);
    c.advance(64);
    s.setScrollTop(2000);
    c.advance(1000);
    expect(s.top).toBe(2000);
  });

  it("does not glide from a slow release, but settles", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    ctl.hold();
    ctl.drag(-5);
    ctl.release(null);
    c.advance(SETTLE_IDLE_MS + SETTLE_MS + 32);
    expect(s.top).toBe(1000);
  });

  it("stop() ends a glide where it is and puts the view on its row at once (a tab going hidden)", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    ctl.hold();
    ctl.release(-2);
    c.advance(48);
    ctl.stop();
    expect(s.top % 20).toBe(0);
    expect(s.offset).toBe(0);
    const at = s.top;
    c.advance(1000);
    expect(s.top).toBe(at);
    expect(c.idle).toBe(true);
    expect(ctl.enabled).toBe(true);
  });

  it("turned off, snaps to the drawn row at once and clears the offset", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    ctl.hold();
    ctl.release(-2);
    c.advance(48);
    ctl.setEnabled(false);
    expect(s.offset).toBe(0);
    expect(s.top % 20).toBe(0);
    expect(c.idle).toBe(true);
    ctl.hold();
    ctl.drag(-7);                     // the touch path never calls these while off; they do nothing
    expect(s.top % 20).toBe(0);
  });

  it("turned on, shifts by the fraction the position already has, then settles it", () => {
    const { s, c, ctl } = setup(false);
    s.setScrollTop(205);
    ctl.setEnabled(true);
    expect(s.offset).toBe(-5);
    c.advance(SETTLE_IDLE_MS + SETTLE_MS + 32);
    expect(s.top).toBe(200);
    expect(s.offset).toBe(0);
  });

  it("a terminal that stops redrawing (hidden) and keeps growing is never shifted past half a row", () => {
    // Second review, C1: against the row xterm DREW, a hidden tab's shift grew a row per line of output
    // until the screen sat outside the stage, xterm's IntersectionObserver kept its renderer paused, and
    // the terminal came back blank for good.
    const s = new FakeSurface(20, 400), c = new FakeClock();
    new SmoothScroll(s, c, true);
    s.setScrollTop(400);
    s.autoRender = false;
    const shifts: number[] = [];
    const watch = s.onScroll(() => shifts.push(s.offset));
    for (let i = 0; i < 60; i++) s.lineAtBottom();
    watch.dispose();
    expect(shifts.length).toBeGreaterThan(60);
    expect(Math.max(...shifts.map(Math.abs))).toBeLessThanOrEqual(10);
    expect(s.offset).toBe(0);
  });

  it("re-syncs at once, never animating, when a resize left xterm's position stale", () => {
    const { s, c } = setup();
    s.autoRender = false;              // the notification alone must do it, not a redraw after it
    s.setScrollTop(10 * 20 + 6);
    const seen: number[] = [];
    s.onScroll((t) => seen.push(t));
    s.resizeStale(7);                  // the row moved to 17; the position still says 10.3
    expect(s.top).toBe(17 * 20);
    expect(s.offset).toBe(0);
    c.advance(SETTLE_IDLE_MS + SETTLE_MS + 64);
    expect(s.top).toBe(17 * 20);
    expect(seen.filter((t) => t !== 17 * 20)).toEqual([206]);   // the dimension event, then the re-sync only
  });

  it("a resize stops a glide", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    ctl.hold();
    ctl.release(-2);
    c.advance(48);
    s.resizeStale(3);
    const at = s.top;
    c.advance(1000);
    expect(s.top).toBe(at);
    expect(s.top % 20).toBe(0);
  });

  it("re-syncs on the resize itself, before the Viewport's queued sync can let a step run stale", () => {
    // Second review, M-a: a refit inside an animation frame, after the clock's own, let the next step
    // start from the stale position and drag xterm's row back for a frame.
    const { s, c, ctl } = setup();
    s.setScrollTop(1000);
    ctl.hold();
    ctl.release(-2);
    c.advance(48);
    s.resizeQuiet(8);
    expect(s.top).toBe(s.y * 20);
    const at = s.top;
    c.advance(1000);
    expect(s.top).toBe(at);            // and the glide stopped
  });

  it("a finger's drag stops at the surface's END, which can be above the scrollable's own bottom", () => {
    // An agent's trailing blank lines are not there (trailing-blanks.ts): `maxScrollTop` ends at the content, while
    // xterm.js's scrollable would go on to the real bottom. Dragged past it and put back, every touchmove did that.
    const { s, ctl } = setup();
    s.maxScrollTop = () => 1000;      // the content's end; the scrollable itself clamps at 2000
    s.setScrollTop(990);
    ctl.hold();
    ctl.drag(50);
    expect(s.top).toBe(1000);
    ctl.drag(-30);                    // and back up from it at once
    expect(s.top).toBe(970);
  });

  it("keeps the fraction, and the text under a still finger, when a full scrollback trims a line", () => {
    const { s, ctl } = setup();
    s.setScrollTop(500);
    ctl.hold();
    ctl.drag(7);
    expect(s.top).toBe(507);
    s.trim();                          // xterm keeps the TEXT still: one row up, the fraction kept
    expect(s.top).toBe(487);
    expect(s.offset).toBe(-7);
  });

  it("a trim DURING the settle moves the settle with the text, never a row off", () => {
    // Second review, I-A: the settle wrote its pre-trim positions and the text jumped a row forward.
    const { s, c } = setup();
    s.setScrollTop(25 * 20 + 7);       // row 25, 7 px on
    c.advance(SETTLE_IDLE_MS + 32);    // settling toward row 25
    s.trim();                          // the text of row 25 is row 24 now
    c.advance(SETTLE_MS + 64);
    expect(s.y).toBe(24);
    expect(s.top).toBe(24 * 20);
  });

  it("puts a trim's fraction back only on ITS snap, relative to the row it snaps to", () => {
    // Second review, M-b: the first trim of a parse got no snap (xterm's row met the Viewport's last
    // recorded row), and its restore landed on the NEXT trim's snap a row off.
    const { s, ctl } = setup();
    s.setScrollTop(25 * 20);
    ctl.hold();
    ctl.drag(7);                       // 507: row 25 + 7 px
    s.trimNoSnap();                    // row 24, position left at 507
    s.trim();                          // row 23: the same text, 7 px on
    expect(s.y).toBe(23);
    expect(s.top).toBe(23 * 20 + 7);
  });

  it("a trim whose snap never comes leaves nothing to land on a later scroll", async () => {
    const { s, ctl } = setup();
    s.setScrollTop(25 * 20);
    ctl.hold();
    ctl.drag(7);
    s.trimNoSnap();
    await Promise.resolve();           // the parse is over
    s.setScrollTop(24 * 20);           // somebody scrolls exactly onto the row that snap would have made
    expect(s.top).toBe(24 * 20);
  });

  it("output streaming into a full scrollback does not keep a still view from settling", () => {
    // Second review, M-c: every trim re-armed the 200 ms settle, so the view stayed between rows for as
    // long as output kept coming.
    const { s, c } = setup(true);
    s.setScrollTop(25 * 20 + 7);
    for (let i = 0; i < 8; i++) { c.advance(60); s.trim(); }       // 480 ms of output, a line per 60 ms
    expect(s.offset).toBe(0);
    expect(s.top % 20).toBe(0);
  });

  it("a glide goes on through trimmed lines as far as it would have gone", () => {
    const glide = (trim: boolean) => {
      // Trims move the position toward line 0 as well: room for both, so neither run meets the top.
      const s = new FakeSurface(20, 5000), c = new FakeClock(), ctl = new SmoothScroll(s, c, true);
      s.setScrollTop(4000);
      ctl.hold();
      ctl.release(-1.5);
      let trimmed = 0;
      for (let i = 0; i < 40; i++) { c.advance(48); if (trim) { s.trim(); trimmed++; } }
      c.advance(10_000);
      return 4000 - s.top - trimmed * 20;   // how far the CONTENT moved
    };
    const clean = glide(false), trimmed = glide(true);
    expect(clean).toBeGreaterThan(500);
    expect(Math.abs(trimmed - clean)).toBeLessThanOrEqual(20);   // the settle may pick the other row
  });

  it("ends a glide rather than finishing it in one frame after the page was hidden", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1500);
    ctl.hold();
    ctl.release(-2);
    c.advance(48);
    const before = s.top;
    c.pause(5000);
    c.advance(16 + SETTLE_MS + 32);
    expect(before - s.top).toBeLessThan(20);                    // at most the settle, never ~v·τ
    expect(c.idle).toBe(true);
  });

  it("disposed, ignores everything the touch handler might still send", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1003);
    ctl.dispose();
    ctl.hold();
    ctl.drag(-50);
    ctl.release(-2);
    ctl.stop();
    ctl.setEnabled(true);
    expect(s.top).toBe(1003);
    expect(c.idle).toBe(true);
  });

  it("disposed, stops listening and leaves no timer, frame or offset behind", () => {
    const { s, c, ctl } = setup();
    s.setScrollTop(1003);
    ctl.hold();
    ctl.release(-2);
    ctl.dispose();
    expect(s.listening).toBe(0);
    expect(c.idle).toBe(true);
    expect(s.offset).toBe(0);
  });
});
