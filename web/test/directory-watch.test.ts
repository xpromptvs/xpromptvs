import { describe, expect, it } from "vitest";
import { watchDirectory, WATCH_PING_MS, type WatchEvent } from "../src/lib/directory-watch";
import { directoryRequestBody, ed25519PublicKey, rootId, verifyEd25519 } from "@rdev/protocol";
import { base64urlDecode, base64urlEncode } from "../src/lib/base64url";

class FakeSocket {
  listeners: Record<string, ((e: any) => void)[]> = {};
  sent: any[] = [];
  closed = false;
  constructor(public url: string) {}
  addEventListener(t: string, cb: (e: any) => void) { (this.listeners[t] ??= []).push(cb); }
  send(d: string) { this.sent.push(JSON.parse(d)); }
  close() { this.closed = true; }
  emit(t: string, e: any) { (this.listeners[t] ?? []).forEach((cb) => cb(e)); }
  frame(m: unknown) { this.emit("message", { data: JSON.stringify(m) }); }
}

const priv = new Uint8Array(32).fill(7);
const identity = { root: new Uint8Array([1, 2, 3]), bundle: new Uint8Array([9, 9]), signingPrivateKey: priv };
const challenge = base64urlEncode(new Uint8Array(32).fill(0x66));

function harness(hidden = false) {
  const sockets: FakeSocket[] = [];
  const timers: { fn: () => void; ms: number; live: boolean }[] = [];
  const events: WatchEvent[] = [];
  const abort = new AbortController();
  const handle = watchDirectory({
    base: "https://cp.test", identity, signal: abort.signal, onEvent: (e) => events.push(e),
    socket: (url) => { const s = new FakeSocket(url); sockets.push(s); return s; },
    schedule: (fn, ms) => { timers.push({ fn, ms, live: true }); return timers.length - 1; },
    clear: (t) => { timers[t as number]!.live = false; },
    hidden: () => hidden,
    random: (n) => new Uint8Array(n).fill(0x44),
  });
  const fire = (ms: number) => {
    const t = timers.find((x) => x.live && x.ms === ms);
    if (!t) throw new Error(`no live ${ms} ms timer`);
    t.live = false; t.fn();
  };
  const pending = (ms: number) => timers.filter((x) => x.live && x.ms === ms).length;
  return { sockets, events, abort, handle, fire, pending };
}

describe("watchDirectory", () => {
  it("connects to /watch on the ws scheme", () => {
    const { sockets } = harness();
    expect(sockets[0]!.url).toBe(
      `wss://cp.test/directory/${base64urlEncode(rootId(identity.root))}/watch`);
  });

  it("answers a challenge with a subscribe the Worker's rebuild verifies", () => {
    const { sockets } = harness();
    sockets[0]!.emit("open", {});
    sockets[0]!.frame({ t: "challenge", challenge });
    const sub = sockets[0]!.sent[0];
    expect(sub.t).toBe("subscribe");
    const body = directoryRequestBody("subscribe", base64urlDecode(challenge)!, rootId(identity.root),
                                      base64urlDecode(sub.operation_id)!, new Uint8Array(0))!;
    expect(verifyEd25519(base64urlDecode(sub.signature)!, body, ed25519PublicKey(priv))).toBe(true);
  });

  it("renews at half of renew_in with the handed-over challenge", () => {
    const { sockets, fire } = harness();
    sockets[0]!.emit("open", {});
    sockets[0]!.frame({ t: "subscribed", renew_in: 60, challenge });
    fire(30_000);
    expect(sockets[0]!.sent.at(-1).t).toBe("subscribe");
  });

  it("reports snapshots, dropping malformed rows", () => {
    const { sockets, events } = harness();
    sockets[0]!.emit("open", {});
    sockets[0]!.frame({ t: "sessions", sessions: [
      { code: "A", token: "t", label: "Mac", device_id: "d" }, { code: "B" }] });
    expect(events).toEqual([{ kind: "sessions",
      sessions: [{ code: "A", token: "t", label: "Mac", device_id: "d" }] }]);
  });

  it("pings every 20 s while open", () => {
    const { sockets, fire } = harness();
    sockets[0]!.emit("open", {});
    fire(WATCH_PING_MS);
    expect(sockets[0]!.sent.at(-1)).toEqual({ t: "ping" });
  });

  for (const code of [4401, 4403, 4429]) {
    it(`stops for good on ${code}`, () => {
      const { sockets, events, pending } = harness();
      sockets[0]!.emit("open", {});
      sockets[0]!.emit("close", { code });
      expect(events.at(-1)).toEqual({ kind: "stopped", reason: "refused", code });
      expect(pending(500)).toBe(0);
    });
  }

  it("reconnects at once on 4408", () => {
    const { sockets, fire } = harness();
    sockets[0]!.emit("open", {});
    sockets[0]!.emit("close", { code: 4408 });
    fire(0);                                     // the immediate kick
    expect(sockets.length).toBe(2);
  });

  it("gives up after three attempts that never opened", () => {
    const { sockets, events, fire } = harness();
    sockets[0]!.emit("close", {}); fire(500);
    sockets[1]!.emit("close", {}); fire(1000);
    sockets[2]!.emit("close", {});
    expect(events.at(-1)).toEqual({ kind: "stopped", reason: "unavailable" });
  });

  it("abort closes and stops every timer", () => {
    const { sockets, abort, pending } = harness();
    sockets[0]!.emit("open", {});
    abort.abort();
    expect(sockets[0]!.closed).toBe(true);
    expect(pending(WATCH_PING_MS)).toBe(0);
  });

  it("ping() sends one now", () => {
    const { sockets, handle } = harness();
    sockets[0]!.emit("open", {});
    handle.ping();
    expect(sockets[0]!.sent.at(-1)).toEqual({ t: "ping" });
  });
});
