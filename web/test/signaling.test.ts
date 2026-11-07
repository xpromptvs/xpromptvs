import { expect, test, vi } from "vitest";
import { SignalingClient, type WebSocketLike } from "../src/lib/signaling";

class FakeSocket implements WebSocketLike {
  sent: string[] = [];
  private listeners: Record<string, ((e: any) => void)[]> = {};
  send(d: string) { this.sent.push(d); }
  close() {}
  addEventListener(type: string, cb: (e: any) => void) { (this.listeners[type] ??= []).push(cb); }
  emit(type: string, e: any) { for (const cb of this.listeners[type] ?? []) cb(e); }
  emitMessage(obj: unknown) { this.emit("message", { data: JSON.stringify(obj) }); }
}

// The JOIN INTENT is said inside the §11 session (`client-confirm`'s app_hello; docs/sources-and-focus.md, "The join
// intent"), never to the relay: a hello names who and how, and the relay refuses one carrying an intent.
test("the relay hello carries no join intent", () => {
  const sock = new FakeSocket();
  new SignalingClient(sock, { role: "client", token: "tok", resumeId: "rid-1", getResume: () => "rebuild" }, {});
  sock.emit("open", {});
  expect(Object.keys(JSON.parse(sock.sent[0]!)).sort()).toEqual(["resume", "resumeId", "role", "t", "token"]);
});

test("sends hello on open", () => {
  const sock = new FakeSocket();
  new SignalingClient(sock, { role: "host", token: "tok" }, {});
  sock.emit("open", {});
  expect(JSON.parse(sock.sent[0]!)).toEqual({ t: "hello", role: "host", token: "tok" });
});

test("routes welcome / peer-joined / e2e to handlers", () => {
  const sock = new FakeSocket();
  const onWelcome = vi.fn();
  const onPeerJoined = vi.fn();
  const onE2E = vi.fn();
  new SignalingClient(sock, { role: "host", token: "tok" }, { onWelcome, onPeerJoined, onE2E });
  const turn = { urls: ["turn:x"], username: "u", credential: "c", ttl: 600 };
  sock.emitMessage({ t: "welcome", sessionId: "s1", turn });
  sock.emitMessage({ t: "peer-joined", peer: "client-uuid-123" });
  sock.emitMessage({ t: "e2e", ct: "AAAA", peer: "client-uuid-123", mode: "auth" });
  expect(onWelcome).toHaveBeenCalledWith(turn);
  expect(onPeerJoined).toHaveBeenCalledWith("client-uuid-123");
  expect(onE2E).toHaveBeenCalledWith("AAAA", "client-uuid-123", "auth");
});

test("routes the host's e2e-reset", () => {
  const sock = new FakeSocket();
  const onE2EReset = vi.fn();
  new SignalingClient(sock, { role: "client", token: "tok" }, { onE2EReset });
  sock.emitMessage({ t: "e2e-reset" });
  expect(onE2EReset).toHaveBeenCalledTimes(1);
});

// **SDP HAS NO PLAINTEXT ARM.** An `offer` on the wire is a shape this client retired with the
// relay that carried it, so it reaches the unhandled-type warning like any other stranger — the
// difference between a protocol that is gone and one that is merely preferred.
test("a plaintext offer is not routed anywhere", () => {
  const sock = new FakeSocket();
  const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
  new SignalingClient(sock, { role: "client", token: "tok" }, {});
  sock.emitMessage({ t: "offer", sdp: "v=1", restart: true });
  expect(warn).toHaveBeenCalled();
  expect(String(warn.mock.calls[0]![0])).toContain("offer");
  warn.mockRestore();
});

test("hello carries resumeId and resume mode when provided", () => {
  const sock = new FakeSocket();
  let mode: "ice" | "rebuild" | undefined;
  new SignalingClient(sock, { role: "client", token: "tok", codecs: ["deflate"], resumeId: "rid-1", getResume: () => mode }, {});
  sock.emit("open", {});
  expect(JSON.parse(sock.sent[0]!)).toEqual({ t: "hello", role: "client", token: "tok", codecs: ["deflate"], resumeId: "rid-1" });
  mode = "rebuild";
  sock.emit("open", {});   // a later (re)open picks up the pending resume mode
  expect(JSON.parse(sock.sent[1]!)).toEqual({ t: "hello", role: "client", token: "tok", codecs: ["deflate"], resumeId: "rid-1", resume: "rebuild" });
});

// A connection that follows its Mac to another room (`host-follow.ts`) says THAT room's token on its next socket.
test("hello reads the token at each open when a getter is given", () => {
  const sock = new FakeSocket();
  let token = "old";
  new SignalingClient(sock, { role: "client", token: "old", getToken: () => token }, {});
  sock.emit("open", {});
  token = "new";
  sock.emit("open", {});
  expect(sock.sent.map((m) => JSON.parse(m).token)).toEqual(["old", "new"]);
});

// The only thing this client puts SDP and ICE into. A client omits `peer`; a host names it, and a
// host envelope without it is DROPPED by the relay — measured, and the reason the parameter exists.
test("sendE2E serializes an envelope, with the mode only on the first", () => {
  const sock = new FakeSocket();
  const c = new SignalingClient(sock, { role: "client", token: "tok" }, {});
  c.sendE2E("AAAA", "auth");
  c.sendE2E("BBBB");
  expect(JSON.parse(sock.sent[0]!)).toEqual({ t: "e2e", ct: "AAAA", mode: "auth" });
  expect(JSON.parse(sock.sent[1]!)).toEqual({ t: "e2e", ct: "BBBB" });
});

test("a host names its peer", () => {
  const sock = new FakeSocket();
  const c = new SignalingClient(sock, { role: "host", token: "tok" }, {});
  c.sendE2E("AAAA", undefined, "peer-uuid-123");
  expect(JSON.parse(sock.sent[0]!)).toEqual({ t: "e2e", ct: "AAAA", peer: "peer-uuid-123" });
});

// A message type the client does not handle must be VISIBLE, not silently discarded. `default: break` is
// how `peer-resumed` stayed invisible: the control plane sends 13 types, this client handles 8, and the
// two host-directed leftovers (peer-resumed, peer-suspended) vanished without trace — which is why a
// permanently-unsatisfiable smoke step survived unnoticed. The next protocol addition should announce
// itself instead.
test("warns once about an unhandled message type instead of swallowing it", () => {
  const sock = new FakeSocket();
  const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
  new SignalingClient(sock, { role: "host", token: "tok" }, {});
  sock.emitMessage({ t: "peer-resumed", peer: "p1", mode: "ice" });
  expect(warn).toHaveBeenCalledTimes(1);
  expect(String(warn.mock.calls[0]![0])).toContain("peer-resumed");
  // Repeats of the SAME type stay quiet — a per-message warning on a chatty type would be noise.
  sock.emitMessage({ t: "peer-resumed", peer: "p2", mode: "ice" });
  expect(warn).toHaveBeenCalledTimes(1);
  // A DIFFERENT unhandled type is its own signal.
  sock.emitMessage({ t: "peer-suspended", peer: "p1" });
  expect(warn).toHaveBeenCalledTimes(2);
  warn.mockRestore();
});

test("known types never warn", () => {
  const sock = new FakeSocket();
  const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
  new SignalingClient(sock, { role: "client", token: "tok" }, {});
  // `offer`, `answer` and `ice` are NOT in this list any more, and their absence is the assertion
  // above: they are shapes this client retired with the relay, and a retired shape must warn.
  for (const m of [{ t: "welcome", turn: null }, { t: "peer-joined", peer: "a" }, { t: "peer-left", peer: "a" },
                   { t: "e2e", ct: "AAAA" }, { t: "e2e-reset" }, { t: "error", code: "x" }, { t: "pong" }]) sock.emitMessage(m);
  expect(warn).not.toHaveBeenCalled();
  warn.mockRestore();
});
