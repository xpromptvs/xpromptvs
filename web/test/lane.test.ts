import { describe, expect, it } from "vitest";
import {
  LaneEngine, LANE_BUDGET_BURST, LANE_BUDGET_BYTES_PER_MS, LANE_DECODER_HISTORY, LANE_HELD_MAX, LANE_MESSAGE_MAX, LANE_QUEUE_TARGET,
  LANE_RATE_BUCKETS, LANE_RATE_BUCKET_MS, LANE_REORDER_MS, LANE_REPAIR_WINDOW, LANE_STUCK_MS, LANE_TAIL_FIRST_MS,
  LANE_TIMER_INITIAL_MS, LANE_TIMER_MAX_MS,
} from "../src/lib/lane";
import {
  buildLaneSymbol, decodeLanePacket, encodeLaneFeedback, encodeLaneRepair, encodeLaneSource, LANE_PACKET_MAX,
  LANE_SYMBOL_MAX, LANE_TYPE_FEEDBACK, LANE_TYPE_REPAIR, LANE_TYPE_SOURCE, type LaneFeedback,
} from "../src/lib/lane-codec";
import parityFixture from "../../protocol/fixtures/lane-parity.json";

// THE LANE ENGINE OVER A SIMULATED LINK (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §3–§5): two
// engines on a fake millisecond clock, seeded loss — independent or in bursts —, a one-way delay, reordering and
// duplication. Side 0 is "a", side 1 is "b". The same cases host/streaming-engine/PionBridge/rdev_lane_engine_test.go
// runs against the Go engine, on the SAME pipe: the Go one draws from this generator, in the same order, so a seed is
// one run in both languages — which is what lets the parity digest (protocol/fixtures/lane-parity.json) hold them to
// one behaviour.
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

type Want = Uint8Array[][][]; // [side][stream] → the messages that side SENT

class LanePipe {
  readonly engines: [LaneEngine, LaneEngine];
  loss: [number, number] = [0, 0];       // indexed by the SENDER
  burst = 0;                              // mean burst length in packets; ≤ 1 is independent loss
  delay = 0;
  reorder = 0;                            // a packet's chance of 1–8 ms extra, so a later one can overtake it
  duplicate = 0;
  drop: ((from: number, packet: Uint8Array) => boolean) | null = null;   // a targeted loss on top
  // late > 0: a lost packet still arrives, `late` ms after it would have — the reliable carrier's retransmission
  // (spec §1, "The carrier"), a copy the lane's own repair has usually made redundant. No draw is made for it.
  late = 0;
  // What the data channel's queue may still take for a side's poll (null: LANE_QUEUE_TARGET) — 0 for a stretch at zero room.
  room: ((side: number, now: number) => number) | null = null;
  // A side whose timers never run: it polls only when a packet arrives (a hidden or suspended page).
  pollOnArrivalOnly: [boolean, boolean] = [false, false];
  now = 0;
  readonly got: Uint8Array[][][] = [[[], [], []], [[], [], []]];
  readonly gotAt: number[][][] = [[[], [], []], [[], [], []]];
  readonly sent: { at: number; packet: Uint8Array; lost: boolean }[][] = [[], []];
  readonly maxQuiet = [0, 0];             // the longest silence while holding unacknowledged data
  private readonly bad = [false, false];
  private readonly lastSent = [0, 0];
  // A side whose last poll filled its room. pion's queue drains by the next millisecond and the glue's
  // OnBufferedAmountLow polls again, so what the room held back — gap, timer or proactive repair — goes then.
  private readonly filled = [false, false];
  private inFlight: { at: number; to: number; data: Uint8Array }[] = [];
  private readonly random: () => number;

  constructor(seed: number, initial = 0) {
    this.random = mulberry32(seed);
    this.engines = [new LaneEngine(1, initial), new LaneEngine(2, initial)];
  }

  private lose(from: number): boolean {
    const loss = this.loss[from]!;
    if (loss <= 0) return false;
    if (loss >= 1) return true;
    if (this.burst <= 1) return this.random() < loss;
    // Gilbert–Elliott: every packet sent in the bad state is lost; bursts average `burst` packets and the
    // stationary share of the bad state is `loss`.
    if (this.bad[from]) { if (this.random() < 1 / this.burst) this.bad[from] = false; }
    else if (this.random() < loss / (this.burst * (1 - loss))) this.bad[from] = true;
    return this.bad[from]!;
  }

  private transmit(from: number, packets: Uint8Array[]): void {
    if (packets.length > 0) this.lastSent[from] = this.now;
    for (const packet of packets) {
      const lost = this.lose(from) || (this.drop?.(from, packet) ?? false);
      this.sent[from]!.push({ at: this.now, packet, lost });
      if (lost) {
        if (this.late > 0) this.inFlight.push({ at: this.now + this.delay + this.late, to: 1 - from, data: packet });
        continue;
      }
      const copies = this.random() < this.duplicate ? 2 : 1;
      for (let i = 0; i < copies; i++) {
        const extra = this.random() < this.reorder ? 1 + Math.floor(this.random() * 8) : 0;
        this.inFlight.push({ at: this.now + this.delay + extra, to: 1 - from, data: packet });
      }
    }
  }

  // Advance the clock 1 ms: arrivals first, then each side polls when something arrived, a timer is due, it has
  // data to send or its queue drained after a poll that filled it.
  step(): void {
    this.now++;
    const due = this.inFlight.filter((f) => f.at <= this.now);
    this.inFlight = this.inFlight.filter((f) => f.at > this.now);
    const arrived = [false, false];
    for (const f of due) {
      const e = this.engines[f.to]!;
      e.receive(f.data, this.now);
      arrived[f.to] = true;
      for (const d of e.takeDelivered()) {
        this.got[f.to]![d.stream]!.push(d.data);
        this.gotAt[f.to]![d.stream]!.push(this.now);
      }
    }
    this.engines.forEach((e, side) => {
      if (this.pollOnArrivalOnly[side] && !arrived[side]) return;
      const wake = e.nextWake(this.now);
      if (arrived[side] || e.hasPending() || this.filled[side] || (wake >= 0 && wake <= this.now)) {
        const room = this.room ? this.room(side, this.now) : LANE_QUEUE_TARGET;
        const packets = e.poll(this.now, room);
        this.transmit(side, packets);
        let size = 0;
        for (const packet of packets) size += packet.length;
        this.filled[side] = size > room - LANE_PACKET_MAX;
      }
      if (e.unacknowledged() > 0) this.maxQuiet[side] = Math.max(this.maxQuiet[side]!, this.now - this.lastSent[side]!);
    });
  }

  runUntil(done: () => boolean, limit: number): void { while (this.now < limit && !done()) this.step(); }

  sendAll(want: Want): void {
    want.forEach((streams, side) => streams.forEach((messages, stream) => {
      for (const m of messages) this.engines[side]!.send(stream, m);
    }));
  }

  delivered(want: Want): boolean {
    return want.every((streams, side) => streams.every((messages, stream) => this.got[1 - side]![stream]!.length >= messages.length));
  }

  expectDelivered(want: Want): void {
    want.forEach((streams, side) => streams.forEach((messages, stream) => {
      const got = this.got[1 - side]![stream]!;
      expect(got.length, `side ${side} stream ${stream}: delivered by ${this.now} ms`).toBe(messages.length);
      messages.forEach((m, i) => { if (!bytesEqual(got[i]!, m)) throw new Error(`side ${side} stream ${stream}: message ${i} differs`); });
    }));
  }
}

const bytesEqual = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((x, i) => x === b[i]);
const emptyWant = (): Want => [[[], [], []], [[], [], []]];
const text = (s: string) => new TextEncoder().encode(s);

/// Message i of a stream: its identity first, then a pattern, `size` bytes in all.
function message(stream: number, i: number, size: number): Uint8Array {
  const head = text(`${stream}:${i}:`);
  const out = new Uint8Array(Math.max(size, head.length));
  out.set(head);
  for (let j = head.length; j < out.length; j++) out[j] = (stream * 67 + i * 13 + j * 7) & 0xff;
  return out;
}

function typicalTraffic(): Want {
  const w = emptyWant();
  for (let i = 0; i < 300; i++) w[0]![0]!.push(message(0, i, 1 + ((i * 97) % 3000)));   // a's terminal output
  for (let i = 0; i < 100; i++) {
    w[0]![2]!.push(message(2, i, 40 + (i % 200)));   // a's control
    w[1]![2]!.push(message(2, i, 30 + (i % 50)));    // b's control
  }
  for (let i = 0; i < 200; i++) w[1]![1]!.push(message(1, i, 38));   // b's keystrokes
  return w;
}

function decoded(packet: Uint8Array) {
  const d = decodeLanePacket(packet);
  if (!d) throw new Error("the engine sent a malformed packet");
  return d;
}

const LONG = 60_000; // a vitest timeout for the longer simulations

describe("the lane delivers every message, in order, exactly once", () => {
  const cases: [string, { loss: number; reorder?: number; duplicate?: number; burst?: number }][] = [
    ["no loss", { loss: 0 }], ["5% loss", { loss: 0.05 }], ["15% loss", { loss: 0.15 }], ["30% loss", { loss: 0.3 }],
    ["5% loss, reordered and duplicated", { loss: 0.05, reorder: 0.2, duplicate: 0.1 }],
    ["5% loss in bursts of 4", { loss: 0.05, burst: 4 }],
  ];
  for (const [name, c] of cases) {
    it(name, () => {
      const p = new LanePipe(7);
      p.loss = [c.loss, c.loss]; p.delay = 40; p.reorder = c.reorder ?? 0; p.duplicate = c.duplicate ?? 0; p.burst = c.burst ?? 0;
      const want = typicalTraffic();
      p.sendAll(want);
      p.runUntil(() => p.delivered(want), 180_000);
      p.expectDelivered(want);
      p.maxQuiet.forEach((q, side) => expect(q, `side ${side} sat silent holding unacknowledged data`).toBeLessThanOrEqual(LANE_TIMER_MAX_MS + 1));
    }, LONG);
  }
});

// A HOLE IN THE TERMINAL STREAM DOES NOT HOLD CONTROL: each stream delivers as soon as ITS bytes are contiguous.
it("a hole in the terminal stream does not hold control", () => {
  const p = new LanePipe(3);
  p.delay = 40;
  p.drop = (from) => from === 0 && p.now <= 20;   // the terminal symbol AND its tail repair
  p.engines[0].send(0, text("terminal, sent first"));
  p.runUntil(() => p.now >= 21, 21);
  p.engines[0].send(2, text("control, sent second"));
  p.runUntil(() => p.got[1]![0]!.length === 1 && p.got[1]![2]!.length === 1, 5000);
  expect([p.gotAt[1]![0]!.length, p.gotAt[1]![2]!.length], "delivered terminal, control").toEqual([1, 1]);
  expect(p.gotAt[1]![2]![0]!, "control waited for the terminal's hole").toBeLessThan(p.gotAt[1]![0]![0]!);
});

// A LONE LOST PACKET IS REBUILT FROM THE TAIL REPAIR: within 10 ms + the one-way delay of being sent.
it("a lone lost packet is rebuilt from the tail repair", () => {
  const p = new LanePipe(5);
  p.delay = 40;
  p.drop = (from, packet) => from === 0 && packet[0] === LANE_TYPE_SOURCE;
  p.engines[0].send(1, text('{"t":"key","data":"a","term":"pty:1"}'));
  p.runUntil(() => p.got[1]![1]!.length === 1, 2000);
  expect(p.gotAt[1]![1]!.length, "the keystroke never arrived").toBe(1);
  expect(p.gotAt[1]![1]![0]!).toBeLessThanOrEqual(1 + LANE_TAIL_FIRST_MS + p.delay + 1);
});

// A LOST BURST END IS REPAIRED AT THE FIRST FEEDBACK AFTER IT, not by the timer one symbol at a time: the receiver
// decodes nothing above the loss, so no reported range shows it, but every lost symbol went more than LANE_REORDER_MS
// before the newest packet the receiver echoes (RACK).
it("a lost burst end is repaired at the first feedback after it", () => {
  const cut = 80; // every source from ESI 80 on is lost, and every repair sent with the burst
  const p = new LanePipe(43);
  p.delay = 40;
  p.drop = (from, packet) => {
    if (from !== 0) return false;
    const d = decoded(packet);
    if (d.kind === LANE_TYPE_SOURCE) return d.esi >= cut;
    if (d.kind === LANE_TYPE_REPAIR) return p.now <= 20;   // the burst's proportional repairs and its tail at +10
    return false;
  };
  const want = emptyWant();
  for (let i = 0; i < 107; i++) want[0]![0]!.push(message(0, i, 1000));   // 101 symbols: ESIs 0..100
  p.sendAll(want);
  let stuck = false;
  p.runUntil(() => {
    stuck = stuck || p.engines[1].stuck(p.now);
    return p.delivered(want);
  }, 60_000);
  p.expectDelivered(want);
  expect(p.engines[0].sentEsi - cut, "the test needs a burst end of ~20 lost source symbols").toBeGreaterThanOrEqual(20);
  let lastSource = 0;
  for (const s of p.sent[0]!) if (s.packet[0] === LANE_TYPE_SOURCE) lastSource = s.at;
  // The bound, from the rules. The burst's last packet is its tail repair, at lastSource + LANE_TAIL_FIRST_MS; it arms
  // the timer with the INITIAL 200 ms (no round trip is measured until the first feedback reaches a, 2 × delay after
  // the burst, and progress resets the backoff, not the deadline). The timer's repair reaches b one delay later and
  // names ESIs above b's newest, so b reports the hole at once; that report reaches a one delay later and echoes the
  // timer repair's ts — ~200 ms after every lost symbol went —, so all k are missing and draw k + 1 gap repairs:
  // 14 of ~1.1 KB fit one poll's 16 KB, the rest go 1 ms later, and they reach b one delay after that.
  const bound = lastSource + LANE_TAIL_FIRST_MS + LANE_TIMER_INITIAL_MS + 3 * p.delay + 1;
  const at = p.gotAt[1]![0]![p.gotAt[1]![0]!.length - 1]!;
  expect(at, "the first feedback after the loss should repair the burst end").toBeLessThanOrEqual(bound);
  expect(stuck, "the receiver was declared stuck").toBe(false);
});

// RACK SPARES SYMBOLS STILL IN FLIGHT: only a symbol sent more than LANE_REORDER_MS before the newest packet the
// receiver echoes is missing — the rest may simply not have arrived yet. (The pipe has no bandwidth limit, so the
// delivery tests REWARD over-repair; this is what holds the rule.)
it("RACK spares symbols still in flight", () => {
  const e = new LaneEngine(51);
  for (let i = 0; i < 30; i++) { e.send(2, new Uint8Array([i])); e.poll(i, LANE_QUEUE_TARGET); }   // ESIs 0..29 at 0..29 ms
  e.poll(39, LANE_QUEUE_TARGET);   // the tail repair goes; nothing else is owed

  // 0..9 acknowledged, nothing decoded above, the echo naming the packet sent at 25 ms: 10..14 went before
  // 25 − LANE_REORDER_MS and are missing (k = 5); 15..29 may still be in flight. One window, [10, 30): k + 1 repairs.
  e.receive(encodeLaneFeedback(0, 59, { cumEsi: 10, ranges: [], lossPermille: 0, echoTs: 25, held: 0 }), 60);
  const out = e.poll(60, LANE_QUEUE_TARGET).map(decoded);
  for (const d of out) {
    expect(d.kind, "only repairs over [10, 30)").toBe(LANE_TYPE_REPAIR);
    if (d.kind === LANE_TYPE_REPAIR) expect([d.esi, d.count], "repairs over [10, 30)").toEqual([10, 20]);
  }
  expect(out.length, `5 + 1 — only 10..14 went more than ${LANE_REORDER_MS} ms before the echo`).toBe(6);
});

// A REPORTED GAP DRAWS k + 1 REPAIRS OVER ITS WINDOW — and the same report within a round trip draws none.
it("a reported gap draws k + 1 repairs, and the same report within a round trip draws none", () => {
  const e = new LaneEngine(9);
  for (let i = 0; i < 10; i++) { e.send(2, new Uint8Array([i])); e.poll(i, LANE_QUEUE_TARGET); }   // ESIs 0..9 at 0..9 ms
  e.poll(19, LANE_QUEUE_TARGET);   // the tail repair goes; nothing else is owed

  const report: LaneFeedback = { cumEsi: 2, ranges: [{ start: 3, length: 2 }, { start: 6, length: 4 }], lossPermille: 0, echoTs: 9, held: 0 };   // 2 and 5 missing
  e.receive(encodeLaneFeedback(0, 10, report), 20);
  const out = e.poll(20, LANE_QUEUE_TARGET).map(decoded);
  for (const d of out) {
    expect(d.kind, "only repairs over [2, 10)").toBe(LANE_TYPE_REPAIR);
    if (d.kind === LANE_TYPE_REPAIR) expect([d.esi, d.count], "repairs over [2, 10)").toEqual([2, 8]);
  }
  expect(out.length, "2 missing symbols: 2 + 1 repairs").toBe(3);
  e.receive(encodeLaneFeedback(1, 11, report), 25);
  expect(e.poll(25, LANE_QUEUE_TARGET).length, "the same report within a round trip").toBe(0);
});

// THE TIMER DOUBLES TO ITS 1 s CAP AND NEVER GIVES UP when no feedback ever comes back.
it("the timer doubles to its 1 s cap and never gives up", () => {
  const p = new LanePipe(11);
  p.delay = 40;
  p.loss = [0, 1];   // nothing from b ever arrives
  p.engines[0].send(1, text("k"));
  p.runUntil(() => p.now >= 6000, 6000);
  const at = p.sent[0]!.filter((s) => s.packet[0] === LANE_TYPE_REPAIR).map((s) => s.at);
  // The tail at +10 re-arms the timer; then it fires 200 ms after the last send, doubling to the 1 s cap.
  expect(at).toEqual([11, 211, 611, 1411, 2411, 3411, 4411, 5411]);
});

// THE TIMER STAYS UNDER ITS 1 s CAP AT A LONG ROUND TRIP: the first sample makes the base srtt + 4·rttvar = 3 × the
// round trip, and progress must not arm a timeout past the cap with it.
it("the timer stays under its 1 s cap at a long round trip", () => {
  const p = new LanePipe(53);
  p.delay = 250;
  p.drop = (from) => from === 1 && p.now > 300;   // only b's first feedback gets back
  p.engines[0].send(1, text("k1"));
  p.runUntil(() => p.now >= 600, 600);
  const a = p.engines[0];
  expect(a.unacknowledged(), "precondition: k1 acknowledged").toBe(0);
  expect(a["rtoBase"](), "precondition: a base timeout past the cap").toBeGreaterThan(LANE_TIMER_MAX_MS);
  a.send(1, text("k2"));   // never acknowledged
  p.runUntil(() => p.now >= 6000, 6000);
  // k2 at 601 and its tail at 611; nothing comes back, so the timer fires at the cap, 1000 ms after each send — the
  // longest silence, read the millisecond before, is LANE_TIMER_MAX_MS − 1.
  expect(p.maxQuiet[0], "the sender's longest silence holding data").toBe(LANE_TIMER_MAX_MS - 1);
});

// THE TIMER REPAIRS THE OLDEST WINDOW, NOT ONLY THE NEWEST: a hole at heldFrom more than 64 symbols below the newest,
// the newest itself acknowledged, the gap repairs lost and no feedback after — only the timer can reach it.
it("the timer repairs the oldest window, not only the newest", () => {
  const e = new LaneEngine(47);
  for (let i = 0; i < 100; i++) { e.send(2, new Uint8Array([i])); e.poll(i, LANE_QUEUE_TARGET); }   // ESIs 0..99 at 0..99 ms
  e.poll(109, LANE_QUEUE_TARGET);   // the tail repair goes; nothing else is owed

  // 0..1 acknowledged and 3..99 decoded: a hole at 2, the newest acknowledged. The gap repairs it draws are lost.
  const report: LaneFeedback = { cumEsi: 2, ranges: [{ start: 3, length: 97 }], lossPermille: 0, echoTs: 99, held: 0 };
  e.receive(encodeLaneFeedback(0, 139, report), 140);
  expect(e.poll(140, LANE_QUEUE_TARGET).length, "the hole drew no gap repair").toBeGreaterThan(0);
  for (let now = 141; now <= 140 + LANE_TIMER_MAX_MS; now++) {
    const packets = e.poll(now, LANE_QUEUE_TARGET);
    if (packets.length === 0) continue;
    const windows: string[] = [];   // nothing else is owed, so the first packets after the gap repairs are the timer's
    for (const d of packets.map(decoded)) {
      if (d.kind === LANE_TYPE_REPAIR && d.esi === 2 && d.count === LANE_REPAIR_WINDOW) return;
      windows.push(d.kind === LANE_TYPE_REPAIR ? `repair [${d.esi}, +${d.count})` : `type ${d.kind}`);
    }
    throw new Error(`the timer at ${now} ms sent ${windows.join(", ")}; want a repair over the oldest window [2, +64)`);
  }
  throw new Error("the timer never fired");
});

// THE 64 kbit/s BUDGET CAPS PROACTIVE REPAIR, however much the loss rate asks for.
it("the 64 kbit/s budget caps proactive repair", () => {
  const e = new LaneEngine(13);
  e.receive(encodeLaneFeedback(0, 0, { cumEsi: 0, ranges: [], lossPermille: 500, echoTs: 0, held: 0 }), 0);   // r = 50%: a repair every 2 symbols
  let proactive = 0;
  for (let now = 1; now <= 2000; now++) {
    e.send(0, new Uint8Array(1000).fill(7));
    for (const b of e.poll(now, LANE_QUEUE_TARGET)) if (b[0] === LANE_TYPE_REPAIR) proactive += b.length;
    // Everything acknowledged at once, so no repair is a GAP repair.
    e.receive(encodeLaneFeedback(now, now, { cumEsi: e.sentEsi, ranges: [], lossPermille: 500, echoTs: now, held: 0 }), now);
  }
  const limit = LANE_BUDGET_BURST + LANE_BUDGET_BYTES_PER_MS * 2000 + LANE_PACKET_MAX;
  expect(proactive, "bytes of proactive repair in 2 s").toBeLessThanOrEqual(limit);
  expect(proactive, "the test never reached the budget").toBeGreaterThan(limit / 2);
});

// PAST 512 UNACKNOWLEDGED SYMBOLS THE STREAMS REPORT FULL, AND DRAIN AS ACKNOWLEDGEMENTS COME — nothing dropped or
// reordered (a full re-send of every tab is bigger than the window).
it("past 512 unacknowledged symbols the streams report full, and drain in order", () => {
  const p = new LanePipe(17);
  p.delay = 40;
  p.loss = [0, 1];   // no acknowledgement reaches a
  const want = emptyWant();
  for (let i = 0; i < 600; i++) want[0]![0]!.push(message(0, i, 1000));
  p.sendAll(want);
  p.runUntil(() => p.now >= 500, 500);
  expect(p.sent[0]!.filter((s) => s.packet[0] === LANE_TYPE_SOURCE).length, "symbols sent with nothing acknowledged").toBe(LANE_HELD_MAX);
  // Nothing acknowledged: the stream reports everything handed (600 KB), not only what is not yet in a symbol.
  expect(p.engines[0].buffered(0), "past the window with nothing acknowledged the stream reports everything handed").toBe(600 * 1000);
  p.loss = [0, 0];
  p.runUntil(() => p.delivered(want), 60_000);
  p.expectDelivered(want);
}, LONG);

// THE QUEUE TARGET FOLLOWS THE DELIVERY RATE AT THE BASE ROUND TRIP: pion counts unacknowledged bytes as buffered, so
// a fixed ceiling would cap the lane at 16 KB a round trip — and a target sized from srtt sized itself: srtt carries
// the queue, which the target holds (measured: srtt 11 s, the target 11 MB). The base is the least pristine sample —
// a packet sent into a lane holding nothing else unacknowledged.
it("the queue target follows the delivery rate at the base round trip", () => {
  const e = new LaneEngine(43);
  const ack = (pkt: number, now: number, echoTs: number) =>
    e.receive(encodeLaneFeedback(pkt, now, { cumEsi: e.sentEsi, ranges: [], lossPermille: 0, echoTs, held: 0 }), now);
  expect(e.queueTarget(0), "an idle lane's target").toBe(LANE_QUEUE_TARGET);
  // A lone symbol, acknowledged 20 ms later: the base round trip is 20 ms.
  e.send(2, text("a keystroke's echo"));
  e.poll(0, 2 ** 30);
  ack(0, 20, 0);
  expect(e.baseRoundTrip, "the base round trip").toBe(20);
  // A 100 KB burst at t=1000, acknowledged whole at t=1500: a 500 ms sample that is the queue, not the path.
  for (let i = 0; i < 100; i++) e.send(0, new Uint8Array(1000));
  e.poll(1000, 2 ** 30);
  ack(1, 1500, 1000);
  expect(e.baseRoundTrip, "a burst's acknowledgement must not move the base").toBe(20);
  expect(e.smoothedRoundTrip, "srtt took the burst's 500 ms sample").toBeGreaterThanOrEqual(60);
  // ~100 KB/s over the last second, at a 20 ms base: 2 × 100 KB/s × 20 ms = ~4 KB over the floor — not ~10 KB (srtt).
  const got = e.queueTarget(1510);
  expect(got, "the target after ~100 KB/s at a 20 ms base").toBeGreaterThanOrEqual(LANE_QUEUE_TARGET + 2 * 90 * 20);
  expect(got, "the target after ~100 KB/s at a 20 ms base").toBeLessThanOrEqual(LANE_QUEUE_TARGET + 2 * 110 * 20);
  expect(e.queueTarget(1510 + LANE_RATE_BUCKETS * LANE_RATE_BUCKET_MS), "a second later the rate must age out").toBe(LANE_QUEUE_TARGET);
});

// BEFORE A PRISTINE SAMPLE THE TARGET USES THE INITIAL TIMER, NOT SRTT: a lane that opens into a burst never sends a
// lone packet, its srtt is the queue's (1.2 s after a blackout, measured), and a target sized from it asked for 967 KB.
it("the queue target never falls back to srtt", () => {
  const e = new LaneEngine(43);
  for (let i = 0; i < 100; i++) e.send(0, new Uint8Array(1000));
  e.poll(0, 2 ** 30);   // ~100 symbols in one poll: nothing pristine
  e.receive(encodeLaneFeedback(0, 500, { cumEsi: e.sentEsi, ranges: [], lossPermille: 0, echoTs: 0, held: 0 }), 500);
  expect(e.baseRoundTrip, "a burst's acknowledgement must not be a base sample").toBeNull();
  expect(e.smoothedRoundTrip, "srtt took the 500 ms sample").toBeGreaterThanOrEqual(400);
  // ~100 KB/s over the last second at the 200 ms initial timer: ≤ 16 KB + 2 × 110 KB/s × 200 ms — not ~116 KB (srtt).
  expect(e.queueTarget(510), "the target with no base known").toBeLessThanOrEqual(LANE_QUEUE_TARGET + 2 * 110 * LANE_TIMER_INITIAL_MS);
});

// THE BASE ROUND TRIP'S RULES, each one: a sample is pristine only when its poll sent ≤ 2 packets and left ≤ 1 symbol
// unacknowledged; a second's samples keep their least; a sample ages out of the 10 s window; with the window empty the
// last base stands. rdev_lane_engine_test.go runs the same cases.
describe("the base round trip's rules", () => {
  const ack = (e: LaneEngine, pkt: number, now: number, echoTs: number) =>
    e.receive(encodeLaneFeedback(pkt, now, { cumEsi: e.sentEsi, ranges: [], lossPermille: 0, echoTs, held: 0 }), now);
  it("a lone symbol is pristine; a symbol beside a feedback is too", () => {
    const e = new LaneEngine(1);
    e.send(2, text("lone"));
    expect(e.poll(0, 2 ** 30).length, "the lone symbol").toBe(1);
    ack(e, 0, 30, 0);
    expect(e.baseRoundTrip, "the base from the lone symbol").toBe(30);
    // The peer's own data makes this end owe feedback; the next poll sends that feedback AND a symbol: two packets.
    e.receive(encodeLaneSource(1, 100, 0, buildLaneSymbol([{ stream: 2, offset: 0, bytes: new Uint8Array([0, 0, 0, 1, 120]) }])), 100);
    e.send(2, text("second"));
    expect(e.poll(120, 2 ** 30).length, "a feedback and a symbol").toBe(2);
    ack(e, 2, 140, 120);
    expect(e.baseRoundTrip, "a symbol beside a feedback is pristine").toBe(20);
  });
  it("a burst is not pristine, nor a poll that leaves two symbols unacknowledged", () => {
    const e = new LaneEngine(1);
    for (let i = 0; i < 3; i++) e.send(0, new Uint8Array(1000));
    e.poll(0, 2 ** 30);   // three symbols
    ack(e, 0, 30, 0);
    expect(e.baseRoundTrip, "a three-symbol poll gives no base").toBeNull();
    e.send(0, new Uint8Array(1500));   // two symbols, one message
    expect(e.poll(100, 2 ** 30).length, "two symbols").toBe(2);
    ack(e, 1, 130, 100);
    expect(e.baseRoundTrip, "a poll leaving two symbols unacknowledged gives no base").toBeNull();
  });
  it("a second keeps its least sample; the window ages out; the last base stands", () => {
    const e = new LaneEngine(1);
    const lone = (now: number, rtt: number, pkt: number) => { e.send(2, text("k")); e.poll(now, 2 ** 30); ack(e, pkt, now + rtt, now); };
    lone(0, 10, 0);
    lone(200, 40, 1);   // the same second: the least stands, not the last
    expect(e.baseRoundTrip, "the second's least").toBe(10);
    lone(3000, 25, 2);
    expect(e.baseRoundTrip, "10 while its sample is in the window").toBe(10);
    lone(11_500, 25, 3);   // second 11: second 0's sample has aged out (> 10 s), second 3's has not
    expect(e.baseRoundTrip, "25 once the 10 ms sample aged out").toBe(25);
    // 30 s of burst: no pristine sample, the last base stands (never zero for lack of samples).
    for (let i = 0; i < 50; i++) e.send(0, new Uint8Array(1000));
    e.poll(12_000, 2 ** 30);
    ack(e, 4, 42_000, 12_000);
    expect(e.baseRoundTrip, "the last base stands").toBe(25);
  });
});

// A PACKET NO NEWER THAN THE NEWEST SEEN MEASURES NOTHING. The carrier is reliable, so SCTP's late copy of a packet
// the lane counted lost — or a reorder — arrives after newer ones: it must not cancel the loss (the estimate is of
// loss on FIRST transmission, what the lane's repair faces), and the echo must time the NEWEST packet, or the sender's
// round trip takes SCTP's retransmission delay. rdev_lane_engine_test.go runs the same case.
it("a late copy moves neither the loss window nor the echo", () => {
  const e = new LaneEngine(61);
  const source = (pkt: number, ts: number, esi: number) =>
    encodeLaneSource(pkt, ts, esi, buildLaneSymbol([{ stream: 2, offset: esi * 5, bytes: new Uint8Array([0, 0, 0, 1, 97 + esi]) }]));
  const feedback = (now: number): LaneFeedback => {
    for (const packet of e.poll(now, 2 ** 30)) {
      const d = decodeLanePacket(packet);
      if (d?.kind === LANE_TYPE_FEEDBACK) return d.feedback;
    }
    throw new Error(`no feedback at ${now} ms`);
  };
  e.receive(source(0, 10, 0), 100);
  e.receive(source(2, 30, 2), 120);   // packet 1 (ESI 1) lost on its first transmission
  const first = feedback(120);
  expect([first.echoTs, first.lossPermille], "precondition: the feedback after the gap").toEqual([30, 333]);
  e.receive(source(1, 20, 1), 400);   // SCTP's late copy of packet 1
  const second = feedback(420);
  expect(second.cumEsi, "the late copy's symbol was used").toBe(3);
  expect.soft([second.echoTs, second.held], "the echo times packet 2, the newest — a late copy's would add SCTP's retransmission delay to the sender's round trip").toEqual([30, 300]);
  expect.soft(second.lossPermille, "the late copy must not cancel the loss — the estimate is of loss on first transmission, what the lane's repair faces").toBe(333);
});

// ...AND A LATE FEEDBACK GIVES NO ROUND-TRIP SAMPLE: SCTP's late copy of a feedback the peer sent before its newest
// packet echoes a packet this end sent long before, so its sample is the retransmission delay, not the path. Its
// acknowledgement still counts. rdev_lane_engine_test.go runs the same case.
it("a late feedback gives no round-trip sample", () => {
  const e = new LaneEngine(62);
  for (let i = 0; i < 2; i++) { e.send(2, new Uint8Array([97 + i])); e.poll(i, 2 ** 30); }   // ESIs 0 and 1, sent at 0 and 1 ms
  e.receive(encodeLaneFeedback(3, 30, { cumEsi: 1, ranges: [], lossPermille: 0, echoTs: 0, held: 0 }), 30);
  expect(e.smoothedRoundTrip, "precondition").toBe(30);
  e.receive(encodeLaneSource(5, 40, 0, buildLaneSymbol([{ stream: 2, offset: 0, bytes: new Uint8Array([0, 0, 0, 1, 120]) }])), 40);
  // The peer's packet 4, a feedback sent between those two, arrives late: it acknowledges ESI 1, echoing ts 1.
  e.receive(encodeLaneFeedback(4, 31, { cumEsi: 2, ranges: [], lossPermille: 0, echoTs: 1, held: 0 }), 500);
  expect(e.smoothedRoundTrip, "a late feedback's 499 ms sample is SCTP's retransmission delay, not the round trip").toBe(30);
  expect(e.unacknowledged(), "the late feedback's acknowledgement still counts").toBe(0);
});

// ...AND A LATE FEEDBACK APPLIES ONLY ITS CUMULATIVE ACKNOWLEDGEMENT. One no newer than the newest FEEDBACK seen
// (here the peer's packet 5 after its packet 6) describes the receiver as it was: its loss, its ranges and the gap
// repairs they would plan must leave the newer report standing — whatever it says. What it acknowledges cumulatively
// is still acknowledged. rdev_lane_engine_test.go runs the same case.
it("a late feedback applies only its cumulative acknowledgement", () => {
  const e = new LaneEngine(63);
  for (let i = 0; i < 10; i++) { e.send(2, new Uint8Array([i])); e.poll(i, LANE_QUEUE_TARGET); }   // ESIs 0..9 at 0..9 ms
  e.poll(19, LANE_QUEUE_TARGET);   // the tail repair goes; nothing else is owed
  // The newest feedback: 0..2 decoded, nothing above, no loss, echoing the packet sent at 9 ms — nothing missing.
  e.receive(encodeLaneFeedback(6, 39, { cumEsi: 3, ranges: [], lossPermille: 0, echoTs: 9, held: 0 }), 40);
  expect(e.poll(40, LANE_QUEUE_TARGET).length, "precondition: the newest feedback shows nothing missing").toBe(0);
  // Its packet 5 arrives late: 3 decoded too, a hole at 4..7 under 8..9, 40% loss.
  e.receive(encodeLaneFeedback(5, 38, { cumEsi: 4, ranges: [{ start: 8, length: 2 }], lossPermille: 400, echoTs: 9, held: 0 }), 41);
  expect.soft(e["heldFrom"], "the late feedback's cumulative acknowledgement").toBe(4);
  expect.soft(e["lossPermille"], "the late feedback's loss must not overwrite the newest feedback's").toBe(0);
  expect.soft(e["knownAbove"].size, "the late feedback must not rebuild the ranges known above the acknowledgement").toBe(0);
  expect.soft(e.poll(41, LANE_QUEUE_TARGET).length, "gap repairs drawn by the late feedback's stale holes").toBe(0);
});

// A LATE-FILLED HOLE RELEASES EVERYTHING ABOVE IT IN ONE FEEDBACK — 160 KB at once after a 10 s stall on a 12.5 KB/s
// link (measured). The rate is the bytes acknowledged over the last SECOND, so that lump reads as 160 KB/s, not the
// 1.6 MB/s a best-100-ms bucket made of it (which raised the target by 64 KB: 5 s of link).
it("a lump of acknowledgements does not blow up the queue target", () => {
  const e = new LaneEngine(43);
  const ack = (pkt: number, now: number, echoTs: number) =>
    e.receive(encodeLaneFeedback(pkt, now, { cumEsi: e.sentEsi, ranges: [], lossPermille: 0, echoTs, held: 0 }), now);
  e.send(2, text("x"));
  e.poll(0, 2 ** 30);
  ack(0, 20, 0);   // base 20 ms
  for (let i = 0; i < 160; i++) e.send(0, new Uint8Array(1000));
  e.poll(1000, 2 ** 30);
  ack(1, 11_000, 1000);
  expect(e.queueTarget(11_010), "the target after a 160 KB lump").toBeLessThanOrEqual(LANE_QUEUE_TARGET + 2 * 170 * 20);
});

it("a stuck lane is declared after 30 s, and resetStuck restarts the clock", () => {
  const e = new LaneEngine(19);
  e.send(1, text("k"));
  e.poll(0, LANE_QUEUE_TARGET);
  expect(e.stuck(LANE_STUCK_MS - 1), "stuck before 30 s").toBe(false);
  expect(e.stuck(LANE_STUCK_MS), "30 s holding data with no feedback").toBe(true);
  e.resetStuck(LANE_STUCK_MS);   // the connection came back: the clock starts over
  expect(e.stuck(2 * LANE_STUCK_MS - 1), "resetStuck restarts the 30 s").toBe(false);
  expect(e.stuck(2 * LANE_STUCK_MS), "resetStuck restarts the 30 s").toBe(true);
  const r = new LaneEngine(23);
  r.receive(encodeLaneSource(0, 0, 1, buildLaneSymbol([{ stream: 1, offset: 0, bytes: new Uint8Array([0, 0, 0, 1, 107]) }])), 0);   // ESI 0 never comes
  expect(r.stuck(LANE_STUCK_MS - 1), "a receiver with a hole it cannot fill, before 30 s").toBe(false);
  expect(r.stuck(LANE_STUCK_MS), "a receiver with a hole it cannot fill, at 30 s").toBe(true);
});

// THE RECEIVER'S 30 s IS FOR A HOLE IT CANNOT FILL, not for some hole at every arrival: under sustained output on a
// lossy path the oldest hole keeps filling while a newer one opens above it — a lane that works.
// STUCK MEANS NO PROGRESS, NOT NO FEEDBACK (stalledFor): the peer's keepalive feedback, acknowledging nothing new,
// kept a lane whose own packets never arrived alive forever (2026-10-13: a phone's keystrokes held in its SCTP's
// backoff, the Mac's packets still getting through — typing with no reply, neither end ever stuck). A feedback that
// moves the cumulative acknowledgement IS progress.
it("stuck means no progress, not no feedback", () => {
  const e = new LaneEngine(19, 0);
  e.send(1, new Uint8Array([107]));
  e.poll(0, LANE_QUEUE_TARGET);
  expect(e.stalledFor(1000), "stalledFor after 1 s holding").toBe(1000);
  for (let at = 1000; at < LANE_STUCK_MS; at += 1000) {   // the peer's keepalive, every second, acknowledging nothing
    e.receive(encodeLaneFeedback(at / 1000, at, { cumEsi: 0, ranges: [], lossPermille: 0, echoTs: 0, held: 0 }), at);
  }
  expect(e.stuck(LANE_STUCK_MS), "feedback that acknowledges nothing kept the lane from being stuck").toBe(true);
  e.receive(encodeLaneFeedback(100, LANE_STUCK_MS, { cumEsi: 1, ranges: [], lossPermille: 0, echoTs: 0, held: 0 }), LANE_STUCK_MS);
  expect(e.stuck(LANE_STUCK_MS + 1), "an acknowledgement is progress").toBe(false);
  expect(e.stalledFor(LANE_STUCK_MS + 1), "nothing held").toBe(-1);
});

it("a hole that keeps filling is not stuck", () => {
  const r = new LaneEngine(55);
  const empty = buildLaneSymbol([]);
  let pkt = 0;
  const arrive = (esi: number, now: number) => {
    r.receive(encodeLaneSource(pkt, now, esi, empty), now);
    pkt++;
    if (r["cumEsi"] > r["highestEsi"]) throw new Error(`precondition: no hole at ${now} ms`);
  };
  arrive(1, 0);   // a hole at 0
  let now = 0;
  for (let i = 1; i <= (2 * LANE_STUCK_MS) / 1000; i++) {   // a second apart, for twice the threshold
    now = i * 1000;
    arrive(2 * i + 1, now);   // a new hole opens at 2i…
    arrive(2 * i - 2, now);   // …and the oldest, 2i − 2, fills: cumEsi moves on to 2i
    expect(r.stuck(now), `stuck at ${now} ms, though every hole so far filled within a second`).toBe(false);
  }
  // And a hole that stops filling, while data keeps arriving above it, is stuck 30 s after cumEsi last moved.
  const last = now;
  for (let esi = 2 * (now / 1000) + 3; now < last + LANE_STUCK_MS; esi++) {
    now += 1000;
    arrive(esi, now);
    expect(r.stuck(now - 1), `stuck at ${now - 1} ms; the hole has not filled since ${last} ms`).toBe(now - 1 - last >= LANE_STUCK_MS);
  }
  expect(r.stuck(now), `${now - last} ms after the hole last filled`).toBe(true);
});

// A PEER THAT BREAKS THE PROTOCOL CLOSES THE LANE, AND GROWS NOTHING (Important 4 of the final review): none of
// these is reachable from a conforming peer. A chunk further ahead of the delivered offset than the sender's window
// could carry would sit in `segments` forever — cumEsi still advances, so nothing else ever notices — and a frame header
// claiming more than a message would grow `framed` to 4 GiB. rdev_lane_engine_test.go runs the same cases.
it("a chunk past the sender's window closes the lane", () => {
  const r = new LaneEngine(65);
  const bound = LANE_HELD_MAX * LANE_SYMBOL_MAX;
  r.receive(encodeLaneSource(0, 0, 0, buildLaneSymbol([{ stream: 0, offset: bound, bytes: new Uint8Array([1]) }])), 0);
  expect([r.stuck(0), r["in"][0]!.segments.size], "a chunk at the window's reach is a conforming sender's").toEqual([false, 1]);
  r.receive(encodeLaneSource(1, 1, 1, buildLaneSymbol([{ stream: 0, offset: bound + 1, bytes: new Uint8Array([2]) }])), 1);
  expect.soft(r.stuck(1), "a chunk past what the sender's window could hold closes the lane").toBe(true);
  expect.soft(r["in"][0]!.segments.size, "a chunk past what the sender's window could hold is not kept").toBe(1);
});

it("a frame longer than any message closes the lane", () => {
  const frame = (size: number) => {
    const header = new Uint8Array(4);
    new DataView(header.buffer).setUint32(0, size);
    return encodeLaneSource(0, 0, 0, buildLaneSymbol([{ stream: 2, offset: 0, bytes: header }]));
  };
  const ok = new LaneEngine(66);
  ok.receive(frame(LANE_MESSAGE_MAX), 0);
  expect(ok.stuck(0), "a frame of exactly 1 MiB is a message, waiting for its bytes").toBe(false);
  const broken = new LaneEngine(67);
  broken.receive(frame(LANE_MESSAGE_MAX + 1), 0);
  expect(broken.stuck(0), "a frame claiming more than 1 MiB closes the lane").toBe(true);
});

// AN ESI PAST WHAT THE SENDER'S WINDOW COULD HOLD IS REFUSED: it would lift highestEsi by up to 2³¹, and every feedback
// after would walk cumEsi…highestEsi.
it("an ESI past the sender's window is refused", () => {
  const r = new LaneEngine(68);
  const empty = buildLaneSymbol([]);
  r.receive(encodeLaneSource(0, 0, LANE_DECODER_HISTORY - 1, empty), 0);
  expect(r["highestEsi"], "precondition: a source within the decoder's history is taken").toBe(LANE_DECODER_HISTORY - 1);
  r.receive(encodeLaneSource(1, 0, LANE_DECODER_HISTORY, empty), 0);
  expect.soft(r["highestEsi"], `a source at cumEsi + ${LANE_DECODER_HISTORY}`).toBe(LANE_DECODER_HISTORY - 1);
  r.receive(encodeLaneRepair(2, 0, LANE_DECODER_HISTORY - 1, 2, 1, new Uint8Array(2)), 0);
  r.receive(encodeLaneRepair(3, 0, 2 ** 31, 1, 1, new Uint8Array(2)), 0);
  expect.soft(r["highestEsi"], `a repair reaching past cumEsi + ${LANE_DECODER_HISTORY}`).toBe(LANE_DECODER_HISTORY - 1);
});

// A SYMBOL THE ENGINE CANNOT USE LEAVES ITS HOLE: one that does not parse, or a known ESI whose symbol the decoder no
// longer holds, must not be acknowledged — `get(esi)!` threw on the second, abandoning the rest of what was known, and
// the Mac's engine moved cumESI past bytes no stream was given. The hole stays, and at 30 s the lane is stuck.
it("a symbol the engine cannot use leaves its hole", () => {
  const r = new LaneEngine(69);
  r.receive(encodeLaneSource(0, 0, 0, new Uint8Array([0xff, 0xff])), 0);   // a length no symbol has
  expect.soft(r["cumEsi"], "a symbol that does not parse is not acknowledged").toBe(0);
  expect.soft(r.stuck(LANE_STUCK_MS), "the hole a malformed symbol leaves is stuck at 30 s").toBe(true);
  const gone = new LaneEngine(70);
  expect(() => gone["noteData"](0, 0, [0]), "a known ESI the decoder does not hold").not.toThrow();
  expect.soft(gone["cumEsi"], "a symbol the decoder does not hold is not acknowledged").toBe(0);
});

it("the counters wrap", () => {
  const p = new LanePipe(29, 2 ** 32 - 40);
  p.loss = [0.05, 0.05]; p.delay = 20;
  const want = emptyWant();
  for (let i = 0; i < 200; i++) want[0]![0]!.push(message(0, i, 1500));
  for (let i = 0; i < 50; i++) want[1]![1]!.push(message(1, i, 38));
  p.sendAll(want);
  p.runUntil(() => p.delivered(want), 60_000);
  p.expectDelivered(want);
}, LONG);

it("refuses an empty and an oversize message, and carries one of exactly 1 MiB", () => {
  const e = new LaneEngine(31);
  expect(() => e.send(0, new Uint8Array(0)), "an empty message (pion refuses an empty send too)").toThrow(RangeError);
  expect(() => e.send(0, new Uint8Array(LANE_MESSAGE_MAX + 1)), "a message over 1 MiB").toThrow(RangeError);
  const p = new LanePipe(37);
  p.loss = [0.05, 0.05]; p.delay = 20;
  const want = emptyWant();
  want[0]![2]!.push(message(2, 0, LANE_MESSAGE_MAX));
  p.sendAll(want);
  p.runUntil(() => p.delivered(want), 60_000);
  p.expectDelivered(want);
}, LONG);

// REVIEW FOCUS 1: a receiver that polls only when a packet arrives (its timers throttled or suspended) still
// acknowledges what arrives — the sender's timer repairs and its keepalive draw feedback — so the sender is never stuck.
it("a receiver polled only on arrival still acknowledges", () => {
  const p = new LanePipe(41);
  p.loss = [0.05, 0.05]; p.delay = 40;
  p.pollOnArrivalOnly[1] = true;
  const want = emptyWant();
  for (let i = 0; i < 200; i++) want[0]![0]!.push(message(0, i, 700));
  p.sendAll(want);
  p.runUntil(() => p.delivered(want), 120_000);
  p.expectDelivered(want);
  const a = p.engines[0];
  p.runUntil(() => a.unacknowledged() === 0, p.now + 10_000);
  expect(a.unacknowledged(), "symbols still unacknowledged 10 s after delivery").toBe(0);
  expect(a.stuck(p.now), "the sender was declared stuck").toBe(false);
}, LONG);

// A STREAM'S BUFFERED AMOUNT IS WHAT THE PEER HAS NOT ACKNOWLEDGED, IN PAYLOAD BYTES: TermPacer's model of the number
// (pion's bufferedAmount counts bytes until SCTP acknowledges them). Not the bytes not yet in a symbol — those read 0
// whenever the lane had room, and the pacer handed a whole re-send into the stream's FIFO; and not the framed bytes —
// 4 more per message, so `handed − buffered` stepped back by 4 per message and TermPath's rate wrapped.
it("a stream's buffered amount is what the peer has not acknowledged", () => {
  const e = new LaneEngine(5);
  for (const size of [10, 20, 30]) e.send(0, new Uint8Array(size));
  expect(e.buffered(0), "three pending messages of 60 payload bytes (72 would be the framed bytes)").toBe(60);
  expect(e.poll(0, 2 ** 30).length, "one symbol").toBe(1);
  expect(e.buffered(0), "in a symbol and unacknowledged, the stream still holds 60").toBe(60);
  e.receive(encodeLaneFeedback(0, 10, { cumEsi: e.sentEsi, ranges: [], lossPermille: 0, echoTs: 0, held: 0 }), 10);
  expect(e.buffered(0), "acknowledged, the stream holds nothing").toBe(0);
});

// `handed − buffered` NEVER DECREASES: acknowledgements arrive by symbol, a symbol boundary falls anywhere in a
// message — inside a 1-byte message's 4-byte prefix too — and a step back wraps TermPath's rate (the host crashed on
// the Int conversion). Checked after every step of a lossy run of messages of every size.
it("handed minus buffered never decreases", () => {
  const p = new LanePipe(23);
  p.loss = [0.1, 0.1]; p.delay = 30;
  const want = emptyWant();
  for (let i = 0; i < 400; i++) want[0]![0]!.push(message(0, i, i % 7 === 0 ? 1 : 1 + ((i * 37) % 1500)));
  p.sendAll(want);
  const handed = want[0]![0]!.reduce((n, m) => n + m.length, 0);
  const a = p.engines[0];
  let least = -1;
  // Through delivery, then on until the last acknowledgement is back (a one-way delay after the last delivery).
  while (p.now < 60_000 && (!p.delivered(want) || a.unacknowledged() > 0)) {
    p.step();
    const acked = handed - a.buffered(0);
    if (acked < least) throw new Error(`at ${p.now} ms handed − buffered fell from ${least} to ${acked}`);
    least = acked;
  }
  p.expectDelivered(want);
  expect([a.unacknowledged(), a.buffered(0)], "unacknowledged symbols, buffered bytes once everything is acknowledged").toEqual([0, 0]);
}, LONG);

// THE TWO ENGINES ARE ONE BEHAVIOUR: each scenario of protocol/fixtures/lane-parity.json — loss, bursts, reordering,
// duplicates, late copies, a stretch at zero room, both directions, counters at the wrap — run over the pipe, every
// packet each side emits hashed in order, against the digests rdev_lane_engine_test.go asserts too. The byte-level
// vectors pin the encodings; only this catches a feedback-timing or repair-planning rule changed on one side. A digest
// that moves is pasted in from the failing suite's message, and the other suite must then pass unchanged.
interface ParitySide { packets: number; sha256: string; checkpoints: string[] }
interface ParityScenario {
  name: string; seed: number; initial: number; delay: number; loss: [number, number]; burst: number; reorder: number;
  duplicate: number; late: number; zeroRoom: { side: number; from: number; to: number }[];
  traffic: { side: number; stream: number; count: number; size: [number, number, number]; at: number; every: number }[];
  end: number; sides: [ParitySide, ParitySide];
}

async function runParity(s: ParityScenario, checkpointEvery: number): Promise<[ParitySide, ParitySide]> {
  const p = new LanePipe(s.seed, s.initial);
  p.delay = s.delay; p.loss = [...s.loss]; p.burst = s.burst; p.reorder = s.reorder; p.duplicate = s.duplicate; p.late = s.late;
  if (s.zeroRoom.length > 0) {
    p.room = (side, now) => s.zeroRoom.some((z) => z.side === side && now >= z.from && now < z.to) ? 0 : LANE_QUEUE_TARGET;
  }
  const want = emptyWant();
  const sent = s.traffic.map(() => 0);
  while (p.now < s.end) {
    s.traffic.forEach((tr, k) => {
      for (; sent[k]! < tr.count && tr.at + sent[k]! * tr.every <= p.now; sent[k]!++) {
        const m = message(tr.stream, sent[k]!, tr.size[0] + ((sent[k]! * tr.size[1]) % tr.size[2]));
        p.engines[tr.side as 0 | 1].send(tr.stream, m);
        want[tr.side]![tr.stream]!.push(m);
      }
    });
    p.step();
  }
  s.traffic.forEach((tr, k) => expect(sent[k], `traffic ${k}: the scenario must send everything by its end`).toBe(tr.count));
  p.expectDelivered(want);   // a digest of a run that failed to deliver would pin a broken behaviour
  const hexOf = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
  const out: ParitySide[] = [];
  for (const log of p.sent) {
    const parts: Uint8Array[] = [];
    let total = 0;
    for (const l of log) {
      const head = new Uint8Array(7);
      const v = new DataView(head.buffer);
      v.setUint32(0, l.at >>> 0);
      head[4] = l.lost ? 1 : 0;
      v.setUint16(5, l.packet.length);
      parts.push(head, l.packet);
      total += head.length + l.packet.length;
    }
    const all = new Uint8Array(total);
    const ends: number[] = [];
    let at = 0;
    parts.forEach((b, i) => { all.set(b, at); at += b.length; if (i % 2 === 1) ends.push(at); });
    const checkpoints: string[] = [];
    for (let n = checkpointEvery; n <= log.length; n += checkpointEvery) {
      checkpoints.push(hexOf(await crypto.subtle.digest("SHA-256", all.slice(0, ends[n - 1]!))).slice(0, 16));
    }
    out.push({ packets: log.length, sha256: hexOf(await crypto.subtle.digest("SHA-256", all)), checkpoints });
  }
  return [out[0]!, out[1]!];
}

describe("the engines agree packet for packet", () => {
  const fixture = parityFixture as unknown as { checkpointEvery: number; scenarios: ParityScenario[] };
  it("the fixture holds scenarios — an empty list passes every assertion", () => {
    expect(fixture.scenarios.length).toBeGreaterThan(0);
    expect(fixture.checkpointEvery).toBeGreaterThan(0);
  });
  for (const s of fixture.scenarios) {
    it(s.name, async () => {
      const got = await runParity(s, fixture.checkpointEvery);
      got.forEach((side, i) => expect(side.packets, `side ${i} sent nothing`).toBeGreaterThan(0));
      if (JSON.stringify(got) === JSON.stringify(s.sides)) return;
      const where = got.map((g, side) => {
        const w = s.sides[side]!;
        const i = g.checkpoints.findIndex((c, k) => k < w.checkpoints.length && c !== w.checkpoints[k]);
        return i < 0 ? `side ${side}: no checkpoint differs` : `side ${side} first differs within packets [${i * fixture.checkpointEvery}, ${(i + 1) * fixture.checkpointEvery})`;
      });
      throw new Error(`the packets differ from the fixture's digests (${where.join("; ")}); if the engine change is meant, ` +
        `paste this as the scenario's "sides" and rdev_lane_engine_test.go must then pass unchanged:\n${JSON.stringify(got)}`);
    }, LONG);
  }
});
