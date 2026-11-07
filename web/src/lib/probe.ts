// web/src/lib/probe.ts
import { TIMECODE_BITS, decodeTimecodeBits } from "./timecode";

// Mirror of RdevCore's LatencyProbeStamp — keep in lock-step. (It named
// SimFramebufferVideoSource.LatencyProbeStamp until 2026-08-01; that file was deleted with
// simulator support in 2d9666c, taking the host's ability to stamp anything with it, and the
// geometry now lives in RdevCore beside LatencyTimecode.)
// Layout: [B][W] ...bitCount data bits (MSB-first)... [W][B], starting at corner (0,0).
// M = TIMECODE_BITS + 4 total cells.
// cellW=16, cellH=24 are the host's native cell dimensions (reference only; browser self-calibrates).
export const STAMP = { cellW: 16, cellH: 24, bits: TIMECODE_BITS } as const;
export type StampLayout = typeof STAMP;

const M = TIMECODE_BITS + 4; // total cells: [B][W] + 32 data + [W][B]

/**
 * Locate the timecode stamp by its marker cells and sample the data bits.
 *
 * Convention: [B][W] ...bitCount data bits (MSB-first)... [W][B], anchored at corner (0,0).
 * - cell 0 = BLACK (start finder + black reference)
 * - cell 1 = WHITE (start finder + white reference)
 * - cells 2..bitCount+1 = data bits MSB-first
 * - cell bitCount+2 = WHITE (end finder)
 * - cell bitCount+3 = BLACK (end finder)
 *
 * Returns `bitCount` bits, or an all-false array if the stamp cannot be located/validated.
 */
export function sampleTimecodeBits(rgba: Uint8ClampedArray, imgWidth: number, imgHeight: number): boolean[] {
  const allFalse = (): boolean[] => Array<boolean>(TIMECODE_BITS).fill(false);

  if (imgWidth <= 0 || imgHeight <= 0) return allFalse();

  // Step 1: sample row near the very top (stays inside the cell even if vertically downscaled)
  const y = Math.min(2, imgHeight - 1);

  // Step 2: build luma scanline
  const L = new Float32Array(imgWidth);
  for (let x = 0; x < imgWidth; x++) {
    const o = (y * imgWidth + x) * 4;
    L[x] = 0.299 * rgba[o]! + 0.587 * rgba[o + 1]! + 0.114 * rgba[o + 2]!;
  }

  // Step 3: black reference from corner (cell 0), find max luma in left 60% of frame
  const blackRef0 = (L[0]! + (imgWidth > 1 ? L[1]! : L[0]!) + (imgWidth > 2 ? L[2]! : L[0]!)) / 3;
  const searchEnd = Math.floor(imgWidth * 0.6);
  let maxL = -Infinity;
  for (let x = 0; x < searchEnd; x++) {
    if (L[x]! > maxL) maxL = L[x]!;
  }
  if (maxL - blackRef0 < 20) return allFalse(); // no stamp

  // Step 4: find cell0→cell1 dark→light boundary to derive cellW
  const crossThresh = (blackRef0 + maxL) / 2;
  let edge = -1;
  for (let x = 1; x < imgWidth; x++) {
    if (L[x]! >= crossThresh) { edge = x; break; }
  }
  if (edge < 0) return allFalse();
  const cellW = edge; // derived cell width

  // Step 5: too small to sample reliably
  if (cellW < 2) return allFalse();

  // Step 6: check stamp fits
  const center = (i: number) => Math.round((i + 0.5) * cellW);
  if (center(M - 1) >= imgWidth) return allFalse();

  // Step 7: per-cell references and threshold
  const blackRef = L[center(0)]!;
  const whiteRef = L[center(1)]!;
  const thr = (blackRef + whiteRef) / 2;

  // Step 8: validate end finders
  if (L[center(TIMECODE_BITS + 2)]! < thr) return allFalse(); // should be WHITE
  if (L[center(TIMECODE_BITS + 3)]! >= thr) return allFalse(); // should be BLACK

  // Step 9: sample data bits
  const bits: boolean[] = [];
  for (let i = 0; i < TIMECODE_BITS; i++) {
    bits.push(L[center(2 + i)]! >= thr);
  }
  return bits;
}

export interface LatencySample {
  g2gMs: number;
  pipelineMs: number;
  hostEpochLow32: number;
  /// stamp -> the last packet of this frame arriving (host encode + deliver + network). From
  /// `VideoFrameCallbackMetadata.receiveTime`; absent when the browser does not supply it.
  wireMs?: number;
  /// last packet arriving -> this callback firing (jitter buffer + decode + Chrome's <video>
  /// render path). The term that subtraction alone cannot separate from the wire.
  renderMs?: number;
  /// `VideoFrameCallbackMetadata.processingDuration` — decode proper, in ms.
  decodeMs?: number;
}

/// Decode the host timecode from an RGBA frame and compute glass-to-glass ms against a display epoch
/// (both low-32 ms). Returns null when no stamp is present (g2g falls outside the sane <5000 ms range).
///
/// TWO numbers, because they are optimized by completely different work:
///   g2gMs      stamp -> the frame's SCHEDULED SCAN-OUT (`expectedDisplayTime`). The honest
///              end-to-end figure, and what a user perceives.
///   pipelineMs stamp -> the moment the frame became available to the page (`requestVideoFrameCallback`
///              firing). Everything rdev controls: encode, packetize, network, jitter buffer, decode.
///
/// `g2gMs - pipelineMs` is therefore the COMPOSITOR/VSYNC WAIT — time the frame spends decoded and
/// idle, waiting for the next scan-out. Nothing in the host or the transport can shorten it, so
/// conflating the two makes the pipeline look worse than it is and sends optimization work at the
/// wrong half. `nowEpochLow32` defaults to the display epoch, which collapses pipelineMs onto g2gMs
/// for callers that do not have it.
export function computeG2gFromRgba(
  rgba: Uint8ClampedArray,
  imgWidth: number,
  imgHeight: number,
  displayEpochLow32: number,
  nowEpochLow32: number = displayEpochLow32,
): LatencySample | null {
  const hostEpochLow32 = decodeTimecodeBits(sampleTimecodeBits(rgba, imgWidth, imgHeight));
  const g2gMs = (displayEpochLow32 - hostEpochLow32) >>> 0; // modular; valid while < ~2^31
  if (g2gMs >= 5000) return null;
  const pipelineMs = (nowEpochLow32 - hostEpochLow32) >>> 0;
  return { g2gMs, pipelineMs, hostEpochLow32 };
}

/**
 * Start reading the host timecode each displayed frame and reporting glass-to-glass latency.
 * g2g = (low32 of (timeOrigin + expectedDisplayTime)) − hostStampLow32, modulo 2^32 ms.
 * Same-machine: system wall clock is shared, so no clock sync is needed. Returns a stop fn.
 */
/// How many rows to read back to find the host's timecode.
///
/// STRIP-ONLY, AND SAMPLED — NOT AN OPTIMISATION, A CORRECTNESS RULE. A full-frame `getImageData`
/// per frame is a GPU->CPU readback of the whole picture; at 60fps it stalls the page enough for the
/// compositor to drop frames, and this session measured exactly that: a "defect" of ~9% wrong-dwell
/// frames that vanished (to 0.1%) the moment the readback was removed. The instrument was creating
/// what it reported. The stamp is corner-anchored at (0,0) and 24 native rows tall, so the readback
/// is bounded by the STAMP's geometry rather than the frame's.
export function stampStripHeight(frameHeight: number): number {
  if (frameHeight <= STAMP.cellH * 2) return frameHeight;
  return Math.min(frameHeight, Math.max(STAMP.cellH * 2, Math.ceil(frameHeight * 0.05)));
}

/// How many COLUMNS to read back to find the host's timecode — the strip's other bound.
///
/// The stamp is 36 cells of 16 POINTS, and the frame carries it in PIXELS: 576 px only while the
/// capture is at one pixel per point. A Retina window captured at full scale carries it at 1152 px,
/// and a 600-px read (the bound until 2026-09-26) cut the end finder off, so every frame was "no
/// stamp" and `probe=1` reported NOTHING, silently — found measuring the native app's session window
/// (`scripts/app-latency.sh`, a 640×480 pt source arriving as 1280×960). 1200 holds the 2× stamp with
/// a margin; a strip 1200 × `stampStripHeight` is still a strip, never the frame.
export function stampStripWidth(frameWidth: number): number {
  return Math.min(frameWidth, 1200);
}

/// Read one glass-to-glass sample out of an already-drawn frame. `displayMs` is the rAF timestamp of
/// the vsync the frame was drawn for — the honest display time for a canvas renderer, and the direct
/// replacement for requestVideoFrameCallback's `expectedDisplayTime`, which is a PREDICTION.
export function sampleG2gFromSource(
  source: CanvasImageSource,
  width: number,
  height: number,
  scratch: { canvas: HTMLCanvasElement; ctx: CanvasRenderingContext2D },
  displayMs: number,
): LatencySample | null {
  const w = stampStripWidth(width);
  const h = stampStripHeight(height);
  if (w <= 0 || h <= 0) return null;
  if (scratch.canvas.width !== w || scratch.canvas.height !== h) {
    scratch.canvas.width = w; scratch.canvas.height = h;
  }
  scratch.ctx.drawImage(source, 0, 0, w, h, 0, 0, w, h);
  const rgba = scratch.ctx.getImageData(0, 0, w, h).data;
  return computeG2gFromRgba(rgba, w, h,
    (performance.timeOrigin + displayMs) >>> 0,
    (performance.timeOrigin + performance.now()) >>> 0);
}

export function startLatencyProbe(video: HTMLVideoElement, onSample: (s: LatencySample) => void): () => void {
  const anyVideo = video as HTMLVideoElement & {
    requestVideoFrameCallback?: (cb: (now: number, md: { expectedDisplayTime: number }) => void) => number;
    cancelVideoFrameCallback?: (h: number) => void;
  };
  if (!anyVideo.requestVideoFrameCallback) return () => {};
  // RVFC metadata is relative to the presenting video document, including related native views.
  const clock = video.ownerDocument.defaultView?.performance ?? performance;
  const canvas = video.ownerDocument.createElement("canvas");
  const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
  let handle = 0;
  let stopped = false;
  const onFrame = (_now: number, md: {
    expectedDisplayTime: number; receiveTime?: number; processingDuration?: number;
  }) => {
    if (stopped) return;
    // STRIP-ONLY, like `sampleG2gFromSource` — see `stampStripHeight`. This path read back the WHOLE
    // frame until 2026-09-04, on every presented frame: at 60fps that is exactly the readback the
    // canvas path had already measured as stalling the compositor, so the judder it reported was
    // partly its own. The stamp is corner-anchored and 24 native rows tall.
    const w = stampStripWidth(video.videoWidth), h = stampStripHeight(video.videoHeight);
    if (w > 0 && h > 0) {
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
      ctx.drawImage(video, 0, 0, w, h, 0, 0, w, h);
      const rgba = ctx.getImageData(0, 0, w, h).data;
      const displayEpoch = (clock.timeOrigin + md.expectedDisplayTime) >>> 0;
      const nowEpoch = (clock.timeOrigin + _now) >>> 0;
      const s = computeG2gFromRgba(rgba, w, h, displayEpoch, nowEpoch);
      if (s) {
        // Split the pipeline at the WIRE using the frame's own metadata rather than by subtracting
        // getStats() averages — those are whole-session means over a different frame population,
        // so subtracting them from a per-frame number silently mixes two timebases.
        if (md.receiveTime !== undefined) {
          const recvEpoch = (clock.timeOrigin + md.receiveTime) >>> 0;
          s.wireMs = (recvEpoch - s.hostEpochLow32) >>> 0;
          s.renderMs = Math.max(0, _now - md.receiveTime);
        }
        if (md.processingDuration !== undefined) s.decodeMs = md.processingDuration * 1000;
        onSample(s);
      }
    }
    handle = anyVideo.requestVideoFrameCallback!(onFrame);
  };
  handle = anyVideo.requestVideoFrameCallback(onFrame);
  return () => { stopped = true; anyVideo.cancelVideoFrameCallback?.(handle); };
}

export interface ReceiverLatencyStats {
  jitterBufferMs: number; decodeMs: number; processingMs: number; fps: number; rttMs: number;
}

/**
 * A stateful meter for the incoming video bitrate (Mbit/s), derived from the `inbound-rtp` video
 * `bytesReceived` delta between successive getStats() reports, keyed PER-SSRC and summed across all
 * inbound video tracks (multi-source: N subscriptions == N ssrcs sharing one getStats() report — a
 * single scalar `prevBytes` would mis-aggregate their deltas). Each ssrc reports 0 until it has two
 * samples, and 0 across a byte-counter reset (a pc rebuild) — make a fresh meter per pc. Kept as a
 * closure (not a module global) so it's testable and reset-safe.
 */
export function makeRxBitrateMeter(): (report: RTCStatsReport) => number {
  const prev = new Map<number, { bytes: number; ts: number }>();   // ssrc -> last sample
  return (report: RTCStatsReport): number => {
    let mbps = 0;
    report.forEach((s: any) => {
      if (s.type === "inbound-rtp" && s.kind === "video") {
        const ssrc = s.ssrc ?? 0, bytes = s.bytesReceived || 0, ts = s.timestamp || 0;
        const p = prev.get(ssrc);
        if (p && ts > p.ts && bytes >= p.bytes) {
          mbps += ((bytes - p.bytes) * 8) / ((ts - p.ts) / 1000) / 1e6;
        }
        prev.set(ssrc, { bytes, ts });
      }
    });
    return mbps;   // summed across all inbound video tracks
  };
}

/** One-shot getStats() snapshot of the receiver-side latency components (per-frame averages). */
export async function pollReceiverStats(pc: Pick<RTCPeerConnection, "getStats">): Promise<ReceiverLatencyStats> {
  const report = await pc.getStats();
  const out: ReceiverLatencyStats = { jitterBufferMs: 0, decodeMs: 0, processingMs: 0, fps: 0, rttMs: 0 };
  report.forEach((s: any) => {
    if (s.type === "inbound-rtp" && s.kind === "video") {
      const frames = s.framesDecoded || 1;
      const jbEmit = s.jitterBufferEmittedCount || 1;
      out.jitterBufferMs = ((s.jitterBufferDelay || 0) / jbEmit) * 1000;
      out.decodeMs = ((s.totalDecodeTime || 0) / frames) * 1000;
      out.processingMs = ((s.totalProcessingDelay || 0) / frames) * 1000;
      out.fps = s.framesPerSecond || 0;
    }
    if (s.type === "candidate-pair" && s.nominated && s.state === "succeeded") {
      out.rttMs = (s.currentRoundTripTime || 0) * 1000;
    }
  });
  return out;
}
