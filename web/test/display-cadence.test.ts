import { expect, test } from "vitest";
import { DisplayCadence } from "../src/lib/display-cadence";

const R120 = 1000 / 120;
const R60 = 1000 / 60;

function feed(c: DisplayCadence, gaps: number[]): DisplayCadence {
  for (const g of gaps) c.observe(g);
  return c;
}

function repeat(value: number, times: number): number[] {
  return Array.from({ length: times }, () => value);
}

test("a loop keeping up with a 120Hz panel is 100% smooth", () => {
  const c = feed(new DisplayCadence(), repeat(R120, 200));
  const s = c.stats();
  expect(s.smoothPercent).toBe(100);
  expect(s.skips).toBe(0);
  expect(s.lostRefreshes).toBe(0);
  expect(s.refreshMs).toBeCloseTo(R120, 1);
});

test("a doubled interval is one skipped vsync, not a slower display", () => {
  // The distinction this class exists for: the panel did refresh, our callback did not run.
  const c = feed(new DisplayCadence(), [...repeat(R120, 180), ...repeat(R120 * 2, 20)]);
  const s = c.stats();
  expect(s.skips).toBe(20);
  expect(s.lostRefreshes).toBe(20);
  expect(s.refreshMs).toBeCloseTo(R120, 1);
});

test("a long skip is counted by how much it cost, not just that it happened", () => {
  // Two one-refresh skips and one four-refresh skip are very different to watch, and `skips` alone
  // cannot tell them apart.
  const c = feed(new DisplayCadence(), [...repeat(R120, 190), R120 * 5]);
  const s = c.stats();
  expect(s.skips).toBe(1);
  expect(s.lostRefreshes).toBe(4);
  expect(s.worstSteps).toBe(5);
});

// THE ESTIMATE MUST NOT BE BIASED LOW. The first version took a low percentile outright, which on a
// healthy loop reported 16.00ms for a true 16.67ms — and that error was then compared against the
// source's frame period and read as a 4.4% beat that did not exist.
test("a jittery but healthy loop reports the true period, not the fastest tick", () => {
  const c = new DisplayCadence();
  // Symmetric jitter around 16.67: a low percentile lands near 16.0, the cluster median near 16.67.
  const gaps: number[] = [];
  for (let i = 0; i < 300; i++) gaps.push(R60 + (i % 5) * 0.35 - 0.7);
  feed(c, gaps);
  expect(c.stats().refreshMs).toBeGreaterThan(16.3);
  expect(c.stats().refreshMs).toBeLessThan(17.0);
});

test("the refresh is read from the FASTEST regular tick, not the median", () => {
  // THE FAILURE THIS PREVENTS: with most callbacks skipped, a median estimator reads the period as
  // double the truth and then classifies every skip as smooth — the metric reports perfection
  // exactly when the loop is at its worst. A low percentile still finds the real refresh here.
  const c = feed(new DisplayCadence(), [...repeat(R120, 40), ...repeat(R120 * 2, 160)]);
  const s = c.stats();
  expect(s.refreshMs).toBeCloseTo(R120, 1);
  expect(s.skips).toBe(160);
  expect(s.smoothPercent).toBeLessThan(30);
});

test("a 60Hz panel keeping up is smooth, not half-rate", () => {
  // The unit is whatever the display actually does; 60Hz is not a degraded 120.
  const c = feed(new DisplayCadence(), repeat(R60, 200));
  const s = c.stats();
  expect(s.smoothPercent).toBe(100);
  expect(s.refreshMs).toBeCloseTo(R60, 1);
});

test("a backgrounded tab is a STALL, never sixty lost refreshes", () => {
  // One second hidden would otherwise add 120 to lostRefreshes and swamp a statistic about
  // smoothness with a moment that was not about smoothness at all.
  const c = feed(new DisplayCadence(), [...repeat(R120, 190), 1000, ...repeat(R120, 10)]);
  const s = c.stats();
  expect(s.stalls).toBe(1);
  expect(s.skips).toBe(0);
  expect(s.lostRefreshes).toBe(0);
  expect(s.smoothPercent).toBe(100);
});

test("reports nothing until there are enough samples to mean anything", () => {
  // Absent means unknown. A percentile over five intervals is noise, and a smoothness figure built
  // from it would be read as a measurement.
  const c = feed(new DisplayCadence(), repeat(R120, 5));
  const s = c.stats();
  expect(s.refreshMs).toBeNull();
  expect(s.smoothPercent).toBeNull();
  expect(s.ticks).toBe(0);
});

test("a clock artefact is ignored rather than classified", () => {
  // Zero and negative deltas have been seen from a paused-and-resumed tab. Rounding one to a step
  // count would invent a skip.
  const c = new DisplayCadence();
  feed(c, [...repeat(R120, 100), 0, -5, Number.NaN, Number.POSITIVE_INFINITY, ...repeat(R120, 100)]);
  const s = c.stats();
  expect(s.ticks).toBe(200);
  expect(s.smoothPercent).toBe(100);
});

test("the window is bounded, so the report describes now rather than the session", () => {
  const c = new DisplayCadence();
  feed(c, repeat(R120 * 2, 1200));   // a bad stretch that fills the window
  feed(c, repeat(R120, 1200));       // followed by a good one that replaces it
  expect(c.stats().smoothPercent).toBe(100);
});
