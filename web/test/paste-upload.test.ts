import { afterEach, describe, expect, it, vi } from "vitest";
import { ACCEPT_TIMEOUT_MS, DRAIN_POLL_MS, PACE_HIGH_BYTES, PasteUploader, type Delivery, type UploaderDeps } from "../src/client/paste-upload";
import { PASTE_CHUNK_BYTES } from "../src/client/paste-wire";

// jsdom's Blob lacks arrayBuffer(); every browser the product ships to has it.
if (typeof Blob.prototype.arrayBuffer !== "function") {
  Blob.prototype.arrayBuffer = function (this: Blob) {
    return new Promise<ArrayBuffer>((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(r.result as ArrayBuffer);
      r.onerror = () => reject(r.error);
      r.readAsArrayBuffer(this);
    });
  };
}

/// What the HOST does with a `paste-begin` it opens: `paste-accepted`, a task later (the reply crosses the channel).
/// Every uploader below that is not about the acknowledgement itself is built with it.
function accepting(deps: UploaderDeps): PasteUploader {
  const up: PasteUploader = new PasteUploader({
    ...deps,
    send: (m) => {
      deps.send(m);
      const o = m as { t?: string; id?: string };
      if (o.t === "paste-begin") setTimeout(() => up.onReply({ t: "paste-accepted", id: o.id! }), 0);
    },
  });
  return up;
}
function rig({ accept = true }: { accept?: boolean } = {}) {
  const ch = { readyState: "open" as RTCDataChannelState, bufferedAmount: 0 };
  const sent: Record<string, unknown>[] = [];
  const progress: number[] = [];
  let n = 0;
  const deps: UploaderDeps = {
    channel: () => ch as never,
    send: (m) => { sent.push(m as Record<string, unknown>); },
    onProgress: (s) => { progress.push(s); },
    sleep: async () => { ch.bufferedAmount = Math.max(0, ch.bufferedAmount - PACE_HIGH_BYTES); },
    newId: () => `p${++n}`,
  };
  const up = accept ? accepting(deps) : new PasteUploader(deps);
  return { ch, sent, progress, up };
}
const file = (bytes: number, name = "a.png"): Delivery["items"][number] =>
  ({ kind: "file", name, type: "image/png", blob: new Blob([new Uint8Array(bytes).fill(7)]) });
const until = async (f: () => boolean) => { for (let i = 0; i < 1000 && !f(); i++) await new Promise((r) => setTimeout(r, 0)); };

describe("PasteUploader — §3", () => {
  it("declares, sends 16 KiB pieces in order, ends, and resolves on paste-done", async () => {
    const { sent, up } = rig();
    const done = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await until(() => sent.some((m) => m.t === "paste-end"));
    expect(sent[0]).toMatchObject({ t: "paste-begin", id: "p1", to: { term: "pty:1" }, items: [{ kind: "file", size: 40_000 }] });
    const data = sent.filter((m) => m.t === "paste-data");
    expect(data.map((m) => m.seq)).toEqual([0, 1, 2]);
    expect(data.map((m) => atob(m.data as string).length)).toEqual([PASTE_CHUNK_BYTES, PASTE_CHUNK_BYTES, 40_000 - 2 * PASTE_CHUNK_BYTES]);
    up.onReply({ t: "paste-done", id: "p1", how: "paste" });
    expect(await done).toEqual({ ok: true, how: "paste" });
  });
  it("text goes as UTF-8, and one delivery waits for the one before", async () => {
    const { sent, up } = rig();
    const a = up.deliver({ to: { win: "win:1" }, items: [{ kind: "text", text: "héllo" }] });
    const b = up.deliver({ to: { term: "pty:1" }, items: [file(1)] });
    await until(() => sent.some((m) => m.t === "paste-end"));
    expect(sent.filter((m) => m.t === "paste-begin").length).toBe(1);
    expect(sent[0]).toMatchObject({ items: [{ kind: "text", size: 6 }] });
    up.onReply({ t: "paste-done", id: "p1", how: "paste" });
    await a;
    await until(() => sent.filter((m) => m.t === "paste-begin").length === 2);
    up.onReply({ t: "paste-done", id: "p2", how: "paste" });
    expect(await b).toEqual({ ok: true, how: "paste" });
  });
  it("never lets the channel hold more than 256 KiB unsent", async () => {
    const ch = { readyState: "open" as RTCDataChannelState, bufferedAmount: 0 };
    let maxSeen = 0, pieces = 0;
    const up = accepting({
      channel: () => ch as never,
      send: (m) => {
        const d = (m as { data?: string }).data;
        if (d) { ch.bufferedAmount += atob(d).length; pieces++; maxSeen = Math.max(maxSeen, ch.bufferedAmount); }
      },
      // The network drains only while the uploader PACES (sleep(8)); the 256 KiB yield (sleep(0)) must not
      // drain, or the yield alone would bound the backlog and hide a missing pacing loop.
      sleep: async (ms) => { if (ms > 0) ch.bufferedAmount = 0; },
      newId: () => "p1",
    });
    const done = up.deliver({ to: { term: "pty:1" }, items: [file(2_000_000)] });
    await until(() => pieces === Math.ceil(2_000_000 / PASTE_CHUNK_BYTES));
    up.onReply({ t: "paste-done", id: "p1", how: "paste" });
    await done;
    expect(maxSeen).toBeGreaterThan(PACE_HIGH_BYTES);   // the guard: the run did reach the high-water mark
    expect(maxSeen).toBeLessThanOrEqual(PACE_HIGH_BYTES + PASTE_CHUNK_BYTES);
  });
  it("too large is refused before a byte is sent", async () => {
    const { sent, up } = rig();
    expect(await up.deliver({ to: { term: "pty:1" }, items: [{ kind: "text", text: "x".repeat(4_194_305) }] })).toEqual({ ok: false, reason: "too-large" });
    expect(sent).toEqual([]);
  });
  it("a host error mid-upload stops it; cancel sends paste-cancel; a closed channel fails at once", async () => {
    const { sent, up, ch } = rig();
    const a = up.deliver({ to: { term: "pty:1" }, items: [file(500_000)] });
    await until(() => sent.length > 2);
    up.onReply({ t: "paste-error", id: "p1", reason: "not-driver" });
    expect(await a).toEqual({ ok: false, reason: "not-driver" });
    const n = sent.length; await new Promise((r) => setTimeout(r, 5));
    expect(sent.length).toBe(n);
    const b = up.deliver({ to: { term: "pty:1" }, items: [file(500_000)] });
    await until(() => sent.some((m) => m.id === "p2"));
    up.cancel();
    expect(await b).toEqual({ ok: false, reason: "cancelled" });
    expect(sent.at(-1)).toEqual({ t: "paste-cancel", id: "p2" });
    const c = up.deliver({ to: { term: "pty:1" }, items: [file(500_000)] });
    await until(() => sent.some((m) => m.id === "p3"));
    ch.readyState = "closed";
    up.fail("closed", ch as never);
    expect(await c).toEqual({ ok: false, reason: "closed" });
  });
  // An OLD control channel's `close` is a task after its pc is torn down, and can land once the REBUILT
  // channel already carries the next delivery (rtc-connection.ts, `rebuildPc`) — maybe past its paste-end,
  // which the host will paste. Failing that one would say "the connection dropped" over a paste that happens.
  it("a channel's close fails only the delivery running on THAT channel", async () => {
    const old = { readyState: "closed" as RTCDataChannelState, bufferedAmount: 0 };
    const now = { readyState: "open" as RTCDataChannelState, bufferedAmount: 0 };
    const sent: Record<string, unknown>[] = [];
    let n = 0;
    const up = accepting({
      channel: () => now as never,
      send: (m) => { sent.push(m as Record<string, unknown>); },
      sleep: async () => {},
      newId: () => `p${++n}`,
    });
    const a = up.deliver({ to: { term: "pty:1" }, items: [file(1)] });
    await until(() => sent.some((m) => m.t === "paste-end" && m.id === "p1"));
    up.fail("closed", old as never);                 // the old channel's late close
    expect(up.busy).toBe(true);
    up.onReply({ t: "paste-done", id: "p1", how: "paste" });
    expect(await a).toEqual({ ok: true, how: "paste" });
    const b = up.deliver({ to: { term: "pty:1" }, items: [file(500_000)] });
    await until(() => sent.some((m) => m.id === "p2"));
    up.fail("closed", now as never);                 // ITS channel closing does fail it
    expect(await b).toEqual({ ok: false, reason: "closed" });
    // Losing control is not a channel's: it abandons whatever runs.
    const c = up.deliver({ to: { term: "pty:1" }, items: [file(500_000)] });
    await until(() => sent.some((m) => m.id === "p3"));
    up.fail("not-driver");
    expect(await c).toEqual({ ok: false, reason: "not-driver" });
  });
  it("a stale reply for an id already abandoned does not settle the current delivery", async () => {
    const { sent, up } = rig();
    const a = up.deliver({ to: { term: "pty:1" }, items: [file(500_000)] });
    await until(() => sent.length > 2);
    up.cancel();
    expect(await a).toEqual({ ok: false, reason: "cancelled" });
    const b = up.deliver({ to: { term: "pty:1" }, items: [file(1)] });
    await until(() => sent.some((m) => m.t === "paste-end" && m.id === "p2"));
    up.onReply({ t: "paste-error", id: "p1", reason: "failed" });   // the host's late word about the old one
    expect(up.busy).toBe(true);
    up.onReply({ t: "paste-done", id: "p2", how: "drop" });
    expect(await b).toEqual({ ok: true, how: "drop" });
  });
  it("a send that throws settles closed and nothing more is sent", async () => {
    const ch = { readyState: "open" as RTCDataChannelState, bufferedAmount: 0 };
    let calls = 0;
    const sent: unknown[] = [];
    const up = accepting({
      channel: () => ch as never,
      send: (m) => { if (++calls === 3) throw new DOMException("not open", "InvalidStateError"); sent.push(m); },
      sleep: async () => {},
      newId: () => "p1",
    });
    expect(await up.deliver({ to: { term: "pty:1" }, items: [file(100_000)] })).toEqual({ ok: false, reason: "closed" });
    expect(calls).toBe(3);
    expect(up.busy).toBe(false);
  });
  it("yields a macrotask every 256 KiB even when bufferedAmount stays 0", async () => {
    let sleeps = 0;
    const ch = { readyState: "open" as RTCDataChannelState, bufferedAmount: 0 };
    const sent: Record<string, unknown>[] = [];
    const up = accepting({
      channel: () => ch as never,
      send: (m) => { sent.push(m as Record<string, unknown>); },
      sleep: async (ms) => { if (ms === 0) sleeps++; },
      newId: () => "p1",
    });
    const done = up.deliver({ to: { term: "pty:1" }, items: [{ kind: "text", text: "x".repeat(1024 * 1024) }] });
    await until(() => sent.some((m) => m.t === "paste-end"));
    up.onReply({ t: "paste-done", id: "p1", how: "paste" });
    await done;
    expect(sleeps).toBe(4);   // 1 MiB / 256 KiB: one yield each time 256 KiB has been handed over, never per 16 KiB piece
  });
});

// THE MAC ACKNOWLEDGES A DELIVERY'S START (2026-10-02). An older Mac ignored `paste-*`: the whole upload went,
// the note froze at 94%, and only the 60 s reply timeout ended it. Now nothing is sent until `paste-accepted`.
describe("PasteUploader — paste-accepted before any piece", () => {
  afterEach(() => { vi.useRealTimers(); });
  const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };

  it("sends no piece until the Mac accepts, then the pieces flow", async () => {
    vi.useFakeTimers();
    const { sent, progress, up } = rig({ accept: false });
    const done = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await vi.advanceTimersByTimeAsync(ACCEPT_TIMEOUT_MS - 1);
    expect(sent.map((m) => m.t)).toEqual(["paste-begin"]);
    expect(up.busy).toBe(true);
    expect(progress).toEqual([0]);                      // "Sending … — 0%" is up while it waits
    up.onReply({ t: "paste-accepted", id: "p1" });
    vi.useRealTimers();
    await until(() => sent.some((m) => m.t === "paste-end"));
    expect(sent.map((m) => m.t)).toEqual(["paste-begin", "paste-data", "paste-data", "paste-data", "paste-end"]);
    up.onReply({ t: "paste-done", id: "p1", how: "paste" });
    expect(await done).toEqual({ ok: true, how: "paste" });
  });
  it("a paste-error before the acceptance settles that reason, and no piece is sent", async () => {
    const { sent, up } = rig({ accept: false });
    const done = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await until(() => sent.length === 1);
    up.onReply({ t: "paste-error", id: "p1", reason: "busy" });
    expect(await done).toEqual({ ok: false, reason: "busy" });
    await new Promise((r) => setTimeout(r, 5));
    expect(sent.map((m) => m.t)).toEqual(["paste-begin"]);
    expect(up.busy).toBe(false);
  });
  it("no answer within 5 s: unanswered, a paste-cancel sent, no piece — and the next delivery goes", async () => {
    vi.useFakeTimers();
    const { sent, up } = rig({ accept: false });
    let out: unknown = null;
    void up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] }).then((o) => { out = o; });
    await vi.advanceTimersByTimeAsync(ACCEPT_TIMEOUT_MS - 1);
    expect(out).toBeNull();
    await vi.advanceTimersByTimeAsync(1);
    expect(out).toEqual({ ok: false, reason: "unanswered" });
    expect(sent).toEqual([expect.objectContaining({ t: "paste-begin", id: "p1" }), { t: "paste-cancel", id: "p1" }]);
    expect(up.busy).toBe(false);
    // An acceptance that arrives after all is for a delivery that is gone: it lets nothing through.
    up.onReply({ t: "paste-accepted", id: "p1" });
    const next = up.deliver({ to: { term: "pty:1" }, items: [file(1)] });
    await flush();
    expect(sent.at(-1)).toMatchObject({ t: "paste-begin", id: "p2" });
    up.onReply({ t: "paste-accepted", id: "p2" });
    vi.useRealTimers();                                 // jsdom's Blob reads finish on its own clock
    await until(() => sent.some((m) => m.t === "paste-end"));
    expect(sent.slice(-2).map((m) => m.t)).toEqual(["paste-data", "paste-end"]);
    up.onReply({ t: "paste-done", id: "p2", how: "paste" });
    expect(await next).toEqual({ ok: true, how: "paste" });
  });
  it("a stale paste-accepted for another id is ignored", async () => {
    vi.useFakeTimers();
    const { sent, up } = rig({ accept: false });
    const a = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await flush();
    up.cancel();
    expect(await a).toEqual({ ok: false, reason: "cancelled" });
    const b = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await flush();
    up.onReply({ t: "paste-accepted", id: "p1" });          // the cancelled one's, late
    up.onReply({ t: "paste-accepted", id: "zz" });
    await vi.advanceTimersByTimeAsync(1000);
    expect(sent.filter((m) => m.t === "paste-data")).toEqual([]);
    up.onReply({ t: "paste-accepted", id: "p2" });
    vi.useRealTimers();
    await until(() => sent.some((m) => m.t === "paste-end"));
    expect(sent.filter((m) => m.t === "paste-data" && m.id === "p2")).toHaveLength(3);
    up.onReply({ t: "paste-done", id: "p2", how: "drop" });
    expect(await b).toEqual({ ok: true, how: "drop" });
  });
  it("Stop sending and losing control end the wait at once, with no piece", async () => {
    const { sent, up } = rig({ accept: false });
    const a = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await until(() => sent.length === 1);
    up.cancel();
    expect(await a).toEqual({ ok: false, reason: "cancelled" });
    const b = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await until(() => sent.some((m) => m.t === "paste-begin" && m.id === "p2"));
    up.fail("not-driver");
    expect(await b).toEqual({ ok: false, reason: "not-driver" });
    expect(sent.map((m) => m.t)).toEqual(["paste-begin", "paste-cancel", "paste-begin"]);
  });
  it("its channel closing during the wait settles closed at once — not 5 s later — with only the begin sent", async () => {
    vi.useFakeTimers();
    const { ch, sent, up } = rig({ accept: false });
    let out: unknown = null;
    void up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] }).then((o) => { out = o; });
    await flush();
    ch.readyState = "closed";
    up.fail("closed", ch as never);
    await flush();
    expect(out).toEqual({ ok: false, reason: "closed" });
    expect(sent.map((m) => m.t)).toEqual(["paste-begin"]);
    expect(vi.getTimerCount()).toBe(0);                 // the 5 s give-up went with it
  });
  // A rebuild can replace the channel with no `close` reaching the uploader: at 5 s that is the connection's
  // failure, not the Mac's — "may need updating" would send the person to update a Mac that is fine.
  it("a channel replaced or closed by the 5 s give-up settles closed, not unanswered", async () => {
    vi.useFakeTimers();
    const old = { readyState: "open" as RTCDataChannelState, bufferedAmount: 0 };
    let current = old;
    const up = new PasteUploader({ channel: () => current as never, send: () => {}, newId: () => "p1" });
    const a = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await flush();
    current = { readyState: "open", bufferedAmount: 0 };   // rebuilt; the old one's close never came
    await vi.advanceTimersByTimeAsync(ACCEPT_TIMEOUT_MS);
    expect(await a).toEqual({ ok: false, reason: "closed" });
    current = old;
    const b = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await flush();
    old.readyState = "closed";                          // closed, its close not delivered
    await vi.advanceTimersByTimeAsync(ACCEPT_TIMEOUT_MS);
    expect(await b).toEqual({ ok: false, reason: "closed" });
  });
  it("a paste-begin that throws settles closed — not busy, and no timer left", async () => {
    vi.useFakeTimers();
    const ch = { readyState: "open" as RTCDataChannelState, bufferedAmount: 0 };
    const up = new PasteUploader({
      channel: () => ch as never,
      send: () => { throw new DOMException("not open", "InvalidStateError"); },
      newId: () => "p1",
    });
    expect(await up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] })).toEqual({ ok: false, reason: "closed" });
    expect(up.busy).toBe(false);
    expect(vi.getTimerCount()).toBe(0);
  });
});

// THE PROGRESS NEVER FREEZES (2026-10-02): it was reported only as a piece was handed over, so after the LAST one
// the note stayed at whatever was still queued — 94% — until the answer. It now follows the queue as it drains.
describe("PasteUploader — progress after the last piece", () => {
  /// A channel whose queue holds the pieces handed over; `poll` is the uploader's drain wait.
  function draining(poll: (ch: { bufferedAmount: number }) => Promise<void>) {
    const ch = { readyState: "open" as RTCDataChannelState, bufferedAmount: 0 };
    const sent: Record<string, unknown>[] = [];
    const progress: number[] = [];
    const up = accepting({
      channel: () => ch as never,
      send: (m) => {
        sent.push(m as Record<string, unknown>);
        const d = (m as { data?: string }).data;
        if (d) ch.bufferedAmount += atob(d).length;
      },
      sleep: (ms) => (ms === DRAIN_POLL_MS ? poll(ch) : Promise.resolve()),
      onProgress: (s, t) => { expect(t).toBe(40_000); progress.push(s); },
      newId: () => "p1",
    });
    return { ch, sent, progress, up };
  }

  it("keeps reporting while the queue drains, to every byte, and stops polling once it is empty", async () => {
    const polls: number[] = [];
    const { sent, progress, up } = draining(async (ch) => { polls.push(ch.bufferedAmount); ch.bufferedAmount = Math.max(0, ch.bufferedAmount - 16_384); });
    const done = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await until(() => progress.includes(40_000));
    expect(sent.filter((m) => m.t === "paste-data")).toHaveLength(3);
    expect(sent.at(-1)).toEqual({ t: "paste-end", id: "p1" });
    // The wait for the acceptance, the three pieces' reports (all 40 000 bytes still queued), then one per poll
    // as the queue drains.
    expect(progress).toEqual([0, 0, 0, 0, 16_384, 32_768, 40_000]);
    expect(polls).toEqual([40_000, 23_616, 7_232]);
    await new Promise((r) => setTimeout(r, 5));
    expect(polls).toHaveLength(3);                      // drained: polling stopped
    expect(progress).toHaveLength(7);
    up.onReply({ t: "paste-done", id: "p1", how: "paste" });
    expect(await done).toEqual({ ok: true, how: "paste" });
  });
  it("the answer ends it at once — never held for the next poll — and no report follows", async () => {
    const { progress, up } = draining(() => new Promise<void>(() => {}));   // a poll that never comes back
    const done = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await until(() => progress.length === 4);
    up.onReply({ t: "paste-error", id: "p1", reason: "failed" });
    expect(await done).toEqual({ ok: false, reason: "failed" });
    expect(progress).toEqual([0, 0, 0, 0]);
  });
  it("its channel closing stops the reports; the close is what fails the delivery", async () => {
    const { ch, progress, up } = draining(() => new Promise<void>((r) => setTimeout(r, 1)));   // nothing drains
    const done = up.deliver({ to: { term: "pty:1" }, items: [file(40_000)] });
    await until(() => progress.length >= 6);
    ch.readyState = "closed";
    await new Promise((r) => setTimeout(r, 10));
    const n = progress.length;
    await new Promise((r) => setTimeout(r, 10));
    expect(progress.length).toBe(n);
    expect(up.busy).toBe(true);
    up.fail("closed", ch as never);
    expect(await done).toEqual({ ok: false, reason: "closed" });
  });
});
