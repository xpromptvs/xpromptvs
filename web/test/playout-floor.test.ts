import { expect, test } from "vitest";
import { arrivalSpread, floorFor, nextPlayoutFloor, PLAYOUT_FLOOR_START, PLAYOUT_FLOOR_CAP_MS,
         nextPlayoutWindow, playoutRequest, playoutWindowCapable, playoutWindowStart, playoutWindowFor,
         PLAYOUT_WINDOW_MS, PLAYOUT_WINDOW_MAX_MS,
         type ArrivalSample, type PlayoutFloorState, type PlayoutWindowState } from "../src/lib/playout-floor";

const RTP_TICKS_PER_MS = 90;
const PERIOD = 1000 / 60;

/// Frames on a media timeline (`mediaMs`, when each was captured) that each ARRIVED `lateMs` after a
/// constant transit. The RTP timestamp carries the media time; `receiveMs` carries transit + lateness.
///
/// THIS IS THE INPUT, NOT THE OUTPUT. The controller this file replaced measured how evenly frames
/// were PAINTED, which is downstream of its own actuator — raising the floor changed the reading —
/// so every raise needed a trial, a verdict and a ban. Arrival is upstream: the floor cannot change
/// when a packet reaches the machine, so there is nothing to verify and no loop to close.
function samples(mediaMs: readonly number[], lateMs: readonly number[] = [],
                 opts: { rtpStart?: number; recvStart?: number } = {}): ArrivalSample[] {
  const rtpStart = opts.rtpStart ?? 90_000;
  const recvStart = opts.recvStart ?? 5_000;
  return mediaMs.map((m, i) => ({
    rtpTimestamp: (rtpStart + Math.round(m * RTP_TICKS_PER_MS)) >>> 0,
    receiveMs: recvStart + m + (lateMs[i] ?? 0),
  }));
}
const even = (n: number, period = PERIOD) => Array.from({ length: n }, (_, i) => i * period);

// ─── arrivalSpread ────────────────────────────────────────────────────────────────────────────

test("a steady path measures no spread", () => {
  expect(arrivalSpread(samples(even(240)))!).toBeLessThan(0.1);
});

// THE MISTAKE THE PREVIOUS CONTROLLER WAS REBUILT AROUND, KEPT FIXED. rdev's timestamps carry real
// capture time and a window source is content-driven: a window that does not redraw for 33ms
// produces a genuine 33ms gap, with nothing late. Its arrival matches its timestamp exactly.
test("a source that simply had nothing new is not spread", () => {
  const gaps = Array.from({ length: 240 }, (_, i) => (i % 2 === 0 ? 33.3 : 16.7));
  let t = 0;
  const media = gaps.map((g) => (t += g));
  expect(arrivalSpread(samples(media))!).toBeLessThan(0.1);
});

test("frames arriving later than their timestamps put them are spread", () => {
  // One frame in twenty arrives 60ms late: 5% of the window, well inside the 98th percentile.
  const late = even(240).map((_, i) => (i % 20 === 0 ? 60 : 0));
  expect(arrivalSpread(samples(even(240), late))!).toBeGreaterThanOrEqual(55);
});

// THE SHAPE SEEN ON THE RELAY: a beat every half second, each one holding several frames back and
// then delivering them together. The spread must read the stall, not the frames between stalls.
test("a periodic stall delivering frames in a burst measures the stall", () => {
  const late = even(240).map((_, i) => {
    const phase = i % 30;                  // a stall every 30 frames, four frames deep
    return phase < 4 ? 50 - phase * PERIOD : 0;   // all four arrive when the last one does
  });
  expect(arrivalSpread(samples(even(240), late))!).toBeGreaterThanOrEqual(45);
});

// A PERCENTILE, NOT A MAXIMUM. One keyframe of forty packets, or one packet having a bad day, must
// not set every future frame's latency.
test("a single outlier does not set the spread", () => {
  const late = even(240).map((_, i) => (i === 100 ? 300 : 0));
  expect(arrivalSpread(samples(even(240), late))!).toBeLessThan(10);
});

// The receiver's clock and the sender's RTP epoch have nothing to do with each other; only the
// deviation's SPREAD means anything.
test("the offset between the two clocks is irrelevant however large", () => {
  expect(arrivalSpread(samples(even(240), [], { rtpStart: 7, recvStart: 3_000_000 }))!).toBeLessThan(0.1);
});

// RTP timestamps are 32-bit and wrap every 13 hours at 90kHz. A window straddling the wrap must not
// read as a 13-hour deviation.
test("survives the RTP timestamp wrapping", () => {
  const rtpStart = 2 ** 32 - 120 * 1500;   // wraps halfway through the window
  const s = samples(even(240), [], { rtpStart });
  expect(s[0]!.rtpTimestamp).toBeGreaterThan(s[239]!.rtpTimestamp);   // the wrap really happened
  expect(arrivalSpread(s)!).toBeLessThan(0.1);
});

// ABSENT MEANS UNKNOWN. A spread from ten samples describes the samples, and a controller acting
// on it would act with confidence on nothing.
test("refuses a window too small to describe", () => {
  expect(arrivalSpread(samples(even(10)))).toBeNull();
  expect(arrivalSpread([])).toBeNull();
});

// ─── floorFor ─────────────────────────────────────────────────────────────────────────────────

// THE FLOOR IS THE REQUIREMENT. Not a step toward it, not a probe of it: the spread says how long
// a receiver must hold frames to present them evenly, and that number, in the extension's 10ms
// units with headroom for the percentile's complement, is the floor.
test("the floor is the measured requirement in the extension's units", () => {
  expect(floorFor(80)).toBe(90);
  expect(floorFor(84)).toBe(100);
  expect(floorFor(15)).toBe(20);
  expect(floorFor(200)).toBe(230);
});

// A LAN PATH MUST NEVER PAY. Every receiver holds 13-18ms on its own, so a floor of one unit can
// never bind — sending it would change the wire and nothing else. Below that the answer is zero.
test("a clean path asks for nothing", () => {
  for (const spread of [0, 1, 3, 6, 9, 12]) expect(floorFor(spread)).toBe(0);
});

test("never exceeds the cap however bad the path is", () => {
  expect(floorFor(5000)).toBe(PLAYOUT_FLOOR_CAP_MS);
});

// CROSS-IMPLEMENTATION PIN. The host clamps at `maximumPlayoutDelayMinMs` (RdevCore,
// PlayoutDelayControl.swift); a client cap above it would ask for a floor the host silently reduces,
// and the panel would then claim a number the wire does not carry.
test("the cap is what the host will accept", () => {
  expect(PLAYOUT_FLOOR_CAP_MS).toBe(500);
});

// ─── nextPlayoutFloor ─────────────────────────────────────────────────────────────────────────

function run(from: PlayoutFloorState, spreads: readonly (number | null)[]): PlayoutFloorState[] {
  const out: PlayoutFloorState[] = [];
  let state = from;
  for (const s of spreads) { state = nextPlayoutFloor(state, s); out.push(state); }
  return out;
}
const floors = (states: readonly PlayoutFloorState[]) => states.map((s) => s.floorMs);
const settled = (floorMs: number): PlayoutFloorState => ({ floorMs, aboveTicks: 0, belowTicks: 0 });
const repeat = <T extends number | null>(n: number, v: T) => Array.from({ length: n }, () => v);

test("a clean path never leaves zero", () => {
  const states = run(PLAYOUT_FLOOR_START, repeat(600, 3));
  expect(new Set(floors(states))).toEqual(new Set([0]));
});

// A RAMP, NEVER A JUMP. The receiver applies the minimum as an instantaneous clamp on every frame's
// render time (libwebrtc `VCMTiming::RenderTime`: `local_time + clamp(current_delay, min, max)`), so
// a raise of N ms holds the picture for N ms at once. One unit per second is the smallest step the
// extension can express and the only one under a 60Hz frame period, so each step is at most one
// repeated frame rather than a visible hold — at the price of reaching the requirement over
// seconds rather than at once, which the reporter chose with eyes open.
//
// AND NOT ON A SINGLE READING. Three consecutive seconds of demand before the first step: the cost
// of a wrong step is a hitch, and one tick is not evidence of a path.
test("climbs one unit per second, after three seconds of sustained demand", () => {
  expect(floors(run(PLAYOUT_FLOOR_START, repeat(12, 80))))
    .toEqual([0, 0, 20, 30, 40, 50, 60, 70, 80, 90, 90, 90]);
});

test("a two-second blip moves nothing", () => {
  const states = run(PLAYOUT_FLOOR_START, [80, 80, 3, 3, 80, 80, 3, 3, 3]);
  expect(new Set(floors(states))).toEqual(new Set([0]));
});

// AN UNKNOWN WINDOW IS NOT A CLEAN WINDOW. Null neither raises, lowers, nor counts toward either.
test("an unknown reading changes nothing", () => {
  const held = run(settled(90), repeat(50, null));
  expect(new Set(floors(held))).toEqual(new Set([90]));
  expect(held[49]!.belowTicks).toBe(0);
  expect(nextPlayoutFloor(PLAYOUT_FLOOR_START, null)).toEqual(PLAYOUT_FLOOR_START);
});

// GIVES BACK SLOWLY, ON STRONG EVIDENCE, AND NOT ALL OF IT. Thirty consecutive seconds with the need
// at least two units below the floor before the first step down; then one unit per second; and the
// descent stops ONE UNIT ABOVE the need. That cushion is the stabilisation: a floor sitting exactly
// on its need flaps on measurement noise, and every flap is a hitch.
test("descends after thirty clean seconds and stops one unit above the need", () => {
  // Spread 70 needs 80 (70 x 1.15 = 80.5). From 100 that is two units too many: the ordinary hold.
  const states = floors(run(settled(100), repeat(40, 70)));
  expect(states.slice(0, 29)).toEqual(repeat(29, 100));
  expect(states.slice(29, 32)).toEqual([90, 90, 90]);
  expect(new Set(states.slice(31))).toEqual(new Set([90]));
});

// A LARGE SURPLUS IS GIVEN BACK SOONER. Measured 2026-09-04 (docs/latency-campaign/2026-09-04-report.md):
// a seeded congested path whose steady need was 12 ms read a 54 ms spread during its first four
// seconds, climbed to a 50 ms floor by the fifth, and then held it for the whole thirty-second hold
// against readings of 0 — while a second run of the same path that missed the transient settled at
// 20. Three units of surplus for ten consecutive seconds is the discriminator: a transient has left
// the four-second window twice over, while a path that bursts every ten seconds still keeps its floor.
test("a surplus of three units or more descends after ten seconds, not thirty", () => {
  // Need 0 (spread 3) from a floor of 50: five units of surplus. Down to two units in three steps
  // after the ten-second hold; the last two units are the ordinary thirty-second rule, counted from
  // the first second of surplus, so the whole descent still completes at thirty.
  const states = floors(run(settled(50), repeat(35, 3)));
  expect(states.slice(0, 9)).toEqual(repeat(9, 50));
  expect(states.slice(9, 12)).toEqual([40, 30, 20]);
  expect(new Set(states.slice(12, 29))).toEqual(new Set([20]));
  expect(states[29]).toBe(0);
});

test("three units: ten seconds for the first unit, then the ordinary hold", () => {
  // Spread 70 needs 80; from 110 that is three units. One step at ten, the next at thirty, and the
  // floor stops one unit above the need.
  const states = floors(run(settled(110), repeat(35, 70)));
  expect(states.slice(0, 9)).toEqual(repeat(9, 110));
  expect(new Set(states.slice(9, 29))).toEqual(new Set([100]));
  expect(new Set(states.slice(29))).toEqual(new Set([90]));
});

test("the shorter hold hands over to the ordinary one as the surplus shrinks", () => {
  // Need 20 (spread 18 -> 20.7 -> 20) from 60: four units, then three, then two — the last unit of
  // descent is back on the thirty-second rule, and the floor stops one unit above the need.
  const states = floors(run(settled(60), repeat(60, 18)));
  expect(states.slice(9, 11)).toEqual([50, 40]);                 // 60->50 after ten ticks, 50->40 (three units)
  expect(new Set(states.slice(11, 29))).toEqual(new Set([40]));  // two units above: the ordinary hold
  expect(new Set(states.slice(29))).toEqual(new Set([30]));      // one unit above the need, and stays
});

test("a relapse during the hold restarts it", () => {
  const states = run(settled(100), [...repeat(25, 70), 85, ...repeat(29, 70)]);
  expect(new Set(floors(states))).toEqual(new Set([100]));
});

// THE QUIESCENT BAND. Measurement noise of a few milliseconds around a settled need must move
// nothing, however long it goes on — this is the property the first version lacked, where a need
// straddling a rounding boundary would have flapped a unit every dozen seconds.
test("noise around a settled need moves nothing", () => {
  let seed = 7;
  const noisy = Array.from({ length: 600 }, () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return 70 + (seed % 1200) / 100;          // 70.00 .. 81.99: needs 80.5 .. 94.3, targets 80 and 90
  });
  const states = floors(run(settled(90), noisy));
  expect(new Set(states)).toEqual(new Set([90]));
});

// A SINGLE STALL BUYS A UNIT AND KEEPS IT — by design, and this test pins the size of "it". The
// stall lifts the p98 for the four seconds it stays in the window, which is long enough to climb;
// when it leaves, the descent returns everything but the cushion. A path that stalls now and then
// ends up one unit above its quiet need, and stops moving.
test("a passing stall leaves exactly one unit behind", () => {
  // Quiet need: spread 60 -> 69 -> floor 70. The stall: spread 75 -> 86.25 -> floor 90.
  const states = floors(run(settled(70), [...repeat(5, 75), ...repeat(60, 60)]));
  expect(Math.max(...states)).toBeGreaterThanOrEqual(80);
  expect(states[states.length - 1]).toBe(80);
});

// FROM EITHER SIDE, WITHIN ONE UNIT, AND THEN STILL. The endpoint depends on the direction by at
// most the cushion; what must not depend on anything is that it stops.
test("settles within one unit of the requirement from either side, and stays", () => {
  const fromAbove = floors(run(settled(200), repeat(120, 80)));
  const fromBelow = floors(run(PLAYOUT_FLOOR_START, repeat(120, 80)));
  expect([90, 100]).toContain(fromAbove[119]);
  expect([90, 100]).toContain(fromBelow[119]);
  expect(new Set(fromAbove.slice(60))).toEqual(new Set([fromAbove[119]]));
  expect(new Set(fromBelow.slice(60))).toEqual(new Set([fromBelow[119]]));
});

// ONE UNIT IS NEVER SENT, IN EITHER DIRECTION: the smallest floor that can bind is two units, so the
// step below it is straight to zero.
test("the last step down goes to zero, never to one unit", () => {
  const states = floors(run(settled(20), repeat(40, 3)));
  expect(states).not.toContain(10);
  expect(states[states.length - 1]).toBe(0);
});

test("never exceeds the cap however bad the path is", () => {
  const states = floors(run(settled(490), repeat(10, 5000)));
  expect(Math.max(...states)).toBe(PLAYOUT_FLOOR_CAP_MS);
});

// ─── the window ───────────────────────────────────────────────────────────────────────────────

const runWindow = (from: PlayoutWindowState, spreads: readonly (number | null)[], capable = true) => {
  const out: PlayoutWindowState[] = [];
  let state = from;
  for (const s of spreads) { state = nextPlayoutWindow(state, s, capable); out.push(state); }
  return out;
};
const sizes = (states: readonly PlayoutWindowState[]) => states.map((s) => (s.active ? s.sizeMs : null));

// SIZED TO THE PATH: 10 under a 7 ms need, else one unit above the need rounded up, nothing past 50.
// Loopback and a LAN (need 2–4) get 10; the stall-free relay (need 13–16) gets 30, which measured
// smooth at 48.6 ms where 20 measured a one-refresh judder tail; the AirDrop-stalled relay (need
// 80) is left to the floor design.
test("the window a need calls for", () => {
  expect(playoutWindowFor(3)).toBe(10);
  expect(playoutWindowFor(7)).toBe(10);
  expect(playoutWindowFor(7.5)).toBe(20);
  expect(playoutWindowFor(14.5)).toBe(30);
  expect(playoutWindowFor(20)).toBe(30);
  expect(playoutWindowFor(20.1)).toBe(40);
  expect(playoutWindowFor(40)).toBe(PLAYOUT_WINDOW_MAX_MS);
  expect(playoutWindowFor(40.1)).toBeNull();
  expect(playoutWindowFor(80)).toBeNull();
});

// THE FAST PATH IS CHOSEN WHEN THE STREAM STARTS, so a capable session starts IN the window, at the
// smallest size, before its first frame; an incapable one never enters.
test("a capable session starts in the smallest window; an incapable one does not", () => {
  expect(playoutWindowStart(true)).toMatchObject({ active: true, sizeMs: PLAYOUT_WINDOW_MS });
  expect(playoutWindowStart(false).active).toBe(false);
  expect(new Set(sizes(runWindow(playoutWindowStart(false), repeat(10, 3), false)))).toEqual(new Set([null]));
  expect(nextPlayoutWindow(playoutWindowStart(true), 3, false).active).toBe(false);
});

// THE STARTING SIZE IS THE ONE THAT COUNTS. A session started at 10 and resized to 30 on the relay
// measured 60 ms; the same window from the start 48.6. A remembered prior starts the next session
// there; anything that is not a valid window is ignored rather than clamped into a guess.
test("a remembered window is where the next session starts; an invalid one is ignored", () => {
  expect(playoutWindowStart(true, 30).sizeMs).toBe(30);
  expect(playoutWindowStart(true, 50).sizeMs).toBe(50);
  expect(playoutWindowStart(true, 25).sizeMs).toBe(10);
  expect(playoutWindowStart(true, 60).sizeMs).toBe(10);
  expect(playoutWindowStart(true, 0).sizeMs).toBe(10);
  expect(playoutWindowStart(true, Number.NaN).sizeMs).toBe(10);
  expect(playoutWindowStart(false, 30).active).toBe(false);
});

test("a quiet path keeps the 10 ms window; unknown readings change nothing", () => {
  const states = runWindow(playoutWindowStart(true), [3, null, 2, 3, null, 3]);
  expect(new Set(sizes(states))).toEqual(new Set([10]));
});

// RESIZES AFTER THREE AGREEING READINGS. The relay reads need ~14.5 (spread 12.6): the window
// grows 10 -> 30 on the third reading, and shrinks back only after three quiet ones.
test("grows to the path's need after three readings, and shrinks the same way", () => {
  const grown = runWindow(playoutWindowStart(true), repeat(5, 12.6));
  expect(sizes(grown)).toEqual([10, 10, 30, 30, 30]);
  const shrunk = runWindow(grown.at(-1)!, repeat(5, 3));
  expect(sizes(shrunk)).toEqual([30, 30, 10, 10, 10]);
});

test("a reading that disagrees resets the count; two different targets do not add up", () => {
  const states = runWindow(playoutWindowStart(true), [12.6, 12.6, 3, 12.6, 12.6, 22, 22, 22]);
  expect(sizes(states)).toEqual([10, 10, 10, 10, 10, 10, 10, 40]);
});

// PAST THE CAP THE FLOOR DESIGN TAKES OVER, and the window re-enters when the path quietens.
test("leaves for the floor design past 50 ms, and re-enters when the need returns under it", () => {
  const left = runWindow(playoutWindowStart(true), repeat(4, 70));    // need 80.5
  expect(sizes(left)).toEqual([10, 10, null, null]);
  const back = runWindow(left.at(-1)!, repeat(4, 12.6));
  expect(sizes(back)).toEqual([null, null, 30, 30]);
});

test("the request is the window when active, else the floor under the configured ceiling", () => {
  const active = runWindow(playoutWindowStart(true), repeat(3, 12.6)).at(-1)!;
  expect(playoutRequest(settled(0), active)).toEqual({ minMs: 30, maxMs: 30 });
  expect(playoutRequest(settled(80), playoutWindowStart(false))).toEqual({ minMs: 80, maxMs: null });
  expect(playoutRequest(settled(0), playoutWindowStart(false))).toEqual({ minMs: 0, maxMs: null });
});

// WEBKIT TAKES THE CEILING LITERALLY AND DISCARDS. Chrome, Edge, Electron and Chrome on iOS all say
// Chrome-something beside AppleWebKit; Safari and the iPad do not.
test("WebKit is not capable; Chromium-family engines are", () => {
  expect(playoutWindowCapable("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15")).toBe(false);
  expect(playoutWindowCapable("Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1")).toBe(false);
  expect(playoutWindowCapable("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")).toBe(true);
  expect(playoutWindowCapable("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) rdev/0.1.0 Chrome/140.0.0.0 Electron/38.0.0 Safari/537.36")).toBe(true);
  expect(playoutWindowCapable("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0")).toBe(true);
});
