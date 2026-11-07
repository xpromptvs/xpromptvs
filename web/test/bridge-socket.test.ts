import { describe, expect, it } from "vitest";
import { encodeSocketFrame } from "@rdev/protocol";
import { BridgeMessageSocket, base64ToBytes, bytesToBase64, type ShellSocketApi } from "../src/lib/bridge-socket";
import { SocketChannels } from "../src/lib/socket-channels";

function fakeShell() {
  const calls: unknown[][] = [];
  const handlers = new Map<string, { frames(f: string[]): void; closed(): void }>();
  const shell: ShellSocketApi = {
    socketOpen: (id, h) => { calls.push(["open", id]); handlers.set(id, h); },
    socketSend: (id, frame) => { calls.push(["send", id, frame]); },
    socketClose: (id) => { calls.push(["close", id]); },
  };
  return { shell, calls, handlers };
}
const settle = () => new Promise<void>((r) => setTimeout(r, 0));
const bytesOf = (data: unknown) => Array.from(new Uint8Array(data as ArrayBuffer));

describe("BridgeMessageSocket", () => {
  it("opens asynchronously — after the caller has attached its listeners — and says so once", async () => {
    const { shell, calls } = fakeShell();
    const s = new BridgeMessageSocket(shell, "sock-1");
    expect(calls).toEqual([["open", "sock-1"]]);
    expect(s.readyState).toBe(0);
    let opened = 0;
    s.addEventListener("open", () => { opened++; });
    await settle();
    expect(s.readyState).toBe(1);
    expect(opened).toBe(1);
  });

  it("refuses to send before it opens, as a WebSocket does", () => {
    const { shell } = fakeShell();
    const s = new BridgeMessageSocket(shell, "sock-1");
    expect(() => s.send(new Uint8Array([1]))).toThrow(/not open/);
  });

  it("sends each frame as STANDARD base64 — the alphabet Swift's Data(base64Encoded:) reads", async () => {
    const { shell, calls } = fakeShell();
    const s = new BridgeMessageSocket(shell, "sock-1");
    await settle();
    s.send(new Uint8Array([0xfb, 0xff, 0x00]));
    expect(calls.at(-1)).toEqual(["send", "sock-1", "+/8A"]);
  });

  it("delivers the host's frames in order, each as its own ArrayBuffer", async () => {
    const { shell, handlers } = fakeShell();
    const s = new BridgeMessageSocket(shell, "sock-1");
    await settle();
    const got: number[][] = [];
    s.addEventListener("message", (e) => got.push(bytesOf((e as MessageEvent).data)));
    handlers.get("sock-1")!.frames([bytesToBase64(new Uint8Array([1, 2])), bytesToBase64(new Uint8Array([3]))]);
    expect(got).toEqual([[1, 2], [3]]);
  });

  it("the host closing it fires close once, and it delivers nothing after", async () => {
    const { shell, handlers } = fakeShell();
    const s = new BridgeMessageSocket(shell, "sock-1");
    await settle();
    let closes = 0, messages = 0;
    s.addEventListener("close", () => { closes++; });
    s.addEventListener("message", () => { messages++; });
    const h = handlers.get("sock-1")!;
    h.closed();
    h.closed();
    h.frames([bytesToBase64(new Uint8Array([9]))]);
    expect(s.readyState).toBe(3);
    expect(closes).toBe(1);
    expect(messages).toBe(0);
  });

  it("closing it tells the host, and fires close asynchronously", async () => {
    const { shell, calls } = fakeShell();
    const s = new BridgeMessageSocket(shell, "sock-1");
    await settle();
    let closes = 0;
    s.addEventListener("close", () => { closes++; });
    s.close(4001, "leaving");
    expect(calls.at(-1)).toEqual(["close", "sock-1"]);
    expect(closes).toBe(0);
    await settle();
    expect(closes).toBe(1);
    s.send(new Uint8Array([1]));                 // a closed WebSocket discards; it does not throw
    expect(calls.at(-1)).toEqual(["close", "sock-1"]);
  });

  it("a frame that is not base64 closes it", async () => {
    const { shell, calls, handlers } = fakeShell();
    const s = new BridgeMessageSocket(shell, "sock-1");
    await settle();
    handlers.get("sock-1")!.frames(["not base64!"]);
    expect(s.readyState).toBe(3);
    expect(calls.at(-1)).toEqual(["close", "sock-1"]);
  });

  it("carries the three channels: SocketChannels over it reads the host's frames", async () => {
    const { shell, handlers } = fakeShell();
    const s = new BridgeMessageSocket(shell, "x");
    const channels = new SocketChannels(s);
    await settle();
    channels.markOpen();
    const got: number[][] = [];
    channels.control.addEventListener("message", (e) => got.push(bytesOf((e as MessageEvent).data)));
    handlers.get("x")!.frames([bytesToBase64(encodeSocketFrame("control", new Uint8Array([1, 2, 3])))]);
    expect(got).toEqual([[1, 2, 3]]);
  });
});

describe("the bridge's base64", () => {
  it("round-trips every byte value and a large buffer", () => {
    const all = Uint8Array.from({ length: 256 }, (_, i) => i);
    expect(Array.from(base64ToBytes(bytesToBase64(all))!)).toEqual(Array.from(all));
    const big = Uint8Array.from({ length: 200_000 }, (_, i) => (i * 31) & 0xff);
    expect(Array.from(base64ToBytes(bytesToBase64(big))!)).toEqual(Array.from(big));
  });
  it("refuses what is not base64", () => {
    expect(base64ToBytes("not base64!")).toBeNull();
  });
});
