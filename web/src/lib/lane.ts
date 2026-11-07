/// THE LANE'S ENGINE (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §2–§4): one END of the lane — the
/// sender of this end's three streams and the receiver of the other end's. PURE: it is handed the time (milliseconds
/// since the lane opened) and returns the packets to put on the data channel, so tests run two of them over a
/// simulated link (web/test/lane.test.ts). The page's twin of host/streaming-engine/PionBridge/rdev_lane_engine.go —
/// the SAME design, name for name: a change to one is a change to both. The two agree on the wire
/// (protocol/fixtures/lane-vectors.json) and meet end to end in the lossy-link gate.
import {
  LANE_CHUNK_HEADER, LANE_HEADER_BYTES, LANE_RANGES_MAX, LANE_STREAMS, LANE_SYMBOL_MAX, LANE_TYPE_FEEDBACK,
  LANE_TYPE_REPAIR, LANE_TYPE_SOURCE, buildLaneSymbol, decodeLanePacket, encodeLaneFeedback, encodeLaneRepair,
  encodeLaneSource, parseLaneSymbol, unwrapLane32, type LaneChunk, type LaneFeedback, type LaneRange,
} from "./lane-codec";
import { RlcDecoder, rlcNextSeed, rlcRepair } from "./rlc";

export const LANE_MESSAGE_MAX = 1 << 20;
export const LANE_REPAIR_WINDOW = 64;
export const LANE_HELD_MAX = 512;
export const LANE_TAIL_FIRST_MS = 10;
export const LANE_TAIL_SECOND_MS = 40;
export const LANE_TAIL_SECOND_PERMILLE = 20;
export const LANE_RATE_MIN_PERMILLE = 100;
export const LANE_RATE_MAX_PERMILLE = 500;
export const LANE_RATE_LOSS_FACTOR = 3;
export const LANE_FEEDBACK_DELAY_MS = 20;
export const LANE_FEEDBACK_EVERY = 8;
export const LANE_FEEDBACK_GAP_MS = 10;
export const LANE_KEEPALIVE_MS = 1000;
/// A symbol sent this much before the newest packet the peer echoes, and not decoded, is lost.
export const LANE_REORDER_MS = 10;
/// Twice the receiver's longest feedback hold: an on-time acknowledgement never races the timer.
export const LANE_TIMER_FLOOR_MS = 40;
export const LANE_TIMER_INITIAL_MS = 200;
export const LANE_TIMER_MAX_MS = 1000;
/// 64 kbit/s of PROACTIVE repair.
export const LANE_BUDGET_BYTES_PER_MS = 8;
export const LANE_BUDGET_BURST = 16384;
export const LANE_STUCK_MS = 30_000;
export const LANE_LOSS_WINDOW = 256;
export const LANE_PROACTIVE_OWED_MAX = 4;
/// Past LANE_HELD_MAX and a window: an ESI the sender may still repair is never pruned.
export const LANE_DECODER_HISTORY = 1024;
/// queueTarget's floor: the short queue on top of the bytes in flight.
export const LANE_QUEUE_TARGET = 16 * 1024;
export const LANE_RATE_BUCKET_MS = 100;
/// The base round trip is the least pristine sample of the last 10 s.
export const LANE_BASE_WINDOW_SEC = 10;
/// The send stamps of the last pristine polls, for the base round trip.
const LANE_PRISTINE_RING = 8;
/// The delivery rate is the bytes acknowledged over the last second.
export const LANE_RATE_BUCKETS = 10;

/// Packing order: control, input, terminal — small and urgent before bulk output.
const LANE_STREAM_PRIORITY = [2, 1, 0] as const;

export interface LaneDelivery { stream: number; data: Uint8Array }

interface LaneOutStream {
  queue: Uint8Array[];   // framed messages (len u32 · message) not yet in a symbol
  taken: number;         // bytes of queue[0] already in a symbol
  bytes: number;         // pending bytes
  offset: number;        // the stream offset of the first pending byte
  // What the application handed and what the peer has acknowledged, in PAYLOAD bytes (`buffered`): every message
  // handed, and the messages not yet wholly acknowledged — their framed end offsets, oldest first — against the framed
  // offset the peer's cumulative acknowledgement has reached.
  handed: number;
  messages: LaneOutMessage[];
  ackedOffset: number;
  ackedWhole: number;    // payload bytes of the messages acknowledged whole (shifted off `messages`)
}

interface LaneOutMessage { end: number /* the stream offset after this message's framed bytes */; size: number /* its payload bytes */ }

interface LaneInStream {
  offset: number;                      // the next byte to deliver
  segments: Map<number, Uint8Array>;   // chunks ahead of offset, keyed by their offset
  framed: Uint8Array;                  // delivered bytes not yet a whole message
}

interface LaneHeldSymbol {
  bytes: Uint8Array;
  sentAt: number;
  // Each stream's offset after what this symbol carried of it (`carried` says which): on the symbol's cumulative
  // acknowledgement the stream's `ackedOffset` reaches it.
  ends: number[];
  carried: boolean[];
}
interface LaneRepairPlan { first: number; count: number; n: number /* repairs still to send over this window */ }
interface LaneAckBucket { slot: number /* now / LANE_RATE_BUCKET_MS */; bytes: number }
interface LaneBaseSample { second: number; ms: number }

/// A symbol or repair zero-extended to LANE_SYMBOL_MAX: the decoder's algebra needs one width.
export function padLane(b: Uint8Array): Uint8Array {
  const out = new Uint8Array(LANE_SYMBOL_MAX);
  out.set(b);
  return out;
}

function take(o: LaneOutStream, n: number): Uint8Array {
  const out = new Uint8Array(n);
  let filled = 0;
  while (filled < n) {
    const head = o.queue[0]!;
    const k = Math.min(n - filled, head.length - o.taken);
    out.set(head.subarray(o.taken, o.taken + k), filled);
    filled += k;
    o.taken += k;
    if (o.taken === head.length) { o.queue.shift(); o.taken = 0; }
  }
  o.bytes -= n;
  o.offset += n;
  return out;
}

/// The peer's cumulative acknowledgement reached `offset` of stream `o` — the messages ending at or before it are
/// acknowledged whole.
function acknowledged(o: LaneOutStream, offset: number): void {
  if (offset <= o.ackedOffset) return;
  o.ackedOffset = offset;
  while (o.messages.length > 0 && o.messages[0]!.end <= offset) o.ackedWhole += o.messages.shift()!.size;
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  if (a.length === 0) return b;
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

export class LaneEngine {
  // ---- sending ----
  private readonly out: LaneOutStream[] = [];
  private readonly held = new Map<number, LaneHeldSymbol>();   // ESIs in [heldFrom, nextEsi)
  private heldFrom: number;                                    // every ESI below is acknowledged and released
  private nextEsi: number;
  private knownAbove = new Set<number>();                      // ESIs ≥ heldFrom the latest feedback reported decoded
  private pkt: number;
  private seed: number;
  private srtt = 0;
  private rttvar = 0;
  private hasRtt = false;
  private lossPermille = 0;                                    // the peer's latest report
  private tailDue = -1;
  private tail2Due = -1;
  private sinceRepair = 0;
  private tokens = LANE_BUDGET_BURST;
  private tokensAt = 0;
  private urgent: LaneRepairPlan[] = [];                       // gap and timer repair
  private proactiveOwed = 0;                                   // tail and proportional repair
  private readonly gapRepairedAt = new Map<number, number>();
  private timerDeadline = -1;
  private timerRto = LANE_TIMER_INITIAL_MS;
  private lastFeedbackAt = 0;
  /// The cumulative acknowledgement last moved — or the link (re)connected (resetStuck). What `stuck` and `stalledFor`
  /// measure from: a feedback that acknowledges nothing new is not progress. Measured from the last FEEDBACK, a lane
  /// whose own packets never reached the peer stayed alive forever on the peer's keepalives (2026-10-13: a phone's SCTP
  /// holding its keystrokes in its backoff after a network blink, the Mac's packets still arriving — typing with no
  /// reply for minutes, neither end ever stuck).
  private lastProgressAt = 0;
  /// Bytes the peer acknowledged, per 100 ms.
  private readonly ackBuckets: LaneAckBucket[] = Array.from({ length: LANE_RATE_BUCKETS }, () => ({ slot: 0, bytes: 0 }));
  /// THE BASE ROUND TRIP (queueTarget): the least round trip among PRISTINE samples — feedback echoing a packet sent
  /// when the lane held nothing else unacknowledged — in per-second buckets over LANE_BASE_WINDOW_SEC; with none in
  /// the window the last stands. Every sample otherwise includes the data channel's queue for the lane, which the
  /// target itself sizes: measured at 100 kbit/s (2026-10-12, term-slow-link-check), srtt climbed to 11 s, the target
  /// to 11 MB and pion's queue to 132 KB — ten seconds of link in front of every keystroke's echo.
  private readonly pristineTs: number[] = new Array<number>(LANE_PRISTINE_RING).fill(-1);
  private pristineN = 0;
  private baseSamples: LaneBaseSample[] = [];
  private baseRtt = 0;
  private hasBase = false;
  /// The newest FEEDBACK's pkt (`everFeedback`: one has arrived): only it describes the receiver (onFeedback).
  private feedbackPkt = 0;
  private everFeedback = false;

  // ---- receiving ----
  private readonly decoder = new RlcDecoder(LANE_DECODER_HISTORY);
  private highestEsi: number;
  private everReceived = false;
  private readonly processed = new Set<number>();
  private cumEsi: number;                                      // the first ESI not yet known
  private readonly in: LaneInStream[] = [];
  private delivered: LaneDelivery[] = [];
  private everPkt = false;
  private highestPkt: number;
  private firstPkt: number;
  private readonly pktSeen: number[] = new Array<number>(LANE_LOSS_WINDOW).fill(0);   // pkt + 1 last seen in each slot; 0 = never
  private arrivals = 0;
  private firstArrivalAt = 0;
  private feedbackNow = false;
  private lastGapFeedbackAt = -Infinity;
  private lastFeedbackSentAt = 0;
  private lastTs = 0;
  private lastAt = 0;
  private holeSince = -1;
  /// The peer broke the protocol in a way no conforming sender can (consume) — stuck reads true at once, and the glue
  /// closes the lane through the stuck path (an ordinary channel loss and rebuild).
  private violated = false;

  /// Every counter starts at `initial` (0 in the product; just below 2³² in the wrap test). `seed` starts the repair
  /// coefficients.
  constructor(seed: number, initial = 0) {
    this.seed = seed >>> 0;
    this.heldFrom = this.nextEsi = this.highestEsi = this.cumEsi = this.highestPkt = this.firstPkt = initial;
    this.pkt = initial >>> 0;
    for (let s = 0; s < LANE_STREAMS; s++) {
      this.out.push({ queue: [], taken: 0, bytes: 0, offset: initial, handed: 0, messages: [], ackedOffset: initial, ackedWhole: 0 });
      this.in.push({ offset: initial, segments: new Map(), framed: new Uint8Array(0) });
    }
  }

  // ---- the application's side ----

  send(stream: number, message: Uint8Array): void {
    if (message.length === 0 || message.length > LANE_MESSAGE_MAX) throw new RangeError("lane: a message is 1 to 1048576 bytes");
    const framed = new Uint8Array(4 + message.length);
    new DataView(framed.buffer).setUint32(0, message.length);
    framed.set(message, 4);
    const o = this.out[stream]!;
    o.queue.push(framed);
    o.bytes += framed.length;
    o.handed += message.length;
    o.messages.push({ end: o.offset + o.bytes, size: message.length });
  }

  /// What `stream` has been handed and the peer has not yet ACKNOWLEDGED — pending bytes and those in symbols its
  /// feedback has not yet covered cumulatively — in payload bytes, the frame prefixes excluded. It is what the channel
  /// reports as its bufferedAmount, and TermPacer's model of that number (TermPath): pion's counts bytes until SCTP
  /// acknowledges them, and `handed − buffered` must never decrease. Reporting the bytes not yet in a symbol read 0
  /// whenever the lane had room, so the pacer handed a whole re-send into this stream's FIFO — where its reordering
  /// (the wire start and the tab on screen first) could not reach it: 18.7 s to a wire start and 20.4 s to an echo at
  /// 100 kbit/s (2026-10-12, term-slow-link-check) — and counted each message's 4-byte frame prefix, so
  /// `handed − buffered` stepped back by 4 per message and TermPath's rate wrapped to 9e20 B/s: `Int(bytes)` trapped
  /// the host. The Mac's engine computes the same number.
  buffered(stream: number): number {
    const o = this.out[stream]!;
    let acked = o.ackedWhole;
    const head = o.messages[0];
    if (head !== undefined) {
      // The oldest message not yet acknowledged whole: what the acknowledgement reached of its payload, past its prefix.
      const start = head.end - head.size - 4;
      if (o.ackedOffset > start + 4) acked += Math.min(o.ackedOffset - start - 4, head.size);
    }
    return o.handed - acked;
  }

  hasPending(): boolean { return this.out.some((o) => o.bytes > 0); }

  /// Symbols sent and not yet acknowledged.
  unacknowledged(): number { return this.nextEsi - this.heldFrom; }

  /// TEST-ONLY: the next ESI this end will send.
  get sentEsi(): number { return this.nextEsi; }

  /// The peer broke the protocol (`violated`): the glue names it when it closes the lane.
  get protocolViolated(): boolean { return this.violated; }

  takeDelivered(): LaneDelivery[] {
    const d = this.delivered;
    this.delivered = [];
    return d;
  }

  // ---- receiving ----

  receive(packet: Uint8Array, now: number): void {
    const p = decodeLanePacket(packet);
    if (!p) return;
    // THE NEWEST PACKET ONLY MEASURES THE PATH (spec §1, "The carrier"): the carrier is reliable, so SCTP's late copy
    // of a packet the lane counted lost — or a reorder — arrives after newer ones. It still delivers what it carries,
    // but cancels no loss (the estimate is of loss on FIRST transmission, what the lane's repair faces), leaves the
    // echo on the newest packet, and as a feedback gives no round-trip sample: its echo is as old as it is late.
    const pkt = unwrapLane32(this.highestPkt, p.pkt);
    const newest = this.notePkt(pkt);
    if (newest) { this.lastTs = p.ts; this.lastAt = now; }
    // AN ESI PAST WHAT THE SENDER'S WINDOW COULD HOLD IS REFUSED (no conforming sender reaches cumEsi + 512): it would
    // lift highestEsi by up to 2³¹, and every feedback after would walk cumEsi…highestEsi, and the decoder would prune
    // everything below it.
    switch (p.kind) {
      case LANE_TYPE_SOURCE: {
        const esi = unwrapLane32(this.highestEsi, p.esi);
        if (esi >= this.cumEsi + LANE_DECODER_HISTORY) return;
        this.noteData(now, esi, this.decoder.addSource(esi, padLane(p.payload)));
        break;
      }
      case LANE_TYPE_REPAIR: {
        if (p.count > LANE_REPAIR_WINDOW) return;
        const first = unwrapLane32(this.highestEsi, p.esi);
        if (first + p.count - 1 >= this.cumEsi + LANE_DECODER_HISTORY) return;
        this.noteData(now, first + p.count - 1, this.decoder.addRepair(first, p.count, p.seed, padLane(p.payload)));
        break;
      }
      case LANE_TYPE_FEEDBACK:
        this.onFeedback(p.feedback, now, newest, pkt);
        break;
    }
  }

  /// Counts a packet in the loss window if it is the newest yet, and says whether it was. One no newer than the
  /// highest seen changes nothing: a loss already counted stays counted.
  private notePkt(pkt: number): boolean {
    if (this.everPkt && pkt <= this.highestPkt) return false;
    if (!this.everPkt) { this.firstPkt = pkt; this.everPkt = true; }
    this.highestPkt = pkt;
    this.pktSeen[pkt % LANE_LOSS_WINDOW] = pkt + 1;
    return true;
  }

  /// The share of the peer's last 256 packets that never arrived, from the gaps in `pkt`.
  private lossSeenPermille(): number {
    if (!this.everPkt) return 0;
    const expected = Math.min(this.highestPkt - this.firstPkt + 1, LANE_LOSS_WINDOW);
    let received = 0;
    for (let i = 0; i < expected; i++) {
      const pkt = this.highestPkt - i;
      if (this.pktSeen[pkt % LANE_LOSS_WINDOW] === pkt + 1) received++;
    }
    return Math.floor(((expected - received) * 1000) / expected);
  }

  /// A SOURCE or REPAIR arrived, reaching up to `last`, and made `known` decoded.
  private noteData(now: number, last: number, known: number[]): void {
    if (!this.everReceived || last > this.highestEsi) this.highestEsi = last;
    this.everReceived = true;
    for (const esi of known) {
      if (esi < this.cumEsi || this.processed.has(esi)) continue;
      // PROCESSED ONLY ONCE CONSUMED: a symbol the decoder no longer holds, or one that does not parse, leaves its hole
      // — cumEsi stops there and the stuck detector closes the lane — where marking it first acknowledged bytes no
      // stream was ever given (and `get(esi)!` threw on a pruned ESI, abandoning the rest of `known`).
      const symbol = this.decoder.get(esi);
      if (!symbol || !this.consume(symbol)) continue;
      this.processed.add(esi);
    }
    const before = this.cumEsi;
    while (this.processed.has(this.cumEsi)) { this.processed.delete(this.cumEsi); this.cumEsi++; }
    if (this.cumEsi !== before) this.holeSince = -1;   // the oldest hole filled: one still open above it is a new one
    if (this.arrivals === 0) this.firstArrivalAt = now;
    this.arrivals++;
    if (this.cumEsi <= this.highestEsi) {   // a hole below what has arrived
      if (this.holeSince < 0) this.holeSince = now;
      if (now - this.lastGapFeedbackAt >= LANE_FEEDBACK_GAP_MS) this.feedbackNow = true;
    } else {
      this.holeSince = -1;
    }
  }

  /// Hands a known symbol's chunks to their streams, delivering every message whose bytes are now contiguous, and says
  /// whether it could. A chunk past what the sender's window could hold, or a frame longer than any message, is a
  /// broken peer (`violated`): kept, either would grow without bound.
  private consume(symbol: Uint8Array): boolean {
    const chunks = parseLaneSymbol(symbol);
    if (!chunks) return false;
    for (const c of chunks) {
      if (c.bytes.length === 0) continue;   // a zero-length chunk at the delivery offset would never advance it
      const s = this.in[c.stream]!;
      const offset = unwrapLane32(s.offset, c.offset);
      if (offset + c.bytes.length <= s.offset) continue;
      // A conforming sender holds fewer than LANE_HELD_MAX symbols past what this end acknowledged, every byte of them at
      // most LANE_SYMBOL_MAX on: nothing it sends starts further ahead of the delivered offset than this.
      if (offset > s.offset + LANE_HELD_MAX * LANE_SYMBOL_MAX) { this.violated = true; return false; }
      s.segments.set(offset, c.bytes);
      for (let segment = s.segments.get(s.offset); segment; segment = s.segments.get(s.offset)) {
        s.segments.delete(s.offset);
        s.offset += segment.length;
        s.framed = concat(s.framed, segment);
      }
      while (s.framed.length >= 4) {
        const size = new DataView(s.framed.buffer, s.framed.byteOffset, 4).getUint32(0);
        if (size > LANE_MESSAGE_MAX) { this.violated = true; return false; }
        if (s.framed.length < 4 + size) break;
        this.delivered.push({ stream: c.stream, data: s.framed.slice(4, 4 + size) });
        s.framed = s.framed.subarray(4 + size);
      }
    }
    return true;
  }

  /// The peer's report on what it decoded — the sender's acknowledgement, loss and round trip. A feedback that is not
  /// the `newest` packet seen gives no round-trip sample (receive). A LATE FEEDBACK — no newer than the newest FEEDBACK
  /// seen (`pkt`): SCTP's copy of one the lane counted lost, guaranteed under loss on a reliable carrier — applies only
  /// its cumulative acknowledgement. Its loss, its ranges and the gap repairs they would plan describe the receiver as
  /// it was: applied, they overwrote the newer report's loss and replanned repair from a stale picture of the holes.
  /// Two gates, one stricter: the newest packet of any kind is always the newest feedback too, so a feedback that may
  /// give a round-trip sample may always apply its ranges and loss, never the other way round.
  private onFeedback(f: LaneFeedback, now: number, newest: boolean, pkt: number): void {
    this.lastFeedbackAt = now;
    const current = !this.everFeedback || pkt > this.feedbackPkt;
    if (current) { this.feedbackPkt = pkt; this.everFeedback = true; }
    const sample = (((now >>> 0) - f.echoTs) >>> 0) - f.held;
    if (newest && sample >= 0 && sample < 60_000) {
      this.updateRtt(sample);
      if (this.isPristine(f.echoTs)) this.noteBase(now, sample);
    }
    if (current) this.lossPermille = f.lossPermille;
    const cum = Math.min(unwrapLane32(this.heldFrom, f.cumEsi), this.nextEsi);
    if (cum > this.heldFrom) {
      let released = 0;
      for (let esi = this.heldFrom; esi < cum; esi++) {
        const h = this.held.get(esi)!;
        released += LANE_HEADER_BYTES + 4 + h.bytes.length;
        for (let s = 0; s < LANE_STREAMS; s++) if (h.carried[s]) acknowledged(this.out[s]!, h.ends[s]!);
        this.held.delete(esi);
      }
      this.heldFrom = cum;
      this.lastProgressAt = now;
      this.timerRto = Math.min(this.rtoBase(), LANE_TIMER_MAX_MS);   // progress: the backoff starts over, under the cap
      this.noteAcked(now, released);
    }
    if (this.nextEsi === this.heldFrom) this.timerDeadline = -1;   // nothing unacknowledged: nothing to time
    if (current) {
      this.knownAbove = new Set();
      let highestKnown = this.heldFrom;   // exclusive
      for (const r of f.ranges) {
        const start = unwrapLane32(this.heldFrom, r.start);
        for (let i = 0; i < r.length; i++) {
          const esi = start + i;
          if (esi >= this.heldFrom && esi < this.nextEsi) {
            this.knownAbove.add(esi);
            highestKnown = Math.max(highestKnown, esi + 1);
          }
        }
      }
      const echoAt = now - (((now >>> 0) - f.echoTs) >>> 0);   // when this end sent the newest packet the peer echoes
      this.planGapRepairs(this.missingEsis(highestKnown, echoAt), now);
    }
    for (const start of [...this.gapRepairedAt.keys()]) if (start < this.heldFrom) this.gapRepairedAt.delete(start);
  }

  /// The unacknowledged ESIs the latest feedback shows lost — not reported decoded, and either below one it reports
  /// decoded or first sent more than LANE_REORDER_MS before the newest packet it echoes (RACK). The second is how a
  /// lost burst END — symbols and their tail repairs — shows: the peer decoded nothing above it, so no range reveals it.
  private missingEsis(highestKnown: number, echoAt: number): number[] {
    const missing: number[] = [];
    for (let esi = this.heldFrom; esi < this.nextEsi; esi++) {
      if (!this.knownAbove.has(esi) && (esi < highestKnown || this.held.get(esi)!.sentAt + LANE_REORDER_MS < echoAt)) missing.push(esi);
    }
    return missing;
  }

  /// k + 1 repairs per window of ≤ 64 holding k missing symbols, each window at most once per rtoBase.
  private planGapRepairs(missing: number[], now: number): void {
    const interval = Math.trunc(this.rtoBase());
    for (let i = 0; i < missing.length;) {
      const first = missing[i]!;
      const end = Math.min(first + LANE_REPAIR_WINDOW, this.nextEsi);
      let k = 0;
      while (i < missing.length && missing[i]! < end) { k++; i++; }
      const at = this.gapRepairedAt.get(first);
      if (at !== undefined && now - at < interval) continue;
      this.gapRepairedAt.set(first, now);
      this.urgent.push({ first, count: end - first, n: k + 1 });
    }
  }

  private rtoBase(): number {
    if (!this.hasRtt) return LANE_TIMER_INITIAL_MS;
    return this.srtt + Math.max(4 * this.rttvar, LANE_TIMER_FLOOR_MS);
  }

  private noteAcked(now: number, bytes: number): void {
    const slot = Math.floor(now / LANE_RATE_BUCKET_MS);
    const b = this.ackBuckets[slot % LANE_RATE_BUCKETS]!;
    if (b.slot !== slot) { b.slot = slot; b.bytes = 0; }
    b.bytes += bytes;
  }

  /// The most the data channel may hold for the lane. pion — and the page's SCTP — count bytes until SCTP
  /// ACKNOWLEDGES them, so a fixed ceiling would cap throughput at that ceiling per round trip; this is the bytes in
  /// flight at the delivery rate, twice over, plus a 16 KB queue — urgent packets wait behind little, and throughput
  /// can double per round trip until SCTP's own window or the 512 held symbols stop it.
  ///
  /// The round trip is the BASE one (`baseRtt`), never srtt: srtt carries the queue, which this target sizes — a loop
  /// that ran the target to 11 MB. The rate is the bytes acknowledged over the LAST SECOND, never the best 100 ms: a
  /// hole the receiver fills late releases everything above it in one feedback — 161 KB in one 100 ms bucket at a
  /// 12.5 KB/s link — and a best bucket read that as the link's rate (2026-10-12, term-slow-link-check).
  queueTarget(now: number): number {
    const slot = Math.floor(now / LANE_RATE_BUCKET_MS);
    let acked = 0;
    for (const b of this.ackBuckets) if (slot - b.slot < LANE_RATE_BUCKETS) acked += b.bytes;
    // Before the first pristine sample the INITIAL timer stands in for the base — never srtt, which carries the queue
    // this target sizes: a lane opening into a burst took its 1.2 s srtt and asked for 967 KB (2026-10-12, measured).
    const rtt = this.hasBase ? this.baseRtt : LANE_TIMER_INITIAL_MS;
    return LANE_QUEUE_TARGET + Math.trunc(((2 * acked) / (LANE_RATE_BUCKETS * LANE_RATE_BUCKET_MS)) * rtt);
  }

  /// This poll's packets went into a lane holding nothing else unacknowledged — their echo measures the path, not the
  /// queue — so their send stamp is remembered for isPristine.
  private markPristine(now: number): void {
    this.pristineTs[this.pristineN % LANE_PRISTINE_RING] = now >>> 0;
    this.pristineN++;
  }

  private isPristine(echoTs: number): boolean {
    for (let i = 0; i < Math.min(this.pristineN, LANE_PRISTINE_RING); i++) if (this.pristineTs[i] === echoTs) return true;
    return false;
  }

  /// A pristine round-trip sample. The least of each second is kept for LANE_BASE_WINDOW_SEC; the base is the least in
  /// the window, or the last base when the window is empty (a long saturated stretch) — never zero FOR LACK OF SAMPLES.
  /// A 0 ms sample on a sub-millisecond LAN is a real base of 0, and the target is then its 16 KB floor.
  private noteBase(now: number, sample: number): void {
    const second = Math.floor(now / 1000);
    const last = this.baseSamples.at(-1);
    if (last !== undefined && last.second === second) last.ms = Math.min(last.ms, sample);
    else this.baseSamples.push({ second, ms: sample });
    this.baseSamples = this.baseSamples.filter((s) => second - s.second <= LANE_BASE_WINDOW_SEC);
    this.baseRtt = Math.min(...this.baseSamples.map((s) => s.ms));
    this.hasBase = true;
  }

  /// TEST-ONLY: the base round trip, or null while none is known.
  get baseRoundTrip(): number | null { return this.hasBase ? this.baseRtt : null; }
  /// TEST-ONLY: the smoothed round trip.
  get smoothedRoundTrip(): number { return this.srtt; }

  private updateRtt(sample: number): void {
    if (!this.hasRtt) { this.srtt = sample; this.rttvar = sample / 2; this.hasRtt = true; return; }
    this.rttvar = 0.75 * this.rttvar + 0.25 * Math.abs(this.srtt - sample);
    this.srtt = 0.875 * this.srtt + 0.125 * sample;
  }

  // ---- sending ----

  /// The packets to send now, `room` being the bytes the data channel's queue may still take; feedback ignores it.
  poll(now: number, room: number): Uint8Array<ArrayBuffer>[] {
    const packets: Uint8Array<ArrayBuffer>[] = [];
    let timed = false;   // a source or repair went: the timer re-arms from now
    const emit = (p: Uint8Array<ArrayBuffer>) => {
      packets.push(p);
      room -= p.length;
      timed = timed || p[0] !== LANE_TYPE_FEEDBACK;
    };
    this.refill(now);
    if (this.feedbackDue(now)) emit(this.feedbackPacket(now));
    if (this.timerDeadline >= 0 && now >= this.timerDeadline && this.nextEsi > this.heldFrom) {
      // Nothing sent for a whole timeout with data unacknowledged: repair the OLDEST window — where a hole below an
      // acknowledged newest symbol sits — and the newest, where a lost tail sits, when they differ.
      const oldest = Math.min(this.nextEsi - this.heldFrom, LANE_REPAIR_WINDOW);
      this.urgent.push({ first: this.heldFrom, count: oldest, n: 1 });
      const [first, count] = this.newestWindow();
      if (first !== this.heldFrom) this.urgent.push({ first, count, n: 1 });
      this.timerRto = Math.min(this.timerRto * 2, LANE_TIMER_MAX_MS);
      this.timerDeadline = now + Math.trunc(this.timerRto);
    }
    while (this.urgent.length > 0) {
      const plan = this.urgent[0]!;
      const [first, count] = this.clampWindow(plan.first, plan.count);
      if (count === 0) { this.urgent.shift(); continue; }
      if (this.repairSize(first, count) > room) break;
      emit(this.repairPacket(first, count, now));
      if (--plan.n === 0) this.urgent.shift();
    }
    while (this.hasPending() && this.nextEsi - this.heldFrom < LANE_HELD_MAX
           && room >= LANE_HEADER_BYTES + 4 + 2 + LANE_CHUNK_HEADER + 1) {
      const [symbol, ends, carried] = this.packSymbol(room - LANE_HEADER_BYTES - 4);
      const esi = this.nextEsi++;
      this.held.set(esi, { bytes: symbol, sentAt: now, ends, carried });
      emit(encodeLaneSource(this.nextPkt(), now, esi, symbol));
      if (++this.sinceRepair >= Math.floor(1000 / this.ratePermille())) { this.sinceRepair = 0; this.owe(); }
      this.tailDue = now + LANE_TAIL_FIRST_MS;
      this.tail2Due = this.lossPermille >= LANE_TAIL_SECOND_PERMILLE ? now + LANE_TAIL_SECOND_MS : -1;
    }
    if (this.tailDue >= 0 && now >= this.tailDue) { this.tailDue = -1; this.owe(); }
    if (this.tail2Due >= 0 && now >= this.tail2Due) { this.tail2Due = -1; this.owe(); }
    if (this.nextEsi === this.heldFrom) this.proactiveOwed = 0;   // nothing left to protect
    while (this.proactiveOwed > 0) {
      const [first, count] = this.newestWindow();
      const size = this.repairSize(first, count);
      if (size > room || size > this.tokens) break;
      this.tokens -= size;
      this.proactiveOwed--;
      emit(this.repairPacket(first, count, now));
    }
    if (this.nextEsi === this.heldFrom) this.timerDeadline = -1;
    else if (timed) this.timerDeadline = now + Math.trunc(this.timerRto);
    // A lone packet into an otherwise acknowledged lane (a keystroke's echo, a keepalive): its round trip is the path's.
    if (packets.length > 0 && packets.length <= 2 && this.nextEsi - this.heldFrom <= 1) this.markPristine(now);
    return packets;
  }

  /// Takes pending stream bytes — control, then input, then terminal — into one symbol of at most `limit`, and says
  /// where each stream it carried now ends.
  private packSymbol(limit: number): [Uint8Array, number[], boolean[]] {
    let space = Math.min(limit, LANE_SYMBOL_MAX) - 2;
    const chunks: LaneChunk[] = [];
    const ends = new Array<number>(LANE_STREAMS).fill(0);
    const carried = new Array<boolean>(LANE_STREAMS).fill(false);
    for (const s of LANE_STREAM_PRIORITY) {
      const o = this.out[s]!;
      while (o.bytes > 0 && space > LANE_CHUNK_HEADER) {
        const n = Math.min(space - LANE_CHUNK_HEADER, o.bytes);
        const offset = o.offset;
        chunks.push({ stream: s, offset, bytes: take(o, n) });
        space -= LANE_CHUNK_HEADER + n;
        ends[s] = o.offset;
        carried[s] = true;
      }
    }
    return [buildLaneSymbol(chunks), ends, carried];
  }

  private nextPkt(): number {
    const p = this.pkt;
    this.pkt = (this.pkt + 1) >>> 0;
    return p;
  }

  private owe(): void { this.proactiveOwed = Math.min(this.proactiveOwed + 1, LANE_PROACTIVE_OWED_MAX); }

  private ratePermille(): number {
    return Math.min(Math.max(LANE_RATE_LOSS_FACTOR * this.lossPermille, LANE_RATE_MIN_PERMILLE), LANE_RATE_MAX_PERMILLE);
  }

  private refill(now: number): void {
    if (now > this.tokensAt) {
      this.tokens = Math.min(LANE_BUDGET_BURST, this.tokens + (now - this.tokensAt) * LANE_BUDGET_BYTES_PER_MS);
      this.tokensAt = now;
    }
  }

  /// The newest ≤ 64 unacknowledged symbols — what tail, proportional and timer repair cover.
  private newestWindow(): [number, number] {
    const first = Math.max(this.heldFrom, this.nextEsi - LANE_REPAIR_WINDOW);
    return [first, this.nextEsi - first];
  }

  /// Trims a planned window to what is still held (acknowledgements may have arrived since).
  private clampWindow(first: number, count: number): [number, number] {
    const from = Math.max(first, this.heldFrom);
    const end = Math.min(first + count, this.nextEsi, from + LANE_REPAIR_WINDOW);
    return end <= from ? [from, 0] : [from, end - from];
  }

  private repairSize(first: number, count: number): number {
    let width = 0;
    for (let i = 0; i < count; i++) width = Math.max(width, this.held.get(first + i)!.bytes.length);
    return LANE_HEADER_BYTES + 10 + width;
  }

  private repairPacket(first: number, count: number, now: number): Uint8Array<ArrayBuffer> {
    const symbols: Uint8Array[] = [];
    for (let i = 0; i < count; i++) symbols.push(this.held.get(first + i)!.bytes);
    const seed = this.seed;
    this.seed = rlcNextSeed(seed);
    return encodeLaneRepair(this.nextPkt(), now, first, count, seed, rlcRepair(symbols, seed));
  }

  private feedbackDue(now: number): boolean {
    if (!this.everReceived) return false;
    return this.feedbackNow || this.arrivals >= LANE_FEEDBACK_EVERY
      || (this.arrivals > 0 && now - this.firstArrivalAt >= LANE_FEEDBACK_DELAY_MS)
      || now - this.lastFeedbackSentAt >= LANE_KEEPALIVE_MS;
  }

  private feedbackPacket(now: number): Uint8Array<ArrayBuffer> {
    const ranges: LaneRange[] = [];
    for (let esi = this.cumEsi + 1; esi <= this.highestEsi && ranges.length < LANE_RANGES_MAX;) {
      if (!this.decoder.has(esi)) { esi++; continue; }
      const start = esi;
      while (esi <= this.highestEsi && this.decoder.has(esi) && esi - start < 65535) esi++;
      ranges.push({ start, length: esi - start });
    }
    const f: LaneFeedback = {
      cumEsi: this.cumEsi, ranges, lossPermille: this.lossSeenPermille(), echoTs: this.lastTs,
      held: Math.min(Math.max(now - this.lastAt, 0), 65535),
    };
    if (this.cumEsi <= this.highestEsi) this.lastGapFeedbackAt = now;
    this.arrivals = 0;
    this.feedbackNow = false;
    this.lastFeedbackSentAt = now;
    return encodeLaneFeedback(this.nextPkt(), now, f);
  }

  /// When poll should run next (−1: nothing scheduled — a send or an arrival will call it).
  nextWake(now: number): number {
    let wake = -1;
    const at = (t: number) => { if (t >= 0 && (wake < 0 || t < wake)) wake = t; };
    if (this.everReceived) {
      if (this.arrivals > 0) at(this.firstArrivalAt + LANE_FEEDBACK_DELAY_MS);
      at(this.lastFeedbackSentAt + LANE_KEEPALIVE_MS);
    }
    at(this.tailDue);
    at(this.tail2Due);
    at(this.timerDeadline);
    if (this.proactiveOwed > 0 && this.nextEsi > this.heldFrom) {
      const [first, count] = this.newestWindow();
      const need = this.repairSize(first, count) - this.tokens;
      if (need > 0) at(now + Math.ceil(need / LANE_BUDGET_BYTES_PER_MS));
    }
    return wake >= 0 && wake < now ? now : wake;
  }

  /// 30 s holding unacknowledged data with no PROGRESS (`stalledFor`), or 30 s with a hole that cannot be filled — or at once, a peer
  /// that broke the protocol (`violated`). The GLUE acts on it only on a connected link (an outage is not a stuck lane)
  /// and calls resetStuck when the link connects.
  stuck(now: number): boolean {
    if (this.violated) return true;
    if (this.stalledFor(now) >= LANE_STUCK_MS) return true;
    return this.holeSince >= 0 && now - this.holeSince >= LANE_STUCK_MS;
  }

  /// How long the oldest unacknowledged symbol has waited for progress — since it was sent, the cumulative
  /// acknowledgement last moved, or the link last connected, whichever is latest — or −1 with nothing unacknowledged.
  stalledFor(now: number): number {
    if (this.nextEsi === this.heldFrom) return -1;
    return now - Math.max(this.lastProgressAt, this.held.get(this.heldFrom)!.sentAt);
  }

  resetStuck(now: number): void {
    this.lastFeedbackAt = now;
    this.lastProgressAt = now;
    if (this.holeSince >= 0) this.holeSince = now;
  }
}
