import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { decodeSocketFrame, parseSocketHello } from "@rdev/protocol";
import { socketTransport } from "../src/client/socket-connection";
import { SessionScope } from "../src/client/session-scope";
import type { Channels } from "../src/lib/channel";
import type { MessageSocket } from "../src/lib/socket-channels";
import type { RdevDebug } from "../src/lib/debug";

class FakeSocket extends EventTarget implements MessageSocket {
  binaryType: BinaryType = "blob";
  readyState = 0;
  sent: Uint8Array[] = [];
  closedWith: number | undefined;
  send(data: ArrayBufferLike | ArrayBufferView): void {
    this.sent.push(ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice()
                                            : new Uint8Array(data as ArrayBuffer).slice());
  }
  close(code?: number): void { this.closedWith = code; this.readyState = 3; this.dispatchEvent(new Event("close")); }
  opened(): void { this.readyState = 1; this.dispatchEvent(new Event("open")); }
  dropped(): void { this.readyState = 3; this.dispatchEvent(new Event("close")); }
  hello() { const f = decodeSocketFrame(this.sent[0]!); return f?.channel === "meta" ? parseSocketHello(f.payload) : null; }
}

describe("SocketConnection", () => {
  let sockets: FakeSocket[];
  let scope: SessionScope;
  let handed: Channels[];
  let statuses: string[];
  const connect = () => socketTransport({ clientId: "tab-1", open: () => { const s = new FakeSocket(); sockets.push(s); return s; } })
    .connect({ scope, dbg: {} as RdevDebug, jitterBufferTargetMs: 1,
               sink: { channels: (ch) => { handed.push(ch); }, status: (_s, t) => { statuses.push(t); } } });

  beforeEach(() => { vi.useFakeTimers(); sockets = []; scope = new SessionScope(); handed = []; statuses = []; });
  afterEach(() => { scope.dispose(); vi.useRealTimers(); });

  test("carries no media", () => {
    expect(socketTransport({ clientId: "x", open: () => new FakeSocket() }).carriesMedia).toBe(false);
    expect(connect().media).toBeNull();
  });

  test("the first frame is a hello saying connect, then the three channels open", () => {
    const c = connect();
    expect(c.connectionState).toBe("connecting");
    sockets[0]!.opened();
    expect(sockets[0]!.hello()).toEqual({ client: "tab-1", intent: "connect" });
    expect(handed.length).toBe(1);
    expect(handed[0]!.control.readyState).toBe("open");
    expect(c.connectionState).toBe("connected");
    expect(statuses.at(-1)).toBe("connected");
  });

  test("a socket that drops after the control channel opened reconnects, saying reconnect", () => {
    connect();
    sockets[0]!.opened();
    sockets[0]!.dropped();
    expect(handed[0]!.control.readyState).toBe("closed");
    expect(statuses.at(-1)).toBe("reconnecting…");
    vi.advanceTimersByTime(1000);
    expect(sockets.length).toBe(2);
    sockets[1]!.opened();
    expect(sockets[1]!.hello()).toEqual({ client: "tab-1", intent: "reconnect" });
    expect(handed.length).toBe(2);
  });

  test("a socket that never opened retries with connect, backing off", () => {
    connect();
    sockets[0]!.dropped();
    vi.advanceTimersByTime(1000);
    sockets[1]!.dropped();
    vi.advanceTimersByTime(1999);
    expect(sockets.length).toBe(2);
    vi.advanceTimersByTime(1);
    sockets[2]!.opened();
    expect(sockets[2]!.hello()).toEqual({ client: "tab-1", intent: "connect" });
  });

  test("leave closes with the leave code and never reconnects", () => {
    const c = connect();
    sockets[0]!.opened();
    c.leave();
    expect(sockets[0]!.closedWith).toBe(4001);
    expect(handed[0]!.control.readyState).toBe("closed");         // as a closed peer's channels read
    expect(handed[0]!.terminal.readyState).toBe("closed");
    expect(handed[0]!.input.readyState).toBe("closed");
    vi.advanceTimersByTime(60_000);
    expect(sockets.length).toBe(1);
    expect(c.connectionState).toBe("closed");
  });
});

test("native presentation is a trusted transport option, independent of media and sameMac", () => {
  const open = () => new FakeSocket();
  expect(socketTransport({ clientId: "x", open, sameMac: true }).presentation).toBe("terminal-only");
  expect(socketTransport({ clientId: "x", open, sameMac: true, nativeSimulators: true }).presentation).toBe("native-simulators");
});
