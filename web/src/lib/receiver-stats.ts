/**
 * The receiver's own view of an inbound video track — the one vantage point rdev has never used.
 *
 * IT EXISTS TO SEPARATE THREE EXPLANATIONS OF THE SAME SYMPTOM. A stream that stutters while the
 * host is asked for a keyframe roughly once a second can be losing packets, receiving them and
 * failing to DECODE them, or receiving them too late to use. The host cannot tell those apart: it
 * sees keyframe requests either way, and the sender's loss controller reads TWCC, which reports a
 * packet that ARRIVED and was then discarded locally as perfectly delivered.
 *
 *   packetsLost / nackCount        > 0  → real loss on the wire (and FEC should have helped)
 *   framesReceived >> framesDecoded     → the packets arrive and the decoder discards frames
 *   jitterBufferMs large                → frames arriving too late to use, which FEC cannot fix
 *
 * `pliCount` AND `firCount` together are the reconciliation: if the receiver's counts are far below
 * the host's `N requested`, the requests are not coming from this decoder at all and the search moves
 * elsewhere.
 *
 * BOTH, BECAUSE THE HOST ESCALATES ON EITHER. `readFrameTrackRTCP` turns a PictureLossIndication OR a
 * FullIntraRequest into a keyframe request, and the FIR arm is unconditional. Reporting only `pli`
 * made `pli=0` beside `5 requested` read as "the receiver asked for nothing" — which sent one
 * investigation into an elaborate story about packet reordering before anyone noticed the other half
 * of the question was simply not measured.
 */
export interface InboundVideoDiagnostics {
  ssrc: number | null;
  codec: string | null;
  packetsReceived: number | null;
  packetsLost: number | null;
  nackCount: number | null;
  pliCount: number | null;
  /// Full Intra Requests this receiver sent. A SEPARATE request type from PLI, and the host acts on
  /// it identically — so a session can be demanding keyframes with `pli` flat at zero.
  firCount: number | null;
  framesReceived: number | null;
  framesDecoded: number | null;
  framesDropped: number | null;
  keyFramesDecoded: number | null;
  freezeCount: number | null;
  totalFreezesSeconds: number | null;
  jitterSeconds: number | null;
  /// jitterBufferDelay / jitterBufferEmittedCount over the WHOLE SESSION, in ms. NULL rather than 0
  /// when nothing has been emitted: the raw accumulator is meaningless alone, and 0 would claim
  /// frames arrive instantly.
  ///
  /// A SESSION AVERAGE IS THE WRONG NUMBER TO READ LIVE, which is why the raw accumulators are kept
  /// beside it: both fields are cumulative, so a pathological opening minute drags this figure up
  /// long after the stream has recovered. `formatDiagnostics` windows it against the previous
  /// sample instead.
  jitterBufferMs: number | null;
  /// The raw accumulators, so consecutive samples can be differenced.
  jitterBufferDelaySeconds: number | null;
  jitterBufferEmittedCount: number | null;
  /// What FEC is costing on the wire, and the media it is measured against. All cumulative.
  bytesReceived: number | null;
  fecPacketsReceived: number | null;
  fecBytesReceived: number | null;
}

/// The share of received video bandwidth spent on FEC repair, over the window between two samples.
///
/// WINDOWED, NEVER CUMULATIVE. Both counters run for the life of the connection, so their raw ratio
/// is a session average — which reports a burst from a minute ago as though it were happening now.
/// The footer shows a LIVE value, so it must be a window; this is the same mistake the `[rx]` report
/// made with its jitter buffer, corrected there for the same reason.
///
/// BYTES WHEN THE BROWSER REPORTS THEM, PACKETS OTHERWISE. The question is a bandwidth share, so
/// bytes answer it directly; packets are a reasonable stand-in because repair packets run near MTU,
/// and they are also what the host's own `[bridge] fec:` line counts — so the two readings can be
/// compared. Returns null when neither is available or nothing arrived in the window: an absent
/// measurement must not render as 0%, which would claim FEC is off.
export function fecBandwidthFraction(
  cur: InboundVideoDiagnostics,
  prev?: InboundVideoDiagnostics,
): number | null {
  const delta = (pick: (x: InboundVideoDiagnostics) => number | null): number | null => {
    const now = pick(cur);
    if (now === null) return null;
    const was = prev ? pick(prev) : null;
    if (was === null) return now;
    return now < was ? null : now - was;
  };
  const fecBytes = delta((x) => x.fecBytesReceived);
  const mediaBytes = delta((x) => x.bytesReceived);
  if (fecBytes !== null && mediaBytes !== null && fecBytes + mediaBytes > 0) {
    return fecBytes / (fecBytes + mediaBytes);
  }
  const fecPackets = delta((x) => x.fecPacketsReceived);
  const mediaPackets = delta((x) => x.packetsReceived);
  if (fecPackets !== null && mediaPackets !== null && fecPackets + mediaPackets > 0) {
    return fecPackets / (fecPackets + mediaPackets);
  }
  return null;
}

/// EVERY FIELD IS `number | null`, AND null MEANS THE BROWSER DID NOT REPORT IT. Not every engine
/// implements every counter and Safari is the receiver being diagnosed here, so defaulting a missing
/// one to 0 would report "no frames dropped, no freezes" about a browser that simply never said —
/// the strongest possible reading of the evidence, invented rather than measured.
function num(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function inboundVideoDiagnostics(report: RTCStatsReport): InboundVideoDiagnostics[] {
  const out: InboundVideoDiagnostics[] = [];
  report.forEach((r) => {
    const s = r as Record<string, unknown>;
    // `remote-inbound-rtp` is the REMOTE end's view of what WE send, carried in its receiver
    // reports — the opposite direction, and its packetsLost would answer a different question.
    if (s.type !== "inbound-rtp" || s.kind !== "video") return;
    const codecId = typeof s.codecId === "string" ? s.codecId : undefined;
    const codec = codecId
      ? ((report.get(codecId) as { mimeType?: string } | undefined)?.mimeType ?? null)
      : null;
    const delay = num(s.jitterBufferDelay);
    const emitted = num(s.jitterBufferEmittedCount);
    out.push({
      ssrc: num(s.ssrc),
      codec,
      packetsReceived: num(s.packetsReceived),
      packetsLost: num(s.packetsLost),
      nackCount: num(s.nackCount),
      pliCount: num(s.pliCount),
      firCount: num(s.firCount),
      framesReceived: num(s.framesReceived),
      framesDecoded: num(s.framesDecoded),
      framesDropped: num(s.framesDropped),
      keyFramesDecoded: num(s.keyFramesDecoded),
      freezeCount: num(s.freezeCount),
      totalFreezesSeconds: num(s.totalFreezesDuration),
      jitterSeconds: num(s.jitter),
      jitterBufferMs: delay !== null && emitted !== null && emitted > 0 ? (delay / emitted) * 1000 : null,
      jitterBufferDelaySeconds: delay,
      jitterBufferEmittedCount: emitted,
      bytesReceived: num(s.bytesReceived),
      fecPacketsReceived: num(s.fecPacketsReceived),
      fecBytesReceived: num(s.fecBytesReceived),
    });
  });
  return out;
}

/// Render the diagnostics as ONE line for the host log.
///
/// The client renders it because the client is the only holder of these numbers — the host has no
/// independent view to reconcile them against, so passing a rendered line through is honest rather
/// than lazy, and it keeps fourteen optional counters out of the wire schema.
///
/// A MISSING COUNTER PRINTS `?`, NEVER 0. Safari does not implement every one of these, and a 0
/// would read as "no frames dropped, no freezes" about a browser that never said. The whole point of
/// the reading is lost if absence and zero look alike.
/// Render one WINDOW of the receiver's counters as a single line for the host log.
///
/// WINDOWED, NOT CUMULATIVE, and that is a correction rather than a preference. Every field
/// getStats() returns here is a running total, so a session that opened badly reports its opening
/// forever: a real iPad showed `jbuf=843ms` long after the stream had recovered, because the average
/// still carried a keyframe storm from a minute earlier. Deltas say what is happening NOW, which is
/// the same reasoning the `[bridge] fec:` reporter already applies to its counters.
///
/// `targetMs` is what the client ASKED the receiver to buffer, printed beside what it actually did.
/// `transport` is p2p or relay — WITHOUT IT THE NUMBERS ARE UNREADABLE AFTER THE FACT, because a
/// relayed TCP path and a LAN path produce entirely different figures from identical code, and
/// nothing else in the log says which one a session used.
/// The `<video>` element's OWN playback state, which no `getStats` counter describes.
///
import type { Cadence } from "./presentation-cadence";

/// EVERY FIELD IN `InboundVideoDiagnostics` DESCRIBES THE DECODER. A media element can decode
/// perfectly and present nothing — and when it does, `frames`, `dropped`, `freeze`, `lost` and `pli`
/// all read healthy while the user is looking at a still image. That is not hypothetical: it arrived
/// as a report whose host log showed frames=300/300, dropped=0, freeze=0, encoder at 59.8fps and a
/// jitter buffer that had already recovered to 0.9ms.
export interface ElementPlayback {
  /// Frames the element actually PRESENTED across this window, counted by
  /// `requestVideoFrameCallback` — the only browser API that reports paint rather than decode.
  ///
  /// NOT `currentTime`. For `srcObject = MediaStream` that property is a WALL CLOCK: it advances
  /// whether or not a single new frame is painted, so an earlier version of this field reported
  /// "playing 100%" over a picture the reporter was looking at, frozen. And NOT `framesDecoded`,
  /// which is the decoder's count — an element can decode every frame and paint none.
  presented: number | null;
  /// The WALL time this window covered, so `presented` can be expressed as a rate.
  elapsedMs: number | null;
  readyState: number | null;
  paused: boolean | null;
  /// How many times this client has re-attached a frozen element THIS SESSION. Reported so the host
  /// log shows whether the self-heal fired: the rebind happens in the client and otherwise leaves no
  /// trace the reporter of a bug can see, which makes "it did not help" indistinguishable from "it
  /// never ran" and from "that build predates it".
  rebinds?: number;
  /// How EVENLY those frames were painted. `presented` is a RATE, and a rate averages judder away:
  /// two streams painting 54.5fps looked plainly different to a reporter while this line reported
  /// them identically. Absent when the window held too few samples to describe.
  cadence?: Cadence | null;
  /// How unevenly the frames ARRIVED — p98 minus minimum of each presented frame's arrival against
  /// its own RTP timestamp, over the last four seconds (`playout-floor.ts`). THE INPUT to the jitter
  /// buffer, where `cadence` above is its output. Null when the browser supplied no arrival times —
  /// which is UNKNOWN, never a clean path.
  arrivalSpreadMs?: number | null;
  /// The playout-delay floor in force and whose choice it was. Read beside `arr` and `jbuf`: the
  /// three together say what the path demanded, what rdev asked for and what the receiver held.
  /// `window` true means the client asked for a fixed WINDOW (min = max) rather than a floor under
  /// the configured ceiling — see `playout-floor.ts`, "THE WINDOW".
  floor?: { ms: number; auto: boolean; window?: boolean } | null;
}

export function formatDiagnostics(
  cur: InboundVideoDiagnostics[],
  prev: InboundVideoDiagnostics[] = [],
  opts: { targetMs?: number; transport?: string; element?: ElementPlayback | null } = {},
): string {
  // `paused` is checked BEFORE `advancedMs`, because a paused element also has a still clock and the
  // two want different responses — one is a bug to chase, the other is the user having stopped it.
  const el = opts.element;
  const elField = !el ? [] : (() => {
    // PRESENTED frames per second. This is the picture's own rate, and the only number on this line
    // that is not about the decoder.
    // `drift` FIRST, because it is the one that means judder. The gap figures beside it describe the
    // SOURCE as much as the transport — a content-driven window legitimately produces long gaps with
    // no drift at all — and reading them as damage is what sent an adaptive floor to its ceiling.
    const cadence = el.cadence
      ? ` drift=${el.cadence.offsetSpreadMs === null ? "?" : `${el.cadence.offsetSpreadMs.toFixed(1)}ms`}`
        + ` gaps=${el.cadence.p50Ms.toFixed(1)}/${el.cadence.p95Ms.toFixed(1)}ms`
        + ` skips=${el.cadence.skips}/${el.cadence.count}`
      : "";
    // `arr` beside `floor`: the demand and the response. Either is omitted only when the client did
    // not measure at all; a measured-but-unavailable spread prints `?`.
    const arrival = el.arrivalSpreadMs === undefined ? ""
      : ` arr=${el.arrivalSpreadMs === null ? "?" : `${el.arrivalSpreadMs.toFixed(1)}ms`}`;
    const floor = !el.floor ? "" : ` floor=${el.floor.window ? "window" : el.floor.auto ? "auto" : "pinned"}:${el.floor.ms}ms`;
    const fps = el.presented === null || !el.elapsedMs
      ? null
      : (el.presented / el.elapsedMs) * 1000;
    // `paused` FIRST: a paused element also presents nothing, and the two want opposite responses —
    // one is a bug to chase, the other is the user having stopped it.
    const word = el.paused === true ? "paused"
      : fps === null ? "?"
      : fps < 1 ? "FROZEN"
      : fps < 20 ? "SLOW"
      : "playing";
    // Absent when zero: a healthy session should carry no noise, and a non-zero count is a finding.
    const rebinds = el.rebinds ? ` rebinds=${el.rebinds}` : "";
    return [`el=${word}${fps === null ? "" : ` ${fps.toFixed(1)}fps`}${cadence}${arrival}${floor} rs=${el.readyState === null ? "?" : el.readyState}${rebinds}`];
  })();
  const n = (v: number | null, digits = 0) => (v === null ? "?" : v.toFixed(digits));
  // A COUNTER THAT WENT BACKWARDS REPORTS NOTHING RATHER THAN A NEGATIVE: the SSRC can be replaced
  // by a renegotiation, and a wrapped subtraction would read as a catastrophe.
  const delta = (a: number | null, b: number | null): number | null =>
    a === null || b === null || a < b ? a : a - b;

  return cur.map((d) => {
    const was = prev.find((p) => p.ssrc === d.ssrc);
    const w = (pick: (x: InboundVideoDiagnostics) => number | null) =>
      was ? delta(pick(d), pick(was)) : pick(d);
    // The window's own average hold time, not the session's.
    const heldSeconds = w((x) => x.jitterBufferDelaySeconds);
    const emitted = w((x) => x.jitterBufferEmittedCount);
    const jbuf = heldSeconds !== null && emitted !== null && emitted > 0
      ? (heldSeconds / emitted) * 1000
      : null;
    return [
      `ssrc=${n(d.ssrc)}`,
      (d.codec ?? "?").replace(/^video\//, ""),
      ...(opts.transport ? [`via=${opts.transport}`] : []),
      `rx=${n(w((x) => x.packetsReceived))}`,
      `lost=${n(w((x) => x.packetsLost))}`,
      `nack=${n(w((x) => x.nackCount))}`,
      `pli=${n(w((x) => x.pliCount))}`,
      `fir=${n(w((x) => x.firCount))}`,
      // decoded/received is the discriminating pair: a wide gap is the receiver discarding frames it
      // was given, which is invisible to the sender because TWCC reported them as delivered.
      `frames=${n(w((x) => x.framesDecoded))}/${n(w((x) => x.framesReceived))}`,
      `dropped=${n(w((x) => x.framesDropped))}`,
      `kf=${n(w((x) => x.keyFramesDecoded))}`,
      `freeze=${n(w((x) => x.freezeCount))}/${n(w((x) => x.totalFreezesSeconds), 1)}s`,
      `jbuf=${jbuf === null ? "?" : jbuf.toFixed(1)}ms`,
      `jitter=${d.jitterSeconds === null ? "?" : (d.jitterSeconds * 1000).toFixed(1)}ms`,
      ...(opts.targetMs === undefined ? [] : [`target=${opts.targetMs}ms`]),
      ...elField,
      // The first sample has nothing to subtract; saying so beats showing a session's opening burst
      // as if it were a steady state.
      ...(was ? [] : ["(since start)"]),
    ].join(" ");
  }).join(" · ");
}


/// The receiver's own inbound-AUDIO counters, summarised for the `[rx]` line.
///
/// SESSION-WIDE, NOT PER SOURCE, AND THAT IS DELIBERATE. An audio SSRC is a separate `inbound-rtp`
/// entry from its window's video, and rdev puts audio on its OWN MSID — so relating one back to a
/// source id would mean inventing a track-to-stream correspondence from `trackIdentifier`. Only one
/// source carries audio at a time anyway (the ownership election), so a summary loses nothing real
/// and cannot be quietly wrong about which window it describes.
///
/// EVERY FIELD IS `number | null` AND null MEANS THE BROWSER DID NOT REPORT IT. Defaulting to 0
/// would claim "no loss, no concealment" about a browser that never said — the rule every counter
/// on this line already follows.
///
/// Returns `aud=?` when there is no inbound audio report at all, NEVER `aud=0`: no report and a
/// silent stream are different facts, and `arr=?` already carries that distinction for the floor.
export function formatAudioDiagnostics(report: RTCStatsReport): string {
  let found = false;
  let packets: number | null = null;
  let lost: number | null = null;
  let concealed: number | null = null;
  let total: number | null = null;
  let jitterMs: number | null = null;
  let energy: number | null = null;
  report.forEach((raw) => {
    const s = raw as Record<string, unknown> & { type?: string; kind?: string };
    if (s.type !== "inbound-rtp" || s.kind !== "audio") return;
    found = true;
    const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
    const add = (a: number | null, b: number | null) => (a === null ? b : b === null ? a : a + b);
    packets = add(packets, num(s.packetsReceived));
    lost = add(lost, num(s.packetsLost));
    concealed = add(concealed, num(s.concealedSamples));
    total = add(total, num(s.totalSamplesReceived));
    energy = add(energy, num(s.totalAudioEnergy));
    const delay = num(s.jitterBufferDelay);
    const emitted = num(s.jitterBufferEmittedCount);
    if (delay !== null && emitted !== null && emitted > 0) jitterMs = (delay / emitted) * 1000;
  });
  if (!found) return "aud=?";
  const n = (v: number | null) => (v === null ? "?" : String(v));
  const conceal = concealed === null || total === null || total === 0
    ? "?"
    : `${((concealed / total) * 100).toFixed(2)}%`;
  const jbuf = jitterMs === null ? "?" : `${(jitterMs as number).toFixed(1)}ms`;
  // `aenergy` IS THE ONLY FIELD THAT SEPARATES SOUND FROM SILENCE, and every other counter on this
  // line is satisfied by a perfectly delivered stream of zeroes — which is what a broken framer, a
  // refused encode or a mis-scoped interceptor all produce. totalAudioEnergy is computed from the
  // DECODED samples, so a non-zero value means the receiver really heard something.
  // Cast for the same reason `jitterMs` needs one: TS cannot see the assignment inside the
  // forEach closure, so it narrows the declared type away to `never`.
  const e = energy === null ? "?" : (energy as number).toFixed(3);
  return `aud=${n(packets)} alost=${n(lost)} aconceal=${conceal} ajbuf=${jbuf} aenergy=${e}`;
}
