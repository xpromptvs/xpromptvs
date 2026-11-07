import { describe, expect, it } from "vitest";
import { LateHistoryLog, SWAP_PATIENCE_MS, SWAP_QUIET_MS, swapWouldDisturb, type SwapMoment } from "../src/client/late-history";

// THE LATE HISTORY's live text (docs/terminal.md, "Scrollback comes after the screen"): what a rebuild replays after the
// full snapshot — exactly the text applied beyond the generation's own snapshot, however the writer cut it.
describe("LateHistoryLog", () => {
  const log = (cap = 1 << 20) => {
    const abandoned: [string, number][] = [];
    return { l: new LateHistoryLog(cap, (tab, gen) => abandoned.push([tab, gen])), abandoned };
  };

  it("keeps only what was applied beyond the snapshot", () => {
    const { l } = log();
    l.begin("pty:1", 1);
    l.snapshot("pty:1", 1, 10);
    l.applied("pty:1", 1, "0123456789");
    expect(l.take("pty:1", 1)).toBe("");
    l.applied("pty:1", 1, "live");
    expect(l.take("pty:1", 1)).toBe("live");
  });

  it("splits ONE write that carries the snapshot's tail and live text (a coalesced or ?2026-held write)", () => {
    const { l } = log();
    l.begin("pty:1", 1);
    l.snapshot("pty:1", 1, 6);
    l.snapshot("pty:1", 1, 4);                               // the router decodes the snapshot in pieces
    l.applied("pty:1", 1, "0123456");
    l.applied("pty:1", 1, "789-and-live");
    expect(l.take("pty:1", 1)).toBe("-and-live");
  });

  it("reproduces the live text exactly however the writes cut it", () => {
    const snapshot = "S".repeat(37), live = "the typed line\r\n$ ";
    for (const cut of [1, 3, 7, 50]) {
      const { l } = log();
      l.begin("pty:1", 1);
      l.snapshot("pty:1", 1, snapshot.length);
      const all = snapshot + live;
      for (let i = 0; i < all.length; i += cut) l.applied("pty:1", 1, all.slice(i, i + cut));
      expect(l.take("pty:1", 1), `cut ${cut}`).toBe(live);
    }
  });

  it("`take` hands over what is kept and keeps counting: the rebuild catches up in steps", () => {
    const { l } = log();
    l.begin("pty:1", 1);
    l.applied("pty:1", 1, "a");
    expect(l.take("pty:1", 1)).toBe("a");
    l.applied("pty:1", 1, "b");
    expect(l.take("pty:1", 1)).toBe("b");
    l.end("pty:1", 1);
    l.applied("pty:1", 1, "c");
    expect(l.take("pty:1", 1)).toBeNull();
    expect(l.wants("pty:1", 1)).toBe(false);
  });

  it("past the cap of kept text the rebuild is abandoned, once", () => {
    const { l, abandoned } = log(8);
    l.begin("pty:1", 3);
    l.applied("pty:1", 3, "12345");
    expect(l.take("pty:1", 3)).toBe("12345");               // handed over: no longer counts against the cap
    l.applied("pty:1", 3, "12345678");
    expect(abandoned).toEqual([]);
    l.applied("pty:1", 3, "9");
    l.applied("pty:1", 3, "more");
    expect(abandoned).toEqual([["pty:1", 3]]);
    expect(l.wants("pty:1", 3)).toBe(false);
    expect(l.take("pty:1", 3)).toBeNull();
  });

  it("a newer generation, a drop or a clear ends what was kept — and only that tab's", () => {
    const { l } = log();
    l.begin("pty:1", 1);
    l.begin("pty:10", 2);
    l.begin("pty:1", 3);                                     // a newer generation of pty:1
    expect(l.wants("pty:1", 1)).toBe(false);
    expect(l.wants("pty:1", 3)).toBe(true);
    l.drop("pty:1");
    expect(l.wants("pty:1", 3)).toBe(false);
    expect(l.wants("pty:10", 2), "pty:10 is not pty:1").toBe(true);
    l.clear();
    expect(l.wants("pty:10", 2)).toBe(false);
  });

  it("a generation no screen snapshot began keeps nothing", () => {
    const { l } = log();
    l.snapshot("pty:1", 1, 5);
    l.applied("pty:1", 1, "text");
    expect(l.wants("pty:1", 1)).toBe(false);
    expect(l.take("pty:1", 1)).toBeNull();
  });
});

// The swap waits while it would disturb the person at the shown tab — and never longer than its patience.
describe("swapWouldDisturb", () => {
  const calm: SwapMoment = {
    tab: "pty:1", visible: "pty:1", holding: false, predicting: false, selecting: false, lastKey: null, now: 100_000, waitedMs: 0,
  };
  const at = (o: Partial<SwapMoment>) => swapWouldDisturb({ ...calm, ...o });

  it("nothing going on: it swaps", () => { expect(at({})).toBe(false); });

  it("each disturbance alone holds it back", () => {
    expect(at({ holding: true }), "a held resize").toBe(true);
    expect(at({ predicting: true }), "predictions drawn").toBe(true);
    expect(at({ selecting: true }), "a selection").toBe(true);
    expect(at({ lastKey: { term: "pty:1", at: calm.now - 10 } }), "a key just typed into it").toBe(true);
  });

  it("a key is quiet after SWAP_QUIET_MS, and a key into ANOTHER tab never counts", () => {
    expect(at({ lastKey: { term: "pty:1", at: calm.now - SWAP_QUIET_MS + 1 } })).toBe(true);
    expect(at({ lastKey: { term: "pty:1", at: calm.now - SWAP_QUIET_MS } })).toBe(false);
    expect(at({ lastKey: { term: "pty:2", at: calm.now - 10 } })).toBe(false);
  });

  it("a hidden tab never waits, whatever the shown one is doing", () => {
    expect(at({ visible: "pty:2", holding: true, predicting: true, selecting: true, lastKey: { term: "pty:1", at: calm.now } })).toBe(false);
    expect(at({ visible: null, selecting: true })).toBe(false);
  });

  it("past its patience it swaps anyway: a selection left up must not keep the scrollback away", () => {
    expect(at({ selecting: true, waitedMs: SWAP_PATIENCE_MS - 1 })).toBe(true);
    expect(at({ selecting: true, waitedMs: SWAP_PATIENCE_MS })).toBe(false);
  });
});
