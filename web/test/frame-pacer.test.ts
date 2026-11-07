import { expect, test } from "vitest";
import { FramePacer, MAX_QUEUE } from "../src/lib/frame-pacer";

const closed: string[] = [];
const pacer = (marginMs: number | "auto" = 0) => {
  closed.length = 0;
  return new FramePacer<string>((f) => closed.push(f), { marginMs });
};

test("picks the NEWEST frame whose target has come, releasing what it skipped", () => {
  const p = pacer(0);
  p.push({ frame: "a", mediaMs: 0, arrivalMs: 0 });
  p.push({ frame: "b", mediaMs: 16, arrivalMs: 16 });
  p.push({ frame: "c", mediaMs: 32, arrivalMs: 32 });
  expect(p.pick(32, null)?.frame).toBe("c");
  expect(closed).toEqual(["a", "b"]);
});

test("returns null when nothing is due — the canvas keeps its bitmap, so a repeat costs no draw", () => {
  const p = pacer(0);
  p.push({ frame: "a", mediaMs: 100, arrivalMs: 100 });
  expect(p.pick(100, null)?.frame).toBe("a");
  expect(p.pick(108, null)).toBeNull();
});

test("never presents out of media order", () => {
  const p = pacer(0);
  p.push({ frame: "b", mediaMs: 16, arrivalMs: 16 });
  p.push({ frame: "a", mediaMs: 0, arrivalMs: 17 });
  expect(p.pick(20, null)?.frame).toBe("b");
  p.push({ frame: "c", mediaMs: 32, arrivalMs: 33 });
  expect(p.pick(40, null)?.frame).toBe("c");
  expect(closed).toContain("a");
});

test("the margin delays presentation by exactly that much", () => {
  const p = pacer(16);
  p.push({ frame: "a", mediaMs: 0, arrivalMs: 0 });
  expect(p.pick(0, null)).toBeNull();
  expect(p.pick(16, null)?.frame).toBe("a");
});

test("offset tracks the MINIMUM arrival delay, so one late frame does not shift the schedule", () => {
  const p = pacer(0);
  p.push({ frame: "a", mediaMs: 0, arrivalMs: 5 });
  p.pick(5, null);
  p.push({ frame: "b", mediaMs: 16, arrivalMs: 100 });
  p.push({ frame: "c", mediaMs: 32, arrivalMs: 37 });
  expect(p.stats().offsetMs).toBeCloseTo(5, 0);
});

test("offset is recomputed from the window, NEVER accumulated from its own last value", () => {
  // The FEC bitrate ratchet and the summed-RTP-delta bug are both this shape: feed the output back
  // into the input and every individual step looks correct while the value walks away.
  const p = pacer(0);
  for (let i = 0; i < 300; i++) {
    p.push({ frame: `f${i}`, mediaMs: i * 16, arrivalMs: i * 16 + 5 });
    p.pick(i * 16 + 5, null);
  }
  expect(p.stats().offsetMs).toBeCloseTo(5, 0);
});

test("a queue past MAX_QUEUE releases the OLDEST and counts it", () => {
  const p = pacer(1e6);                       // margin so nothing is ever due
  for (let i = 0; i < MAX_QUEUE + 3; i++) p.push({ frame: `f${i}`, mediaMs: i * 16, arrivalMs: i * 16 });
  expect(p.stats().dropped).toBe(3);
  expect(closed).toEqual(["f0", "f1", "f2"]);
});

test("reset releases everything queued — a hidden tab must not pin frames", () => {
  const p = pacer(1e6);
  p.push({ frame: "a", mediaMs: 0, arrivalMs: 0 });
  p.push({ frame: "b", mediaMs: 16, arrivalMs: 16 });
  p.reset();
  expect(closed).toEqual(["a", "b"]);
  expect(p.pick(1e9, null)).toBeNull();
});

test("a starve is counted once the source's cadence is known", () => {
  // The gap must exceed 1.5 source periods — past that it is closer to two periods than to one, so a
  // slot's worth of time really did pass empty. Inside one period the source has merely jittered,
  // which is what a content-driven window does constantly.
  const p = steadySource(1000 / 60, 1000 / 120, 40);
  const before = p.stats().starve;
  let now = 40 * (1000 / 60);
  for (let i = 0; i < 8; i++) { p.pick(now, 1000 / 120); now += 1000 / 120; }
  expect(p.stats().starve).toBeGreaterThan(before);
});

test("NOTHING is counted as a starve before the cadence is known", () => {
  // Counting against a 60fps guess is what produced a burst at every session start: a slow source
  // scored starves purely from the fallback, before anything about it had been measured. `empty`
  // still records that there was nothing to show — that classification needs no cadence.
  const p = pacer(0);
  p.push({ frame: "a", mediaMs: 0, arrivalMs: 0 });
  p.pick(0, null);
  p.pick(17, null); p.pick(34, null); p.pick(100, null);
  expect(p.stats().starve).toBe(0);
  expect(p.stats().empty).toBeGreaterThan(0);
});

test("stats survive a reset of the counters without disturbing the schedule", () => {
  const p = pacer(0);
  p.push({ frame: "a", mediaMs: 0, arrivalMs: 0 });
  p.pick(0, null);
  expect(p.stats().presented).toBe(1);
  p.resetStats();
  expect(p.stats().presented).toBe(0);
  p.push({ frame: "b", mediaMs: 16, arrivalMs: 16 });
  expect(p.pick(16, null)?.frame).toBe("b");        // lastMedia preserved: "b" is still newer than "a"
});

// ---- adaptive margin ----------------------------------------------------------------------------

/// Feed `n` frames whose arrival jitter is drawn from `jitterMs`, at a steady 60fps media clock, and
/// return the pacer afterwards. Deterministic: the jitter pattern is a fixed cycle, not random, so a
/// failure is reproducible.
function soak(p: FramePacer<string>, n: number, jitterMs: readonly number[], startMs = 0): void {
  for (let i = 0; i < n; i++) {
    const media = startMs + i * (1000 / 60);
    const arrival = media + 50 + jitterMs[i % jitterMs.length]!;   // 50ms of constant path delay
    p.push({ frame: `f${i}`, mediaMs: media, arrivalMs: arrival });
    p.pick(arrival, null);
  }
}

test("Auto converges to the jitter actually present, not to zero", () => {
  // `auto` used to map to a margin of 0, which meant the pacer held nothing and degenerated into
  // "show whatever is newest" — the unpaced behaviour it exists to replace. On a link whose jitter
  // exceeds the margin that is exactly what happens, which is why a fixed 16ms looked perfect on
  // loopback (~8ms of jitter) and did not help on a real link.
  const p = new FramePacer<string>(() => {}, { marginMs: "auto" });
  soak(p, 2000, [0, 4, 8, 12, 16, 20, 24, 20, 16, 12, 8, 4]);   // ~24ms peak-to-peak
  const m = p.marginMs();
  expect(m).toBeGreaterThan(15);
  expect(m).toBeLessThan(30);
});

// THE COMPLEMENT OF A PERCENTILE IS LATE BY CONSTRUCTION. p98 over the window leaves about one frame
// a second arriving after the margin, which is visible as micro-judder on a stream that has otherwise
// settled — reported from a relayed session sitting at a stable 70ms. Headroom covers that without
// reaching for a more extreme percentile, where a single unlucky arrival would set the next four
// seconds of latency.
test("holds slightly more than the measured spread, to cover the percentile's own tail", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: "auto" });
  // A flat distribution 0..24ms: p98 of it is ~24, so a margin sized exactly to the spread leaves the
  // top of the distribution late.
  soak(p, 3000, [0, 4, 8, 12, 16, 20, 24, 20, 16, 12, 8, 4]);
  const spreadP98 = 24;
  expect(p.marginMs()).toBeGreaterThan(spreadP98 * 1.05);
  // ...and the slack stays SLACK. A margin that drifted far past the spread would be buying latency
  // for a tail that is not there.
  expect(p.marginMs()).toBeLessThan(spreadP98 * 1.35);
});

// PROPORTIONAL, so it costs nothing where there is nothing to absorb. Latency is the product's whole
// promise, and a fixed addition would be charged to the paths that least need it.
test("headroom adds nothing measurable on a clean path", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: "auto" });
  soak(p, 2000, [0, 0.1, 0, 0.2]);
  expect(p.marginMs()).toBeLessThan(14);
});

test("a near-jitter-free stream converges to the FLOOR, not to zero", () => {
  // Zero hold is not a target even on a perfect link: a frame that arrives one microsecond late has
  // nowhere to go. The floor is the smallest hold worth having.
  //
  // The floor is 10ms, not 4. Frames present on VSYNC, so a frame that misses its refresh waits a
  // whole refresh period rather than slipping by the amount it was late — a 4ms hold turns a 5ms
  // hiccup into a 16.7ms one. Observed directly over loopback, where the margin sits on the floor by
  // definition and the picture was still not smooth at 4.
  const p = new FramePacer<string>(() => {}, { marginMs: "auto" });
  soak(p, 2000, [0, 0.1, 0, 0.2]);
  expect(p.marginMs()).toBeGreaterThanOrEqual(10);
  expect(p.marginMs()).toBeLessThan(14);
});

// THE FLOOR IS A FLOOR, NOT A TARGET. A link whose real spread exceeds it must still be measured and
// covered — raising the floor must not flatten the adaptation it sits under, which is the way this
// change could go wrong and be invisible on a clean link.
test("a jittery link still adapts above the raised floor", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: "auto" });
  soak(p, 8000, [0, 30, 8, 45, 15]);
  expect(p.marginMs()).toBeGreaterThan(14);
});

test("the margin never exceeds the clamp, however bad the link", () => {
  // The clamp is 500ms: past that a link is not interactive by any definition, and the answer is a
  // different path rather than more patience. It is a BOUND, not a target — a clean link converges
  // to the 10ms floor regardless, which is what makes a high ceiling free.
  const p = new FramePacer<string>(() => {}, { marginMs: "auto" });
  soak(p, 20000, [0, 400, 800, 1200, 1600]);
  expect(p.marginMs()).toBeLessThanOrEqual(500);
});

// A LINK THAT STALLS RATHER THAN DROPS needs a hold the old 120ms ceiling could not give it.
// Measured over a VPN-over-TCP relay: 250-350ms of silence and then everything at once, with more
// frames arriving after being given up on than were ever lost.
test("holds long enough for a path that goes quiet for a third of a second", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: "auto" });
  soak(p, 20000, [0, 0, 0, 0, 300]);   // mostly prompt, with a periodic 300ms stall
  expect(p.marginMs()).toBeGreaterThan(200);
});

test("THE MARGIN IS SLEW-LIMITED — an adaptive control that steps is a hitch generator", () => {
  // The whole point of holding frames is an even schedule. A margin that jumps moves every future
  // frame's target at once, which is precisely the hitch this is meant to remove.
  const p = new FramePacer<string>(() => {}, { marginMs: "auto" });
  soak(p, 600, [0, 1]);                        // settle on a quiet link
  const before = p.marginMs();
  soak(p, 60, [0, 100], 600 * (1000 / 60));    // one second of sudden 100ms jitter
  const after = p.marginMs();
  expect(after - before).toBeLessThanOrEqual(2.5);   // ~2ms/s, plus a tolerance for the frame grid
});

test("an explicit margin is NOT adaptive — the fixed modes stay available for A/B", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: 16 });
  soak(p, 2000, [0, 40, 80]);
  expect(p.marginMs()).toBe(16);
});

test("setMargin switches between fixed and adaptive at runtime", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: 16 });
  expect(p.marginMs()).toBe(16);
  p.setMargin("auto");
  soak(p, 2000, [0, 4, 8, 12]);
  expect(p.marginMs()).not.toBe(16);
  p.setMargin(33);
  expect(p.marginMs()).toBe(33);
});

// ---- cadence lock -------------------------------------------------------------------------------

const REFRESH = 1000 / 120;      // a 120Hz display
const SRC = 1000 / 60;           // a 60fps source -> exactly 2 refreshes per frame

/// Run a simulated vsync grid and report how many refreshes each PRESENTED frame occupied.
/// `arrivalJitter(i)` perturbs when frame i reaches the pacer, which is what makes an unlocked pacer
/// flip a frame between two vsyncs.
function runGrid(
  p: FramePacer<string>,
  vsyncs: number,
  arrivalJitter: (i: number) => number = () => 0,
): number[] {
  const dwell: number[] = [];
  let lastPresentAt: number | null = null;
  let pushed = 0;
  for (let k = 0; k < vsyncs; k++) {
    const now = k * REFRESH;
    // Feed every source frame whose arrival time has come.
    while (pushed * SRC + 50 + arrivalJitter(pushed) <= now) {
      p.push({ frame: `f${pushed}`, mediaMs: pushed * SRC, arrivalMs: pushed * SRC + 50 + arrivalJitter(pushed) });
      pushed++;
    }
    const got = p.pick(now, REFRESH);
    if (got) {
      if (lastPresentAt !== null) dwell.push(Math.round((now - lastPresentAt) / REFRESH));
      lastPresentAt = now;
    }
  }
  return dwell;
}

const share = (d: number[], n: number) => d.filter((x) => x === n).length / d.length;

/// WHAT THIS SIMULATION CANNOT DO, stated so nobody reads more into these tests than they support.
///
/// Two attempts to reproduce the ~6.7% of wrong-length frames measured on a real stream both failed:
///   - ±1.5ms of arrival jitter: the UNLOCKED pacer scored a perfect 100%, because in simulation the
///     media clock is exact and every target lands at the same phase against the vsync grid.
///   - ±5ms (straddling a half-refresh): the LOCKED pacer scored 0%, because locking does not create
///     frames — if one is not there at its slot the lock starves.
///
/// So the mechanism behind the real 6.7% is NOT yet demonstrated, and these tests assert only what
/// the lock provably does: lock on a stable cadence, hold it, refuse to lock on an irregular source,
/// and let go when it starves. Whether that is the fix for the observed roughness is an open
/// question, to be settled by classifying real wrong-dwell frames — not by tuning this simulation
/// until it agrees.

test("a locked pacer presents on the cadence when frames are available at their slot", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: 4 });
  const d = runGrid(p, 1200, () => 0);
  expect(share(d, 2)).toBeGreaterThan(0.97);
});

test("it does not lock until the cadence has been stable", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: 2 });
  runGrid(p, 20, () => 0);
  expect(p.cadence()).toBeNull();
  runGrid(p, 200, () => 0);
  expect(p.cadence()).toBe(2);
});

test("IT NEVER LOCKS ON AN IRREGULAR SOURCE — locking to a cadence that does not exist would invent motion", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: 2 });
  // A source whose frames arrive at wildly varying media intervals: a content-driven window.
  let media = 0, pushed = 0;
  for (let k = 0; k < 1200; k++) {
    const now = k * REFRESH;
    if (k % 3 === 0) { media += SRC * (1 + (pushed % 4)); p.push({ frame: `f${pushed++}`, mediaMs: media, arrivalMs: now }); }
    p.pick(now, REFRESH);
  }
  expect(p.cadence()).toBeNull();
});

test("a locked pacer unlocks when it starves — the source rate changed under it", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: 2 });
  runGrid(p, 400, () => 0);
  expect(p.cadence()).toBe(2);
  // Frames stop arriving; the cadence it locked to no longer exists.
  for (let k = 400; k < 700; k++) p.pick(k * REFRESH, REFRESH);
  expect(p.cadence()).toBeNull();
});

test("a locked pacer still presents every source frame — locking must not drop or repeat", () => {
  const p = new FramePacer<string>(() => {}, { marginMs: 2 });
  const d = runGrid(p, 1200, () => 0);
  // 1200 vsyncs at 120Hz is 10s; a 60fps source is ~600 frames, each occupying 2 refreshes.
  expect(d.length).toBeGreaterThan(560);
  expect(share(d, 2)).toBeGreaterThan(0.97);
});

// ---------------------------------------------------------------------------
// STARVE IS JUDGED AGAINST THE SOURCE, NOT AGAINST 60fps.
//
// Every rdev window source is content-driven, so it runs below 60 and irregularly. The old check
// compared the gap to a hardcoded 1000/60, which asked whether the SOURCE was keeping up with 60 —
// not whether the pacer had gone hungry — so an ordinary 50fps window accumulated starves forever
// while presenting every frame it was ever given.

/// Feed a source at a fixed period, presenting on a display refresh, for `frames` frames.
/// Returns the pacer so its counters can be read.
function steadySource(periodMs: number, refreshMs: number, frames: number): FramePacer<string> {
  const p = new FramePacer<string>(() => {}, { marginMs: 0, cadenceLock: false });
  let now = 0;
  for (let i = 0; i < frames; i++) {
    const media = i * periodMs;
    // arrival == media: a perfect link, so the offset is zero and the target is the media time
    // itself. The point of these tests is the SOURCE's rate, with the transport contributing nothing.
    p.push({ frame: `f${i}`, mediaMs: media, arrivalMs: media });
    // Walk the display forward one refresh at a time, picking at each — the sampling the real rAF
    // loop does, and the reason the effective threshold is quantized by the refresh period.
    const until = media + periodMs;
    while (now < until) {
      p.pick(now, refreshMs);
      now += refreshMs;
    }
  }
  return p;
}

test("a steady 50fps source on a 120Hz display does not starve", () => {
  // 20ms period against the old 16.67ms threshold: every single interval qualified as a starve by
  // arithmetic, while nothing was ever actually missing.
  const p = steadySource(20, 1000 / 120, 200);
  expect(p.stats().presented).toBeGreaterThan(150);
  expect(p.stats().starve).toBe(0);
});

test("a steady 30fps source does not starve either", () => {
  // The further below 60 a source runs, the worse the old threshold scored it — and 30fps is a
  // perfectly ordinary rate for a window that is not being animated.
  const p = steadySource(1000 / 30, 1000 / 120, 150);
  expect(p.stats().starve).toBe(0);
});

test("a source that genuinely stops IS a starve", () => {
  // The counter must still fire for the thing it names, or keying it to the source would have
  // replaced a false alarm with a blind spot.
  const p = steadySource(20, 1000 / 120, 60);
  const before = p.stats().starve;
  // Nothing pushed: walk the display forward through a long silence, starting where the source
  // stopped.
  let now = 60 * 20;
  for (let i = 0; i < 120; i++) { p.pick(now, 1000 / 120); now += 1000 / 120; }
  expect(p.stats().starve).toBeGreaterThan(before);
});

test("the source period is measured from the media clock, not from arrival", () => {
  // Arrival deltas would fold the transport's jitter into the source's cadence, and the estimate is
  // then largest exactly when the link is worst — which is when a starve most needs to be real.
  const p = steadySource(20, 1000 / 120, 100);
  expect(p.sourcePeriodMs()).toBeGreaterThan(19);
  expect(p.sourcePeriodMs()).toBeLessThan(21);
});

test("the period is null until enough intervals have been seen", () => {
  // Three frames do not describe a cadence. Until it can be measured the fallback is the old 60fps
  // constant, which is no worse than what shipped.
  const p = new FramePacer<string>(() => {}, { marginMs: 0, cadenceLock: false });
  expect(p.sourcePeriodMs()).toBeNull();
});
