import { describe, expect, test } from "vitest";
import { decodeSocketFrame, encodeSocketFrame, SOCKET_MALFORMED_CLOSE_CODE } from "@rdev/protocol";
import { SocketChannels, type MessageSocket } from "../src/lib/socket-channels";

/** A WebSocket-shaped socket the test drives: `sent` is what the page sent, `receive` the host sending. */
class FakeSocket extends EventTarget implements MessageSocket {
  binaryType: BinaryType = "blob";
  readyState = 1;
  sent: Uint8Array[] = [];
  closed: { code?: number; reason?: string } | null = null;
  send(data: ArrayBufferLike | ArrayBufferView): void {
    this.sent.push(ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice()
                                            : new Uint8Array(data as ArrayBuffer).slice());
  }
  close(code?: number, reason?: string): void { this.closed = { code, reason }; }
  receive(frame: Uint8Array): void { this.dispatchEvent(new MessageEvent("message", { data: frame.slice().buffer })); }
}

describe("SocketChannels", () => {
  test("a channel sends its bytes in a frame naming it", () => {
    const s = new FakeSocket();
    const ch = new SocketChannels(s);
    ch.markOpen();
    ch.control.send(new Uint8Array([0, 123, 125]));
    ch.input.send("a");
    const result = s.sent.map((f) => {
      const decoded = decodeSocketFrame(f);
      return decoded ? { channel: decoded.channel, payload: [...decoded.payload] } : null;
    });
    expect(result).toEqual([
      { channel: "control", payload: [0, 123, 125] },
      { channel: "input", payload: [97] },
    ]);
  });

  test("a channel is CONNECTING until opened, refuses to send before, and opens in WebRTC's order", () => {
    const ch = new SocketChannels(new FakeSocket());
    expect(ch.control.readyState).toBe("connecting");
    expect(() => ch.control.send("x")).toThrow();
    const order: string[] = [];
    for (const c of [ch.control, ch.input, ch.terminal, ch.bulk]) c.addEventListener("open", () => order.push(c.label));
    ch.markOpen();
    expect(order).toEqual(["terminal", "input", "control", "bulk"]);
    expect(ch.terminal.readyState).toBe("open");
  });

  test("a frame from the host reaches its channel as an ArrayBuffer", () => {
    const s = new FakeSocket();
    const ch = new SocketChannels(s);
    ch.markOpen();
    const got: ArrayBuffer[] = [];
    ch.terminal.addEventListener("message", (e) => got.push((e as MessageEvent).data as ArrayBuffer));
    s.receive(encodeSocketFrame("terminal", new Uint8Array([4, 0])));
    expect(got.map((b) => [...new Uint8Array(b)])).toEqual([[4, 0]]);
  });

  test("a frame naming no channel, or the meta channel, closes the socket as malformed", () => {
    for (const frame of [new Uint8Array([9, 1]), encodeSocketFrame("meta", new Uint8Array([1]))]) {
      const s = new FakeSocket();
      new SocketChannels(s).markOpen();
      s.receive(frame);
      expect(s.closed?.code).toBe(SOCKET_MALFORMED_CLOSE_CODE);
    }
  });

  test("markClosed closes every channel once", () => {
    const ch = new SocketChannels(new FakeSocket());
    ch.markOpen();
    let closes = 0;
    ch.control.addEventListener("close", () => { closes++; });
    ch.markClosed(); ch.markClosed();
    expect(closes).toBe(1);
    expect(ch.control.readyState).toBe("closed");
  });

  test("all() hands the four channels over under their names", () => {
    const ch = new SocketChannels(new FakeSocket());
    const all = ch.all();
    expect([all.terminal.label, all.input.label, all.control.label, all.bulk.label]).toEqual(["terminal", "input", "control", "bulk"]);
  });
});
