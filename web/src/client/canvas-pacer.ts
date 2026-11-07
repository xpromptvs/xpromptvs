/// A TESTING renderer: the `<video>` element still decodes, a `<canvas>` presents on rdev's schedule.
///
/// WHY THIS SHAPE. Frame SELECTION on the plain `<video>` path already measures ~99.8% correct
/// (every source frame shown, in order). What is not perfect is DWELL — how many refreshes each frame
/// occupies. Measured on a 120.5Hz panel with a 60fps source, 97.8% of frames get their correct 2
/// refreshes and ~2.2% get 1, 3 or more. `<video>` inherits that from arrival phase; a canvas
/// presents when we say. This exists to find out whether deciding it explicitly is visibly better.
///
/// OPT-IN ONLY (`?render=canvas`). The default path is untouched.
///
/// It does NOT use WebCodecs: no VideoDecoder, no encoded transform, so it works on any origin and in
/// both engines. The cost is that it can only re-time frames the browser PRESENTS — one the browser
/// never shows is invisible to `requestVideoFrameCallback` and unrecoverable here.
import { FramePacer, MAX_QUEUE } from "../lib/frame-pacer";
import { sampleG2gFromSource } from "../lib/probe";
import { percentiles } from "./paced-render";
import type { PacedRenderHandle, PacedRenderStats } from "./paced-render";

interface RvfcMetadata { rtpTimestamp?: number; mediaTime?: number }
type RvfcVideo = HTMLVideoElement & {
  requestVideoFrameCallback?(cb: (now: number, md: RvfcMetadata) => void): number;
  cancelVideoFrameCallback?(handle: number): void;
};

const RING = MAX_QUEUE + 2;   // strictly larger than the queue cap, so a queued slot is never reused

export function startCanvasPacer(
  video: HTMLVideoElement,
  opts: { marginMs: number | "auto"; cadenceLock?: boolean; probe?: boolean },
): PacedRenderHandle | null {
  const rv = video as RvfcVideo;
  const parent = video.parentElement;
  // No rvfc means no per-frame hook and therefore no pacer. Returning null lets the caller leave the
  // plain <video> path in place rather than presenting a blank canvas.
  if (!rv.requestVideoFrameCallback || !parent) return null;

  const canvas = document.createElement("canvas");
  canvas.className = "win-paced";
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;
  // APPENDED AFTER THE VIDEO AND NOT POSITIONED ABOVE IT BY z-index. Both are `position: absolute`
  // with auto z-index, so paint order is DOM order and the opaque canvas simply covers the video.
  //
  // The <video> is deliberately left VISIBLE and untouched. `visibility: hidden` also works
  // visually, but a non-painting video is a candidate for the browser to deprioritise — and this
  // renderer depends entirely on `requestVideoFrameCallback` continuing to fire at full rate. Not
  // worth the risk to save a compositing layer. `display: none` would be worse still: it collapses
  // the box, and that box is the `#screen` anchor e2e takes tap coordinates from.
  parent.appendChild(canvas);

  let ring: Array<{ c: HTMLCanvasElement; ctx: CanvasRenderingContext2D }> = [];
  let ringW = 0, ringH = 0;
  const pacer = new FramePacer<number>(() => { /* ring slots are reused, nothing to free */ },
    { marginMs: opts.marginMs, cadenceLock: opts.cadenceLock });
  let margin: number | "auto" = opts.marginMs;
  let incoming = 0;
  const dwell: Record<number, number> = {};
  let lastPresentAt: number | null = null;
  let lastMediaMs: number | null = null;   // media time of the last PRESENTED frame, for `asked`

  const rafGaps: number[] = [];
  let lastRaf = 0;
  const refreshMs = (): number | null => {
    if (rafGaps.length < 30) return null;
    const s = [...rafGaps].sort((a, b) => a - b);
    return s[s.length >> 1]!;
  };

  const sizeRing = (w: number, h: number): void => {
    ring = Array.from({ length: RING }, () => {
      const c = document.createElement("canvas");
      c.width = w; c.height = h;
      return { c, ctx: c.getContext("2d")! };
    });
    ringW = w; ringH = h;
    canvas.width = w; canvas.height = h;
    pacer.reset();
  };

  let head = 0;
  let rtpPrev: number | null = null;
  let rtpAcc = 0;
  let stopped = false;
  let rvfcHandle = 0;
  let rafHandle = 0;

  const onFrame = (now: number, md: RvfcMetadata): void => {
    if (stopped) return;
    const w = video.videoWidth, h = video.videoHeight;
    if (w > 0 && h > 0) {
      // A resolution change (auto-resolution, a codec rebuild) invalidates every queued slot, so the
      // ring is rebuilt and the queue dropped rather than blitting a stale size into a resized canvas.
      if (w !== ringW || h !== ringH) sizeRing(w, h);
      const slot = head % RING; head++;
      ring[slot]!.ctx.drawImage(video, 0, 0, w, h);
      // rtpTimestamp is the HOST's capture clock at 90kHz — the whole point of pacing. mediaTime is
      // the fallback for an engine that does not expose it; it is the same timeline, coarser.
      //
      // UNWRAPPED. The RTP timestamp is a uint32 at 90kHz, so it wraps every ~13.25 hours; a raw
      // value would jump backwards by 47721 seconds and the never-go-backwards guard would then
      // refuse every subsequent frame — the picture freezes for good, hours into a session, with no
      // error anywhere. Same arithmetic `e2e/pacing-probe.mjs` uses.
      let mediaMs: number;
      if (md.rtpTimestamp !== undefined) {
        if (rtpPrev === null) { rtpPrev = md.rtpTimestamp; rtpAcc = md.rtpTimestamp; }
        else {
          let d = md.rtpTimestamp - rtpPrev;
          if (d < -(2 ** 31)) d += 2 ** 32;
          if (d > 2 ** 31) d -= 2 ** 32;
          rtpAcc += d;
          rtpPrev = md.rtpTimestamp;
        }
        mediaMs = rtpAcc / 90;
      } else {
        mediaMs = (md.mediaTime ?? 0) * 1000;
      }
      pacer.push({ frame: slot, mediaMs, arrivalMs: now });
      incoming++;
    }
    rvfcHandle = rv.requestVideoFrameCallback!(onFrame);
  };
  rvfcHandle = rv.requestVideoFrameCallback(onFrame);

  /// WHAT THE SOURCE ASKED FOR, in the same units as `dwell`: the media-time gap between
  /// consecutively PRESENTED frames, rounded to refresh periods. Capture is content-driven, so a host
  /// app that missed a compose genuinely produces a 25ms gap and a correct pacer MUST hold that frame
  /// for 3 refreshes. Without this, `dwell` grades the SOURCE's cadence as if it were the pacer's
  /// error, and can never reach 100% however well the pacer behaves.
  const asked: Record<number, number> = {};
  /// The number that actually grades the pacer: presented dwell == asked dwell.
  let cadenceHit = 0, cadenceMiss = 0;
  const g2gMs: number[] = [];
  const PROBE_EVERY = 6;
  let sinceProbe = 0;
  let probeScratch: { canvas: HTMLCanvasElement; ctx: CanvasRenderingContext2D } | null = null;

  const onRaf = (t: number): void => {
    if (stopped) return;
    if (lastRaf) { rafGaps.push(t - lastRaf); if (rafGaps.length > 240) rafGaps.shift(); }
    lastRaf = t;
    const picked = pacer.pick(t, refreshMs());
    if (picked !== null && ring[picked.frame]) {
      ctx.drawImage(ring[picked.frame]!.c, 0, 0);
      // THE SAME g2g PROBE THE WEBCODECS PACER RUNS, on the same helper and the same clock. Its whole
      // value is the comparison: this path has no script transform and no worker hop, so the
      // difference between the two is what that hop costs. Sampled 1-in-N for the same reason there —
      // a per-frame getImageData stalls the page and destroys what it is measuring.
      if (opts.probe && ++sinceProbe >= PROBE_EVERY) {
        sinceProbe = 0;
        if (!probeScratch) {
          const pc = document.createElement("canvas");
          const pcx = pc.getContext("2d", { willReadFrequently: true });
          if (pcx) probeScratch = { canvas: pc, ctx: pcx };
        }
        if (probeScratch) {
          const s = sampleG2gFromSource(canvas, canvas.width, canvas.height, probeScratch, t);
          if (s) { g2gMs.push(s.g2gMs); if (g2gMs.length > 600) g2gMs.shift(); }
        }
      }
      const r = refreshMs();
      if (r !== null && lastPresentAt !== null) {
        const steps = Math.max(1, Math.round((t - lastPresentAt) / r));
        dwell[steps] = (dwell[steps] ?? 0) + 1;
        // BEFORE lastMediaMs is overwritten below.
        if (lastMediaMs !== null) {
          const want = Math.max(1, Math.round((picked.mediaMs - lastMediaMs) / r));
          asked[want] = (asked[want] ?? 0) + 1;
          if (want === steps) cadenceHit++; else cadenceMiss++;
        }
      }
      lastMediaMs = picked.mediaMs;
      lastPresentAt = t;
    }
    rafHandle = requestAnimationFrame(onRaf);
  };
  rafHandle = requestAnimationFrame(onRaf);

  // rAF stops entirely in a hidden tab while frames keep arriving, so the queue would fill with
  // stale slots and the first frame back would be seconds old.
  const onVisibility = (): void => { if (document.hidden) { pacer.reset(); lastPresentAt = null; lastMediaMs = null; } };
  document.addEventListener("visibilitychange", onVisibility);

  return {
    stop(): void {
      stopped = true;
      document.removeEventListener("visibilitychange", onVisibility);
      try { rv.cancelVideoFrameCallback?.(rvfcHandle); } catch { /* already gone */ }
      cancelAnimationFrame(rafHandle);
      pacer.reset();
      canvas.remove();
    },
    setMargin(ms: number | "auto"): void { margin = ms; pacer.setMargin(ms); },
    stats(): PacedRenderStats {
      const s = pacer.stats();
      return {
        mode: "canvas" as const,
        incoming, presented: s.presented, starve: s.starve, dropped: s.dropped,
        queueMax: s.queueMax, offsetMs: s.offsetMs, waiting: s.waiting, empty: s.empty, refreshMs: refreshMs(), marginMs: pacer.marginMs(),
        dwell: { ...dwell }, asked: { ...asked }, cadenceHit, cadenceMiss, cadence: pacer.cadence(), width: ringW, height: ringH,
        g2g: percentiles(g2gMs), g2gSamples: g2gMs.length,
      };
    },
    resetStats(): void {
      pacer.resetStats();
      incoming = 0; g2gMs.length = 0; sinceProbe = 0;
      for (const k of Object.keys(asked)) delete asked[Number(k)];
      cadenceHit = 0; cadenceMiss = 0;
      for (const k of Object.keys(dwell)) delete dwell[Number(k)];
    },
  };
}
