/// One source's receive path: symbols in, whole frames out.
///
/// Owns the sliding-window decoder, the frame assembler and the integrity counters that sit
/// underneath the pacer's latency and smoothness numbers. Those three together are what separate
/// "the transport lost frames" from "the renderer mishandled frames it had".
import { RlcDecoder, fnv1a } from "./rlc";
import type { DcPacket } from "./dc-wire";

export interface CompleteFrame {
  frameSeq: number;
  /// The 90 kHz media clock, anchored by the host. The decoder paces on this.
  rtp: number;
  key: boolean;
  payloadType: number;
  data: ArrayBuffer;
}

interface FrameDescriptor {
  firstEsi: number;
  fragCount: number;
  frameBytes: number;
  rtp: number;
  key: boolean;
  payloadType: number;
  /// What the sender computed over the whole access unit. See the check in `harvest`.
  frameHash: number;
  /// How many frames back this frame's reference is. Zero means it references nothing.
  dependsOnOffset: number;
}

/// Reassembles frames from source and repair symbols, recovering losses through the code.
///
/// A FRAME'S DESCRIPTOR COMES FROM ANY ONE OF ITS SURVIVING SYMBOLS. Every source symbol carries its
/// own `esi` and `fragIndex`, so `firstEsi = esi - fragIndex` gives the whole frame's symbol range.
/// That is what lets a partially-lost frame still be assembled: the metadata is not stranded in the
/// packet that happened to die. Only a frame that loses EVERY source symbol is unrecoverable — at 2%
/// loss and 4 symbols, about 1.6e-7 — and that case shows up as a hole in the sequence span.
/// The narrowest and widest the wait may be, in frames. The floor is what a healthy link deserves —
/// three frames of slack after the one-frame request guard, so a retransmission on a fast path has
/// time to land. The ceiling is a second of video: past that this is not interactive by any
/// definition, and a link needing more needs a different answer than patience.
const REORDER_FRAMES_MIN = 4;
const REORDER_FRAMES_MAX = 60;
/// Report windows without a single late arrival before the wait narrows by one frame. Slow, because
/// giving patience back costs a discarded frame to learn again.
const PATIENT_WINDOWS_BEFORE_NARROWING = 6;

/// How far the stream may run ahead of a missing frame before it is declared lost rather than merely
/// reordered.
///
/// BOTH WAITS ARE COUNTED IN FRAMES, and that is the whole point. A retransmission is requested once
/// the stream has moved on by ONE frame (see `takeNackable`) and the frame is abandoned after this
/// many, so there are three frames — 50ms at 60fps — for the request and its answer to cross a link
/// whose round trip measures ~25ms. The relationship holds at any frame size.
///
/// It did not before. The request guard was counted in SYMBOLS and this deadline in FRAMES, which
/// agree only when a frame is about four symbols. A window whose content has stopped changing sends
/// ONE symbol per frame, so the guard became four FRAMES against a deadline of three: the frame was
/// abandoned before its retransmission had been asked for, and every loss turned into a keyframe
/// request for something ARQ would have covered. Reported from a live session as keyframe requests
/// starting whenever the window went behind another one.

/// A hard ceiling on one harvest, so no logic error in the loop can spin the main thread.
const MAX_HARVEST_FRAMES = 256;
/// How far back a hole is still worth asking about, matching the decoder's own history: past that
/// the symbol has been pruned and could not be used even if it arrived.
const NACK_LOOKBACK_SYMBOLS = 128;
/// Recent ARQ round trips kept for the percentile. A few seconds of them at any realistic loss rate.
const ARQ_SAMPLES = 64;
/// How many delivered frame sequences stay remembered, for checking references against.
const DELIVERED_MEMORY = 256;
/// How many requested ESIs stay remembered for de-duplication.
const REQUESTED_MEMORY = 1024;

export class DcSourceFeed {
  private decoder = new RlcDecoder();
  private frames = new Map<number, FrameDescriptor>();
  /// ESIs the code supplied rather than the network. What makes `repairedFrames` honest: without it
  /// a clean run and a fully-repaired run report identically.
  private recoveredEsis = new Set<number>();
  private generation: number | null = null;
  private lastEmitted = -1;
  private firstEmitted = -1;

  sourceReceived = 0;
  repairReceived = 0;
  emitted = 0;
  repairedFrames = 0;
  tooLate = 0;
  generationResets = 0;

  /// When each requested symbol was asked for, in frames, so its answer's round trip can be measured.
  /// Bounded by `requested`, which is itself capped.
  private readonly nackedAtFrame = new Map<number, number>();
  /// Recent ARQ round trips, in frames. The question this answers: is the reorder window wide enough
  /// for this link, or is every retransmission arriving after its frame was abandoned?
  private readonly arqRoundTrips: number[] = [];

  /// Symbols already asked for, so each is requested once. See `takeNackable`.
  private readonly requested = new Set<number>();
  private newestFrameSeq = -1;
  private newestEsi = -1;
  /// The first symbol of the newest frame seen. Everything below it belongs to an older frame, which
  /// is what makes the request guard exactly one frame wide at any frame size.
  private newestFrameFirstEsi = 0;
  /// Symbols this feed has asked to have sent again.
  nacked = 0;
  /// Frames whose contents did not match the hash the sender computed over them, and how many of
  /// those were keyframes. Both are zero on a healthy stream; the first is the count of damaged
  /// pictures that did NOT reach the decoder.
  corruptFrames = 0;
  corruptKeyframes = 0;
  /// Frames the decoder could not have used because the frame they reference was never delivered.
  ///
  /// EXACT, NOT INFERRED. Before this the client knew only that there was a HOLE somewhere, and
  /// stopped everything until a keyframe — correct for a linear chain and wrong for anything else,
  /// and correct here only because the write path happens to hardcode L1T1. Each frame now says how
  /// far back its reference is, so the question "can this be decoded" is about THAT frame and is
  /// answerable the moment it arrives.
  undecodable = 0;
  /// How far the stream may run past a missing frame before giving up on it, in frames.
  ///
  /// ADAPTIVE, BECAUSE THE RIGHT VALUE IS A PROPERTY OF THE LINK. A LAN needs a frame or two; a
  /// stalling tunnel needs twenty. It only ever grows on evidence — a frame that actually arrived
  /// after being discarded — and shrinks on a sustained absence of it, so the feedback is negative:
  /// widening removes the very events that caused it.
  private reorderFrames = REORDER_FRAMES_MIN;
  /// Symbols per frame, averaged over what has actually been assembled. The reorder wait is counted in
  /// FRAMES and the decoder's memory in SYMBOLS, so converting between them needs this.
  private symbolsPerFrame = 1;
  private framesMeasured = 0;
  private symbolsMeasured = 0;
  /// Report windows with nothing arriving late, counted toward narrowing the wait again.
  private patientWindows = 0;

  /// Counters as of the previous report, so loss can be expressed over the window between them.
  private spanAtLastReport = 0;
  private emittedAtLastReport = 0;
  private undecodableAtLastReport = 0;
  private tooLateAtLastReport = 0;

  /// Frame sequences actually delivered, so a frame's reference can be checked. Bounded: a reference
  /// further back than this could not be held by the decoder either.
  private readonly delivered = new Set<number>();

  /// Frames emitted after a gap — a lost frame the code could not repair and ARQ could not retrieve
  /// in time. Each one leaves the decoder referencing a picture it never had.
  discontinuities = 0;
  /// Whether the LAST harvest crossed a gap. Read and cleared by the caller.
  private sawDiscontinuity = false;

  /// True once per harvest that crossed a gap, so a burst of losses costs one keyframe, not one each.
  takeDiscontinuity(): boolean {
    const seen = this.sawDiscontinuity;
    this.sawDiscontinuity = false;
    return seen;
  }

  push(packet: DcPacket): CompleteFrame[] {
    // A GENERATION CHANGE IS A HARD RESET. A codec change or peer rebuild starts a new ESI space;
    // carrying the window over would solve equations against symbols from a stream that no longer
    // exists, and mixing two spaces produces plausible garbage rather than an error.
    if (this.generation !== null && packet.generation !== this.generation) {
      this.resetStream();
      this.generationResets++;
    }
    this.generation = packet.generation;

    let touched: number[];
    if (packet.kind === "source") {
      this.sourceReceived++;
      // REGISTERED EVEN WHEN IT IS ALREADY TOO LATE, so `harvest` can count it exactly once as it
      // discards it. Skipping registration here saved assembling a frame nobody wants, but it also
      // made the counter silently read zero — and `tooLate` is how a reordering or over-eager repair
      // problem becomes visible at all.
      if (packet.frameSeq > this.newestFrameSeq) {
        this.newestFrameSeq = packet.frameSeq;
        // Its FIRST symbol, derived the same way the descriptor is: `esi - fragIndex`, so it is known
        // from whichever symbol of the frame happens to arrive first.
        this.newestFrameFirstEsi = packet.esi - packet.fragIndex;
      }
      if (packet.esi > this.newestEsi) this.newestEsi = packet.esi;
      if (!this.frames.has(packet.frameSeq)) {
        this.frames.set(packet.frameSeq, {
          firstEsi: packet.esi - packet.fragIndex,
          fragCount: packet.fragCount,
          frameBytes: packet.frameBytes,
          rtp: packet.rtp,
          key: packet.key,
          payloadType: packet.payloadType,
          frameHash: packet.frameHash,
          dependsOnOffset: packet.dependsOnOffset,
        });
      }
      // COPIED out of the channel's buffer: the decoder keeps symbols in its window long after this
      // message's backing store is reused.
      // A SYMBOL WE ASKED FOR, COMING BACK. The distance in frames since the request is the ARQ round
      // trip as the reorder window experiences it: if this routinely exceeds `MAX_REORDER_FRAMES`,
      // every retransmission is arriving after its frame has already been given up on, and the
      // requests are pure cost.
      const askedAt = this.nackedAtFrame.get(packet.esi);
      if (askedAt !== undefined) {
        this.nackedAtFrame.delete(packet.esi);
        this.arqRoundTrips.push(Math.max(0, this.newestFrameSeq - askedAt));
        if (this.arqRoundTrips.length > ARQ_SAMPLES) this.arqRoundTrips.shift();
      }
      touched = this.decoder.addSource(packet.esi, new Uint8Array(packet.payload));
    } else {
      this.repairReceived++;
      touched = this.decoder.addRepair(
        packet.firstEsi, packet.windowLen, packet.seed, packet.payload,
      );
      for (const esi of touched) this.recoveredEsis.add(esi);
    }
    return touched.length === 0 ? [] : this.harvest();
  }

  private resetStream(): void {
    this.decoder = new RlcDecoder();
    this.frames.clear();
    this.recoveredEsis.clear();
    this.delivered.clear();
    this.requested.clear();
    this.sawDiscontinuity = false;
    this.newestFrameSeq = -1;
    this.newestFrameFirstEsi = 0;
    this.newestEsi = -1;
    this.lastEmitted = -1;
    this.firstEmitted = -1;
  }

  /// Symbols worth asking the host to send again, each returned at most once.
  ///
  /// WHY RETRANSMISSION RATHER THAN MORE REDUNDANCY. Measured on a relayed WAN path: 26.9% of the
  /// wire spent on repair recovered about 9% of what was lost, because real loss there is BURSTY —
  /// a burst taking several symbols from one window exceeds the rank available to solve it, and
  /// adding redundancy makes the burst likelier rather than the recovery better. Asking again has
  /// neither problem, and the time to hide it is already being paid: the pacer's adaptive margin
  /// measured 72ms against a 25ms round trip.
  ///
  /// A FEW SYMBOLS OF PATIENCE FIRST. A symbol that is merely reordered arrives on its own, and
  /// asking for it wastes a round trip and a retransmission on a channel that has just proven it is
  /// losing things. The guard is counted in SYMBOLS rather than frames because a frame that never
  /// arrived contributes no frame to count.
  takeNackable(): number[] {
    const out: number[] = [];
    if (this.newestEsi < 0) return out;
    // SCANNED OVER THE ESI SEQUENCE, NOT OVER REGISTERED FRAMES. ESIs are contiguous per stream, so a
    // hole in them IS a lost symbol — whereas a frame whose symbols were ALL lost has no descriptor
    // at all and is invisible to anything that iterates what arrived. That is precisely the case ARQ
    // exists for, and the first version of this missed it: it could only ask for symbols belonging to
    // frames it had already partly received.
    // ONE FRAME OF PATIENCE, EXPRESSED AS ONE FRAME. Everything below the newest frame's first symbol
    // belongs to a frame the stream has already moved past, whatever that frame's size — which is
    // what keeps this in step with the abandonment deadline above. Counting symbols instead made the
    // patience depend on how many symbols a frame happened to have.
    const oldest = Math.max(0, this.newestEsi - NACK_LOOKBACK_SYMBOLS);
    for (let esi = oldest; esi < this.newestFrameFirstEsi; esi++) {
      if (this.decoder.has(esi) || this.requested.has(esi)) continue;
      this.requested.add(esi);
      // WHEN IT WAS ASKED FOR, in FRAMES. Measuring the answer's round trip in the same unit as the
      // window that waits for it needs no clock and no frame-rate assumption — and it is the only
      // number that says whether that window is wide enough for this link.
      this.nackedAtFrame.set(esi, this.newestFrameSeq);
      out.push(esi);
    }
    // ONCE EACH, and the set is only a dedup — dropping the oldest half when it grows loses nothing
    // but the memory of frames the stream has long passed, which can never be asked for again anyway.
    if (this.requested.size > REQUESTED_MEMORY) {
      const keep = [...this.requested].slice(-REQUESTED_MEMORY / 2);
      this.requested.clear();
      for (const esi of keep) this.requested.add(esi);
    }
    this.nacked += out.length;
    return out;
  }

  /// Is every symbol of this frame known?
  private isComplete(descriptor: FrameDescriptor): boolean {
    for (let i = 0; i < descriptor.fragCount; i++) {
      if (!this.decoder.has(descriptor.firstEsi + i)) return false;
    }
    return true;
  }

  /// The lowest frame sequence still pending, or null when nothing is registered. Used only for the
  /// FIRST emission, where there is no predecessor to follow.
  private oldestPending(): number | null {
    let oldest: number | null = null;
    for (const frameSeq of this.frames.keys()) {
      if (oldest === null || frameSeq < oldest) oldest = frameSeq;
    }
    return oldest;
  }

  /// Emit frames in sequence order, waiting briefly for a hole rather than skipping it.
  private harvest(): CompleteFrame[] {
    /// Set when a frame is emitted after a gap, so the caller can ask for a keyframe once per burst
    /// rather than once per frame.
    let discontinuity = false;
    // IN ORDER, WAITING BRIEFLY FOR A HOLE TO FILL — not "everything that happens to be complete".
    //
    // The channel is `ordered: false`, so frame N+1 routinely completes before N. Emitting whatever
    // was ready meant N+1 went out, `lastEmitted` advanced past N, and N was thrown away as TOO LATE
    // when its last symbol arrived a moment later. Ordinary reordering became a hole in the stream —
    // and once a hole started costing a keyframe request, the cost became visible: keyframes roughly
    // every two seconds, REGULARLY, on a path losing 0.34% of frames. That rate accounts for one
    // every five seconds, and nothing about loss is regular.
    //
    // Waiting is cheap here: the pacer downstream already holds ~70ms for jitter, so a few frames of
    // reorder tolerance fit inside a delay that is being paid for anyway.
    const out: CompleteFrame[] = [];
    // BOUNDED, and not as a formality. The guard below is what terminates this loop, and a mutation
    // test that removed it did not fail — it HUNG, spinning forever on the main thread. That is the
    // exact symptom under investigation elsewhere in this file, so the frame path does not get to
    // have an unbounded loop in it whatever the logic says. Far above any real harvest: a burst of
    // 256 frames is four seconds of video arriving at once.
    for (let guard = 0; guard < MAX_HARVEST_FRAMES; guard++) {
      const next = this.lastEmitted < 0 ? this.oldestPending() : this.lastEmitted + 1;
      if (next === null) break;
      const descriptor = this.frames.get(next);
      if (descriptor === undefined || !this.isComplete(descriptor)) {
        // GIVE UP ONLY WHEN IT CANNOT STILL ARRIVE. Declaring a loss early is what turned reordering
        // into keyframe requests; declaring it never would stall the stream on one lost frame.
        //
        // ALREADY GONE BEATS STILL WAITING. A frame whose symbols sit below the decoder's prune floor
        // cannot be completed by anything — not a repair symbol, not a retransmission, not more
        // patience — so waiting out the reorder window for it achieves nothing and costs everything.
        //
        // THIS IS THE FORWARD-PROGRESS GUARANTEE, and it exists because the feed has now wedged twice
        // in exactly this way: the emission point pinned `reorderFrames` behind the newest frame,
        // every frame there already pruned, one skip per arriving frame and not one emitted ever
        // again. Measured: `emitted` frozen at 2631 while `gaps` climbed 98 -> 375 -> 639, which is
        // 55 per second — the frame rate exactly.
        const provablyGone = descriptor !== undefined && descriptor.firstEsi < this.decoder.floorEsi();
        if (!provablyGone && this.newestFrameSeq - next < this.reorderFrames) break;
        this.frames.delete(next);
        if (this.lastEmitted >= 0) { this.discontinuities++; discontinuity = true; }
        this.lastEmitted = next;
        continue;
      }
      const frameSeq = next;
      this.frames.delete(frameSeq);
      // Measured here rather than assumed: frame size varies by an order of magnitude between a delta
      // frame and a keyframe, and the retention budget is spent in symbols.
      this.framesMeasured++;
      this.symbolsMeasured += descriptor.fragCount;
      this.symbolsPerFrame = this.symbolsMeasured / this.framesMeasured;
      const data = new Uint8Array(descriptor.frameBytes);
      let repaired = false;
      for (let i = 0; i < descriptor.fragCount; i++) {
        const esi = descriptor.firstEsi + i;
        if (this.recoveredEsis.has(esi)) repaired = true;
        const symbol = this.decoder.get(esi)!;
        const offset = i * symbol.length;
        const take = Math.min(symbol.length, descriptor.frameBytes - offset);
        if (take > 0) data.set(symbol.subarray(0, take), offset);
      }
      // VERIFIED BEFORE IT REACHES THE DECODER, and this is the only place it can be.
      //
      // The code SOLVES for a lost symbol, and a solve against a stale or wrong equation does not
      // fail — it produces a symbol of the right length full of plausible garbage. Every other check
      // in this file describes the FRAMING; none of them can look at the content. Reported from a
      // live session as repeated damaged pictures in the run-up to the tab locking up, and a decoder
      // fed nonsense is the one thing here able to take a whole page down.
      if (fnv1a(data) !== descriptor.frameHash) {
        this.corruptFrames++;
        // A CORRUPT KEYFRAME MUST BE ASKED FOR AGAIN, or every frame after it references a picture
        // the decoder never had. Dropping it silently trades one bad picture for a broken stream.
        if (descriptor.key) this.corruptKeyframes++;
        this.lastEmitted = frameSeq;   // it is gone; do not wait for it or re-admit it later
        continue;
      }
      // ITS REFERENCE MUST HAVE BEEN DELIVERED. A keyframe (offset 0) needs none; anything else is
      // undecodable without the frame it points at, and handing it to the decoder renders artifacts
      // against a picture that was never there — visually identical to data corruption.
      // AT STREAM START THERE IS NOTHING TO CHECK AGAINST, and refusing everything until a keyframe
      // is the DECODER's job — its own gate already drops frames until it sees an IDR. Enforcing it
      // here as well would mean two places deciding when a stream may begin.
      if (this.delivered.size > 0 && descriptor.dependsOnOffset > 0
          && !this.delivered.has(frameSeq - descriptor.dependsOnOffset)) {
        this.undecodable++;
        this.lastEmitted = frameSeq;
        continue;
      }
      if (repaired) this.repairedFrames++;
      // A HOLE IN THE STREAM MUST BE ANNOUNCED, or the decoder quietly decodes against a picture it
      // never had. Nothing else here can see it: the frames that DO arrive are byte-exact and pass
      // their hash, the transport reports the loss as a number nobody acts on, and the reference
      // tracker accepts everything because this path carries no dependency metadata. The result is
      // artifacts that look exactly like corruption and persist until the next keyframe — which,
      // with nothing asking for one, is whenever the host happens to send it.
      this.lastEmitted = frameSeq;
      this.delivered.add(frameSeq);
      // BOUNDED to the decoder's own reach: a reference older than this could not be held anyway.
      if (this.delivered.size > DELIVERED_MEMORY) {
        for (const seq of this.delivered) {
          if (seq < frameSeq - DELIVERED_MEMORY) this.delivered.delete(seq);
        }
      }
      if (this.firstEmitted < 0) this.firstEmitted = frameSeq;
      this.emitted++;
      out.push({
        frameSeq, rtp: descriptor.rtp, key: descriptor.key,
        payloadType: descriptor.payloadType, data: data.buffer,
      });
    }
    // Frames the emission point has passed can never be used. Under in-order emission they are never
    // ADMITTED rather than being emitted and discarded, so this is where a straggler is counted: a
    // symbol that arrived after its frame's slot had gone by.
    for (const frameSeq of this.frames.keys()) {
      if (frameSeq <= this.lastEmitted) {
        this.tooLate++;
        this.frames.delete(frameSeq);
        // IT ARRIVED. It says exactly how much more patience would have kept it: the wait that was in
        // force, plus how far the emission point had already run past it. Waiting that long next time
        // turns a discarded frame into a delivered one.
        //
        // A link can STALL rather than drop — a VPN over TCP retransmits underneath us, so it goes
        // quiet and then delivers everything at once — and against a fixed window that reads as loss.
        // Measured on one: 185 frames arriving after being given up on against 55 genuinely lost.
        // Neither redundancy nor retransmission can repair lateness; only a longer wait can.
        const wouldHaveNeeded = this.reorderFrames + (this.lastEmitted - frameSeq) + 1;
        if (wouldHaveNeeded > this.reorderFrames) {
          this.reorderFrames = Math.min(REORDER_FRAMES_MAX, this.retentionFrames(), wouldHaveNeeded);
        }
        this.patientWindows = 0;
      }
    }
    this.sawDiscontinuity = discontinuity;
    return out;
  }

  /// THE LONGEST WAIT THE DECODER CAN ACTUALLY BACK, in frames.
  ///
  /// YOU CANNOT WAIT LONGER THAN YOU CAN REMEMBER. The reorder window is counted in frames and the
  /// decoder's history in symbols, and the two were set independently — 60 frames here, 128 symbols
  /// there, in different files with nothing relating them. At the ~4 symbols per frame this stream
  /// actually produces, 60 frames is 240 symbols against a memory of 128: the moment the emission
  /// point falls that far back, every frame it wants next has already been pruned, and no amount of
  /// patience or redundancy can bring one back.
  ///
  /// Worse than a wedge, it is SELF-INFLICTED: past this bound our own pruning destroys frames that
  /// the network delivered perfectly well. The session that produced this had lost exactly ONE frame
  /// in 2510 when it collapsed.
  private retentionFrames(): number {
    const frames = Math.floor(RlcDecoder.historySymbols / Math.max(1, this.symbolsPerFrame));
    return Math.max(REORDER_FRAMES_MIN, frames);
  }

  /// FRAME LOSS IS DERIVED FROM THE SEQUENCE SPAN, not from a count the client cannot have. The host
  /// numbers frames consecutively, so everything between the first and last emitted was sent, and
  /// whatever is missing from that span was lost. Counting "frames I did not receive" is impossible
  /// from inside the client; counting holes in a known-dense range is not.
  summary(): Record<string, number> {
    const span = this.firstEmitted < 0 ? 0 : this.lastEmitted - this.firstEmitted + 1;
    // LOSS SINCE THE LAST REPORT, not since the session began. The host sets its redundancy from this
    // number, and a lifetime average barely moves: a link that is clean for ten minutes and then
    // degrades would report a fraction of a percent while dropping frames continuously, and the
    // adaptation would be inert in exactly the case it exists for.
    const recentSpan = span - this.spanAtLastReport;
    const recentEmitted = this.emitted - this.emittedAtLastReport;
    const recentUndecodable = this.undecodable - this.undecodableAtLastReport;
    const recentLost = Math.max(0, recentSpan - recentEmitted - recentUndecodable);
    // NARROW AGAIN WHEN NOTHING IS ARRIVING LATE — but slowly: every frame of patience given back is
    // one that must be re-learned by discarding a frame that would have arrived.
    if (this.tooLate === this.tooLateAtLastReport) {
      this.patientWindows++;
      if (this.patientWindows >= PATIENT_WINDOWS_BEFORE_NARROWING) {
        this.patientWindows = 0;
        this.reorderFrames = Math.max(REORDER_FRAMES_MIN, this.reorderFrames - 1);
      }
    }
    this.tooLateAtLastReport = this.tooLate;
    this.spanAtLastReport = span;
    this.emittedAtLastReport = this.emitted;
    this.undecodableAtLastReport = this.undecodable;
    // UNDECODABLE FRAMES ARE NOT LOST ONES. They arrived intact and were refused because the frame
    // they reference never did, so counting them here would turn `lost=` — read all evening as a
    // measure of the LINK — into a measure of the decode chain, and make a single dropped frame look
    // like a burst of them.
    const lost = Math.max(0, span - this.emitted - this.undecodable);
    return {
      sourceReceived: this.sourceReceived,
      repairReceived: this.repairReceived,
      emitted: this.emitted,
      framesLost: lost,
      // CUMULATIVE, for reading. It is the number a human compares across a session.
      frameLossPercent: span === 0 ? 0 : (100 * lost) / span,
      // RECENT, for acting on. The host's redundancy follows this one.
      recentLossPercent: recentSpan <= 0 ? 0 : (100 * recentLost) / recentSpan,
      repairedFrames: this.repairedFrames,
      corruptFrames: this.corruptFrames,
      undecodable: this.undecodable,
      // The ARQ round trip in FRAMES, which is directly comparable with `MAX_REORDER_FRAMES`. A p95
      // at or above that window means the retransmissions are arriving too late to be used.
      arqRoundTripFrames: percentileOf(this.arqRoundTrips, 0.5),
      arqRoundTripFramesP95: percentileOf(this.arqRoundTrips, 0.95),
      arqAnswered: this.arqRoundTrips.length,
      discontinuities: this.discontinuities,
      corruptKeyframes: this.corruptKeyframes,
      recoveredSymbols: this.decoder.recovered,
      redundantEquations: this.decoder.redundant,
      tooLate: this.tooLate,
      reorderFrames: this.reorderFrames,
      generationResets: this.generationResets,
      pending: this.frames.size,
      duplicateSymbols: this.decoder.duplicateSymbols,
      // NEAR 100% MEANS THE SENDER IS NOT NUMBERING SYMBOLS — a fault that reports cleanly while
      // delivering nothing, because the decoder just overwrites one slot forever.
      duplicatePercent: this.sourceReceived === 0
        ? 0 : (100 * this.decoder.duplicateSymbols) / this.sourceReceived,
      // MEASURED, not restated from the host's repair-per-frame setting: what it costs depends on
      // how many symbols a frame actually took, which depends on the content.
      overheadPercent: this.sourceReceived === 0
        ? 0 : (100 * this.repairReceived) / this.sourceReceived,
    };
  }

  reset(): void {
    this.sourceReceived = 0;
    this.repairReceived = 0;
    this.emitted = 0;
    this.repairedFrames = 0;
    this.tooLate = 0;
    this.generationResets = 0;
    this.firstEmitted = -1;
  }
}

/// Nearest-rank percentile of a small unsorted sample; 0 when there is nothing to report.
function percentileOf(values: readonly number[], q: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(q * sorted.length) - 1));
  return sorted[index]!;
}
