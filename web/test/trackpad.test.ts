import { describe, it, expect } from "vitest";
import {
  Trackpad, accelGain, MIN_GAIN, MAX_GAIN, ACCEL_REF, TAP_SLOP_PX, TAP_MAX_MS, DOUBLE_TAP_MS,
  FLING_MIN_SPEED, FLING_IDLE_MS,
  type TrackpadOutput, type TrackpadEvent,
} from "../src/client/trackpad";

const BOX = { w: 400, h: 225 };
const run = (pad: Trackpad, evs: Array<[TrackpadEvent["kind"], number, number, number, number?]>) => {
  const out: TrackpadOutput[] = [];
  for (const [kind, x, y, t, id] of evs) out.push(...pad.handle({ kind, x, y, t, id: id ?? 1 }, BOX));
  return out;
};

describe("accelGain", () => {
  it("is bounded and monotonic in speed", () => {
    expect(accelGain(0)).toBeCloseTo(MIN_GAIN);
    expect(accelGain(ACCEL_REF)).toBeCloseTo(MAX_GAIN);
    expect(accelGain(ACCEL_REF * 100)).toBeCloseTo(MAX_GAIN);   // saturates, never runs away
    expect(accelGain(-5)).toBeCloseTo(MIN_GAIN);                // a negative speed is not a thing
    // THE SHAPE IS THE CONTRACT, not the constants — those are untuned starting points.
    const samples = [0, 0.5, 1, 1.5, 2, 4].map(accelGain);
    for (let i = 1; i < samples.length; i++) expect(samples[i]).toBeGreaterThanOrEqual(samples[i - 1]!);
  });
});

describe("trackpad gestures", () => {
  it("starts centred", () => {
    expect(new Trackpad().cursor).toEqual({ x: 0.5, y: 0.5 });
  });

  it("a tap clicks at the cursor without moving it", () => {
    const pad = new Trackpad();
    const out = run(pad, [["down", 10, 10, 0], ["up", 10, 10, 50]]);
    expect(out).toEqual([
      { t: "touch", phase: "down", button: "left", x: 0.5, y: 0.5 },
      { t: "touch", phase: "up", button: "left", x: 0.5, y: 0.5 },
    ]);
    expect(pad.cursor).toEqual({ x: 0.5, y: 0.5 });
  });

  it("a drag past the slop moves the cursor and clicks nothing", () => {
    const pad = new Trackpad();
    const out = run(pad, [["down", 10, 10, 0], ["move", 90, 10, 100], ["up", 90, 10, 120]]);
    expect(out.every((o) => o.t === "hover")).toBe(true);
    expect(pad.cursor.x).toBeGreaterThan(0.5);
    expect(pad.cursor.y).toBeCloseTo(0.5);
  });

  it("a press held past TAP_MAX_MS is not a tap", () => {
    const pad = new Trackpad();
    const out = run(pad, [["down", 10, 10, 0], ["up", 10, 10, TAP_MAX_MS + 1]]);
    expect(out).toEqual([]);
  });

  it("a press that moves past the slop is not a tap", () => {
    const pad = new Trackpad();
    const out = run(pad, [["down", 10, 10, 0], ["move", 10 + TAP_SLOP_PX + 1, 10, 20], ["up", 40, 10, 40]]);
    expect(out.some((o) => o.t === "touch")).toBe(false);
  });

  it("double-tap-and-hold drags: down, moves, up", () => {
    const pad = new Trackpad();
    run(pad, [["down", 10, 10, 0], ["up", 10, 10, 40]]);            // the first tap
    const out = run(pad, [
      ["down", 10, 10, 40 + DOUBLE_TAP_MS - 10],
      ["move", 60, 10, 40 + DOUBLE_TAP_MS + 20],
      ["up", 60, 10, 40 + DOUBLE_TAP_MS + 60],
    ]);
    expect(out[0]).toMatchObject({ t: "touch", phase: "down", button: "left" });
    expect(out[1]).toMatchObject({ t: "touch", phase: "move", button: "left" });
    expect(out[out.length - 1]).toMatchObject({ t: "touch", phase: "up", button: "left" });
    expect(out.some((o) => o.t === "hover")).toBe(false);
  });

  it("a tap too late to double-tap is just another tap", () => {
    const pad = new Trackpad();
    run(pad, [["down", 10, 10, 0], ["up", 10, 10, 40]]);
    const out = run(pad, [["down", 10, 10, 40 + DOUBLE_TAP_MS + 50], ["move", 60, 10, 40 + DOUBLE_TAP_MS + 80]]);
    expect(out.every((o) => o.t === "hover")).toBe(true);
  });

  it("a cancel mid-drag releases the button", () => {
    // WITHOUT THIS the host is left holding a stuck press — the same reason `endTouch` releases
    // without consulting its active gate.
    const pad = new Trackpad();
    run(pad, [["down", 10, 10, 0], ["up", 10, 10, 40]]);
    const out = run(pad, [["down", 10, 10, 60], ["move", 60, 10, 80], ["cancel", 60, 10, 90]]);
    expect(out[out.length - 1]).toMatchObject({ t: "touch", phase: "up", button: "left" });
  });

  it("two fingers dragging scroll, and scroll nothing before the slop", () => {
    const pad = new Trackpad();
    const before = run(pad, [["down", 10, 10, 0, 1], ["down", 30, 10, 5, 2], ["move", 32, 10, 10, 2]]);
    expect(before).toEqual([]);   // centroid moved 1px: still a tap candidate
    const out = run(pad, [["move", 30, 90, 30, 2], ["move", 30, 130, 50, 2]]);
    expect(out.every((o) => o.t === "scroll")).toBe(true);
    // NATURAL: fingers moving DOWN scroll the content DOWN, which is a NEGATIVE wheel deltaY.
    expect((out[0] as { dy: number }).dy).toBeLessThan(0);
  });

  it("two fingers tapped are a right click", () => {
    const pad = new Trackpad();
    const out = run(pad, [
      ["down", 10, 10, 0, 1], ["down", 30, 10, 5, 2],
      ["up", 30, 10, 40, 2], ["up", 10, 10, 45, 1],
    ]);
    expect(out).toEqual([
      { t: "touch", phase: "down", button: "right", x: 0.5, y: 0.5 },
      { t: "touch", phase: "up", button: "right", x: 0.5, y: 0.5 },
    ]);
  });

  it("two fingers that scrolled do not also right-click on release", () => {
    const pad = new Trackpad();
    run(pad, [["down", 10, 10, 0, 1], ["down", 30, 10, 5, 2], ["move", 30, 120, 30, 2]]);
    const out = run(pad, [["up", 30, 120, 40, 2], ["up", 10, 10, 45, 1]]);
    expect(out.some((o) => o.t === "touch")).toBe(false);
  });

  it("the cursor clamps to the picture, in both directions", () => {
    // One long press whose finger keeps travelling, so the clock stays monotonic and no release can
    // register a tap. Each move is far enough past the slop to count immediately.
    const pad = new Trackpad();
    let t = 0;
    run(pad, [["down", 0, 0, t]]);
    for (let i = 1; i <= 40; i++) run(pad, [["move", i * 50, i * 50, (t += 200)]]);
    expect(pad.cursor).toEqual({ x: 1, y: 1 });
    run(pad, [["up", 2000, 2000, (t += 200)]]);

    run(pad, [["down", 0, 0, (t += 5000)]]);   // well past DOUBLE_TAP_MS: a fresh press, not a drag
    for (let i = 1; i <= 40; i++) run(pad, [["move", -i * 50, -i * 50, (t += 200)]]);
    expect(pad.cursor).toEqual({ x: 0, y: 0 });
  });
});

// THE FLICK. What leaves here is a VELOCITY, once, and the host runs the glide from it — see
// `ScrollMomentum` for why the curve is not streamed a frame at a time. These tests own the decision
// of WHAT COUNTS AS A FLICK; the curve it produces is asserted in RdevCore.
describe("trackpad flick", () => {
  /// Two fingers down, then `steps` moves of the second finger 16ms apart, each carrying the
  /// centroid by `perStep` px. Returns the pad, the finger's position and the last move's time.
  const flick = (perStep: number, steps = 4) => {
    const pad = new Trackpad();
    run(pad, [["down", 10, 200, 0, 1], ["down", 30, 200, 5, 2]]);
    let t = 20;
    let y = 200;
    for (let i = 0; i < steps; i++) {
      y -= perStep * 2;   // only one of two fingers moves, so the centroid carries half
      run(pad, [["move", 30, y, t, 2]]);
      t += 16;
    }
    return { pad, y, t: t - 16 };
  };

  it("a flick reports a velocity in px per second, in the scroll sign convention", () => {
    const { pad, y, t } = flick(20);
    const out = run(pad, [["up", 30, y, t + 8, 2]]);
    const fling = out.find((o) => o.t === "fling");
    expect(fling).toBeDefined();
    // Fingers moving UP carry the content up, which is a POSITIVE scroll delta here — the same sign
    // the `scroll` messages of the same gesture carried.
    expect((fling as { vy: number }).vy).toBeCloseTo(1250, -2);
    expect((fling as { vx: number }).vx).toBe(0);
  });

  it("a slow release is not a flick", () => {
    const pad = new Trackpad();
    run(pad, [["down", 10, 200, 0, 1], ["down", 30, 200, 5, 2]]);
    run(pad, [["move", 30, 160, 20, 2]]);            // past the slop, into twoScroll
    let t = 36;
    let y = 160;
    for (let i = 0; i < 5; i++) { y -= 4; run(pad, [["move", 30, y, t, 2]]); t += 16; }
    const speed = (2 / 16) * 1000;                   // centroid px per second
    expect(speed).toBeLessThan(FLING_MIN_SPEED);     // the premise of this test, stated
    expect(run(pad, [["up", 30, y, t, 2]]).some((o) => o.t === "fling")).toBe(false);
  });

  /// A FINGER THAT STOPPED AND THEN LET GO MEANS "LEAVE IT HERE". Without this the view is thrown
  /// every time someone scrolls to a spot and lifts, which is the more common gesture of the two.
  it("a flick that comes to rest before the lift throws nothing", () => {
    const { pad, y, t } = flick(20);
    expect(run(pad, [["up", 30, y, t + FLING_IDLE_MS + 1, 2]]).some((o) => o.t === "fling")).toBe(false);
  });

  /// A cancelled gesture is not a flick: the browser took the gesture away (a system edge swipe, a
  /// call arriving), and throwing the view on the way out is the one thing nobody asked for.
  it("a cancelled gesture throws nothing", () => {
    const { pad, y, t } = flick(20);
    expect(run(pad, [["cancel", 30, y, t + 8, 2]]).some((o) => o.t === "fling")).toBe(false);
  });

  /// ONE FLICK PER GESTURE. Both fingers lift, a few ms apart, and the second lift must not throw
  /// the view a second time — it would double the glide for a single flick of the hand.
  it("only the first finger to lift throws", () => {
    const { pad, y, t } = flick(20);
    expect(run(pad, [["up", 30, y, t + 8, 2]]).filter((o) => o.t === "fling")).toHaveLength(1);
    expect(run(pad, [["up", 10, 200, t + 16, 1]]).some((o) => o.t === "fling")).toBe(false);
  });

  /// A PRESS STOPS THE GLIDE, and it must be sent from the press itself: in this mode a press emits
  /// NOTHING until it becomes a tap or a move, so without it the host coasts on under a finger that
  /// is already on the glass.
  it("the next press sends a stop, exactly once", () => {
    const { pad, y, t } = flick(20);
    run(pad, [["up", 30, y, t + 8, 2]]);
    run(pad, [["up", 10, 200, t + 16, 1]]);
    const stopped = run(pad, [["down", 10, 200, t + 400, 1]]);
    expect(stopped).toContainEqual({ t: "fling", vx: 0, vy: 0, x: 0.5, y: 0.5 });
    run(pad, [["up", 10, 200, t + 430, 1]]);
    expect(run(pad, [["down", 10, 200, t + 900, 1]]).some((o) => o.t === "fling")).toBe(false);
  });

  it("a press with no glide behind it sends nothing", () => {
    const pad = new Trackpad();
    expect(run(pad, [["down", 10, 200, 0, 1]])).toEqual([]);
  });
});
