import { describe, expect, it } from "vitest";
import { summarizeGesture, type ProbeEvent, type ProbeFrame, type ProbeUpdate } from "../src/client/scroll-probe";

/// The scroll probe's summary (scroll-probe.ts) — the numbers a person reads off the overlay to tell a
/// JUDDERING wheel stream (frames that get two events, then none) from an even one.

/// `n` frames `dt` apart; frame i gets `events(i)` wheel events of `eventPx` each and moves `move(i)` px.
function stream(n: number, events: (i: number) => number, move: (i: number) => number, eventPx = 4, dt = 1000 / 120) {
  const frames: ProbeFrame[] = [], evs: ProbeEvent[] = [];
  let t = 0;
  for (let i = 0; i < n; i++) {
    t += dt;
    for (let k = 0; k < events(i); k++) evs.push({ t: t - dt / 2 + k, deltaY: eventPx, deltaMode: 0, wheelDeltaY: -3 * eventPx });
    frames.push({ t, dt, events: events(i), moved: move(i), sinceWheelMs: 0 });
  }
  return { frames, evs };
}

describe("summarizeGesture", () => {
  it("reads a steady stream as even: one event per frame, no empty frame, unevenness 0", () => {
    const { frames, evs } = stream(60, () => 1, () => 5);
    const s = summarizeGesture(frames, evs);
    expect(s.activeFrames).toBe(60);
    expect(s.perFrame).toEqual({ 0: 0, 1: 60, 2: 0, "3+": 0 });
    expect(s.emptyFrames).toBe(0);
    expect(s.unevenness).toBe(0);
    expect(s.hz).toBeCloseTo(120, 0);
    expect(s.longFrames).toBe(0);
    expect(s.movedPx).toBe(300);
    expect(s.gain).toBeCloseTo(1.25, 5);          // 5 px moved per 4 px of wheel
    expect(s.eventPxMean).toBe(4);
    expect(s.eventPxCv).toBe(0);
    expect(s.wheelRatio).toBe(-3);
  });

  it("reads events BEATING against frames — two, then none — as uneven, with half the frames empty", () => {
    const { frames, evs } = stream(60, (i) => (i % 2 === 0 ? 2 : 0), (i) => (i % 2 === 0 ? 10 : 0));
    const s = summarizeGesture(frames, evs);
    expect(s.perFrame[2]).toBe(30);
    expect(s.perFrame[0]).toBe(29);              // the active window ends on the last frame WITH an event
    expect(s.emptyFrames).toBe(29);
    expect(s.unevenness).toBeGreaterThan(1.5);
  });

  it("does not count a steady ACCELERATION as unevenness", () => {
    const { frames, evs } = stream(60, () => 1, (i) => 2 + i * 0.5);
    expect(summarizeGesture(frames, evs).unevenness).toBeLessThan(0.001);
  });

  it("counts a frame over one and a half times the usual interval as long", () => {
    const { frames, evs } = stream(40, () => 1, () => 5);
    frames[10]!.dt = 25; frames[20]!.dt = 30;
    expect(summarizeGesture(frames, evs).longFrames).toBe(2);
  });

  it("separates movement after the wheel stopped — the settle onto a row — from the wheel's own", () => {
    const { frames, evs } = stream(30, (i) => (i < 20 ? 1 : 0), (i) => (i < 20 ? 5 : 0));
    frames[26]!.sinceWheelMs = 210; frames[26]!.moved = 3;
    frames[27]!.sinceWheelMs = 220; frames[27]!.moved = 2;
    const s = summarizeGesture(frames, evs);
    expect(s.settleFrames).toBe(2);
    expect(s.settlePx).toBe(5);
    expect(s.movedPx).toBe(100);                  // the wheel's alone
  });

  it("is all zeros for no frames at all", () => {
    const s = summarizeGesture([], []);
    expect(s.activeFrames).toBe(0);
    expect(s.unevenness).toBe(0);
    expect(s.wheelRatio).toBeNull();
    expect(s.rows).toBeNull();
  });

  it("summarizes the rows' redraw over the frames that redrew: time per frame, rows built and reused", () => {
    const { frames, evs } = stream(10, () => 1, () => 5);
    // [ms, built, reused] of the redraw passes between each frame and the one before (row-cache.ts's counters).
    const passes = [[0.5, 1, 49], [0, 0, 0], [1.5, 2, 48], [0.4, 1, 49], [3, 50, 0], [0, 0, 0], [0.6, 1, 49], [0.5, 1, 49], [0.7, 1, 49], [0.5, 1, 49]];
    frames.forEach((f, i) => {
      const [ms, built, reused] = passes[i]!;
      f.rows = { passes: built! + reused! > 0 ? 1 : 0, ms: ms!, built: built!, reused: reused! };
    });
    // Eight frames redrew; sorted 0.4 0.5 0.5 0.5 0.6 0.7 1.5 3.
    expect(summarizeGesture(frames, evs).rows).toEqual({ frames: 8, msP50: 0.55, msP95: 1.5, msMax: 3, built: 58, reused: 342 });
  });

  it("summarizes what was PAINTED: every rendering update, those without an animation frame, and rows shown off", () => {
    const { frames, evs } = stream(10, () => 1, () => 5);
    // 120 Hz updates for 100 ms, an animation frame at every other one; two painted a row off (the rows
    // xterm.js had not redrawn yet, shifted for the new one), one of them two rows.
    const updates: ProbeUpdate[] = Array.from({ length: 13 }, (_, i) => ({ t: i * 8.33, frame: i % 2 === 0, errRows: 0.02 }));
    updates[3]!.errRows = 1; updates[7]!.errRows = -2;
    updates[5]!.errRows = 0.5;   // rounding (smooth scrolling off) is never counted as a row off
    const p = summarizeGesture(frames, evs, updates).painted!;
    expect(p.updates).toBe(13);
    expect(p.perSecond).toBeCloseTo(120, 0);
    expect(p.withoutFrame).toBe(6);
    expect(p.rowOff).toBe(2);
    expect(p.maxRowsOff).toBe(2);
  });

  it("has no painted summary without updates", () => {
    const { frames, evs } = stream(10, () => 1, () => 5);
    expect(summarizeGesture(frames, evs).painted).toBeNull();
    expect(summarizeGesture(frames, evs, []).painted).toBeNull();
  });

  it("has no row summary when the frames carry no counters (a terminal without the row cache)", () => {
    const { frames, evs } = stream(10, () => 1, () => 5);
    expect(summarizeGesture(frames, evs).rows).toBeNull();
  });
});
