import { describe, it, expect, vi } from "vitest";
import { ReconnectingSocket } from "../src/lib/reconnecting-socket";

// A fake underlying socket we can drive.
class FakeSocket {
  listeners: Record<string, ((e: any) => void)[]> = {};
  sent: string[] = [];
  closed = false;
  addEventListener(t: string, cb: (e: any) => void) { (this.listeners[t] ??= []).push(cb); }
  send(d: string) { this.sent.push(d); }
  close() { this.closed = true; this.emit("close", {}); }
  emit(t: string, e: any) { (this.listeners[t] ?? []).forEach((cb) => cb(e)); }
}

function harness() {
  const sockets: FakeSocket[] = [];
  const timers: { fn: () => void; ms: number }[] = [];
  const rs = new ReconnectingSocket(() => { const s = new FakeSocket(); sockets.push(s); return s; }, {
    backoffMinMs: 500, backoffMaxMs: 8000,
    schedule: (fn, ms) => { timers.push({ fn, ms }); return timers.length - 1; },
    clear: () => {},
  });
  return { rs, sockets, timers };
}

describe("ReconnectingSocket", () => {
  it("opens the first socket and forwards messages", () => {
    const { rs, sockets } = harness();
    const seen: string[] = [];
    rs.addEventListener("message", (e) => seen.push(e.data));
    sockets[0]!.emit("open", {});
    sockets[0]!.emit("message", { data: "hi" });
    expect(seen).toEqual(["hi"]);
  });
  it("reconnects with backoff after an unexpected close and fires onReconnect", () => {
    const { rs, sockets, timers } = harness();
    const reconnects: number[] = [];
    rs.onReconnect(() => reconnects.push(1));
    sockets[0]!.emit("open", {});
    sockets[0]!.emit("close", {});           // unexpected drop
    expect(timers.length).toBe(1);
    expect(timers[0]!.ms).toBe(500);         // first backoff
    timers[0]!.fn();                          // fire the reconnect timer
    expect(sockets.length).toBe(2);          // a new socket was created
    sockets[1]!.emit("open", {});
    expect(reconnects.length).toBe(1);       // onReconnect fired on reopen
  });
  it("does not reconnect after an explicit close()", () => {
    const { rs, sockets, timers } = harness();
    sockets[0]!.emit("open", {});
    rs.close();
    expect(timers.length).toBe(0);
    expect(sockets.length).toBe(1);
  });
  it("resets backoff after a successful open", () => {
    const { rs, sockets, timers } = harness();
    sockets[0]!.emit("open", {});
    sockets[0]!.emit("close", {});
    timers[0]!.fn();                 // 500ms
    sockets[1]!.emit("open", {});    // success resets
    sockets[1]!.emit("close", {});
    expect(timers[1]!.ms).toBe(500); // back to min, not 1000
  });
  it("recycle() on an open socket forces a reconnect", () => {
    const { rs, sockets, timers } = harness();
    sockets[0]!.emit("open", {});
    rs.recycle();
    expect(sockets[0]!.closed).toBe(true);   // recycle closed the current underlying socket
    expect(timers.length).toBe(1);           // the ordinary close listener scheduled a reconnect
    timers[0]!.fn();                          // fire the backoff timer
    expect(sockets.length).toBe(2);          // a new socket was created — same path as an unexpected drop
  });
  it("recycle() after an explicit close() is a safe no-op", () => {
    const { rs, sockets, timers } = harness();
    sockets[0]!.emit("open", {});
    rs.close();
    rs.recycle();
    expect(timers.length).toBe(0);
    expect(sockets.length).toBe(1);
  });
  it("recycle() with no live socket (never opened yet) is a safe no-op", () => {
    const { rs, sockets, timers } = harness();
    rs.recycle();                    // never opened — no live socket to recycle
    expect(sockets[0]!.closed).toBe(false);
    expect(timers.length).toBe(0);
    expect(sockets.length).toBe(1);
  });
  it("recycle() while already reconnecting (down) is a safe no-op", () => {
    const { rs, sockets, timers } = harness();
    sockets[0]!.emit("open", {});
    sockets[0]!.emit("close", {});   // unexpected drop — already reconnecting
    expect(timers.length).toBe(1);
    rs.recycle();                    // no live socket right now — must not schedule a second timer
    expect(timers.length).toBe(1);
    expect(sockets.length).toBe(1);
  });

  // A socket that never opens used to be completely silent: it retried forever, swallowed `error`,
  // and nothing upstream could tell "unreachable" from "still connecting".
  it("reports every retried close, with opened false until one has opened", () => {
    const { rs, sockets, timers } = harness();
    const down: { opened: boolean; failures: number }[] = [];
    rs.onDown((info) => down.push(info));
    sockets[0]!.emit("close", {});
    timers[0]!.fn();
    sockets[1]!.emit("close", {});
    expect(down).toEqual([{ opened: false, failures: 1 }, { opened: false, failures: 2 }]);
  });
  it("counts failures consecutively and resets them on a successful open", () => {
    const { rs, sockets, timers } = harness();
    const down: { opened: boolean; failures: number }[] = [];
    rs.onDown((info) => down.push(info));
    sockets[0]!.emit("close", {});
    timers[0]!.fn();
    sockets[1]!.emit("open", {});            // the link came back
    sockets[1]!.emit("close", {});           // ...and dropped again
    expect(down).toEqual([{ opened: false, failures: 1 }, { opened: true, failures: 1 }]);
  });
  it("does NOT report an explicit close", () => {
    const { rs, sockets } = harness();
    const down: unknown[] = [];
    rs.onDown((info) => down.push(info));
    sockets[0]!.emit("open", {});
    rs.close(4001, "leaving");
    expect(down).toEqual([]);
  });
  it("still reconnects — the notification changes no retry policy", () => {
    const { rs, sockets, timers } = harness();
    rs.onDown(() => {});
    sockets[0]!.emit("close", {});
    expect(timers[0]!.ms).toBe(500);
    timers[0]!.fn();
    expect(sockets.length).toBe(2);
  });
});

/** Timers that can actually be cancelled, so a watchdog that was disarmed is seen NOT to fire. */
function timedHarness(opts: { connectTimeoutMs?: number; staleAfterMs?: number;
                              staleDeferred?: () => boolean } = {}) {
  const sockets: FakeSocket[] = [];
  const timers: { fn: () => void; ms: number; live: boolean }[] = [];
  const rs = new ReconnectingSocket(() => { const s = new FakeSocket(); sockets.push(s); return s; }, {
    backoffMinMs: 500, backoffMaxMs: 8000, ...opts,
    schedule: (fn, ms) => { timers.push({ fn, ms, live: true }); return timers.length - 1; },
    clear: (t) => { timers[t as number]!.live = false; },
  });
  /** Fire the live timer scheduled for `ms`, which must exist. */
  const fire = (ms: number): void => {
    const t = timers.find((x) => x.live && x.ms === ms);
    if (!t) throw new Error(`no live ${ms} ms timer`);
    t.live = false;
    t.fn();
  };
  const pending = (ms: number): number => timers.filter((x) => x.live && x.ms === ms).length;
  return { rs, sockets, fire, pending };
}

// A weak network strands a socket rather than closing it: it reads OPEN while every send vanishes.
describe("ReconnectingSocket — watchdogs", () => {
  it("abandons an attempt stuck in CONNECTING and reconnects", () => {
    const { rs, sockets, fire, pending } = timedHarness({ connectTimeoutMs: 10_000 });
    const down: unknown[] = [];
    rs.onDown((d) => down.push(d));
    fire(10_000);
    expect(sockets[0]!.closed).toBe(true);
    expect(down).toEqual([{ opened: false, failures: 1 }]);
    fire(500);
    expect(sockets.length).toBe(2);
    // A link that is merely SLOW gets longer on each consecutive timeout.
    expect(pending(20_000)).toBe(1);
  });

  it("an attempt that opens in time is not abandoned", () => {
    const { sockets, pending } = timedHarness({ connectTimeoutMs: 10_000 });
    sockets[0]!.emit("open", {});
    expect(pending(10_000)).toBe(0);
  });

  it("abandons an OPEN socket that has heard nothing, and resumes on the new one", () => {
    const { rs, sockets, fire } = timedHarness({ staleAfterMs: 45_000 });
    const reconnects: number[] = [];
    rs.onReconnect(() => reconnects.push(1));
    sockets[0]!.emit("open", {});
    fire(45_000);
    expect(sockets[0]!.closed).toBe(true);
    fire(500);
    sockets[1]!.emit("open", {});
    expect(reconnects).toEqual([1]);
  });

  it("every message re-arms the stale watchdog", () => {
    const { sockets, pending } = timedHarness({ staleAfterMs: 45_000 });
    sockets[0]!.emit("open", {});
    sockets[0]!.emit("message", { data: "pong" });
    sockets[0]!.emit("message", { data: "pong" });
    expect(pending(45_000)).toBe(1);
  });

  it("an ABANDONED socket's late events are ignored", () => {
    const { rs, sockets, fire } = timedHarness({ staleAfterMs: 45_000 });
    const seen: string[] = [];
    const down: unknown[] = [];
    rs.addEventListener("message", (e) => seen.push(e.data));
    rs.onDown((d) => down.push(d));
    sockets[0]!.emit("open", {});
    fire(45_000);
    sockets[0]!.emit("message", { data: "late" });
    sockets[0]!.emit("close", {});             // the closing handshake finally gives up
    expect(seen).toEqual([]);
    expect(down.length).toBe(1);               // one drop, not two
  });

  it("a DEFERRED stale verdict re-arms instead of abandoning (a hidden tab's throttled timers)", () => {
    let hidden = true;
    const { sockets, fire, pending } = timedHarness({ staleAfterMs: 45_000, staleDeferred: () => hidden });
    sockets[0]!.emit("open", {});
    fire(45_000);
    expect(sockets[0]!.closed).toBe(false);
    expect(pending(45_000)).toBe(1);
    hidden = false;
    fire(45_000);
    expect(sockets[0]!.closed).toBe(true);
  });

  it("a PROBE abandons an open socket that stays silent — the page back from the background", () => {
    const { rs, sockets, fire } = timedHarness({ staleAfterMs: 45_000 });
    const down: unknown[] = [];
    rs.onDown((d) => down.push(d));
    sockets[0]!.emit("open", {});
    rs.probe(5_000);
    fire(5_000);
    expect(sockets[0]!.closed).toBe(true);
    expect(down.length).toBe(1);
    fire(500);
    expect(sockets.length).toBe(2);
  });

  it("anything received settles a probe", () => {
    const { rs, sockets, pending } = timedHarness({ staleAfterMs: 45_000 });
    sockets[0]!.emit("open", {});
    rs.probe(5_000);
    sockets[0]!.emit("message", { data: "pong" });
    expect(pending(5_000)).toBe(0);
    expect(sockets[0]!.closed).toBe(false);
  });

  it("a probe is a no-op with no open socket, and is never deferred", () => {
    const { rs, sockets, fire, pending } = timedHarness({ staleAfterMs: 45_000, staleDeferred: () => true });
    rs.probe(5_000);                           // still CONNECTING: nothing to prove
    expect(pending(5_000)).toBe(0);
    sockets[0]!.emit("open", {});
    rs.probe(5_000);
    fire(5_000);                               // staleDeferred says hidden; a probe does not ask
    expect(sockets[0]!.closed).toBe(true);
  });

  it("the watchdogs are OFF by default", () => {
    const { sockets, pending } = timedHarness();
    sockets[0]!.emit("open", {});
    expect(pending(45_000) + pending(10_000)).toBe(0);
  });

  it("close() disarms both watchdogs", () => {
    const { rs, sockets, pending } = timedHarness({ connectTimeoutMs: 10_000, staleAfterMs: 45_000 });
    sockets[0]!.emit("open", {});
    rs.close();
    expect(pending(45_000) + pending(10_000)).toBe(0);
  });
});

describe("ReconnectingSocket.kick", () => {
  it("brings a pending retry forward and resets the backoff", () => {
    const { rs, sockets, pending } = timedHarness();
    sockets[0]!.emit("close", {});
    expect(pending(500)).toBe(1);
    rs.kick();
    expect(pending(500)).toBe(0);
    expect(sockets.length).toBe(2);
    sockets[1]!.emit("close", {});
    expect(pending(500)).toBe(1);            // back to the minimum, not 1000
  });

  it("is a no-op while open, while connecting, and after close()", () => {
    const { rs, sockets } = timedHarness();
    rs.kick();                               // connecting
    sockets[0]!.emit("open", {});
    rs.kick();                               // open
    rs.close();
    rs.kick();                               // closed by us
    expect(sockets.length).toBe(1);
  });
});


describe("ReconnectingSocket — close codes", () => {
  it("passes the close code to onDown, and none for an abandoned socket", () => {
    const { rs, sockets, fire } = timedHarness({ staleAfterMs: 45_000 });
    const codes: Array<number | undefined> = [];
    rs.onDown((d) => codes.push(d.code));
    sockets[0]!.emit("open", {});
    sockets[0]!.emit("close", { code: 4408 });
    fire(500);
    sockets[1]!.emit("open", {});
    fire(45_000);                                // abandoned: no close event of its own
    expect(codes).toEqual([4408, undefined]);
  });
});

describe("ReconnectingSocket — close() from inside onDown", () => {
  it("is honoured: no reconnect is scheduled after the callbacks", () => {
    const { rs, sockets, pending } = timedHarness();
    rs.onDown(() => rs.close());
    sockets[0]!.emit("open", {});
    sockets[0]!.emit("close", { code: 4401 });
    expect(pending(500)).toBe(0);
    expect(sockets.length).toBe(1);
  });
});
