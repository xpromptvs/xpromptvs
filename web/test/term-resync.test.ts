import { describe, expect, it } from "vitest";
import { TermResync, TERM_RESYNC_POLICY } from "../src/client/term-resync";

/// A clock and timers the test advances by hand. `answers`: the host answers every re-declaration with a wire
/// start 10 ms later, as a live host does (false: a request lost on the way, or a host that ignored it). `asking`:
/// whether this page can ask (it drives, its control channel open).
function harness({ answers = true, asking = () => true }: { answers?: boolean; asking?: () => boolean } = {}) {
  let now = 0;
  const timers: { at: number; f: () => void; id: number }[] = [];
  let nextId = 1;
  const log: string[] = [];
  const setTimer = (f: () => void, ms: number) => { const id = nextId++; timers.push({ at: now + ms, f, id }); return id; };
  const r: TermResync<number> = new TermResync<number>({
    request: () => { log.push(`request@${now}`); if (answers) setTimer(() => r.wireStarted(), 10); },
    gaveUp: () => log.push(`gave-up@${now}`),
    recovered: () => log.push(`recovered@${now}`),
    setTimer,
    clearTimer: (id) => { const i = timers.findIndex((t) => t.id === id); if (i >= 0) timers.splice(i, 1); },
    now: () => now,
    asking,
  });
  const advance = (ms: number) => {
    const end = now + ms;
    for (;;) {
      timers.sort((a, b) => a.at - b.at);
      const t = timers[0];
      if (!t || t.at > end) break;
      timers.shift(); now = t.at; t.f();
    }
    now = end;
  };
  return { r, log, advance, pending: () => timers.length, setNow: (t: number) => { now = t; } };
}

describe("TermResync", () => {
  it("backs off 250 ms doubling to 30 s between re-declarations, one at a time", () => {
    const { r, log, advance } = harness();
    const delays: number[] = [];
    let t = 0;
    for (let i = 0; i < TERM_RESYNC_POLICY.maxAttempts; i++) {
      r.failed();
      r.failed();                                     // a second failure while one is pending changes nothing
      advance(60_000);
      delays.push(Number(log.at(-1)!.split("@")[1]) - t);
      t += 60_000;
    }
    expect(log.length).toBe(TERM_RESYNC_POLICY.maxAttempts);
    expect(delays).toEqual([250, 500, 1000, 2000, 4000, 8000, 16000, 30000]);
    expect(log.every((l) => l.startsWith("request@"))).toBe(true);
  });

  it("a failure that repeats every time stops asking after the cap, and says so once", () => {
    const { r, log, advance, pending } = harness();
    for (let i = 0; i < TERM_RESYNC_POLICY.maxAttempts; i++) { r.failed(); advance(60_000); }
    const requests = log.length;
    r.failed();
    expect(log.at(-1)).toMatch(/^gave-up@/);
    expect(pending()).toBe(0);
    r.failed(); advance(10 * 60_000);
    expect(log.length).toBe(requests + 1);            // nothing more: no request, no second notice
  });

  it("a reconnect or a visible page starts over — and asks at once when it had given up", () => {
    const { r, log, advance } = harness();
    for (let i = 0; i <= TERM_RESYNC_POLICY.maxAttempts; i++) { r.failed(); advance(60_000); }
    expect(log.at(-1)).toMatch(/^gave-up@/);
    const n = log.length;
    r.reset(true);
    expect(log.slice(n).map((l) => l.split("@")[0])).toEqual(["recovered", "request"]);
    r.failed(); advance(250);
    expect(log.at(-1)).toMatch(/^request@/);          // back to the first delay
  });

  it("a reset that carries its own re-declaration (a control reopen) cancels a pending retry", () => {
    const { r, log, advance, pending } = harness();
    r.failed();
    r.reset(false);
    expect(pending()).toBe(0);
    advance(60_000);
    expect(log).toEqual([]);
  });

  // N4 (2026-09-27): after giving up, a wire that arrives anyway (a claim, a host-side rebind) and
  // DECODES CLEANLY — its start and a whole snapshot — proves the stream works again: the stop and the
  // "not updating" notice clear at once, not at the next reconnect or return to the page.
  it("after giving up, a wire that decodes cleanly clears the stop and the notice", () => {
    const { r, log, advance, pending } = harness();
    for (let i = 0; i <= TERM_RESYNC_POLICY.maxAttempts; i++) { r.failed(); advance(60_000); }
    expect(log.at(-1)).toMatch(/^gave-up@/);
    const n = log.length;
    r.decoded();
    expect(log.slice(n).map((l) => l.split("@")[0])).toEqual(["recovered"]);   // no request: the wire came
    expect(pending()).toBe(0);
    r.failed(); advance(250);
    expect(log.at(-1)).toMatch(/^request@/);          // asking again, from the first delay
  });

  // …but while it is still retrying a clean snapshot is NOT a recovery: one tab decoding while another
  // fails every time would otherwise reset the count on every wire and retry forever.
  it("a clean snapshot while still retrying leaves the count, so the cap still holds", () => {
    const { r, log, advance } = harness();
    for (let i = 0; i < TERM_RESYNC_POLICY.maxAttempts; i++) { r.failed(); advance(60_000); r.decoded(); }
    r.failed();
    expect(log.at(-1)).toMatch(/^gave-up@/);
    expect(log.filter((l) => l.startsWith("recovered")).length).toBe(0);
  });

  it("failures far apart are not consecutive", () => {
    const { r, log, advance } = harness();
    for (let i = 0; i < 5; i++) { r.failed(); advance(60_000); }
    advance(TERM_RESYNC_POLICY.forgetAfterMs);
    const n = log.length;
    r.failed(); advance(250);
    expect(log.length).toBe(n + 1);                   // retried after the FIRST delay again
  });

  // A WIRE START THAT NEVER COMES (docs/terminal.md, "A wire that never starts is asked for again"). The router drops
  // every frame until a wire start; with the one re-declaration lost — sent into a channel that read open and
  // delivered nothing, or ignored by a host that did not count this page the driver at that moment — nothing asked
  // again, nothing failed again, and no notice ever showed: a terminal frozen behind "connected".
  it("a re-declaration nobody answers is asked again, backing off, until the cap says so", () => {
    const { r, log, advance } = harness({ answers: false });
    r.failed();
    advance(60 * 60_000);
    const requests = log.filter((l) => l.startsWith("request@")).map((l) => Number(l.split("@")[1]));
    expect(requests.length).toBe(TERM_RESYNC_POLICY.maxAttempts);
    // Each wait for the wire is `awaitWireMs`, then the next back-off delay.
    const gaps = requests.slice(1).map((t, i) => t - requests[i]!);
    expect(gaps).toEqual([500, 1000, 2000, 4000, 8000, 16000, 30000].map((d) => d + TERM_RESYNC_POLICY.awaitWireMs));
    expect(log.at(-1)).toMatch(/^gave-up@/);
  });

  it("a wire start ends the wait", () => {
    const { r, log, advance } = harness({ answers: false });
    r.failed(); advance(250);
    r.wireStarted();
    advance(10 * 60_000);
    expect(log).toEqual(["request@250"]);
  });

  it("a wire owed to a driver — a control open, a claim — that never comes is asked for", () => {
    const { r, log, advance } = harness({ answers: false });
    r.expectWire();
    advance(TERM_RESYNC_POLICY.awaitWireMs - 1);
    expect(log).toEqual([]);
    advance(1 + 250);
    expect(log).toEqual([`request@${TERM_RESYNC_POLICY.awaitWireMs + 250}`]);
  });

  it("a page that cannot ask — passive, or its control channel down — drops the wait, and asks for nothing", () => {
    let asking = false;
    const { r, log, advance } = harness({ answers: false, asking: () => asking });
    r.expectWire();
    advance(10 * 60_000);
    expect(log).toEqual([]);
    asking = true;
    r.expectWire();
    advance(TERM_RESYNC_POLICY.awaitWireMs + 250);
    expect(log.length).toBe(1);
  });

  it("a reset that declares raw itself starts over: the wait goes with it", () => {
    const { r, log, advance, pending } = harness({ answers: false });
    r.expectWire();
    r.reset(false);
    expect(pending()).toBe(0);
    advance(10 * 60_000);
    expect(log).toEqual([]);
  });

  // Review finding 1 (2026-10-11): a phone that left and came back inside `awaitWireMs` of a lost wire start — the
  // page becoming visible resets — cancelled the wait and asked for nothing: every tab frozen behind "connected".
  it("the page becoming visible while a wire start is awaited asks for one at once", () => {
    const { r, log, advance } = harness({ answers: false });
    r.becameDriver();                                 // the claim's wire start, lost
    advance(5_000);
    r.reset(true);                                    // away and back within awaitWireMs
    expect(log).toEqual(["request@5000"]);
    advance(TERM_RESYNC_POLICY.awaitWireMs + 250);
    expect(log.length).toBe(2);                       // and that one is awaited too
  });

  it("the page becoming visible keeps the wire that started: becoming the driver later owes nothing", () => {
    const { r, log, advance } = harness({ answers: false });
    r.wireStarted();                                  // the claim's wire, ahead of its control-state…
    r.reset(true);                                    // …a visibility change between them…
    r.becameDriver();                                 // …and the control-state
    advance(10 * 60_000);
    expect(log).toEqual([]);
  });

  it("a control open forgets the wire that started — its router waits for a new one — and owes it", () => {
    const { r, log, advance } = harness({ answers: false });
    r.wireStarted();
    r.connectionOpened();
    r.becameDriver();
    advance(TERM_RESYNC_POLICY.awaitWireMs + 250);
    expect(log).toEqual([`request@${TERM_RESYNC_POLICY.awaitWireMs + 250}`]);
  });

  // "Move here": the host sends the claim's wire BEFORE the control-state that says this page drives — so becoming
  // the driver owes a wire only if none started since the page went passive. Owed regardless, every claim would be
  // followed, 15 s later, by a needless second snapshot of every tab.
  it("becoming the driver after the claim's wire already started owes nothing", () => {
    const { r, log, advance } = harness({ answers: false });
    r.passive();
    r.wireStarted();                                  // the claim's wire, ahead of its control-state
    r.becameDriver();
    advance(10 * 60_000);
    expect(log).toEqual([]);
  });

  it("becoming the driver with no wire yet owes one, and asks when it does not come", () => {
    const { r, log, advance } = harness({ answers: false });
    r.wireStarted();                                  // the previous driver period's
    r.passive();                                      // …forgotten on going passive
    r.becameDriver();
    advance(TERM_RESYNC_POLICY.awaitWireMs + 250);
    expect(log).toEqual([`request@${TERM_RESYNC_POLICY.awaitWireMs + 250}`]);
  });

  it("going passive cancels what was owed", () => {
    const { r, log, advance } = harness({ answers: false });
    r.expectWire();
    r.passive();
    advance(10 * 60_000);
    expect(log).toEqual([]);
  });
});
