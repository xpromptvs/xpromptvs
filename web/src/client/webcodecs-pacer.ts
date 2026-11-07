/// A TESTING renderer: `RTCRtpScriptTransform` -> `VideoDecoder` -> `<canvas>`, presented by rdev.
///
/// The third of three receive paths (`?render=webcodecs`). Unlike `canvas-pacer.ts`, the `<video>`
/// element is bypassed entirely — we consume the encoded frames before the browser's decoder sees
/// them, so we own decode as well as presentation. Both paths share `FramePacer` and report the same
/// counters, so they are directly comparable.
///
/// WHAT IT BUYS OVER THE rvfc PACER. That one can only re-time frames the browser chooses to present;
/// a frame the browser never shows is invisible to `requestVideoFrameCallback`. This one sees every
/// frame that arrives, because it takes them before any of the browser's own scheduling.
///
/// WHAT IT COSTS. `VideoDecoder` is `[SecureContext]` per the W3C WebCodecs spec, so there is no
/// decoder at all on a plain-http origin in Chromium; and consuming the transform starves the
/// browser's decoder, so the browser never sends a PLI again and keyframe recovery becomes ours
/// (hence the host's restored `request-keyframe`).
import { DisplayCadence } from "../lib/display-cadence";
import { FramePacer } from "../lib/frame-pacer";
import { sampleG2gFromSource } from "../lib/probe";
import { percentiles } from "./paced-render";
import { makeKeyframeRequester } from "./keyframe-gate";
import type { PacedRenderHandle, PacedRenderStats } from "./paced-render";

/// How long to wait for the first decoded frame before declaring the path dead.
///
/// GENEROUS ON PURPOSE. `ontrack` fires when the track is ADDED, which is before the host has
/// resolved the codec and built the encoder — so the gap to the first frame is a negotiation, not a
/// render. A tight deadline reports "the transform is not delivering" about a path that was merely
/// still starting.
const FIRST_FRAME_TIMEOUT_MS = 10_000;

/// How long a visible, connected renderer may receive nothing before it is rebuilt. Long enough not
/// to fire on an idle window (a static source legitimately produces no frames), short enough that a
/// real stall reads as a hiccup rather than a dead session.
const STALL_TIMEOUT_MS = 4000;

interface FrameLike { displayWidth: number; displayHeight: number; close(): void }

/// ATTACHED AT `ontrack`, NOT WHEN THE WINDOW APPEARS.
///
/// `RTCRtpScriptTransform` must be installed before RTP starts flowing: set late, it simply never
/// receives — `onrtctransform` does not fire, the worker never speaks, and the window is blank with
/// no error anywhere. The WebCodecs path deleted in 2026-07 carried exactly this warning ("Setting it
/// late (after RTP has started) misses the frames") and it cost a debugging round to rediscover.
///
/// So capture starts here and presentation starts later: frames queue in the pacer from the first
/// one, and `attachCanvas` begins drawing once the window exists.
export function startWebCodecsPacer(
  receiver: RTCRtpReceiver,
  /// A worker from the pool that has ALREADY installed `onrtctransform` — see decode-worker-pool.ts
  /// for why creating one here and attaching immediately does not work.
  worker: Worker,
  opts: {
    marginMs: number | "auto";
    cadenceLock?: boolean;
    codecMap: Map<number, string>;
    fallbackCodec: string | null;
    /// Ask the host for an IDR. Debounced here; the host debounces again per source, and DEFERS
    /// rather than drops — which is the difference between a rate limit and a deadlock.
    requestKeyframe(): void;
    onFatal(reason: string): void;
    /// No frames for STALL_TIMEOUT_MS while visible. The caller rebuilds capture from scratch.
    onStall(): void;
    /// `?probe=1`: sample glass-to-glass latency from the host's timecode. Off by default — the
    /// readback is cheap only because it is a strip AND sampled, and it is still not free.
    probe?: boolean;
  /// EXPERIMENT (`?fwd=0`): stop forwarding to the browser's own decoder.
  forward?: boolean;
  /// SPIKE (`?carrier=1`): treat RTP as a packet transport — the browser's decoder is fed one
  /// stashed keyframe per second instead of the real stream, which it never sees.
  carrier?: boolean;
  /// "datachannel" installs NO transform and expects the caller
  /// to drive `pushEncoded` from the host's mirror channel instead.
  ///
  /// NO TRANSFORM IS THE WHOLE POINT, and it also removes the PLI hazard for free: with nothing
  /// intercepting, the browser's own decoder is fed normally by the RTP track and never starves, so
  /// the keyframe storm of 5d4cfe0 cannot arise on this arm.
  feed?: "transform" | "datachannel";
  },
): PacedRenderHandle | null {
  const RST = (globalThis as { RTCRtpScriptTransform?: new (w: Worker, o?: unknown) => unknown }).RTCRtpScriptTransform;
  if (!RST) return null;

  const canvas = document.createElement("canvas");
  canvas.className = "win-paced";
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;

  const pacer = new FramePacer<FrameLike>((f) => f.close(), { marginMs: opts.marginMs, cadenceLock: opts.cadenceLock });
  const askKeyframe = makeKeyframeRequester(opts.requestKeyframe, () => performance.now());

  let margin: number | "auto" = opts.marginMs;
  let incoming = 0, keyframeRequests = 0, gated = 0, workerMessages = 0;
  // Pooled workers boot and report ready BEFORE a pacer takes one, so those two messages are
  // already spent by the time this listener exists. Nothing here waits on them.
  let ready = true;
  let transformAttached = false;
  let recovered = 0, skipped = 0;
  /// GLASS-TO-GLASS, sampled. One in six presented frames (~10Hz at 60fps) is enough for stable
  /// percentiles and costs a sixth of the readback. Reading EVERY frame is what manufactured a 9%
  /// wrong-dwell "defect" earlier in this work; see stampStripHeight.
  const PROBE_EVERY = 6;
  const g2gMs: number[] = [];
  let sinceProbe = 0;
  let probeScratch: { canvas: HTMLCanvasElement; ctx: CanvasRenderingContext2D } | null = null;
  /// WHAT THE SOURCE ASKED FOR, in the same units as `dwell`: the media-time gap between
  /// consecutively PRESENTED frames, rounded to refresh periods. Capture is content-driven, so a host
  /// app that missed a compose genuinely produces a 25ms gap and a correct pacer MUST hold that frame
  /// for 3 refreshes. Without this, `dwell` grades the SOURCE's cadence as if it were the pacer's
  /// error, and can never reach 100% however well the pacer behaves.
  const asked: Record<number, number> = {};
  /// The number that actually grades the pacer: presented dwell == asked dwell.
  let cadenceHit = 0, cadenceMiss = 0;
  /// Milliseconds spent inside our own rAF callback, when it presented a frame.
  const drawMs: number[] = [];
  const holdMs: number[] = [];
  /// Per-frame VideoDecoder residency, reported by the worker. Recorded for EVERY frame rather than
  /// every sixth: it costs one array push, and unlike the g2g probe it does not read back pixels.
  const decodeMs: number[] = [];
  /// Browser frame-assembly -> our transform callback, computed IN the worker (one time origin).
  /// Empty when the engine reports no `receiveTime` — a missing instrument, never a zero.
  const hopMs: number[] = [];
  let metadataKeys: string[] | null = null;
  let probeDecodeFails = 0;   // reset by resetStats, so each A/B arm reports only its own samples
  /// CLOCK-OFFSET MEASUREMENT. The host captures on the HOST's compositor grid and we present on
  /// OURS; two crystals are never identical, so the media clock drifts against the wall clock and the
  /// difference forces a repeat or a drop every so often. Spanning first-to-last presented frame
  /// gives that offset directly, in ppm, with no extra machinery.
  let firstMediaMs: number | null = null, firstWallMs = 0;
  let lastMediaMs = 0, lastWallMs = 0;
  /// DIAGNOSTIC: the last few things the worker said, with timestamps. A single `error` field keeps
  /// only the last one, which loses the sequence — and the sequence is the whole question when a path
  /// dies intermittently.
  const log: Array<{ t: number; m: string }> = [];
  const note = (m: string): void => { log.push({ t: Math.round(performance.now()), m }); if (log.length > 40) log.shift(); };
  let codec: string | null = null;
  let error: string | undefined;
  let sized = false;
  const dwell: Record<number, number> = {};
  let lastPresentAt: number | null = null;
  const rafGaps: number[] = [];
  // The SAME intervals the refresh estimate is built from, classified for a different question:
  // `refreshMs` asks how fast the display is, this asks how often we failed to keep up with it.
  const display = new DisplayCadence();
  let lastRaf = 0;
  const refreshMs = (): number | null => {
    if (rafGaps.length < 30) return null;
    const s = [...rafGaps].sort((a, b) => a - b);
    return s[s.length >> 1]!;
  };

  let stopped = false;
  let rafHandle = 0;
  const teardown = (reason?: string): void => {
    if (stopped) return;
    stopped = true;
    if (reason) error = reason;
    document.removeEventListener("visibilitychange", onVisibility);
    clearInterval(watchdog);
    cancelAnimationFrame(rafHandle);
    clearTimeout(firstFrameTimer);
    try { (receiver as unknown as { transform: unknown }).transform = null; } catch { /* ignore */ }
    worker.terminate();
    pacer.reset();
    canvas.remove();
  };

  // NO FRAME MEANS SAY SO. A silent fallback to <video> is worse than a failure here: you would
  // believe you were measuring WebCodecs while watching the ordinary path.
  const firstFrameTimer = setTimeout(() => {
    if (!sized) {
      // The counters say WHICH stage failed. A pooled worker has already booted and reported ready
      // before this pacer exists, so those are not among the possibilities here.
      const why = workerMessages === 0
        ? "no frame in 10s and the worker never spoke — the transform is not delivering"
        : codec === null
        ? `no frame in 10s; ${gated} frames reached the worker but the codec was never resolved`
        : "no frame in 10s; the codec resolved but nothing decoded";
      teardown(why);
      opts.onFatal(error!);
    }
  }, FIRST_FRAME_TIMEOUT_MS);

  worker.onmessage = (e: MessageEvent) => {
    if (stopped) return;
    workerMessages++;
    const d = e.data as { type?: string; frame?: FrameLike; mediaMs?: number; arrivalMs?: number; decodeMs?: number;
                          hopMs?: number; keys?: string[];
                          codec?: string; message?: string; reason?: string };
    if (d.type === "metadataKeys") { metadataKeys = d.keys ?? []; return; }
    if (d.type === "boot" || d.type === "ready") {
      // Spent before this pacer existed; harmless if a future change re-emits them.
    } else if (d.type === "frame" && d.frame) {
      incoming++;
      sized = true;
      // ARRIVAL IS STAMPED HERE, ON THE MAIN THREAD, and the worker's own stamp is ignored.
      //
      // A dedicated worker has its OWN `performance.timeOrigin` — its creation time, not the page's —
      // so a timestamp taken there is in a different timebase from the `requestAnimationFrame` clock
      // `pick()` compares against. Mixing them makes every frame's target land ~1.8e12 ms in the
      // future: measured as 898 frames decoded, 890 dropped for queue overflow, and not one
      // presented. The postMessage hop costs a small, roughly constant delay, which the pacer's
      // minimum-delay offset absorbs completely.
      if (typeof d.decodeMs === "number") { decodeMs.push(d.decodeMs); if (decodeMs.length > 600) decodeMs.shift(); }
      if (typeof d.hopMs === "number") { hopMs.push(d.hopMs); if (hopMs.length > 600) hopMs.shift(); }
      pacer.push({ frame: d.frame, mediaMs: d.mediaMs ?? 0, arrivalMs: performance.now(), decodedAbs: d.arrivalMs });
    } else if (d.type === "config") {
      if (codec !== null && codec !== d.codec) note(`recodec ${codec} -> ${d.codec}`);
      else if (codec === null) note(`config ${d.codec}`);
      codec = d.codec ?? null;
    } else if (d.type === "skipped") {
      // A frame refused for a lost reference. One IDR resumes the chain; the requester debounces.
      skipped++;
      if (skipped <= 3 || skipped % 500 === 0) note(`skipped: ${d.reason ?? "?"} (#${skipped})`);
      askKeyframe();
    } else if (d.type === "needKeyframe") {
      // Every gated frame posts one of these, so `gated` counts frames that REACHED the worker and
      // were refused for want of an IDR — the difference between "the transform is not delivering"
      // and "it is delivering and no keyframe ever came", which look identical from outside.
      gated++;
      keyframeRequests++;
      if (gated <= 3 || gated % 200 === 0) note(`needKeyframe: ${d.reason ?? "?"} (#${gated})`);
      askKeyframe();
    } else if (d.type === "fatal") {
      note(`FATAL ${d.message ?? "?"}`);
      teardown(d.message ?? "worker reported a fatal error");
      opts.onFatal(error!);
    } else if (d.type === "error") {
      // TRANSIENT. `error` means THIS RENDERER IS DEAD and is set only by teardown; a decode error is
      // now recovered from in the worker (the decoder is replaced and an IDR requested), so recording
      // it here would report a live, self-healing path as failed.
      recovered++;
      note(`recovered: ${d.message ?? "?"}`);
    }
  };
  worker.onerror = (e) => { teardown(`worker error: ${e.message}`); opts.onFatal(error!); };
  worker.postMessage({ type: "init", codecMap: [...opts.codecMap], fallbackCodec: opts.fallbackCodec });

  /// ATTACHED ONLY AFTER THE WORKER SAYS IT IS READY, and that ordering is the whole feature.
  ///
  /// `new RTCRtpScriptTransform(worker, …)` on a worker that has not finished evaluating its module
  /// silently never delivers: the `rtctransform` event is dispatched before `onrtctransform` is
  /// installed, and it is dropped rather than queued. Measured — the worker boots, reports ready,
  /// the receiver's `transform` property reads non-null on the correct live track, and
  /// `onrtctransform` never fires once.
  ///
  /// It is easy to miss because a module worker's imports resolve asynchronously, so the gap is real
  /// but tiny, and because a throwaway probe that creates its worker at page load and attaches
  /// seconds later works perfectly — which is exactly how this was first written and why the bug took
  /// a while to corner.
  ///
  /// Still well before RTP: the first frames wait on the answer, ICE and DTLS.
  const attachTransform = (): void => {
    // BOTH conditions. The worker must have installed `onrtctransform`, and the negotiation that
    // produced this receiver must have finished — attaching from inside `setRemoteDescription`
    // silently never delivers.
    if (stopped || transformAttached) return;
    transformAttached = true;
    try {
      (receiver as unknown as { transform: unknown }).transform = new RST(worker, { forward: opts.forward !== false, carrier: opts.carrier === true });
    } catch (err) {
      teardown(`transform attach failed: ${String(err)}`);
      opts.onFatal(error!);
      return;
    }
    // The decoder must start on an IDR. The host emits one when the encoder is built, but attaching
    // to an already-running track (a reconnect, a second window) misses it — so ask, rather than wait.
    askKeyframe();
    keyframeRequests++;
  };

  // IMMEDIATELY. The worker came from the pool already warmed, so there is nothing to wait for — and
  // waiting is precisely what broke this before, by pushing the attach past `createAnswer`.
  // THROWAWAY SPIKE: the DataChannel arm has no transform to attach — its frames arrive by
  // `pushEncoded`. It still asks for an IDR, because its decoder starts just as empty as this one's.
  if (opts.feed === "datachannel") { askKeyframe(); keyframeRequests++; }
  else attachTransform();

  const onRaf = (t: number): void => {
    if (stopped) return;
    if (lastRaf) {
      rafGaps.push(t - lastRaf); if (rafGaps.length > 240) rafGaps.shift();
      display.observe(t - lastRaf);
    }
    lastRaf = t;
    // HOW LONG OUR OWN CALLBACK TAKES, which is the one thing that separates the two explanations for
    // a skipped vsync — and they need opposite fixes.
    //
    // Safari skips 3-4 consecutive refreshes a few times a window (worst=5x, ~67ms of frozen picture)
    // while Chrome skips none. `starve=0` says the frames were ready, and `mainLate=3ms` says nothing
    // blocked the main thread for anything like 67ms — a 250ms ticker would have caught that. So the
    // callback is simply not being CALLED, and the question is whether we are making it expensive
    // (a GPU-bound drawImage does not show up as thread lateness) or whether the compositor is
    // choosing not to run us.
    //
    // Expensive draw -> move presentation to an OffscreenCanvas in the worker. Cheap draw -> it is
    // the compositor, and the levers are the canvas size and the <video> layer underneath it.
    const drawStart = performance.now();
    const picked = pacer.pick(t, refreshMs());
    if (picked) {
      const f = picked.frame;
      if (canvas.width !== f.displayWidth || canvas.height !== f.displayHeight) {
        canvas.width = f.displayWidth; canvas.height = f.displayHeight;
      }
      // A FRAME IS CLOSED EXACTLY ONCE, including when drawImage throws — VideoFrames pin GPU memory
      // and a leaked one stalls the decoder rather than erroring.
      try {
        ctx.drawImage(f as unknown as CanvasImageSource, 0, 0);
        if (opts.probe && ++sinceProbe >= PROBE_EVERY) {
          sinceProbe = 0;
          if (!probeScratch) {
            const c = document.createElement("canvas");
            const cx = c.getContext("2d", { willReadFrequently: true });
            if (cx) probeScratch = { canvas: c, ctx: cx };
          }
          if (probeScratch) {
            // FROM THE VISIBLE CANVAS, not the VideoFrame: this measures what was actually drawn, and
            // the frame is closed immediately after.
            const s = sampleG2gFromSource(canvas, canvas.width, canvas.height, probeScratch, t);
            if (s) {
              g2gMs.push(s.g2gMs); if (g2gMs.length > 600) g2gMs.shift();
              // THE SPLIT, and it needs no clock synchronisation: `hold` is two instants on the
              // client's own epoch, so g2g minus hold is everything upstream of the decoder output —
              // host capture, encode, wire, depacketize and decode together. Attacking the wrong one
              // of those two is the whole reason this is measured rather than reasoned about.
              if (picked.decodedAbs !== undefined) {
                holdMs.push(performance.timeOrigin + t - picked.decodedAbs);
                if (holdMs.length > 600) holdMs.shift();
              }
            } else probeDecodeFails++;
          }
        }
      } finally { f.close(); }
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
      if (firstMediaMs === null) { firstMediaMs = picked.mediaMs; firstWallMs = t; }
      lastMediaMs = picked.mediaMs; lastWallMs = t;
      lastPresentAt = t;
    }
    if (picked) {
      const spent = performance.now() - drawStart;
      drawMs.push(spent);
      if (drawMs.length > 600) drawMs.shift();
    }
    rafHandle = requestAnimationFrame(onRaf);
  };
  // NOT STARTED YET — see attachCanvas. Queueing without presenting is correct in the gap between
  // the track arriving and its window existing; the queue cap bounds it.

  /// STALL WATCHDOG. Under sustained loss the encoded-frame stream has been observed to stop
  /// delivering for good — the pipe alive, the host still sending, and every counter frozen. Rather
  /// than leave that as a dead window that only a page reload fixes, notice it and rebuild the whole
  /// capture: a fresh worker and a fresh transform. AGENTS.md already records the absence of a
  /// frame-arrival watchdog as a KNOWN GAP; this is one for the receive path.
  ///
  /// Only while VISIBLE: a hidden tab legitimately receives ~1fps (the host re-rates it), and a
  /// backgrounded page would otherwise rebuild itself continuously.
  let lastSeen = 0;
  let lastSeenAt = performance.now();
  const watchdog = setInterval(() => {
    if (stopped || document.hidden) { lastSeenAt = performance.now(); return; }
    if (incoming !== lastSeen) { lastSeen = incoming; lastSeenAt = performance.now(); return; }
    if (performance.now() - lastSeenAt < STALL_TIMEOUT_MS) return;
    note(`STALL — no frame for ${Math.round(STALL_TIMEOUT_MS / 1000)}s, rebuilding`);
    lastSeenAt = performance.now();
    opts.onStall();
  }, 1000);

  // rAF stops entirely in a hidden tab while frames keep arriving, and VideoFrames pin GPU memory.
  const onVisibility = (): void => { if (document.hidden) { pacer.reset(); lastPresentAt = null; } };
  document.addEventListener("visibilitychange", onVisibility);

  return {
    /// Re-send the negotiated payload-type map.
    ///
    /// LOAD-BEARING. The map is read from `pc.localDescription`, and the pacer is created at
    /// `ontrack` — which fires DURING `setRemoteDescription`, before the answer exists. At that point
    /// the description carries no video rtpmap at all, so `payloadType` resolves to nothing, the
    /// worker refuses every frame INCLUDING keyframes, and the gate never opens. Measured: 600
    /// keyframe requests in ten seconds, the host dutifully producing IDRs, and not one accepted.
    updateCodecMap(map: Map<number, string>, fallback: string | null): void {
      if (stopped) return;
      worker.postMessage({ type: "init", codecMap: [...map], fallbackCodec: fallback });
    },
    /// THROWAWAY SPIKE — one access unit from the host's mirror channel.
    ///
    /// TRANSFERRED, NOT COPIED. A structured clone of every frame at 60 fps would put a memcpy on the
    /// main thread inside the very interval this arm is trying to shorten, which is exactly the kind
    /// of instrument that creates what it reports. The caller must not touch `data` afterwards.
    pushEncoded(data: ArrayBuffer, rtp: number, key: boolean, payloadType: number): void {
      if (stopped) return;
      // `incoming` IS NOT TOUCHED HERE. It counts DECODED frames arriving back from the worker, and
      // incrementing it on the way in as well double-counted this arm — reported 3600 against the
      // transform arm's 1800 for the same 1800 frames, which looks like the DataChannel delivering
      // twice as much and is purely the instrument. The stall watchdog reads the same counter and is
      // still fed by the return path.
      worker.postMessage({ type: "chunk", data, rtp, key, payloadType }, [data]);
    },
    /// Put the canvas into this window and begin presenting. Idempotent, and safe to call before any
    /// frame has decoded.
    attachCanvas(video: HTMLVideoElement): void {
      if (stopped || canvas.parentElement) return;
      const parent = video.parentElement;
      if (!parent) return;
      // The <video> is left in place and simply never gets frames: the transform consumed them, so
      // its decoder is starved and it paints nothing while the canvas above it is what is seen. Its
      // box is the `#screen` anchor e2e takes tap coordinates from, so it must not be removed.
      parent.appendChild(canvas);
      if (!rafHandle) rafHandle = requestAnimationFrame(onRaf);
    },
    stop(): void { teardown(); },
    setMargin(ms: number | "auto"): void { margin = ms; pacer.setMargin(ms); },
    stats(): PacedRenderStats {
      const s = pacer.stats();
      return {
        mode: "webcodecs", incoming, presented: s.presented, starve: s.starve, dropped: s.dropped,
        queueMax: s.queueMax, offsetMs: s.offsetMs, waiting: s.waiting, empty: s.empty, refreshMs: refreshMs(), marginMs: pacer.marginMs(),
        sourcePeriodMs: pacer.sourcePeriodMs(),
        display: display.stats(),
        draw: percentiles(drawMs),
        dwell: { ...dwell }, asked: { ...asked }, cadenceHit, cadenceMiss, cadence: pacer.cadence(), width: canvas.width, height: canvas.height,
        error, codec, keyframeRequests,
        ...({
          gated, workerMessages, recovered, skipped, log: [...log],
          g2g: percentiles(g2gMs), g2gSamples: g2gMs.length, probeDecodeFails,
          hold: percentiles(holdMs),   // decoded -> presented; g2g minus this is everything upstream
          decode: percentiles(decodeMs),   // inside VideoDecoder; upstream minus this is delivery
          hop: percentiles(hopMs), metadataKeys,   // assembly -> transform: the worker hop, isolated
          mediaSpanMs: firstMediaMs === null ? 0 : lastMediaMs - firstMediaMs,
          wallSpanMs: firstMediaMs === null ? 0 : lastWallMs - firstWallMs,
        } as unknown as Record<string, number>),
      };
    },
    resetStats(): void {
      pacer.resetStats();
      incoming = 0; keyframeRequests = 0;
      // INCLUDING THE g2g SAMPLES. Leaving them would let one arm of an A/B carry the previous arm's
      // latency into its own percentiles — measured doing exactly that across four margin settings,
      // where n grew 159 -> 289 -> 422 -> 562 and every arm after the first was contaminated.
      g2gMs.length = 0; holdMs.length = 0; decodeMs.length = 0; hopMs.length = 0; probeDecodeFails = 0; sinceProbe = 0;
      for (const k of Object.keys(asked)) delete asked[Number(k)];
      cadenceHit = 0; cadenceMiss = 0;
      for (const k of Object.keys(dwell)) delete dwell[Number(k)];
    },
  };
}

/// p50/p95/max of a sample set, or null when there is nothing to report.
///
/// NULL RATHER THAN ZERO. A probe that has decoded no timecode has measured nothing, and reporting
/// 0ms would claim a perfect pipeline about a run that never read the stamp — the same rule `[rx]`
/// follows for counters the browser did not supply.
