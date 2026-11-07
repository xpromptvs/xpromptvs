import { LaneLink, type LaneDataChannel } from "../src/lib/lane-channel";
import { describe, expect, it, test, vi } from "vitest";
import { ICE_BUFFER_MAX } from "@rdev/protocol";
import { DEFAULT_JITTER_BUFFER_TARGET_MS, PeerSession, parseJitterBufferTargetMs, type RTCPeerConnectionLike } from "../src/lib/peer";
import type { Channels } from "../src/lib/channel";

function fakePC(): RTCPeerConnectionLike & { channels: string[]; listeners: Record<string, any>; added: RTCIceCandidateInit[] } {
  const listeners: Record<string, any> = {};
  return {
    channels: [],
    listeners,
    createDataChannel(label: string) { this.channels.push(label); return { label } as any; },
    async createOffer() { return { type: "offer", sdp: "v=0-offer" } as any; },
    async createAnswer() { return { type: "answer", sdp: "v=0-answer" } as any; },
    async setLocalDescription(d: any) { this.localDescription = d; },
    async setRemoteDescription() {},
    added: [] as RTCIceCandidateInit[],
    async addIceCandidate(c: RTCIceCandidateInit) { (this as any).added.push(c); },
    addTrack() { return {} as any; },
    close() {},
    set onicecandidate(_cb: any) {},
    set ontrack(_cb: any) {},
    set ondatachannel(_cb: any) {},
    localDescription: undefined as any,
  };
}

test("host creates terminal/input/control/bulk channels and emits an offer", async () => {
  const pc = fakePC();
  const onLocalDescription = vi.fn();
  const peer = new PeerSession(pc, "host", { onLocalDescription });
  await peer.startOffer();
  expect(pc.channels).toEqual(["terminal", "input", "control", "bulk"]);
  expect(onLocalDescription).toHaveBeenCalledWith({ type: "offer", sdp: "v=0-offer" });
});

test("client answers a remote offer", async () => {
  const pc = fakePC();
  const onLocalDescription = vi.fn();
  const peer = new PeerSession(pc, "client", { onLocalDescription });
  await peer.acceptOffer("v=0-remote");
  expect(onLocalDescription).toHaveBeenCalledWith({ type: "answer", sdp: "v=0-answer" });
});

// WAS `toBe(0)` UNTIL 2026-08-21, AND THAT PINNED A DEFECT. The latency milestone asked for zero
// buffering on both knobs, and this test held it in place — but zero is a MODE, not a quantity: it
// disables smoothing rather than requesting 0ms. Chrome ignores it (clamping to ~16-18ms), so the
// setting was never actually in force on the browser rdev is developed against; a real iPad honours
// it and answered with 78 keyframe requests in 35 seconds while reporting no loss, no dropped frames
// and no freezes. The intent — minimise buffering — is unchanged and still asserted; what changed is
// that the request is now the smallest NON-ZERO value, which hands the receiver back its adaptive
// estimator instead of switching smoothing off.
test("client minimizes receiver playout/jitter buffering on track, without asking for zero", () => {
  const pc = fakePC();
  let ontrack: ((e: any) => void) | null = null;
  Object.defineProperty(pc, "ontrack", { set(cb: any) { ontrack = cb; } });
  new PeerSession(pc, "client", {});
  const receiver: { jitterBufferTarget?: number | null; playoutDelayHint?: number } = {};
  ontrack!({ receiver, streams: [{}] });
  expect(receiver.jitterBufferTarget).toBe(DEFAULT_JITTER_BUFFER_TARGET_MS);
  expect(receiver.jitterBufferTarget).not.toBe(0);
  expect(receiver.playoutDelayHint).toBe(DEFAULT_JITTER_BUFFER_TARGET_MS / 1000);
});

// The receiver jitter-buffer override. rdev asks for ZERO buffering, and AGENTS.md records that
// Chrome ignores that and clamps to ~16-18ms — so the setting has never actually been in force on
// the browser rdev is developed against. A real iPad honours it: measured jbuf=1.0ms against 4-19ms
// of interarrival jitter, with the receiver then requesting a keyframe about once a second.
function trackingPC() {
  const pc = fakePC() as any;
  let ontrack: any;
  Object.defineProperty(pc, "ontrack", { set(cb: any) { ontrack = cb; }, configurable: true });
  const receiver = { jitterBufferTarget: null as number | null, playoutDelayHint: undefined as number | undefined };
  return { pc, receiver, fireTrack: () => ontrack({ receiver, streams: [] }) };
}

// THE DEFAULT MUST BE NON-ZERO, and this test exists because zero is a MODE rather than a quantity:
// it tells the receiver to disable smoothing entirely, which measured 78 keyframe requests in 35s on
// a real iPad against 1 request in 45s at a target of one millisecond. Any non-zero value hands
// control back to the adaptive estimator; smaller is better because it adapts upward from there.
test("the receiver jitter buffer target is small but never zero", () => {
  const { pc, receiver, fireTrack } = trackingPC();
  new PeerSession(pc, "client", {});
  fireTrack();
  expect(receiver.jitterBufferTarget).not.toBe(0);
  expect(receiver.jitterBufferTarget).toBeLessThanOrEqual(10);
});

// `?jbuf=0` still selects the old disable-smoothing mode, so the broken configuration stays
// reachable for testing rather than becoming unexpressible.
test("an explicit zero still selects the disable-smoothing mode", () => {
  const { pc, receiver, fireTrack } = trackingPC();
  new PeerSession(pc, "client", {}, parseJitterBufferTargetMs("0"));
  fireTrack();
  expect(receiver.jitterBufferTarget).toBe(0);
});

// LOAD-BEARING UNITS, AND THEY ARE INVISIBLE AT ZERO. jitterBufferTarget is MILLISECONDS and
// playoutDelayHint is SECONDS; both read 0 today, so the mismatch cannot show until the value is
// non-zero — at which point passing ms to both would ask for a fifty-SECOND playout delay.
test("a target is applied in each knob's own unit", () => {
  const { pc, receiver, fireTrack } = trackingPC();
  new PeerSession(pc, "client", {}, 50);
  fireTrack();
  expect(receiver.jitterBufferTarget).toBe(50);
  expect(receiver.playoutDelayHint).toBe(0.05);
});

test("the jbuf override parses, defaults to zero, and is bounded", () => {
  expect(parseJitterBufferTargetMs(null)).toBe(DEFAULT_JITTER_BUFFER_TARGET_MS);
  expect(parseJitterBufferTargetMs("")).toBe(DEFAULT_JITTER_BUFFER_TARGET_MS);
  expect(parseJitterBufferTargetMs("nonsense")).toBe(DEFAULT_JITTER_BUFFER_TARGET_MS);
  expect(parseJitterBufferTargetMs("-5")).toBe(DEFAULT_JITTER_BUFFER_TARGET_MS);
  // An explicit zero is honoured — it is a real setting, not a fallback.
  expect(parseJitterBufferTargetMs("0")).toBe(0);
  expect(parseJitterBufferTargetMs("50")).toBe(50);
  // A buffer longer than a second is not a latency experiment, it is a broken session.
  expect(parseJitterBufferTargetMs("99999")).toBe(1000);
});


// ICE CANDIDATES CAN ARRIVE BEFORE THE OFFER, and `addIceCandidate` before `setRemoteDescription` is
// an InvalidStateError by spec. Safari enforces it; Chrome is lenient, which is why this surfaced as
// a Safari-only console error on reload:
//
//   Unhandled Promise Rejection: InvalidStateError: The remote description was null
//
// NOT COSMETIC. A rejected candidate is a DROPPED candidate, and dropping the host's early ones makes
// the winning pair more likely to be peer-reflexive — which this project has already measured as a
// 1000 ms `prflxAcceptanceMinWait` hold on the first input after a reconnect.
test("queues ICE candidates that arrive before the remote description", async () => {
  const pc = fakePC();
  const peer = new PeerSession(pc as RTCPeerConnectionLike, "client", {});
  // Must not reject, and must not reach the peer connection yet.
  await peer.addIce({ candidate: "early-1", sdpMid: "0" });
  await peer.addIce({ candidate: "early-2", sdpMid: "0" });
  expect((pc as any).added).toEqual([]);

  await peer.acceptOffer("v=0-remote");
  // FLUSHED IN ARRIVAL ORDER once the remote description exists.
  expect((pc as any).added.map((c: any) => c.candidate)).toEqual(["early-1", "early-2"]);

  // PAIRED: a queue that never drains would satisfy the first assertion, and a queue that keeps
  // buffering forever would satisfy the second. After the remote description, candidates must go
  // straight through.
  await peer.addIce({ candidate: "late-1", sdpMid: "0" });
  expect((pc as any).added.map((c: any) => c.candidate)).toEqual(["early-1", "early-2", "late-1"]);
});

// The answering side sets its remote description through a different call, and a queue that only
// drained on acceptOffer would strand every candidate on the host.
test("drains the queue on acceptAnswer too", async () => {
  const pc = fakePC();
  const peer = new PeerSession(pc as RTCPeerConnectionLike, "host", {});
  await peer.addIce({ candidate: "early", sdpMid: "0" });
  expect((pc as any).added).toEqual([]);
  await peer.acceptAnswer("v=0-answer");
  expect((pc as any).added.map((c: any) => c.candidate)).toEqual(["early"]);
});

// §11.3 of the E2E protocol spec: the early-candidate queue is BOUNDED, in size and in age. It was a
// plain array with neither — anything that could deliver a candidate could grow it without limit,
// and §4 puts the Control Plane inside the adversary model, so today that is the relay.
test("the early-candidate queue is bounded, and the bound does not disturb a real negotiation", async () => {
  const pc = fakePC();
  const peer = new PeerSession(pc, "client", {});

  // A dual-stack host with TURN offers on the order of a dozen; the cap is far above that, so a
  // real negotiation never notices it.
  for (let i = 0; i < ICE_BUFFER_MAX + 50; i++) {
    await peer.addIce({ candidate: `flood-${i}`, sdpMid: "0" });
  }
  await peer.acceptOffer("v=0");
  expect((pc as any).added.length).toBe(ICE_BUFFER_MAX);
  // The EARLIEST survive: those are the host candidates whose loss produces the peer-reflexive
  // delay this queue exists to avoid.
  expect((pc as any).added[0].candidate).toBe("flood-0");
});

test("candidates from an abandoned attempt are discarded with it", async () => {
  // §11.3: "Discard the buffer with its attempt." A new attempt has fresh ephemerals and a fresh
  // remote description; candidates gathered for the old one describe a path that is gone.
  //
  // ASSERTED ON THE SAME PEER on purpose. The first version of this test built a SECOND PeerSession
  // and checked that nothing flushed into it — which is true whether or not `close()` discards
  // anything, because a fresh session has a fresh buffer. It proved nothing.
  const pc = fakePC();
  const peer = new PeerSession(pc, "client", {});
  await peer.addIce({ candidate: "stale", sdpMid: "0" });
  expect((pc as any).added).toEqual([]);

  peer.close();
  await peer.acceptOffer("v=0-remote");
  expect((pc as any).added).toEqual([]);

  // The control arm: without the abandonment, that same candidate does flush.
  const live = fakePC();
  const kept = new PeerSession(live, "client", {});
  await kept.addIce({ candidate: "stale", sdpMid: "0" });
  await kept.acceptOffer("v=0-remote");
  expect((live as any).added.map((c: any) => c.candidate)).toEqual(["stale"]);
});

// TWO COMPLETE CHANNEL SETS (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §4): the lane and bulk (the
// product), or the SCTP baseline's four (RDEV_TEST_SCTP_CHANNELS). The page hands over whichever completes.
type FakeChannel = EventTarget & { label: string; readyState: RTCDataChannelState; closes: number };
function fakeLanePc(): RTCPeerConnectionLike & { fire(label: string): void; dcs: Record<string, FakeChannel> } {
  const pc = {
    ondatachannel: null as ((e: RTCDataChannelEvent) => void) | null, onicecandidate: null, ontrack: null,
    localDescription: null, connectionState: "connected" as RTCPeerConnectionState,
    dcs: {} as Record<string, FakeChannel>,
    fire(label: string) {
      const ch = Object.assign(new EventTarget(), { label, readyState: "connecting", bufferedAmount: 0,
        bufferedAmountLowThreshold: 0, binaryType: "blob", closes: 0, send() {}, close() { ch.closes++; } });
      pc.dcs[label] = ch as unknown as FakeChannel;
      pc.ondatachannel?.({ channel: ch } as unknown as RTCDataChannelEvent);
    },
    close() {},
  };
  return pc as unknown as RTCPeerConnectionLike & { fire(label: string): void; dcs: Record<string, FakeChannel> };
}

test("eligible streams are published before bulk while legacy handoff waits for the complete set", () => {
  const pc = fakeLanePc(), early = vi.fn(), legacy = vi.fn();
  const session = new PeerSession(pc, "client", { earlyDataChannels: () => true, onDataChannels: early, onChannels: legacy });
  pc.fire("lane");
  expect(early).toHaveBeenCalledTimes(1);
  expect(Object.keys(early.mock.calls[0]![0])).toEqual(["terminal", "input", "control"]);
  expect(legacy).not.toHaveBeenCalled();
  pc.fire("bulk");
  expect(legacy).toHaveBeenCalledTimes(1);
  session.close();
});

describe("PeerSession hands over a complete channel set", () => {
  it("the lane and bulk: three lane streams and the real bulk", () => {
    const pc = fakeLanePc();
    let handed: Channels | null = null;
    new PeerSession(pc, "client", { onChannels: (ch) => { handed = ch; } });
    pc.fire("bulk");
    expect(handed).toBeNull();
    pc.fire("lane");
    expect(handed).not.toBeNull();
    expect([handed!.terminal.label, handed!.input.label, handed!.control.label, handed!.bulk.label])
      .toEqual(["terminal", "input", "control", "bulk"]);
  });
  it("the SCTP baseline: the four real channels", () => {
    const pc = fakeLanePc();
    let handed: Channels | null = null;
    new PeerSession(pc, "client", { onChannels: (ch) => { handed = ch; } });
    for (const l of ["terminal", "input", "control"]) pc.fire(l);
    expect(handed).toBeNull();
    pc.fire("bulk");
    expect(handed!.terminal.label).toBe("terminal");
  });
  // THE LANE GOES WITH ITS PEER (AGENTS.md, "A SESSION IS A `createSession` CALL"): closing the peer session stops the
  // lane's timer and closes its data channel, and nothing that channel does afterwards reaches the session's streams.
  // Left, the old LaneLink's timer outlived the session by up to a second.
  it("closing the peer session closes its lane: no timer, no event outlives it", () => {
    vi.useFakeTimers();
    try {
      const pc = fakeLanePc();
      let handed: Channels | null = null;
      const peer = new PeerSession(pc, "client", { onChannels: (ch) => { handed = ch; } });
      pc.fire("bulk");
      pc.fire("lane");
      const lane = pc.dcs["lane"]!;
      lane.readyState = "open";
      lane.dispatchEvent(new Event("open"));
      const control = handed!.control;
      control.send(new TextEncoder().encode('{"t":"list-terminals"}'));   // a symbol, and its tail repair's timer
      expect(vi.getTimerCount(), "precondition: the lane holds a timer").toBeGreaterThan(0);
      const heard: string[] = [];
      for (const ev of ["message", "close"]) control.addEventListener(ev, () => heard.push(ev));
      peer.close();
      expect(vi.getTimerCount(), "the lane's timer outlived its peer session").toBe(0);
      expect(lane.closes, "the lane's data channel was not closed").toBe(1);
      lane.readyState = "closed";
      lane.dispatchEvent(new Event("close"));
      expect(heard, "an event of the closed lane reached the session's streams").toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });
  it("a label that is none of rdev's still reaches the extra-channel hook", () => {
    const pc = fakeLanePc();
    const extra: string[] = [];
    let handed: Channels | null = null;
    new PeerSession(pc, "client", { onChannels: (ch) => { handed = ch; }, onExtraChannel: (ch) => extra.push(ch.label) });
    pc.fire("video");
    pc.fire("bulk");
    pc.fire("lane");
    expect(extra).toEqual(["video"]);
    expect(handed).not.toBeNull();
  });
});

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

test("legacy messages before bulk are repaired after application listeners attach", async () => {
  vi.useFakeTimers();
  const a = new FakeDataChannel(), b = new FakeDataChannel(); a.peer = b; b.peer = a;
  const host = new LaneLink(a, { connected: () => true, now: () => Date.now(), seed: 1 });
  const pc = fakeLanePc(), received: string[] = [];
  const session = new PeerSession(pc, "client", { onChannels: ch => {
    for (const stream of [ch.terminal, ch.control]) stream.addEventListener("message", event => received.push(new TextDecoder().decode((event as MessageEvent).data)));
  }});
  try {
    pc.ondatachannel?.({channel:b} as unknown as RTCDataChannelEvent);
    a.open(); b.open();
    host.channels[0].send(new TextEncoder().encode('terminal'));
    host.channels[2].send(new TextEncoder().encode('control'));
    await vi.advanceTimersByTimeAsync(100);
    pc.fire('bulk');
    await vi.advanceTimersByTimeAsync(1000);
    expect(received.sort()).toEqual(['control','terminal']);
  } finally { session.close(); host.close(); vi.useRealTimers(); }
});

it('captures negotiated identity before ontrack fires during setRemoteDescription', async () => {
  const pc = fakePC();
  Object.defineProperty(pc, 'ontrack', { value: null, writable: true, configurable: true });
  const stream = { id: 'win:1' } as MediaStream;
  const receiver = { track: { id: 'webkit-generated-uuid' } } as RTCRtpReceiver;
  pc.setRemoteDescription = async () => {
    pc.ontrack?.({ streams: [stream], receiver, transceiver: { mid: '1' } } as unknown as RTCTrackEvent);
  };
  const onTrack = vi.fn();
  const session = new PeerSession(pc, 'client', { onTrack });
  await session.acceptOffer('v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\na=mid:1\r\na=msid:win:1 video-0-win:1\r\n');
  expect(onTrack).toHaveBeenCalledWith(stream, receiver, 'video-0-win:1');
  await session.acceptOffer('v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 45\r\na=mid:1\r\na=msid:win:1 video-9-win:1\r\n');
  expect(onTrack).toHaveBeenLastCalledWith(stream, receiver, 'video-9-win:1');
  session.close();
});
