/// Runs the receive-side encoded transform and a VideoDecoder for ONE source, and transfers each
/// decoded VideoFrame to the main thread, where the pacer decides when to draw it.
///
/// ONE WORKER PER SOURCE. `RTCRtpScriptTransform` takes a Worker in its constructor and dispatches to
/// that worker's global `onrtctransform`, so N sources through one worker would mean demultiplexing
/// by the options bag and sharing one event loop between N decoders.
///
/// FRAMES ARE FORWARDED to `transformer.writable` as well as decoded here. This header used to say
/// the opposite — that we never write, and that the browser therefore stops sending PLIs — and BOTH
/// halves were wrong. Starving the browser's decoder makes it request a keyframe FOREVER: measured on
/// loopback at zero loss, the host produced ten IDRs per five-second window, sustained at its
/// KeyframeDebounce floor, for a client that had asked for one. The browser decodes the stream too
/// and its output goes to the hidden `<video>` under our canvas, which is the price of a satisfied
/// receive pipeline.
///
/// NACK, RTX and FlexFEC are unaffected either way — they live BELOW the transform, in the RTP stack.
/// What we take over is decode and presentation only; `needKeyframe` and the host's `request-keyframe`
/// handler exist so our own decoder can ask for an IDR when ITS references are broken.
///
/// The project's tsconfig uses the DOM lib rather than WebWorker, so the worker globals and the
/// encoded-transform types are declared locally and reached through a cast on `self`.
import { KeyframeGate } from "./keyframe-gate";
import { DecoderSession } from "./decoder-session";
import { FrameReferenceTracker } from "./frame-references";

interface EncodedVideoFrameLike {
  readonly type: "key" | "delta";
  readonly timestamp: number;                    // the RTP timestamp, 90kHz
  readonly data: ArrayBuffer;
  getMetadata?(): {
    payloadType?: number; frameId?: number; dependencies?: readonly number[];
    /// The instant the browser finished ASSEMBLING this frame, on the same epoch as
    /// `performance.timeOrigin + performance.now()`. Where it exists it splits the delivery span in
    /// two — "the browser was slow to assemble" against "the browser had it and we got it late" —
    /// which is otherwise one opaque number and the largest term in the whole latency budget.
    /// Optional and engine-specific: absent means the split is unavailable, never that it was zero.
    receiveTime?: number;
  };
}
interface Transformer {
  readonly readable: ReadableStream<EncodedVideoFrameLike>;
  /// Frames written here continue to the browser's own decoder. Writing NOTHING starves it, and a
  /// starved decoder asks for a keyframe forever — see the pipe below for the measurement.
  readonly writable: WritableStream<EncodedVideoFrameLike>;
}
interface TransformEvent { readonly transformer: Transformer }

const wself = self as unknown as {
  onmessage: ((e: MessageEvent) => void) | null;
  onrtctransform: ((e: TransformEvent) => void) | null;
  postMessage(message: unknown, transfer?: Transferable[]): void;
};

// BOOT SIGNAL, first thing after the module graph resolves. `onrtctransform` is only installed once
// this module has evaluated, so "the worker never spoke" is ambiguous between "it never loaded" and
// "it loaded and the transform never delivered". This separates them.
wselfBoot();
function wselfBoot(): void {
  (self as unknown as { postMessage(m: unknown): void }).postMessage({ type: "boot" });
}

const gate = new KeyframeGate();
const refs = new FrameReferenceTracker();
let codecMap = new Map<number, string>();
let fallbackCodec: string | null = null;
let session: DecoderSession<VideoDecoder> | undefined;
let lastGeneration = 0;

// The media clock, unwrapped across the 32-bit RTP boundary. A uint32 at 90kHz wraps every ~13.25
// hours; a raw value would jump backwards by 47721 seconds and the pacer's never-go-backwards guard
// would then refuse every later frame — the picture freezes for good, hours in, with no error.
/// Chunk-enqueue instants, keyed by the microsecond timestamp handed to the decoder. Bounded: a frame
/// the decoder never emits (a dropped reference, a flush) would otherwise leak an entry per frame.
const enqueuedAt = new Map<number, number>();
/// Assembly -> transform-callback, per frame, when the engine reports `receiveTime`. THE WORKER HOP,
/// isolated: everything before it is the browser's receive path, everything after is ours.
const receiveAt = new Map<number, number>();
const MAX_PENDING_DECODES = 128;
let metadataReported = false;
let rtpPrev: number | null = null;
let rtpAcc = 0;

/// Re-gate and ask for an IDR. The decoder is NOT reset here: a VideoDecoder that reported an error
/// is closed, and `reset()` on it throws. `DecoderSession.failed()` is what discards it.
function needKeyframe(reason: string): void {
  gate.reset();
  refs.reset();
  wself.postMessage({ type: "needKeyframe", reason });
}

function onDecoded(frame: VideoFrame): void {
  // OWNERSHIP MOVES WITH THE TRANSFER — the main thread closes it after drawing, or the pacer closes
  // it when it is skipped. Closing here would hand over a detached frame.
  // How long THIS frame spent inside VideoDecoder, keyed by the timestamp the decoder echoes back.
  // Decode is pipelined, so this is per-frame residency, not a serial cost — but it is what separates
  // "the browser is slow to hand us the bytes" from "the decode itself is expensive", which are
  // different problems with different fixes.
  const enq = enqueuedAt.get(frame.timestamp);
  if (enq !== undefined) enqueuedAt.delete(frame.timestamp);
  const recv = receiveAt.get(frame.timestamp);
  if (recv !== undefined) receiveAt.delete(frame.timestamp);
  wself.postMessage(
    { type: "frame", frame, mediaMs: frame.timestamp / 1000, arrivalMs: performance.timeOrigin + performance.now(),
      decodeMs: enq === undefined ? undefined : performance.timeOrigin + performance.now() - enq,
      hopMs: recv },
    [frame as unknown as Transferable],
  );
}

wself.onmessage = (e: MessageEvent) => {
  const d = e.data as {
    type?: string; codecMap?: Array<[number, string]>; fallbackCodec?: string | null;
    data?: ArrayBuffer; rtp?: number; key?: boolean; payloadType?: number;
  };
  // An access unit delivered over the DataChannel instead of
  // by the encoded transform. Everything downstream is UNCHANGED and that is the point: the same
  // decoder, the same pacer, the same g2g probe, so the only difference between this arm and the
  // transform arm is where the bytes came from.
  //
  // THE SYNTHESIZED METADATA CARRIES `payloadType` AND NOTHING ELSE, and both halves are deliberate.
  //
  // WITH payloadType, this arm resolves its codec by exactly the route the transform arm uses, so
  // the two differ only in transport. WITHOUT it — the first version — the lookup fell through to
  // `fallbackCodec`, which is view-set's activeCodec and never arrives for an eager track: measured
  // as 599 frames gated, `codec: null` and 600 keyframe requests, an arm failing for a reason that
  // had nothing to do with what was being compared. The host supplies it because the host is the one
  // that knows which payload type it packetised with.
  //
  // `frameId`/`dependencies` stay absent, which makes FrameReferenceTracker accept-everything — its
  // documented behaviour for an engine that does not describe its references. Reconstructing them
  // from the mirror would be inventing the thing under test.
  if (d.type === "chunk" && d.data && d.rtp !== undefined) {
    const metadata = { payloadType: d.payloadType };
    handleChunk({
      type: d.key ? "key" : "delta",
      timestamp: d.rtp,
      data: d.data,
      getMetadata: () => metadata,
    });
    return;
  }
  if (d.type !== "init") return;
  if (d.codecMap) codecMap = new Map(d.codecMap);
  if (d.fallbackCodec !== undefined) fallbackCodec = d.fallbackCodec;
  if (!session) {
    if (typeof VideoDecoder === "undefined") {
      // `VideoDecoder` is [SecureContext] per the W3C WebCodecs spec, so a plain-http origin has none
      // in Chromium. This is the ONE genuinely fatal case — everything else recovers in place.
      wself.postMessage({ type: "fatal", message: "VideoDecoder unavailable (WebCodecs needs a secure origin)" });
      return;
    }
    session = new DecoderSession<VideoDecoder>(() => new VideoDecoder({
      output: onDecoded,
      error: (err) => {
        // TERMINAL FOR THIS DECODER. WebCodecs closes the codec on error, so the instance is dead;
        // discard it and re-gate. The next keyframe builds a fresh one. This used to be treated as
        // fatal, which meant one lost reference frame killed the path until a page reload.
        wself.postMessage({ type: "error", message: String(err) });
        session?.failed();
        needKeyframe("decoder error");
      },
    }));
  }
};

wself.onrtctransform = (e: TransformEvent) => {
  // NOTHING IN THE TRANSFORM MAY THROW: a rejection aborts the pipe PERMANENTLY — the stream ends, no
  // further frame arrives, and the renderer is dead with no error anywhere. Every failure inside is
  // already recoverable; the wrapper below guarantees an unanticipated one degrades the same way.
  // FRAMES ARE FORWARDED, NOT CONSUMED — and this is not optional.
  //
  // Writing nothing to `transformer.writable` starves the browser's OWN decoder, and a starved
  // decoder asks for a keyframe forever. Measured on loopback with zero loss: the client requested
  // exactly ONE keyframe while the host produced TEN per five-second window — 2/s, the host's
  // KeyframeDebounce floor, sustained, burning 10% of the bitrate on IDRs nothing needed. Under loss
  // it compounds the storm.
  //
  // (This corrects the opposite claim made when this path was written: that consuming the transform
  // means the browser "never sends a PLI again". It sends them continuously.)
  //
  // The cost is that the browser decodes the stream too. Its output goes to the <video> underneath
  // our canvas and is never seen; what it buys is a satisfied receive pipeline and no PLI storm.
  // READ AND FORWARD ARE DECOUPLED — AND THIS DID NOT REDUCE LATENCY. Kept for what it removes, not
  // for a win it does not deliver.
  //
  // This was `readable.pipeThrough(ours).pipeTo(writable)`, which puts OUR decode behind the
  // BROWSER'S: backpressure from `transformer.writable` propagates back to `transformer.readable`,
  // and that writable feeds the browser's own decoder — the one decoding a copy we never look at. The
  // hypothesis was that its draining stalled our read side.
  //
  // FALSIFIED, twice. `receiveTime` puts assembly -> our transform callback at 7.40 ms p50 / 15.80 ms
  // p95, and it measured 7.50-7.60 after this change and 7.30 with forwarding disabled ALTOGETHER.
  // The browser's decode is not implicated: the ~7.4 ms is intrinsic to how Chromium delivers an
  // assembled frame to a worker's transform callback, and no arrangement of this code touches it.
  //
  // The shape stays because the coupling was real even if its cost was not measurable here — our
  // decode should not be able to block on a decode we discard — and because it is what let the
  // question be asked at all. Forwarding itself is NOT optional: starving the browser's decoder makes
  // it demand keyframes forever (measured: fps collapsing to 31.7 with 4 keyframes per window).
  const reader = e.transformer.readable.getReader();
  const writer = e.transformer.writable.getWriter();
  // BOUNDED, because "do not await" without a bound is just an unbounded queue. On backpressure we
  // stop FORWARDING rather than stop reading: a forwarded frame only feeds the decode we discard, so
  // dropping some costs nothing we can see, while blocking costs us the latency this change exists to
  // remove. The browser asks for a keyframe if it loses its reference chain, which is already handled.
  const MAX_PENDING_FORWARDS = 8;
  // EXPERIMENT ONLY (`?fwd=0`). Not forwarding makes the browser demand keyframes forever; this exists
  // to answer whether its decode costs us LATENCY, which the backpressure hypothesis failed to show.
  const forward = (e.transformer as unknown as { options?: { forward?: boolean } }).options?.forward !== false;

  // ---- CARRIER PROBE (`?carrier=1`) ------------------------------------------------------------
  //
  // THE QUESTION: can RTP be used as a plain packet transport — our payload read out here and never
  // given to the browser — while the browser's own decoder is kept quiet cheaply?
  //
  // Forwarding is not optional: a starved decoder demands keyframes forever (measured, fps to 31.7
  // with 4 keyframes per window). But it does not follow that it must be fed the REAL stream. If a
  // single independently-decodable frame, repeated slowly, satisfies it, then the real payload is
  // ours alone and the browser's decode stops costing us a whole second decode of every frame.
  //
  // A STASHED REAL KEYFRAME RATHER THAN A SYNTHESISED ONE, for the probe. A hand-built 16x16 IDR is
  // the eventual shape — it is far smaller — but synthesising a valid bitstream per codec is real
  // work, and it would be work spent before knowing whether the mechanism holds at all. The first
  // keyframe off the wire is guaranteed valid for whatever was negotiated, and it costs nothing to
  // obtain.
  //
  // The rate matters as much as the content: a 2 megapixel AV1 keyframe decoded sixty times a second
  // is not cheap. One per second is the question being asked — is a periodic still enough?
  const carrier = (e.transformer as unknown as { options?: { carrier?: boolean } }).options?.carrier === true;
  const CARRIER_FORWARD_EVERY_MS = 1000;
  let stashed: ArrayBuffer | null = null;
  let lastCarrierForwardMs = 0;
  let carrierForwards = 0;
  let pendingForwards = 0;
  void (async () => {
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        if (!value) continue;
        // OUR COPY FIRST. `handleChunk` builds an EncodedVideoChunk, which copies the buffer, so the
        // frame is still intact to forward. NOTHING HERE MAY THROW past this catch: a rejection would
        // end the loop and the renderer would die silently, which is the failure this guards.
        try {
          handleChunk(value);
        } catch (err) {
          wself.postMessage({ type: "error", message: `write: ${String(err)}` });
          session?.failed();
          needKeyframe("write threw");
        }
        if (carrier) {
          // Stash the first keyframe we see. `slice(0)` copies: the frame's own buffer is about to be
          // handed onward and must not be aliased by the thing we keep.
          const chunk = value as unknown as { type?: string; data: ArrayBuffer };
          if (stashed === null && chunk.type === "key") stashed = chunk.data.slice(0);
          // ONLY INTO A FRAME ALREADY TYPED `key`, and this is the finding the probe produced.
          //
          // `RTCEncodedVideoFrame.type` is READ-ONLY: `data` can be replaced, the type cannot. A
          // forward landing on a delta-typed frame therefore hands the browser keyframe bytes in a
          // frame its own depacketizer marked as a delta, it has no reference chain to decode that
          // against, and it drops the frame and sends a PLI. Measured: four forwards, TWO decoded
          // (both on real keyframes), two dropped, and pli=7-9 per five seconds — the "constant
          // keyframes" this probe was blamed for.
          //
          // The consequence for the carrier is the important part: the type has to be correct at the
          // RTP LAYER, because nothing on this side can correct it. Every carrier frame must be
          // marked a keyframe by the host — which is what makes the carrier stateless anyway.
          const nowMs = Date.now();
          if (stashed !== null && chunk.type === "key"
              && nowMs - lastCarrierForwardMs >= CARRIER_FORWARD_EVERY_MS
              && pendingForwards < MAX_PENDING_FORWARDS) {
            lastCarrierForwardMs = nowMs;
            // A FRESH COPY EACH TIME. Handing the same ArrayBuffer onward repeatedly risks it being
            // detached or consumed by the first write, and a detached buffer is silent.
            chunk.data = stashed.slice(0);
            pendingForwards++;
            carrierForwards++;
            writer.write(value)
              .catch(() => { /* the browser's decode is not ours to police */ })
              .finally(() => { pendingForwards--; });
          }
          // Everything else is dropped: the browser never sees the real stream at all.
        } else if (forward && pendingForwards < MAX_PENDING_FORWARDS) {
          pendingForwards++;
          writer.write(value)
            .catch(() => { /* the browser's decode is not ours to police */ })
            .finally(() => { pendingForwards--; });
        }
      }
      wself.postMessage({ type: "fatal", message: "the encoded-frame stream ended" });
    } catch (err) {
      wself.postMessage({ type: "fatal", message: `the encoded-frame stream failed: ${String(err)}` });
    }
  })();
};

function handleChunk(chunk: EncodedVideoFrameLike): void {
  {
    {
      if (!session) { wself.postMessage({ type: "needKeyframe", reason: "init not processed" }); return; }
      if (!gate.accept(chunk.type)) { wself.postMessage({ type: "needKeyframe", reason: "waiting for IDR" }); return; }

      // payloadType names the codec the SENDER actually chose, which is the honest answer; the
      // fallback is `view-set`'s activeCodec, for an engine that does not expose it. Both Chromium
      // and WebKit were measured exposing it on 2026-08-27.
      // REFUSE WHAT CANNOT BE DECODED, rather than letting the decoder discover it and close itself.
      // This is the difference between a lost packet costing one skipped frame and it costing a
      // decoder rebuild plus an IDR — see frame-references.ts for the measurement.
      const md = chunk.getMetadata?.();
      if (!metadataReported) {
        metadataReported = true;
        // REPORTED, NOT ASSUMED. `receiveTime` is engine-specific; naming the keys this browser
        // actually provides is what separates "the split is unavailable here" from "we asked wrong".
        wself.postMessage({ type: "metadataKeys", keys: md ? Object.keys(md) : [] });
      }
      if (!refs.accept({ type: chunk.type, frameId: md?.frameId, dependencies: md?.dependencies })) {
        // The chain is broken; only an IDR can resume it. The gate stays OPEN — the tracker already
        // refuses every delta until a keyframe, and closing the gate too would double-count.
        wself.postMessage({ type: "skipped", reason: "reference lost" });
        return;
      }
      const pt = md?.payloadType;
      const codec = (pt !== undefined ? codecMap.get(pt) : undefined) ?? fallbackCodec;
      if (!codec) { needKeyframe("codec unknown"); return; }

      // NO `description` anywhere: the depacketizer delivers Annex-B, so parameter sets are in band.
      let live: VideoDecoder;
      try {
        live = session.ready(codec);
      } catch (err) {
        // A configure that fails on a FRESH decoder is a real problem (an unsupported codec string),
        // but still not worth killing the path over — drop this decoder, ask for a keyframe and let
        // the next one try. Repeated failures surface as a stalled `incoming` count, not a dead page.
        wself.postMessage({ type: "error", message: `configure ${codec}: ${String(err)}` });
        session.failed();
        needKeyframe("configure failed");
        return;
      }
      if (session.generation !== lastGeneration) {
        lastGeneration = session.generation;
        wself.postMessage({ type: "config", codec });
      }

      if (rtpPrev === null) { rtpPrev = chunk.timestamp; rtpAcc = chunk.timestamp; }
      else {
        let delta = chunk.timestamp - rtpPrev;
        if (delta < -(2 ** 31)) delta += 2 ** 32;
        if (delta > 2 ** 31) delta -= 2 ** 32;
        rtpAcc += delta;
        rtpPrev = chunk.timestamp;
      }

      // MICROSECONDS — VideoFrame.timestamp echoes this back, and onDecoded divides it out again.
      const stampUs = Math.round((rtpAcc / 90) * 1000);
      if (enqueuedAt.size >= MAX_PENDING_DECODES) { enqueuedAt.clear(); receiveAt.clear(); }
      enqueuedAt.set(stampUs, performance.timeOrigin + performance.now());
      // THE HOP IS COMPUTED HERE, NOT ACROSS THE BOUNDARY. `receiveTime` is relative to THIS worker's
      // `performance.timeOrigin`, which is its own creation time and not the page's — subtracting it
      // from a main-thread instant would silently measure the difference between two epochs. Both
      // terms here share one origin.
      if (typeof md?.receiveTime === "number") receiveAt.set(stampUs, performance.now() - md.receiveTime);
      try {
        live.decode(new EncodedVideoChunk({
          type: chunk.type,
          timestamp: stampUs,
          data: chunk.data,
        }));
      } catch (err) {
        wself.postMessage({ type: "error", message: String(err) });
        session.failed();
        needKeyframe("decode threw");
      }
    }
  }
}

// HANDLER-INSTALLED SIGNAL. `boot` says the module started evaluating; this says `onrtctransform` is
// actually assigned. Between them sits every top-level statement that could throw — and the two
// together separate "the worker died mid-module" from "the handler is installed and the browser is
// not dispatching to it", which is otherwise pure guesswork.
wself.postMessage({ type: "ready" });
