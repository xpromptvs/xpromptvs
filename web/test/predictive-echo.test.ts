import { describe, expect, it } from "vitest";
import { PredictionController, OverlayModel, validatePredictions, isGhostStale, type ControllerConfig } from "../src/client/predictive-echo";

// Fake terminal buffer: `rows` are row strings; cellAt returns the rune (or " " for blanks/beyond).
const grid = (rows: string[]) => (r: number, c: number) => rows[r]?.[c] ?? " ";

describe("validatePredictions — reconcile against the real buffer", () => {
  const cols = 80;
  it("exact echo confirms all", () => {
    // predicted "a" at col 5; server echoed "a" there, cursor advanced 5→6.
    const r = validatePredictions({ row: 0, col: 5 }, { row: 0, col: 6 }, "a", cols, grid(["     a"]));
    expect(r).toEqual({ survivors: "", matched: true });
  });
  it("partial echo confirms the prefix, ghosts past the cursor survive", () => {
    const r = validatePredictions({ row: 0, col: 5 }, { row: 0, col: 6 }, "abc", cols, grid(["     a"]));
    expect(r).toEqual({ survivors: "bc", matched: true });
  });
  it("REDRAW (\\bab): re-emitted confirmed char is ignored; only cells past the anchor validate", () => {
    // The shell redrew with a backspace then "ab". xterm's buffer ends with a@5, b@6, cursor 6→7.
    // anchor is at col 6 (after the earlier 'a' confirm); predicted was "bcde".
    const r = validatePredictions({ row: 0, col: 6 }, { row: 0, col: 7 }, "bcde", cols, grid(["     ab"]));
    expect(r).toEqual({ survivors: "cde", matched: true });   // the fix: no false divergence, no cascade
  });
  it("mismatch withdraws (buffer disagrees with the guess)", () => {
    const r = validatePredictions({ row: 0, col: 5 }, { row: 0, col: 6 }, "ab", cols, grid(["     x"]));
    expect(r).toEqual({ survivors: "", matched: false });
  });
  it("cursor advanced past all predictions → all confirmed", () => {
    const r = validatePredictions({ row: 0, col: 5 }, { row: 0, col: 9 }, "ab", cols, grid(["     abcd"]));
    expect(r).toEqual({ survivors: "", matched: true });
  });
  it("no forward progress (backspace / ambiguous) → resync, no match", () => {
    const r = validatePredictions({ row: 0, col: 5 }, { row: 0, col: 4 }, "ab", cols, grid(["     "]));
    expect(r).toEqual({ survivors: "", matched: false });
  });
  it("handles wrap across rows via linear positions", () => {
    // cols=10; anchor at (0,9), server echoed "ab" wrapping to (1,1): a@(0,9), b@(1,0).
    const r = validatePredictions({ row: 0, col: 9 }, { row: 1, col: 1 }, "ab", 10, grid(["         a", "b"]));
    expect(r).toEqual({ survivors: "", matched: true });
  });
});

/// A controller on a link whose network round trip is `net` (ms; null — no network, a socket transport).
const ctl = (net: number | null, over: Partial<ControllerConfig> = {}) =>
  new PredictionController({ thresholdMs: 30, force: null, networkRttMs: () => net, ...over });

/// One keystroke whose server bytes arrive `ms` later, at time `t`. Returns the next free time.
const echoAfter = (c: PredictionController, t: number, ms: number): number => {
  c.onKeystroke(t); c.onBytes(t + ms); c.onReconcile(true);
  return t + ms + 100;
};
/// `n` keystrokes, each echoed `ms` later.
const echoes = (c: PredictionController, n: number, ms: number, t = 0): number => {
  for (let i = 0; i < n; i++) t = echoAfter(c, t, ms);
  return t;
};

describe("PredictionController — the gate reads the NETWORK", () => {
  it("inactive client never predicts", () => {
    const c = ctl(120); c.setActive(false);
    expect(c.active()).toBe(false);
  });
  it("alt screen disables prediction", () => {
    const c = ctl(120); c.setActive(true);
    c.setAltScreen(true);
    expect(c.active()).toBe(false);
  });
  it("a network round trip at or under the threshold predicts nothing; over it predicts", () => {
    for (const [net, on] of [[1, false], [30, false], [31, true], [120, true]] as const) {
      const c = ctl(net); c.setActive(true);
      expect(c.active(), `${net} ms`).toBe(on);
    }
  });
  it("NO NETWORK (a socket transport, or no measurement yet) never predicts", () => {
    const c = ctl(null); c.setActive(true);
    echoes(c, 6, 500);                          // however slow the echo
    expect(c.active()).toBe(false);
    expect(c.linkMs()).toBe(null);
  });
  it("the gate follows the network as it changes", () => {
    let net: number | null = 120;
    const c = new PredictionController({ thresholdMs: 30, force: null, networkRttMs: () => net });
    c.setActive(true);
    expect(c.active()).toBe(true);
    net = 2;
    expect(c.active()).toBe(false);
  });
  it("`?predictlag` adds to the link — with no network as well", () => {
    expect(ctl(null, { addedLagMs: 200 }).linkMs()).toBe(200);
    expect(ctl(10, { addedLagMs: 200 }).linkMs()).toBe(210);
    const c = ctl(null, { addedLagMs: 200 }); c.setActive(true);
    expect(c.active()).toBe(true);
  });
  it("repeated mismatches drop out; a match restores health", () => {
    const c = ctl(120); c.setActive(true);
    c.onReconcile(false); c.onReconcile(false);
    expect(c.active()).toBe(false);
    c.onReconcile(true);
    expect(c.active()).toBe(true);
  });
  it("?predict=off forces off, ?predict=on forces on", () => {
    const off = ctl(120, { force: "off" }); off.setActive(true);
    expect(off.active()).toBe(false);
    const on = ctl(null, { force: "on" }); on.setActive(false); on.setAltScreen(true);
    expect(on.active()).toBe(true);
  });

  // THE LOOPBACK LATCH (measured 2026-10-01 in the app's own window, echo ~1 ms): the gate read an EWMA
  // of echo samples taken at the reconcile SETTLE, 40 ms after the echo, so once predicting it could not
  // fall back under 30 ms — and ONE keystroke a shell never echoed (a password prompt) made a 1 s sample
  // that opened it: every character typed afterwards was predicted, on loopback.
  it("THE LATCH: a silent keystroke on a fast network never turns prediction on", () => {
    const c = ctl(1); c.setActive(true);
    let t = echoes(c, 6, 1);
    t = echoAfter(c, t, 1000);                  // `read -s`: no echo until Enter, a second later
    expect(c.active()).toBe(false);
    echoes(c, 40, 1, t);
    expect(c.active()).toBe(false);
  });
  it("a SLOW APPLICATION on a fast network predicts nothing — there is no link latency to hide", () => {
    const c = ctl(1); c.setActive(true);
    echoes(c, 20, 80);                          // a heavy TUI redrawing on every key
    expect(c.active()).toBe(false);
  });
  it("PIPELINED typing on a slow network keeps predicting — echoes closing each other's samples change nothing", () => {
    const c = ctl(250); c.setActive(true);
    for (let k = 0; k < 40; k++) {              // a key every 120 ms against a 250 ms round trip
      c.onKeystroke(k * 120);
      c.onBytes(k * 120 + 250 - 120);           // an EARLIER key's echo lands 130 ms after this one
      expect(c.active(), `key ${k}`).toBe(true);
    }
  });
});

describe("PredictionController — the echo's own latency (the stale-ghost clock)", () => {
  it("is the oldest unacked keystroke to the first bytes (pipelined typing), not the latest", () => {
    const c = ctl(120);
    c.onKeystroke(0); c.onKeystroke(50); c.onKeystroke(90);
    c.onBytes(200);
    expect(c.rttMs()).toBe(200);
  });
  it("is taken at the echo's ARRIVAL, never at the reconcile that follows it", () => {
    const c = ctl(120);
    c.onKeystroke(0); c.onBytes(1);
    c.onReconcile(true);                        // a settle 40 ms later must not lengthen the sample
    expect(c.rttMs()).toBe(1);
  });
  it("output with no keystroke pending is no sample", () => {
    const c = ctl(120);
    echoes(c, 6, 120);
    c.onBytes(5_000); c.onBytes(9_000);         // a program printing on its own
    expect(c.rttMs()).toBe(120);
  });
});

describe("isGhostStale", () => {
  it("false when nothing is pending", () => { expect(isGhostStale(null, 10_000, 200)).toBe(false); });
  it("false before the floor elapses", () => { expect(isGhostStale(0, 2000, 0)).toBe(false); });
  it("true after the floor on a fast link", () => { expect(isGhostStale(0, 3000, 0)).toBe(true); });
  it("does NOT clear a ghost whose high-lag echo is still in flight (the overlay-reveal bug)", () => {
    // 1000ms lag, RTT under-read as 300: at 1000ms the echo has just arrived to confirm — the floor
    // (2500ms) must NOT have wiped the ghost first, which would expose the authoritative replay.
    expect(isGhostStale(0, 1000, 300)).toBe(false);
  });
  it("scales with RTT above the floor", () => {
    expect(isGhostStale(0, 3000, 900)).toBe(false);   // threshold = max(2500, 3600) = 3600
    expect(isGhostStale(0, 4000, 900)).toBe(true);
  });
});

describe("OverlayModel — overlay display prediction model", () => {
  const cols = 80;
  it("predictChar anchors a fresh run and appends (cursor ignored mid-run)", () => {
    const m = new OverlayModel();
    m.predictChar("a", { row: 0, col: 5 });
    m.predictChar("b", { row: 0, col: 99 });
    expect(m.text()).toBe("ab");
    expect(m.anchorAt()).toEqual({ row: 0, col: 5 });
    expect(m.active()).toBe(true);
  });
  it("backspace retains its erase until the host echoes it", () => {
    const m = new OverlayModel();
    m.predictChar("a", { row: 0, col: 5 });
    expect(m.backspace()).toBe(true);
    expect(m.active()).toBe(true);
    expect(m.anchorAt()).toEqual({ row: 0, col: 5 });
    expect(m.backspace()).toBe(false);
  });
  it("reconcile confirms forward typing fully (settled)", () => {
    const m = new OverlayModel();
    "abc".split("").forEach((ch, i) => m.predictChar(ch, { row: 0, col: 5 + i }));
    const r = m.reconcile({ row: 0, col: 8 }, cols, grid(["     abc"]));
    expect(r).toEqual({ matched: true, cleared: true, definitive: false });
    expect(m.active()).toBe(false);
  });
  it("reconcile confirms a prefix and re-anchors the survivors", () => {
    const m = new OverlayModel();
    "abc".split("").forEach((ch, i) => m.predictChar(ch, { row: 0, col: 5 + i }));
    const r = m.reconcile({ row: 0, col: 6 }, cols, grid(["     a"]));
    expect(r).toEqual({ matched: true, cleared: false, definitive: false });
    expect(m.text()).toBe("bc");
    expect(m.anchorAt()).toEqual({ row: 0, col: 6 });
  });
  it("EDIT-REPLAY: reconcile on the SETTLED buffer confirms cleanly (no rewind)", () => {
    // Typed abcde, backspaced e, typed x → predicted "abcdx". The echo stream replays abcde→abcd→abcdx,
    // but reconcile runs only after it SETTLES, so it sees the final buffer "abcdx" and confirms it whole.
    const m = new OverlayModel();
    "abcde".split("").forEach((ch, i) => m.predictChar(ch, { row: 0, col: 5 + i }));
    m.backspace();
    m.predictChar("x", { row: 0, col: 0 });
    expect(m.text()).toBe("abcdx");
    expect(m.anchorAt()).toEqual({ row: 0, col: 5 });
    const r = m.reconcile({ row: 0, col: 10 }, cols, grid(["     abcdx"]));
    expect(r).toEqual({ matched: true, cleared: true, definitive: false });
    expect(m.active()).toBe(false);
  });
  it("EDIT-REPLAY: echo of the about-to-be-deleted char (cursor AT prediction end) is NOT definitive", () => {
    // Predicted "x" at col 5 (after "hell"); the shell echoes the "o" you're about to backspace at col 5,
    // cursor 6. delta(1) == predicted.length(1), so the cursor is NOT past the end → keep covering, wait.
    const m = new OverlayModel();
    m.predictChar("x", { row: 0, col: 5 });
    const r = m.reconcile({ row: 0, col: 6 }, cols, grid(["     o"]));
    expect(r).toEqual({ matched: false, cleared: false, definitive: false });
    expect(m.active()).toBe(true);   // overlay stays covering; the backspace + "x" echoes are still coming
  });
  it("transient mismatch with the cursor WITHIN the prediction range is not definitive", () => {
    const m = new OverlayModel();
    "abc".split("").forEach((ch, i) => m.predictChar(ch, { row: 0, col: 5 + i }));
    const r = m.reconcile({ row: 0, col: 6 }, cols, grid(["     x"]));   // "x" at col5, cursor 6, len 3
    expect(r).toEqual({ matched: false, cleared: false, definitive: false });
    expect(m.active()).toBe(true);
  });
  it("DEFINITIVE divergence: cursor settled PAST the prediction end with wrong content → withdraw", () => {
    const m = new OverlayModel();
    "ab".split("").forEach((ch, i) => m.predictChar(ch, { row: 0, col: 5 + i }));
    const r = m.reconcile({ row: 0, col: 8 }, cols, grid(["     xyz"]));   // cursor 8 > end 7, cells disagree
    expect(r).toEqual({ matched: false, cleared: false, definitive: true });
    m.reset();
    expect(m.active()).toBe(false);
  });
});

describe("pending edit history", () => {
  it("tracks an empty deletion echo even after replacement text is typed", () => {
    const m = new OverlayModel();
    m.beginField({ row: 0, col: 2 }, "a", 1, 40);
    expect(m.hasPendingEmpty()).toBe(false);
    m.backspace();
    m.predictChar("b", { row: 0, col: 3 });
    expect(m.hasPendingEmpty()).toBe(true);
    m.reconcile({ row: 0, col: 2 }, 80, grid(["  "]));
    expect(m.hasPendingEmpty()).toBe(false);
    expect(m.text()).toBe("b");
  });
  it("only marks cells changed from the confirmed composer as speculative", () => {
    const m = new OverlayModel();
    m.beginField({ row: 0, col: 2 }, "hello", 5, 40);
    m.predictChar("x", { row: 0, col: 7 });
    m.predictChar("y", { row: 0, col: 7 });
    expect(m.pendingCells()).toEqual([false, false, false, false, false, true, true]);
    m.reconcile({ row: 0, col: 8 }, 80, grid(["  hellox"]));
    expect(m.pendingCells()).toEqual([false, false, false, false, false, false, true]);
    m.backspace(); m.backspace();
    expect(m.pendingCells()).toEqual([false, false, false, false, false, true, false]);
  });
  it("does not confirm a deletion from the older printable echo", () => {
    const m = new OverlayModel();
    for (const c of "abc") m.predictChar(c, { row: 0, col: 0 });
    m.backspace();
    m.reconcile({ row: 0, col: 3 }, 80, grid(["abc"]));
    expect(m.active()).toBe(true);
    m.predictChar("d", { row: 0, col: 3 });
    expect(m.text()).toBe("abd");
    expect(m.anchorAt()).toEqual({ row: 0, col: 0 });
    m.reconcile({ row: 0, col: 2 }, 80, grid(["ab"]));
    expect(m.text()).toBe("abd");
    expect(m.reconcile({ row: 0, col: 3 }, 80, grid(["abd"])).cleared).toBe(true);
  });
  it("keeps an erase pending when the last ghost was deleted", () => {
    const m = new OverlayModel();
    m.predictChar("a", { row: 0, col: 0 }); m.backspace();
    expect(m.active()).toBe(true);
    m.reconcile({ row: 0, col: 1 }, 80, grid(["a"]));
    expect(m.active()).toBe(true);
    expect(m.reconcile({ row: 0, col: 0 }, 80, grid([""])).cleared).toBe(true);
  });
  it("edits confirmed composer text, preserving the suffix and cursor", () => {
    const m = new OverlayModel();
    m.beginField({ row: 2, col: 2 }, "abcd", 2, 20);
    m.backspace();
    expect(m.text()).toBe("acd");
    expect(m.cursorOffset()).toBe(1);
    expect(m.paintText()).toBe("acd ");
    m.predictChar("x", { row: 2, col: 4 });
    expect(m.text()).toBe("axcd");
    expect(m.reconcile({ row: 2, col: 4 }, 80, grid(["", "", "  axcd"])).cleared).toBe(true);
  });
  it("refuses a predicted edit that would wrap the recognized field", () => {
    const m = new OverlayModel(); m.beginField({ row: 0, col: 2 }, "abcd", 4, 4);
    expect(m.predictChar("x", { row: 0, col: 6 })).toBe(false);
    expect(m.active()).toBe(false);
  });
});


it("covers an entire placeholder until the typed character echoes", () => {
  const m = new OverlayModel();
  m.beginField({ row: 0, col: 2 }, "", 0, 40, 22);
  m.predictChar("a", { row: 0, col: 2 });
  expect(m.paintText()).toBe("a" + " ".repeat(21));
  expect(m.cursorOffset()).toBe(1);
});
