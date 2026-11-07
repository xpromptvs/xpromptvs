// @vitest-environment node
import { describe, expect, it } from "vitest";
// @ts-expect-error - node modules not typed in this project
import { readFileSync } from "node:fs";
// @ts-expect-error - node modules not typed in this project
import { fileURLToPath } from "node:url";
// @ts-expect-error - node modules not typed in this project
import { dirname, resolve } from "node:path";
import { FramePacer, WheelResampler, wheelPixels } from "../src/client/wheel-resample";

/// The wheel resampler (wheel-resample.ts): a trackpad's wheel events land 1, 2 or 3 to a frame, and
/// moving the view by whatever landed makes uneven steps however even the gesture was. The view instead
/// follows the stream AVERAGED over a short window, sampled on a steadied frame clock.

/// How uneven a run of per-frame steps is: the mean distance of each step from the average of its two
/// neighbours, over the mean step (the scroll probe's measure: 0 even, ≳ 0.3 visibly uneven).
function unevenness(d: number[]): number {
  let j = 0;
  for (let i = 1; i + 1 < d.length; i++) j += Math.abs(d[i]! - (d[i - 1]! + d[i + 1]!) / 2);
  const mean = d.reduce((a, v) => a + Math.abs(v), 0) / d.length;
  return j / (d.length - 2) / mean;
}
const steps = (xs: number[]) => xs.slice(1).map((x, i) => x - xs[i]!);

describe("WheelResampler", () => {
  it("is 0 before the first event, ramps a lone event in over its window, then holds it", () => {
    const r = new WheelResampler();
    r.add(100, 32);
    expect(r.at(99)).toBe(0);
    const w = r.window();
    expect(r.at(100 + w / 2)).toBeCloseTo(16, 5);
    expect(r.at(100 + w)).toBe(32);
    expect(r.at(500)).toBe(32);
    expect(r.settled(100 + w)).toBe(true);
    expect(r.settled(100 + w / 2)).toBe(false);
  });

  it("sizes its window to two event gaps: ~17 ms for a 120 Hz stream, ~33 for 60 Hz, within 16…34", () => {
    const at120 = new WheelResampler(), at60 = new WheelResampler(), slow = new WheelResampler();
    for (let i = 0; i < 20; i++) { at120.add(i * 8.33, 5); at60.add(i * 16.67, 5); slow.add(i * 50, 5); }
    expect(at120.window()).toBeCloseTo(16.7, 0);
    expect(at60.window()).toBeCloseTo(33.3, 0);
    expect(slow.window()).toBe(34);
  });

  it("turns events that BEAT against the frames into even steps", () => {
    // Pairs of events 4 ms apart every 16.7 ms (Safari at its 60 fps limit), landing around the frame
    // boundary so a frame gets the pair, half of it, or a pair and a half: 1, 2 or 3 events.
    const r = new WheelResampler();
    const events: number[] = [];
    const drift = [0, -3, 2, -1, 3, -2, 1];
    for (let k = 0; k < 40; k++) { const s0 = k * 16.67 + 11.3 + drift[k % drift.length]!; events.push(s0, s0 + 4); }
    const frames = Array.from({ length: 40 }, (_, i) => 30 + i * 16.67);
    const raw: number[] = [], smooth: number[] = [];
    let ei = 0, landed = 0;
    for (const f of frames) {
      while (ei < events.length && events[ei]! <= f) { r.add(events[ei]!, 10); landed += 10; ei++; }
      raw.push(landed);
      smooth.push(r.at(f));
    }
    expect(unevenness(steps(raw).slice(2, 36))).toBeGreaterThan(0.3);
    expect(unevenness(steps(smooth).slice(2, 36))).toBeLessThan(0.15);   // the probe's "even"
  });

  it("loses nothing: once settled it holds exactly the sum of what came", () => {
    const r = new WheelResampler();
    let sum = 0;
    for (let i = 0; i < 50; i++) { const px = 3 + (i % 5); r.add(i * 7.3, px); sum += px; }
    expect(r.at(50 * 7.3 + 40)).toBeCloseTo(sum, 9);
  });

  it("keeps time moving forward: an event stamped before the last counts at the last", () => {
    const r = new WheelResampler();
    r.add(100, 10);
    r.add(90, 10);
    expect(r.at(200)).toBe(20);
  });
});

describe("FramePacer", () => {
  it("puts frames whose timestamps wobble back on the display's steady clock", () => {
    const p = new FramePacer();
    const grid = Array.from({ length: 60 }, (_, i) => 1000 + i * 16.67);
    const wobble = [0, 3, -2, 4, 1, -4, 2, 5, -1, 3];
    const out = grid.map((g, i) => p.tick(g + wobble[i % wobble.length]!));
    const late = out.slice(20).map((t, i) => t - grid[i + 20]!);
    const spread = Math.max(...late) - Math.min(...late);
    expect(spread).toBeLessThan(2.5);   // the input wobbled over 9 ms
    for (let i = 1; i < out.length; i++) expect(out[i]!).toBeGreaterThan(out[i - 1]!);
  });

  it("keeps the grid through a frame that never came", () => {
    const p = new FramePacer();
    for (let i = 0; i < 20; i++) p.tick(i * 16.67);
    expect(p.tick(21 * 16.67)).toBeCloseTo(21 * 16.67, 1);   // frame 20 never came
    expect(p.tick(22 * 16.67)).toBeCloseTo(22 * 16.67, 1);
  });

  it("follows the display when the frames' phase really moves", () => {
    const p = new FramePacer();
    for (let i = 0; i < 20; i++) p.tick(i * 16.67);
    let out = 0;
    for (let i = 20; i < 80; i++) out = p.tick(i * 16.67 + 6);   // 6 ms later from here on
    expect(out).toBeCloseTo(79 * 16.67 + 6, 0);
  });

  it("learns the period: 120 Hz frames stay 8.3 ms apart", () => {
    const p = new FramePacer();
    const out = Array.from({ length: 40 }, (_, i) => p.tick(i * 8.33 + (i % 3)));
    const d = steps(out).slice(20);
    for (const x of d) expect(x).toBeGreaterThan(7.5), expect(x).toBeLessThan(9.2);
  });
});

describe("wheelPixels — the distance xterm.js's own scrollable moves for a wheel", () => {
  const ev = (o: Partial<WheelEvent> & { wheelDeltaY?: number; wheelDeltaX?: number }) =>
    ({ deltaX: 0, deltaY: 0, deltaMode: 0, altKey: false, ...o }) as WheelEvent;

  it("reads the legacy wheelDeltaY (÷120 × 50, rounded away from zero), as VS Code's StandardWheelEvent does", () => {
    // WebKit and Chrome report wheelDeltaY = −3 × deltaY for a trackpad's pixel deltas.
    expect(wheelPixels(ev({ deltaY: 7, wheelDeltaY: -21 }), 1, 5)).toBe(9);     // 8.75 → 9
    expect(wheelPixels(ev({ deltaY: -7, wheelDeltaY: 21 }), 1, 5)).toBe(-9);
    expect(wheelPixels(ev({ deltaY: 1, wheelDeltaY: -3 }), 1, 5)).toBe(2);      // 1.25 → 2
  });

  it("without the legacy field: pixels ÷40, lines as lines", () => {
    expect(wheelPixels(ev({ deltaY: 40 }), 1, 5)).toBe(50);
    expect(wheelPixels(ev({ deltaY: 3, deltaMode: 1 }), 1, 5)).toBe(150);
  });

  it("applies the sensitivity, ⌥'s fast sensitivity, and ignores a mostly sideways wheel", () => {
    expect(wheelPixels(ev({ deltaY: 40 }), 2, 5)).toBe(100);
    expect(wheelPixels(ev({ deltaY: 40, altKey: true }), 1, 5)).toBe(250);
    expect(wheelPixels(ev({ deltaY: 4, deltaX: 30 }), 1, 5)).toBe(0);
  });
});

describe("the recorded Safari flick (test/fixtures/safari-wheel-flick.json)", () => {
  const cap = JSON.parse(readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), "fixtures/safari-wheel-flick.json"), "utf8")) as
    { frames: number[]; moved: number[]; events: [number, number, number, number][] };
  const first = cap.frames.findIndex((_, i) => cap.moved[i] !== 0);

  it("was UNEVEN as the terminal moved it, and replaying the events as they landed reproduces that", () => {
    const measured = cap.moved.slice(first, 80).map((m) => -m);
    expect(unevenness(measured)).toBeGreaterThan(0.4);
    let ei = 0, landed = 0;
    const replay: number[] = [];
    for (const f of cap.frames) {
      while (ei < cap.events.length && cap.events[ei]![0] <= f) landed += -cap.events[ei++]![1] * 1.25;
      replay.push(landed);
    }
    expect(unevenness(steps(replay).slice(first, 79))).toBeGreaterThan(0.4);
  });

  it("resampled on the steadied clock, the same events move the view in EVEN steps", () => {
    const r = new WheelResampler(), p = new FramePacer();
    let ei = 0;
    const pos: number[] = [];
    for (const f of cap.frames) {
      while (ei < cap.events.length && cap.events[ei]![0] <= f) { const e = cap.events[ei++]!; r.add(e[0], -e[1] * 1.25); }
      pos.push(r.at(p.tick(f)));
    }
    expect(unevenness(steps(pos).slice(first, 79))).toBeLessThan(0.15);
  });
});
