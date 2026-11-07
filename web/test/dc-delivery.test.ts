import { describe, it, expect, vi } from "vitest";
import { DcDelivery } from "../src/client/dc-delivery";
import { fnv1a } from "../src/lib/rlc";
import { DC_HEADER_BYTES } from "../src/lib/dc-wire";

/// A v7 source packet for one sourceIndex. Built by hand, like dc-wire's own tests: generating it
/// from the parser would assert nothing about what the host actually sends.
function sourcePacket(sourceIndex: number, over: Partial<{
  esi: number; frameSeq: number; rtp: number; fragCount: number; frameBytes: number; fill: number;
  key: boolean;
}> = {}): ArrayBuffer {
  const symbolBytes = 8;
  const buffer = new ArrayBuffer(DC_HEADER_BYTES + symbolBytes);
  const view = new DataView(buffer);
  view.setUint32(0, 0x53564452, true);
  view.setUint8(4, 7);
  view.setUint8(5, 0);
  view.setUint16(6, symbolBytes, true);
  view.setUint32(8, over.esi ?? 0, true);
  view.setUint32(12, over.frameSeq ?? 0, true);
  view.setUint32(16, over.rtp ?? 0, true);
  view.setUint16(22, over.fragCount ?? 1, true);
  view.setUint32(24, over.frameBytes ?? symbolBytes, true);
  if (over.key) view.setUint8(28, 1);
  view.setUint8(33, over.key ? 0 : 1);   // L1T1: a delta frame references the one before it
  view.setUint8(29, 45);
  view.setUint16(30, sourceIndex, true);
  const payload = new Uint8Array(buffer, DC_HEADER_BYTES);
  payload.fill(over.fill ?? 7);
  // THE FRAME HASH THE HOST WOULD HAVE COMPUTED. Without it every frame here is discarded as
  // corrupt, which is the check working — but it makes these tests about the check rather than
  // about routing.
  const frameBytes = over.frameBytes ?? symbolBytes;
  view.setUint32(36, fnv1a(payload.subarray(0, frameBytes)), true);
  return buffer;
}

interface FakeChannel {
  label: string;
  binaryType: string;
  addEventListener(type: string, handler: (e: unknown) => void): void;
  fire(type: string, event?: unknown): void;
}

function fakeChannel(label = "video"): FakeChannel {
  const handlers = new Map<string, Array<(e: unknown) => void>>();
  return {
    label,
    binaryType: "blob",
    addEventListener(type, handler) {
      const list = handlers.get(type) ?? [];
      list.push(handler);
      handlers.set(type, list);
    },
    fire(type, event) {
      for (const handler of handlers.get(type) ?? []) handler(event);
    },
  };
}

/// The capability shape a real browser would supply. Overridden per test so the gate can be checked
/// without a secure context or a VideoDecoder.
const ABLE = { hasVideoDecoder: true, isSecureContext: true };

describe("DcDelivery", () => {
  it("sets binaryType to arraybuffer before any message can arrive", () => {
    // The default is "blob", and reading one is ASYNCHRONOUS — a file-reader round trip inside the
    // arrival path would add latency to the very thing this transport exists to shorten.
    const delivery = new DcDelivery(ABLE);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
    expect(channel.binaryType).toBe("arraybuffer");
  });

  it("decodes symbols for an index it has not been told about, and routes once bound", () => {
    // Symbols can arrive before the view-set that names their index. DECODING does not need the
    // mapping — only presentation does — so they must be decoded and counted, not discarded as
    // malformed, or a startup race would look like a transport fault.
    const delivery = new DcDelivery(ABLE);
    const frames = vi.fn();
    delivery.onFrames(frames);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);

    channel.fire("message", { data: sourcePacket(4) });
    expect(frames).not.toHaveBeenCalled();
    expect(delivery.stats().unboundIndexSymbols).toBe(1);

    delivery.setSourceIndex("win:1", 4);
    channel.fire("message", { data: sourcePacket(4, { esi: 1, frameSeq: 1 }) });
    expect(frames).toHaveBeenCalledTimes(1);
    expect(frames.mock.calls[0]![0]).toBe("win:1");
  });

  // AFTER A HOLE, STOP FEEDING THE DECODER UNTIL A KEYFRAME. The frames that follow a lost one
  // reference a picture the decoder never received, so decoding them renders artifacts — visually
  // indistinguishable from data corruption, and lasting until the host's next IDR, which its own
  // debounce can delay by up to 500ms. A brief freeze is far better than half a second of garbage.
  //
  // Reported from a live session on a poor link: `lost=57 (0.81%)`, `gaps=57`, and ZERO corrupt
  // frames — every frame reaching the decoder was byte-exact, and the picture was still wrong.
  it("stops delivering frames after a gap until a keyframe arrives", () => {
    const delivery = new DcDelivery(ABLE);
    const frames = vi.fn();
    delivery.onFrames(frames);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
    delivery.setSourceIndex("win:1", 0);

    channel.fire("message", { data: sourcePacket(0, { esi: 0, frameSeq: 0 }) });
    expect(frames).toHaveBeenCalledTimes(1);

    // Frame 1 never arrives; 2..5 do, so the stream runs far enough past to give up on it.
    for (const seq of [2, 3, 4, 5]) {
      channel.fire("message", { data: sourcePacket(0, { esi: seq, frameSeq: seq }) });
    }
    // Those referenced a picture the decoder never had, so none of them may be handed on.
    expect(frames).toHaveBeenCalledTimes(1);

    // A keyframe needs no predecessor: delivery resumes with it.
    channel.fire("message", { data: sourcePacket(0, { esi: 6, frameSeq: 6, key: true }) });
    expect(frames).toHaveBeenCalledTimes(2);
    expect(frames.mock.calls[1]![1].key).toBe(true);

    // ...and keeps going afterwards.
    channel.fire("message", { data: sourcePacket(0, { esi: 7, frameSeq: 7 }) });
    expect(frames).toHaveBeenCalledTimes(3);
  });

  // A GATE THAT NEVER OPENS IS A DEAD PICTURE, so the request is repeated. A keyframe request can be
  // lost, or land while the host is inside its own 500ms debounce and be dropped.
  it("asks again for the keyframe while it is still withholding frames", () => {
    const delivery = new DcDelivery(ABLE);
    const asked = vi.fn();
    delivery.onFrames(vi.fn());
    delivery.onKeyframeNeeded(asked);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
    delivery.setSourceIndex("win:1", 0);

    channel.fire("message", { data: sourcePacket(0, { esi: 0, frameSeq: 0 }) });
    for (let seq = 2; seq < 80; seq++) {
      channel.fire("message", { data: sourcePacket(0, { esi: seq, frameSeq: seq }) });
    }
    // Once for the gap itself, then again periodically while frames keep being refused for want of
    // the reference that never arrived.
    expect(asked.mock.calls.length).toBeGreaterThan(1);
  });

  it("keeps sources apart when several share the channel", () => {
    // The whole point of multiplexing: one channel, independent ESI spaces. A frame for index 1 must
    // never be routed to the source bound to index 0.
    const delivery = new DcDelivery(ABLE);
    const frames = vi.fn();
    delivery.onFrames(frames);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
    delivery.setSourceIndex("win:1", 0);
    delivery.setSourceIndex("win:2", 1);

    channel.fire("message", { data: sourcePacket(0, { fill: 11 }) });
    channel.fire("message", { data: sourcePacket(1, { fill: 22 }) });
    expect(frames).toHaveBeenCalledTimes(2);
    expect(frames.mock.calls[0]![0]).toBe("win:1");
    expect(frames.mock.calls[1]![0]).toBe("win:2");
    expect(new Uint8Array(frames.mock.calls[0]![1].data)[0]).toBe(11);
    expect(new Uint8Array(frames.mock.calls[1]![1].data)[0]).toBe(22);
  });

  it("refuses the DataChannel when VideoDecoder is unavailable", () => {
    // VideoDecoder is [SecureContext]: Chromium has none on the plain-http LAN origin an iPad uses.
    // Asking for a path this client cannot decode would produce a blank canvas, not a fallback.
    expect(new DcDelivery({ hasVideoDecoder: false, isSecureContext: true }).canUseDataChannel())
      .toBe(false);
  });

  it("refuses the DataChannel on an insecure origin", () => {
    expect(new DcDelivery({ hasVideoDecoder: true, isSecureContext: false }).canUseDataChannel())
      .toBe(false);
  });

  it("drops every feed and reports a fallback when the video channel closes", () => {
    const delivery = new DcDelivery(ABLE);
    const fallback = vi.fn();
    delivery.onFallback(fallback);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
    delivery.setSourceIndex("win:1", 0);
    channel.fire("message", { data: sourcePacket(0) });
    expect(delivery.stats().active).toBe(true);

    channel.fire("close");
    expect(fallback).toHaveBeenCalledWith("channel closed");
    expect(delivery.stats().active).toBe(false);
    // The feeds go with it: a stale decoder holding a dead stream's window would try to solve
    // equations against symbols that can never arrive.
    expect(delivery.stats().sources).toEqual({});
  });

  it("reports a fallback on a channel error too", () => {
    const delivery = new DcDelivery(ABLE);
    const fallback = vi.fn();
    delivery.onFallback(fallback);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
    channel.fire("error");
    expect(fallback).toHaveBeenCalledWith("channel error");
  });

  it("ignores a message that is not an ArrayBuffer rather than throwing", () => {
    // A throw inside the message handler would take the whole channel down; a stray message must
    // cost one counter, not the transport.
    const delivery = new DcDelivery(ABLE);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
    expect(() => channel.fire("message", { data: "not a buffer" })).not.toThrow();
    expect(delivery.stats().malformed).toBe(1);
  });

  it("unbinds a source when its index is cleared", () => {
    // A source that falls back to RTP must stop consuming the channel, or its stale feed would keep
    // a decoder window alive and keep routing frames to a window rendering from the RTP path.
    const delivery = new DcDelivery(ABLE);
    const frames = vi.fn();
    delivery.onFrames(frames);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
    delivery.setSourceIndex("win:1", 0);
    channel.fire("message", { data: sourcePacket(0) });
    expect(frames).toHaveBeenCalledTimes(1);

    delivery.setSourceIndex("win:1", null);
    channel.fire("message", { data: sourcePacket(0, { esi: 1, frameSeq: 1 }) });
    expect(frames).toHaveBeenCalledTimes(1);
  });
});

describe("DcDelivery.dispose", () => {
  it("stops the 5 s report timer — a disposed delivery keeps no interval alive", () => {
    vi.useFakeTimers();
    try {
      const delivery = new DcDelivery(ABLE);
      const feedback = { ...fakeChannel("video-feedback"), readyState: "open", send: vi.fn() };
      delivery.bindFeedbackChannel(feedback as unknown as RTCDataChannel);
      expect(vi.getTimerCount()).toBe(1);
      delivery.dispose();
      expect(vi.getTimerCount()).toBe(0);
    } finally { vi.useRealTimers(); }
  });

  it("delivers no frame after dispose, even from a channel that is still firing", () => {
    const delivery = new DcDelivery(ABLE);
    const frames = vi.fn();
    delivery.onFrames(frames);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
    delivery.setSourceIndex("win:1", 0);
    delivery.dispose();
    channel.fire("message", { data: sourcePacket(0, { key: true }) });
    expect(frames).not.toHaveBeenCalled();
  });

  it("ignores a late dc-map after dispose — a still-open feedback channel cannot repopulate bindings", () => {
    const delivery = new DcDelivery(ABLE);
    const feedback = { ...fakeChannel("video-feedback"), readyState: "open", send: vi.fn() };
    delivery.bindFeedbackChannel(feedback as unknown as RTCDataChannel);
    delivery.dispose();
    feedback.fire("message", { data: JSON.stringify({ t: "dc-map", sources: { "0": "win:1" } }) });
    expect(delivery.stats().bound).toEqual([]);
  });

  it("ignores a video message that arrives after dispose — it does not relearn the binding it forgot", () => {
    const delivery = new DcDelivery(ABLE);
    const frames = vi.fn();
    delivery.onFrames(frames);
    const channel = fakeChannel();
    delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
    delivery.setSourceIndex("win:1", 0);
    delivery.dispose();
    channel.fire("message", { data: sourcePacket(0, { key: true }) });
    expect(frames).not.toHaveBeenCalled();
    expect(delivery.stats().bound).toEqual([]);
    expect(delivery.stats().sources).toEqual({});
  });

  it("a bind attempted after dispose does nothing — no interval, no active channel", () => {
    vi.useFakeTimers();
    try {
      const delivery = new DcDelivery(ABLE);
      delivery.dispose();
      const feedback = { ...fakeChannel("video-feedback"), readyState: "open", send: vi.fn() };
      delivery.bindFeedbackChannel(feedback as unknown as RTCDataChannel);
      expect(vi.getTimerCount()).toBe(0);
      const channel = fakeChannel();
      delivery.bindVideoChannel(channel as unknown as RTCDataChannel);
      expect(channel.binaryType).toBe("blob");   // never touched: the bind was refused
      expect(delivery.stats().active).toBe(false);
    } finally { vi.useRealTimers(); }
  });
});
