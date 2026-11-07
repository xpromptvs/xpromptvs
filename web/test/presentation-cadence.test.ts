import { expect, test } from "vitest";
import { presentationCadence, type PaintSample } from "../src/lib/presentation-cadence";

const NOMINAL = 1000 / 60;   // 16.67ms at 60fps

/// Build samples from paint intervals and the media intervals they correspond to. Equal intervals
/// mean the picture tracked its own timeline exactly.
function samples(paintIntervals: readonly number[], mediaIntervals: readonly number[]): PaintSample[] {
  let paintMs = 1000, mediaMs = 0;
  const out: PaintSample[] = [{ paintMs, mediaMs }];
  for (let i = 0; i < paintIntervals.length; i++) {
    paintMs += paintIntervals[i]!;
    mediaMs += mediaIntervals[i]!;
    out.push({ paintMs, mediaMs });
  }
  return out;
}

// THE MISTAKE THIS MODULE WAS REBUILT TO FIX. rdev's RTP timestamps carry real capture time and a
// window source is content-driven, so a window that does not redraw for 33ms produces a genuine 33ms
// gap with nothing lost and nothing late. Counting that as damage made a controller buy 250ms of
// buffer to close gaps where no frame had ever existed.
test("a source that simply had nothing new is not judder", () => {
  // Every other frame is 33ms late TO PAINT and 33ms late ON THE MEDIA CLOCK: the source produced
  // nothing in between, and the picture faithfully showed that.
  const gaps = Array.from({ length: 60 }, (_, i) => (i % 2 === 0 ? 33.3 : 16.7));
  const c = presentationCadence(samples(gaps, gaps), NOMINAL)!;
  expect(c.offsetSpreadMs).toBeCloseTo(0, 5);
  // ...while the gap statistics DO see it, which is why they are reported and not used to decide.
  expect(c.skips).toBe(30);
  expect(c.p95Ms).toBeGreaterThan(NOMINAL * 1.5);
});

// ...AND THE CASE THAT IS. Frames existed on an even timeline and were painted unevenly.
test("frames that miss their slot are judder", () => {
  const media = Array.from({ length: 60 }, () => 16.7);
  // Alternating 5ms/28.4ms against an even media clock: the same mean, so the same frame rate, and
  // a frame arriving a full period from where its timestamp put it.
  const paint = Array.from({ length: 60 }, (_, i) => (i % 2 === 0 ? 5 : 28.4));
  const c = presentationCadence(samples(paint, media), NOMINAL)!;
  expect(c.offsetSpreadMs).toBeGreaterThan(NOMINAL / 2);
  // The faithful case above reads ~0 on the same statistic, which is the whole point of it.
  const even = Array.from({ length: 60 }, () => 16.7);
  expect(c.offsetSpreadMs!).toBeGreaterThan(
    presentationCadence(samples(even, even), NOMINAL)!.offsetSpreadMs! + 10);
});

// A PERFECT STREAM AT ANY LATENCY IS STILL PERFECT. The absolute offset carries the whole pipeline's
// delay and an arbitrary epoch difference between the two clocks; only its spread means anything.
test("a constant offset is not judder however large", () => {
  const even = Array.from({ length: 60 }, () => 16.7);
  const shifted = samples(even, even).map((s) => ({ ...s, paintMs: s.paintMs + 5000 }));
  const c = presentationCadence(shifted, NOMINAL)!;
  expect(c.offsetSpreadMs).toBeCloseTo(0, 5);
});

// THE TWO SIGNALS MUST DISAGREE ON THE RIGHT CASE, or the rebuild changed nothing. A static-ish
// source and a juddering one can produce identical gap statistics.
test("gap statistics cannot separate the two cases and the offset can", () => {
  const gaps = Array.from({ length: 60 }, (_, i) => (i % 2 === 0 ? 33.3 : 16.7));
  const sourceGaps = presentationCadence(samples(gaps, gaps), NOMINAL)!;
  const lateFrames = presentationCadence(
    samples(gaps, Array.from({ length: 60 }, () => 25)), NOMINAL)!;
  expect(lateFrames.skips).toBe(sourceGaps.skips);
  expect(lateFrames.p95Ms).toBeCloseTo(sourceGaps.p95Ms, 5);
  expect(lateFrames.offsetSpreadMs!).toBeGreaterThan(sourceGaps.offsetSpreadMs! + 5);
});

test("a healthy 60fps stream reports no skips and no spread", () => {
  const jitterless = Array.from({ length: 60 }, (_, i) => (i % 3 === 0 ? 16.4 : 16.9));
  const c = presentationCadence(samples(jitterless, jitterless), NOMINAL)!;
  expect(c.skips).toBe(0);
  expect(c.offsetSpreadMs).toBeCloseTo(0, 5);
  expect(c.count).toBe(60);
});

// ABSENT MEANS UNKNOWN. A spread drawn from two samples describes the sample, not the stream, and a
// controller reading it would act with confidence on nothing.
test("refuses a window too small to describe", () => {
  const even = Array.from({ length: 3 }, () => 16.7);
  expect(presentationCadence(samples(even, even), NOMINAL)).toBeNull();
  expect(presentationCadence([], NOMINAL)).toBeNull();
  const enough = Array.from({ length: 20 }, () => 16.7);
  expect(presentationCadence(samples(enough, enough), 0)).toBeNull();
});

// NEAREST-RANK, not interpolated: the point of the tail is that some frame really waited that long.
test("reports a percentile that a frame actually experienced", () => {
  const media = Array.from({ length: 20 }, () => 16);
  const paint = [...Array.from({ length: 18 }, () => 16), 50, 50];
  const c = presentationCadence(samples(paint, media), NOMINAL)!;
  expect(c.p95Ms).toBe(50);
});


// THE FIELD FAILURE, and the reason this refuses instead of reporting. A `mediaTime` that barely
// advances makes every interval look like a full frame period of deviation — measured as
// `drift=4782.0ms` on a stream that was painting 52fps, and the adaptive floor climbed on it.
// A MEDIA CLOCK THAT IS NOT ADVANCING KILLS `drift` AND NOTHING ELSE.
//
// The whole reading used to be refused, and that cost exactly what the refusal was protecting: on a
// relayed session painting 47-56fps of a 60fps source, the [rx] line carried no drift, no gaps and no
// skips at all, so the shape of a visible half-second beat could not be measured. The paint intervals
// are differences of performance.now() and owe the media clock nothing.
test("reports the paint intervals but no drift when the media clock is not advancing", () => {
  const paint = Array.from({ length: 60 }, () => 16.7);
  const stalled = Array.from({ length: 60 }, () => 0);
  const c = presentationCadence(samples(paint, stalled), NOMINAL)!;
  expect(c).not.toBeNull();
  expect(c.offsetSpreadMs).toBeNull();       // the one number that needed the clock
  expect(c.p50Ms).toBeCloseTo(16.7, 1);      // the ones that did not
  expect(c.count).toBeGreaterThan(50);
  expect(c.skips).toBe(0);

  // A clock advancing at HALF wall time or less is equally unusable — same split.
  const crawling = Array.from({ length: 60 }, () => 5);
  const slow = presentationCadence(samples(paint, crawling), NOMINAL)!;
  expect(slow.offsetSpreadMs).toBeNull();
  expect(slow.p50Ms).toBeCloseTo(16.7, 1);
});

// AND THE INTERVALS STILL DESCRIBE A BEAT when the clock is dead — which is the case that motivated
// this.
//
// NOTE WHICH STATISTIC SEES IT. A half-second beat at 60fps is one interval in thirty: 3.3% of the
// window, so `p95Ms` reads a perfectly ordinary 16.7ms and says nothing at all. `skips` counts the
// events themselves and finds them. A reader looking at the percentile alone would conclude the
// stream was clean — which is how a visible beat can sit underneath a healthy-looking tail.
test("a periodic stall is visible in skips even though p95 cannot see it", () => {
  const paint = Array.from({ length: 60 }, (_, i) => (i % 30 === 0 ? 500 : 16.7));
  const stalled = Array.from({ length: 60 }, () => 0);
  const c = presentationCadence(samples(paint, stalled), NOMINAL)!;
  expect(c.offsetSpreadMs).toBeNull();
  expect(c.skips).toBeGreaterThan(0);
  expect(c.p95Ms).toBeCloseTo(16.7, 1);   // blind to a 3% event, by construction
});

// A TIMELINE RESET COSTS ONE SAMPLE, NOT THE WINDOW. Re-attaching `srcObject` restarts `mediaTime`
// while the paint clock keeps running; differencing the whole window against one origin let that
// single discontinuity dominate everything.
test("a media timeline reset does not poison the window", () => {
  const paint = Array.from({ length: 60 }, () => 16.7);
  const media = Array.from({ length: 60 }, () => 16.7);
  const withReset = samples(paint, media);
  // Halfway through, the media clock jumps back to zero and carries on.
  for (let i = 30; i < withReset.length; i++) withReset[i]!.mediaMs -= 5000;
  const c = presentationCadence(withReset, NOMINAL)!;
  expect(c.offsetSpreadMs).toBeLessThan(NOMINAL);
});
