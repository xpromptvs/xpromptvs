import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LaneLink, laneFlushWake, LANE_REPOLL_MS, type LaneDataChannel } from "../src/lib/lane-channel";
import { LaneEngine } from "../src/lib/lane";
import { LANE_PACKET_MAX, LANE_TYPE_SOURCE } from "../src/lib/lane-codec";

// THE LANE UNDER THE SESSION'S CHANNELS (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §1, §4): three
// RTCDataChannel-shaped streams over one data channel.
class FakeDataChannel extends EventTarget implements LaneDataChannel {
  readyState: RTCDataChannelState = "connecting";
  bufferedAmount = 0;
  bufferedAmountLowThreshold = 0;
  binaryType: BinaryType = "blob";
  peer: FakeDataChannel | null = null;
  drop = false;
  refuse = 0;   // the next `refuse` sends throw, as a full queue's or a closing channel's do
  constructor(readonly label = "lane") { super(); }
  send(data: Uint8Array<ArrayBuffer>): void {
    if (this.readyState !== "open") throw new DOMException("not open", "InvalidStateError");
    if (this.refuse > 0) { this.refuse--; throw new DOMException("send queue is full", "OperationError"); }
    if (this.drop) return;
    const copy = data.slice().buffer;
    const peer = this.peer!;
    queueMicrotask(() => { if (peer.readyState === "open") peer.dispatchEvent(new MessageEvent("message", { data: copy })); });
  }
  open(): void { this.readyState = "open"; this.dispatchEvent(new Event("open")); }
  close(): void {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    this.dispatchEvent(new Event("close"));
    this.peer?.close();
  }
}

function joined(connected: { value: boolean } = { value: true }) {
  const a = new FakeDataChannel(), b = new FakeDataChannel();
  a.peer = b; b.peer = a;
  const now = () => Date.now();
  const A = new LaneLink(a, { connected: () => connected.value, now, seed: 1 });
  const B = new LaneLink(b, { connected: () => connected.value, now, seed: 2 });
  return { a, b, A, B };
}

beforeEach(() => { vi.useFakeTimers(); });
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

describe("LaneLink", () => {
  it("a message on a stream arrives on the SAME stream at the other end, as an ArrayBuffer", async () => {
    const { a, b, A, B } = joined();
    a.open(); b.open();
    const got: unknown[] = [];
    B.channels[2].addEventListener("message", (e) => got.push((e as MessageEvent).data));
    B.channels[0].addEventListener("message", () => got.push("WRONG STREAM"));
    A.channels[2].send(new TextEncoder().encode('{"t":"list-terminals"}'));
    await vi.advanceTimersByTimeAsync(5);
    expect(got.length).toBe(1);
    expect(got[0]).toBeInstanceOf(ArrayBuffer);
    expect(new TextDecoder().decode(got[0] as ArrayBuffer)).toBe('{"t":"list-terminals"}');
  });

  it("open and close reach every stream — none of them can close alone", () => {
    const { a, b, A } = joined();
    const events: string[] = [];
    for (const c of A.channels) { c.addEventListener("open", () => events.push(`${c.label} open`)); c.addEventListener("close", () => events.push(`${c.label} close`)); }
    a.open(); b.open();
    expect(A.channels.map((c) => c.readyState)).toEqual(["open", "open", "open"]);
    A.channels[0].close();
    expect(events).toEqual(["terminal open", "input open", "control open", "terminal close", "input close", "control close"]);
    expect(A.channels.map((c) => c.readyState)).toEqual(["closed", "closed", "closed"]);
  });

  // A SEND THE DATA CHANNEL REFUSES THROWS NOWHERE: it dropped the rest of the poll and reached LaneChannel.send's
  // caller (or the timer). The packet was numbered and is held, so the lane's own repair delivers it.
  it("a send the data channel refuses throws nowhere, and the lane repairs what did not go", async () => {
    const { a, b, A, B } = joined();
    a.open(); b.open();
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const got: string[] = [];
    B.channels[2].addEventListener("message", (e) => got.push(new TextDecoder().decode((e as MessageEvent).data as ArrayBuffer)));
    a.refuse = 1;
    expect(() => A.channels[2].send(new TextEncoder().encode('{"t":"list-terminals"}')), "the refused send").not.toThrow();
    await vi.advanceTimersByTimeAsync(200);
    expect(got, "the message, rebuilt by the lane's repair").toEqual(['{"t":"list-terminals"}']);
  });

  // TermPacer's model of the number: pion's bufferedAmount counts bytes until SCTP acknowledges them.
  it("bufferedAmount is what the peer has not acknowledged, in payload bytes", async () => {
    const { a, b, A } = joined();
    a.open(); b.open();
    a.bufferedAmount = 20_000;                    // pion's queue past the target: nothing more goes
    A.channels[0].send(new Uint8Array(100));
    expect(A.channels[0].bufferedAmount, "pending: the payload, not the 104 framed bytes").toBe(100);
    expect(A.channels[1].bufferedAmount).toBe(0);
    a.bufferedAmount = 0;
    await vi.advanceTimersByTimeAsync(LANE_REPOLL_MS);
    expect(A.channels[0].bufferedAmount, "in a symbol, not yet acknowledged").toBe(100);
    await vi.advanceTimersByTimeAsync(100);       // the peer's feedback (≤ 20 ms after it arrives)
    expect(A.channels[0].bufferedAmount, "acknowledged").toBe(0);
  });

  it("a send before the lane opens throws, as an RTCDataChannel's does", () => {
    const { A } = joined();
    expect(() => A.channels[1].send(new Uint8Array([1]))).toThrow(DOMException);
  });

  it("a stuck lane closes only on a connected link", async () => {
    const connected = { value: false };
    const { a, b, A } = joined(connected);
    a.open(); b.open();
    a.drop = true;                                  // nothing a sends arrives: no feedback ever
    A.channels[1].send(new Uint8Array([1]));
    await vi.advanceTimersByTimeAsync(31_000);
    expect(a.readyState, "an outage is not a stuck lane").toBe("open");
    connected.value = true;
    await vi.advanceTimersByTimeAsync(1_100);     // the next timer repair's flush
    expect(a.readyState).toBe("closed");
  });

  // AFTER A NETWORK BLINK A BROWSER'S SCTP MAY HOLD THE PAGE'S PACKETS IN ITS BACKOFF (2026-10-13, a phone over TURN:
  // its keystrokes reached the Mac ~25 s late) while the Mac's still arrive — keepalive feedback included, which
  // acknowledges nothing. Once the link has dropped and come back, 5 s with no progress closes the lane: the session
  // rebuilds on a fresh association.
  it("after the link drops and comes back, a lane with no progress for 5 s closes, keepalives or not", async () => {
    const { a, b, A } = joined();
    a.open(); b.open();
    A.channels[1].send(new Uint8Array([1]));
    await vi.advanceTimersByTimeAsync(100);        // acknowledged: the peer now has heard us and keeps alive
    A.linkLost(); A.connected();                   // the blink
    a.drop = true;                                 // what the page sends sits in its SCTP's backoff
    A.channels[1].send(new Uint8Array([2]));
    await vi.advanceTimersByTimeAsync(4_000);
    expect(a.readyState, "4 s: not yet").toBe("open");
    await vi.advanceTimersByTimeAsync(2_200);
    expect(a.readyState, "no progress for 5 s after the link came back").toBe("closed");
  });

  it("a link that never dropped keeps 30 s — and the peer's keepalives are not progress", async () => {
    const { a, b, A } = joined();
    a.open(); b.open();
    A.channels[1].send(new Uint8Array([1]));
    await vi.advanceTimersByTimeAsync(100);
    a.drop = true;
    A.channels[1].send(new Uint8Array([2]));
    await vi.advanceTimersByTimeAsync(6_000);
    expect(a.readyState, "no drop seen: 5 s is not the threshold").toBe("open");
    await vi.advanceTimersByTimeAsync(25_000);
    expect(a.readyState, "30 s with no progress, though the peer's keepalives kept arriving").toBe("closed");
  });

  // THE ANSWERING SIDE IS HANDED AN OPEN CHANNEL: a data channel the peer opened is OPEN when `ondatachannel` runs,
  // and its own `open` event follows the hand-over. The session binds its listeners DURING the hand-over, so the
  // streams' open goes out once, in a microtask — after the listeners are on, before anything else can run.
  it("a lane handed over already OPEN announces open to its streams ONCE, after the hand-over", async () => {
    const a = new FakeDataChannel(), b = new FakeDataChannel();
    a.peer = b; b.peer = a;
    a.readyState = "open"; b.readyState = "open";
    const now = () => Date.now();
    const A = new LaneLink(a, { connected: () => true, now, seed: 1 });
    const B = new LaneLink(b, { connected: () => true, now, seed: 2 });
    const opens: string[] = [];
    for (const c of A.channels) c.addEventListener("open", () => opens.push(c.label));   // the hand-over binds
    expect(A.channels.map((c) => c.readyState)).toEqual(["open", "open", "open"]);
    expect(opens, "not from inside the constructor: nothing is bound yet").toEqual([]);
    await Promise.resolve();
    expect(opens).toEqual(["terminal", "input", "control"]);
    a.dispatchEvent(new Event("open"));          // the data channel's own open, after the datachannel event
    await Promise.resolve();
    expect(opens, "announced once").toEqual(["terminal", "input", "control"]);
    // …and it is a working lane.
    const got: number[][] = [];
    B.channels[1].addEventListener("message", (e) => got.push([...new Uint8Array((e as MessageEvent).data as ArrayBuffer)]));
    A.channels[1].send(new Uint8Array([7]));
    await vi.advanceTimersByTimeAsync(5);
    expect(got).toEqual([[7]]);
  });

  it("a lane that opens natively announces once, whatever its data channel says after", async () => {
    const { a, b, A } = joined();
    const opens: string[] = [];
    for (const c of A.channels) c.addEventListener("open", () => opens.push(c.label));
    a.open(); b.open();
    a.dispatchEvent(new Event("open"));
    await Promise.resolve();
    expect(opens).toEqual(["terminal", "input", "control"]);
  });

  it("a lane handed over open and closed before its announcement announces nothing but the close", async () => {
    const a = new FakeDataChannel();
    a.readyState = "open";
    const A = new LaneLink(a, { connected: () => true, now: () => Date.now(), seed: 1 });
    const events: string[] = [];
    for (const c of A.channels) { c.addEventListener("open", () => events.push(`${c.label} open`)); c.addEventListener("close", () => events.push(`${c.label} close`)); }
    a.close();
    await Promise.resolve();
    expect(events).toEqual(["terminal close", "input close", "control close"]);
  });

  // A NON-CONFORMING PEER CAN MAKE THE ENGINE THROW (a pruned ESI). It is the page's event loop it would reach: the
  // lane says so once and carries on, and what comes after still arrives.
  it("an exception from the engine's receive is said once and the lane keeps running", async () => {
    const { a, b, A, B } = joined();
    a.open(); b.open();
    const errors: unknown[] = [];
    const onError = (e: Event) => errors.push(e);
    window.addEventListener("error", onError);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const receive = vi.spyOn(LaneEngine.prototype, "receive")
      .mockImplementationOnce(() => { throw new Error("a pruned ESI"); })
      .mockImplementationOnce(() => { throw new Error("a pruned ESI"); });
    const got: string[] = [];
    B.channels[2].addEventListener("message", (e) => got.push(new TextDecoder().decode((e as MessageEvent).data as ArrayBuffer)));
    A.channels[2].send(new TextEncoder().encode("after the throw"));
    await vi.advanceTimersByTimeAsync(2_000);   // the source and the first repair are thrown away; a later repair lands
    window.removeEventListener("error", onError);
    expect(receive.mock.results.filter((r) => r.type === "throw").length).toBe(2);
    expect(errors, "nothing reached the page's event loop").toEqual([]);
    expect(warn.mock.calls.filter((c) => String(c[0]).startsWith("[lane]")).length, "said once").toBe(1);
    expect(got).toEqual(["after the throw"]);
  });

  it("the clock it hands the engine is whole milliseconds", () => {
    const a = new FakeDataChannel();
    let t = 1000.25;
    a.drop = true;                                // no peer: what it sends goes nowhere
    const A = new LaneLink(a, { connected: () => true, now: () => t, seed: 1 });
    const poll = vi.spyOn(LaneEngine.prototype, "poll");
    a.open();
    t = 1017.9;
    A.channels[0].send(new Uint8Array([1]));
    const seen = poll.mock.calls.map((c) => c[0]);
    expect(seen.length).toBeGreaterThan(0);
    for (const n of seen) expect(Number.isInteger(n)).toBe(true);
    expect(seen.at(-1)).toBe(17);
  });
});

// A QUEUE LEFT WITH LESS ROOM THAN ONE PACKET IS POLLED AGAIN WITHIN 5 ms — the Mac's glue's rule (rdev_lane.go,
// laneFlushWake), the same table: the data channel's low-water event can come late, and an urgent repair the queue
// refused waits in the engine where nextWake does not see it. With room for a packet, the engine's own wake stands.
describe("laneFlushWake", () => {
  const now = 1000;
  it.each([
    ["room for a packet, nothing scheduled", -1, LANE_PACKET_MAX, -1],
    ["room for a packet, a wake far off", now + 300, LANE_PACKET_MAX, now + 300],
    ["room for a packet, a wake now", now, 16 * 1024, now],
    ["short of a packet, nothing scheduled", -1, LANE_PACKET_MAX - 1, now + LANE_REPOLL_MS],
    ["short of a packet, a wake far off", now + 300, LANE_PACKET_MAX - 1, now + LANE_REPOLL_MS],
    ["short of a packet, a wake sooner", now + 2, 0, now + 2],
    ["over target (feedback ignores room)", now + 40, -500, now + LANE_REPOLL_MS],
  ])("%s", (_name, engineWake, roomLeft, want) => {
    expect(laneFlushWake(now, engineWake, roomLeft)).toBe(want);
  });

  it("a link whose queue is full polls again within 5 ms, not at the engine's wake", async () => {
    const { a, b, A } = joined();
    a.open(); b.open();
    const poll = vi.spyOn(LaneEngine.prototype, "poll");
    a.bufferedAmount = 20_000;
    A.channels[0].send(new Uint8Array(100));
    const before = poll.mock.calls.length;
    const send = vi.spyOn(a, "send");
    a.bufferedAmount = 0;                         // drained, and no low-water event says so
    await vi.advanceTimersByTimeAsync(LANE_REPOLL_MS);
    expect(poll.mock.calls.length).toBeGreaterThan(before);
    // A SOURCE symbol went — not only a feedback or keepalive packet, which the engine sends on its own.
    expect(send.mock.calls.some((c) => (c[0] as Uint8Array)[0] === LANE_TYPE_SOURCE), "what the full queue held back went").toBe(true);
  });
});
