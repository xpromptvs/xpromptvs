import { describe, it, expect } from "vitest";
import { createReferenceReceipts } from "../src/client/av1-reference-receipts";
import type { ReferenceFrameNotice, ReferenceMessage } from "../src/shared/av1-reference-wire";
const track = () => ({ id: "same-id", readyState: "live" }) as MediaStreamTrack;
const notice = (rtpTimestamp = 7, frameId = "1", epoch = "e"): ReferenceFrameNotice => ({
  t: "av1-ref-frame", source: "win:1", epoch, frameId, slot: 6, slotGeneration: "1", rtpTimestamp, purpose: "candidate",
});
function setup() {
  let time = 0; const messages: ReferenceMessage[] = []; let send = (m: ReferenceMessage) => messages.push(m);
  const receipts = createReferenceReceipts({ now: () => time, send: m => send(m) });
  const t = track(); receipts.bind("win:1", "e", t, 1);
  return { receipts, t, messages, advance: (n: number) => { time += n; }, handoff: (f: typeof send) => { send = f; },
    acks: () => messages.filter(m => m.t === "av1-ref-ack") };
}
describe("presented reference receipts", () => {
  it.each([false, true])("matches either ordering once (frame first %s)", first => {
    const s = setup();
    if (first) s.receipts.presented("win:1", s.t, 1, 7);
    s.receipts.notice(notice());
    s.receipts.presented("win:1", s.t, 1, 7); s.receipts.notice(notice());
    expect(s.acks()).toEqual([{ ...notice(), t: "av1-ref-ack" }]);
  });
  it.each([0, 4294967295])("matches unsigned timestamp %s", timestamp => {
    const s = setup(); s.receipts.notice(notice(timestamp)); s.receipts.presented("win:1", s.t, 1, timestamp);
    expect(s.acks()).toHaveLength(1);
  });
  it("evicts entry 1 when entry 257 arrives", () => {
    const s = setup(); for (let i = 0; i < 257; i++) s.receipts.presented("win:1", s.t, 1, i);
    s.receipts.notice(notice(0)); s.receipts.notice(notice(256, "2"));
    expect(s.acks()).toEqual([{ ...notice(256, "2"), t: "av1-ref-ack" }]);
  });
  it.each([false, true])("expires both sides after five seconds (%s)", frameFirst => {
    const s = setup();
    if (frameFirst) s.receipts.presented("win:1", s.t, 1, 7); else s.receipts.notice(notice());
    s.advance(5000);
    if (frameFirst) s.receipts.notice(notice()); else s.receipts.presented("win:1", s.t, 1, 7);
    expect(s.acks()).toEqual([]);
  });
  it("checks actual track object and callback generation", () => {
    const s = setup(); s.receipts.notice(notice());
    s.receipts.presented("win:1", track(), 1, 7); s.receipts.presented("win:1", s.t, 2, 7);
    expect(s.acks()).toEqual([]);
    s.receipts.reset("win:1"); s.receipts.bind("win:1", "new", s.t, 2);
    s.receipts.notice(notice(7, "2", "new")); s.receipts.presented("win:1", s.t, 1, 7);
    expect(s.acks()).toEqual([]);
    s.receipts.presented("win:1", s.t, 2, 7); expect(s.acks()).toHaveLength(1);
  });
  it("does not reuse presentation from before binding or accept a retired binding", () => {
    const s = setup(); s.receipts.reset("win:1"); s.receipts.presented("win:1", s.t, 1, 7);
    expect(s.receipts.bind("win:1", "e", s.t, 1)).toBe(false);
    s.receipts.bind("win:1", "new", s.t, 2); s.receipts.notice(notice(7, "1", "new"));
    expect(s.acks()).toEqual([]);
    expect(s.receipts.bind("win:1", "e", s.t, 1)).toBe(false);
  });
  it("keeps identical source names isolated and survives a control transport handoff", () => {
    const a = setup(), b = setup(); a.receipts.notice(notice()); b.receipts.notice(notice());
    const next: ReferenceMessage[] = []; a.handoff(m => next.push(m));
    a.receipts.presented("win:1", a.t, 1, 7);
    expect(next.filter(m => m.t === "av1-ref-ack")).toHaveLength(1); expect(b.acks()).toEqual([]);
  });
  it("does not acknowledge hidden/non-presented frames or after disposal", () => {
    const s = setup(); s.receipts.notice(notice()); expect(s.acks()).toEqual([]);
    s.receipts.dispose(); s.receipts.presented("win:1", s.t, 1, 7); s.receipts.notice(notice());
    expect(s.receipts.bind("win:1", "new", s.t, 2)).toBe(false); expect(s.acks()).toEqual([]);
  });
  it("revokes a binding if runtime timestamps are absent", () => {
    const s = setup(); s.receipts.notice(notice()); s.receipts.presented("win:1", s.t, 1, undefined);
    expect(s.messages.filter(m => m.t === "av1-ref-reset")).toEqual([{ t: "av1-ref-reset", source: "win:1", epoch: "e", reason: "timestamps-unavailable" }]);
    expect(s.receipts.bind("win:1", "new", s.t, 1)).toBe(false);
    s.receipts.presented("win:1", s.t, 1, 7); expect(s.acks()).toEqual([]);
  });
});
it("requires a fresh epoch after a track or element rebind, even with identical track IDs", () => {
  for (const sameTrack of [false, true]) {
    const s = setup(); s.receipts.notice(notice());
    const next = sameTrack ? s.t : track();
    expect(s.receipts.bind("win:1", "e", next, 2)).toBe(false);
    s.receipts.presented("win:1", next, 2, 7); expect(s.acks()).toEqual([]);
    expect(s.receipts.bind("win:1", "fresh", next, 2)).toBe(true);
    s.receipts.notice(notice(7, "2", "fresh"));
    s.receipts.presented("win:1", s.t, 1, 7); expect(s.acks()).toEqual([]);
    s.receipts.presented("win:1", next, 2, 7); expect(s.acks()).toHaveLength(1);
  }
});
it("ignores notices from before binding and preserves cache on duplicate binding", () => {
  const s = setup(); s.receipts.reset("win:1"); s.receipts.notice(notice(8, "2", "fresh"));
  s.receipts.bind("win:1", "fresh", s.t, 2); s.receipts.presented("win:1", s.t, 2, 8);
  expect(s.acks()).toEqual([]);
  s.receipts.bind("win:1", "fresh", s.t, 2); s.receipts.notice(notice(8, "2", "fresh"));
  expect(s.acks()).toHaveLength(1);
});
