import { expect, test } from "vitest";
import { STAMP, sampleTimecodeBits, computeG2gFromRgba, makeRxBitrateMeter, startLatencyProbe, stampStripHeight, stampStripWidth } from "../src/lib/probe";
import { encodeTimecodeBits, decodeTimecodeBits, TIMECODE_BITS } from "../src/lib/timecode";

// M = bitCount + 4 cells: [B][W] ...32 data bits... [W][B]
const M = TIMECODE_BITS + 4;

/**
 * Paint the marker row [B][W] ...data... [W][B] starting at corner (0,0)
 * with the given cellW. cellH = min(24, imgHeight).
 */
function paintFrame(value: number, imgWidth: number, imgHeight: number, cellW: number): Uint8ClampedArray {
  const rgba = new Uint8ClampedArray(imgWidth * imgHeight * 4);
  const bits = encodeTimecodeBits(value);
  const cellH = Math.min(24, imgHeight);

  const paintCell = (cell: number, white: boolean) => {
    const v = white ? 255 : 0;
    const x0 = cell * cellW;
    for (let y = 0; y < cellH; y++) {
      for (let x = x0; x < x0 + cellW; x++) {
        const o = (y * imgWidth + x) * 4;
        rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 255;
      }
    }
  };

  // [B][W] ...data... [W][B]
  paintCell(0, false); // cell 0: BLACK (start finder + black reference)
  paintCell(1, true);  // cell 1: WHITE (start finder + white reference)
  for (let i = 0; i < bits.length; i++) {
    paintCell(2 + i, bits[i]!); // cells 2..33: data bits MSB-first
  }
  paintCell(TIMECODE_BITS + 2, true);  // cell bitCount+2: WHITE (end finder)
  paintCell(TIMECODE_BITS + 3, false); // cell bitCount+3: BLACK (end finder)

  return rgba;
}

// Test 1: Native cellW=16 round-trips
for (const value of [0x0a0b0c0d, 0x00000000, 0xffffffff]) {
  test(`native cellW=16 round-trips 0x${value.toString(16).padStart(8, "0")} through paintFrame → sampleTimecodeBits → decodeTimecodeBits`, () => {
    const cellW = 16;
    const W = M * cellW + 64; // enough margin
    const H = 64;
    const rgba = paintFrame(value, W, H, cellW);
    const bits = sampleTimecodeBits(rgba, W, H);
    expect(bits).toHaveLength(TIMECODE_BITS);
    expect(decodeTimecodeBits(bits)).toBe(value >>> 0);
  });
}

// Test 2: Downscaled cellW=6 (~2.7x downscale) proves edge-derived cellW self-calibrates
test("downscaled cellW=6 round-trips 0x0a0b0c0d (scale-invariance)", () => {
  const cellW = 6;
  const W = M * cellW + 32; // imgWidth >= M*6
  const H = 64;
  const rgba = paintFrame(0x0a0b0c0d, W, H, cellW);
  const bits = sampleTimecodeBits(rgba, W, H);
  expect(bits).toHaveLength(TIMECODE_BITS);
  expect(decodeTimecodeBits(bits)).toBe(0x0a0b0c0d);
});

// A RETINA capture at full scale carries the stamp at TWO pixels per point: cellW 32, 1152 px. The
// strip the probe reads back must still hold all of it, end finder included — a 600-px strip cut it
// off and every frame read as "no stamp" (measured on the native app's session window, 2026-09-26).
test("a Retina-scale stamp (cellW=32) survives the probe's read-back strip", () => {
  const cellW = 32, W = 1280, H = 960;
  const rgba = paintFrame(0x0a0b0c0d, W, H, cellW);
  const sw = stampStripWidth(W), sh = stampStripHeight(H);
  const strip = new Uint8ClampedArray(sw * sh * 4);
  for (let y = 0; y < sh; y++) strip.set(rgba.subarray(y * W * 4, (y * W + sw) * 4), y * sw * 4);
  expect(decodeTimecodeBits(sampleTimecodeBits(strip, sw, sh))).toBe(0x0a0b0c0d);
});

// Test 3: No stamp / garbage frame → all-false (end-finder validation rejects)
test("all-mid-gray frame with no marker row returns all-false", () => {
  const W = 640, H = 64;
  const rgba = new Uint8ClampedArray(W * H * 4).fill(128); // uniform mid-gray
  const bits = sampleTimecodeBits(rgba, W, H);
  expect(bits).toHaveLength(TIMECODE_BITS);
  expect(bits.every((b) => b === false)).toBe(true);
});

// Test 4: Too-small frame → all-false, no out-of-bounds read
test("too-small frame (1×1) returns all-false and does not throw", () => {
  const rgba = new Uint8ClampedArray(1 * 1 * 4).fill(255);
  const bits = sampleTimecodeBits(rgba, 1, 1);
  expect(bits).toHaveLength(TIMECODE_BITS);
  expect(bits.every((b) => b === false)).toBe(true);
});

test("computeG2gFromRgba returns g2g = displayEpoch − hostStamp (mod 2^32)", () => {
  const cellW = 16, W = M * cellW + 64, H = 64;
  const host = 1_000_000; // low32 ms
  const rgba = paintFrame(host, W, H, cellW);
  const display = (host + 30) >>> 0;
  // Without a `now` epoch, pipelineMs collapses onto g2gMs — the honest answer when the caller
  // cannot tell the two apart.
  expect(computeG2gFromRgba(rgba, W, H, display)).toEqual({ g2gMs: 30, pipelineMs: 30, hostEpochLow32: host });
});

test("computeG2gFromRgba splits pipeline time from the compositor wait", () => {
  // The distinction the whole latency effort turns on: g2g is measured to the frame's SCHEDULED
  // scan-out, so it carries a vsync wait that no amount of host or transport work can shorten.
  // pipelineMs stops when the frame reaches the page, which is the part rdev actually controls.
  const cellW = 16, W = M * cellW + 64, H = 64;
  const host = 1_000_000;
  const rgba = paintFrame(host, W, H, cellW);
  const s = computeG2gFromRgba(rgba, W, H, (host + 30) >>> 0, (host + 18) >>> 0);
  expect(s).toEqual({ g2gMs: 30, pipelineMs: 18, hostEpochLow32: host });
  expect(s!.g2gMs - s!.pipelineMs).toBe(12);   // the compositor wait
});

test("computeG2gFromRgba returns null when there is no stamp (g2g out of sane range)", () => {
  const W = 640, H = 64;
  const rgba = new Uint8ClampedArray(W * H * 4).fill(128); // uniform gray, no marker
  // no stamp → hostEpoch decodes to 0 → g2g == displayEpoch (huge) → rejected
  expect(computeG2gFromRgba(rgba, W, H, 2_000_000)).toBeNull();
});

// A minimal RTCStatsReport stand-in: only forEach is used by the meter.
function fakeReport(stats: unknown[]): RTCStatsReport {
  return { forEach: (cb: (v: unknown) => void) => stats.forEach(cb) } as unknown as RTCStatsReport;
}
const rtp = (bytesReceived: number, timestamp: number, ssrc?: number) => ({ type: "inbound-rtp", kind: "video", bytesReceived, timestamp, ssrc });

test("makeRxBitrateMeter returns 0 on the first sample, then Mbit/s from the byte delta", () => {
  const meter = makeRxBitrateMeter();
  expect(meter(fakeReport([rtp(0, 1000)]))).toBe(0);                 // first sample → no delta yet
  // +250000 bytes over 1000ms = 2_000_000 bits/s = 2.0 Mbps
  expect(meter(fakeReport([rtp(250_000, 2000)]))).toBeCloseTo(2.0, 5);
  // +125000 bytes over 1000ms = 1.0 Mbps
  expect(meter(fakeReport([rtp(375_000, 3000)]))).toBeCloseTo(1.0, 5);
});

test("makeRxBitrateMeter yields 0 across a byte-counter reset (pc rebuild)", () => {
  const meter = makeRxBitrateMeter();
  meter(fakeReport([rtp(500_000, 1000)]));
  expect(meter(fakeReport([rtp(1_000, 2000)]))).toBe(0);            // counter went DOWN → treated as reset, no spike
});

test("makeRxBitrateMeter ignores non-video inbound-rtp and reports", () => {
  const meter = makeRxBitrateMeter();
  expect(meter(fakeReport([{ type: "inbound-rtp", kind: "audio", bytesReceived: 9_999_999, timestamp: 1000 }]))).toBe(0);
  expect(meter(fakeReport([]))).toBe(0);
});

test("makeRxBitrateMeter sums per-ssrc deltas across multiple inbound video tracks (multi-source)", () => {
  const meter = makeRxBitrateMeter();
  // Prime both ssrcs at t=1000 — first sample per ssrc, no delta yet.
  expect(meter(fakeReport([rtp(0, 1000, 111), rtp(0, 1000, 222)]))).toBe(0);
  // Each ssrc: +125000 bytes over 1000ms = 1.0 Mbps; summed across both ssrcs = 2.0 Mbps.
  expect(meter(fakeReport([rtp(125_000, 2000, 111), rtp(125_000, 2000, 222)]))).toBeCloseTo(2.0, 5);
  // ssrc 222 disappears from the report (e.g. its subscription was dropped) — the meter keeps working
  // for the remaining ssrc 111 with no NaN/throw, and no longer counts the vanished one.
  expect(meter(fakeReport([rtp(250_000, 3000, 111)]))).toBeCloseTo(1.0, 5);
});

// THE INSTRUMENT MUST NOT CREATE WHAT IT REPORTS. A full-frame GPU->CPU readback on every presented
// frame stalls the page enough for the compositor to drop frames (measured on the canvas path at ~9%
// wrong-dwell frames that vanished when the readback was bounded), so a judder number taken through
// a probe that reads the whole picture is a number about the probe. The stamp is corner-anchored and
// 24 native rows tall; the readback is bounded by ITS geometry, never the frame's.
test("startLatencyProbe reads back only the stamp strip, never the whole frame", () => {
  const draws: Array<{ w: number; h: number }> = [];
  const reads: Array<{ w: number; h: number }> = [];
  const canvas = {
    width: 0, height: 0,
    getContext: () => ({
      drawImage: (_s: unknown, _sx: number, _sy: number, _sw: number, _sh: number, _dx: number, _dy: number, dw: number, dh: number) => {
        draws.push({ w: dw, h: dh });
      },
      getImageData: (_x: number, _y: number, w: number, h: number) => {
        reads.push({ w, h });
        return { data: new Uint8ClampedArray(w * h * 4) };
      },
    }),
  };
  const savedDocument = (globalThis as { document?: unknown }).document;
  (globalThis as { document?: unknown }).document = { createElement: () => canvas };
  let callback: ((now: number, md: { expectedDisplayTime: number }) => void) | undefined;
  const video = {
    ownerDocument: (globalThis as {document: unknown}).document,
    videoWidth: 1920, videoHeight: 1080,
    requestVideoFrameCallback: (f: typeof callback) => { callback = f; return 1; },
    cancelVideoFrameCallback: () => {},
  };
  try {
    const stop = startLatencyProbe(video as unknown as HTMLVideoElement, () => {});
    callback!(0, { expectedDisplayTime: 0 });
    stop();
  } finally {
    (globalThis as { document?: unknown }).document = savedDocument;
  }
  const strip = { w: stampStripWidth(1920), h: stampStripHeight(1080) };
  expect(strip.w).toBeLessThan(1920);
  expect(strip.h).toBeLessThan(1080);
  expect(draws).toEqual([strip]);
  expect(reads).toEqual([strip]);
  expect(canvas.width).toBe(strip.w);
  expect(canvas.height).toBe(strip.h);
});
