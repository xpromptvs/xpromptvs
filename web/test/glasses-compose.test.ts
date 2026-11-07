import { describe, expect, it } from "vitest";
import { chipBytes, composeToKeys, CHIP_BYTES, CHIP_CSI } from "../src/client/glasses-compose";

describe("composeToKeys", () => {
  it("sends the committed text and NEVER a carriage return", () => {
    // Typing must not auto-submit. The wearer reviews what landed at the prompt and fires the ⏎ chip
    // deliberately; a composer that ran the command on commit gave no chance to correct a
    // mis-dictated word, and dictation mishears words.
    expect(composeToKeys("ls -la")).toBe("ls -la");
  });

  it("strips EVERY trailing newline — one would submit the command by itself", () => {
    // A \n reaching the PTY is Enter. If the on-glasses composer appends its own newline on commit,
    // failing to strip it auto-submits just as surely as appending \r did.
    expect(composeToKeys("ls\n")).toBe("ls");
    expect(composeToKeys("ls\r\n")).toBe("ls");
    expect(composeToKeys("ls\n\n")).toBe("ls");
    expect(composeToKeys("ls\r")).toBe("ls");
  });

  it("keeps interior newlines — those are the wearer's own text", () => {
    expect(composeToKeys("a\nb")).toBe("a\nb");
  });

  it("sends nothing for an empty commit", () => {
    expect(composeToKeys("")).toBe("");
    expect(composeToKeys("\n")).toBe("");
  });
});

describe("CHIP_BYTES", () => {
  it("carries the control bytes a handwriting/voice composer cannot express", () => {
    expect(CHIP_BYTES["chip:enter"]).toBe("\r");
    expect(CHIP_BYTES["chip:backspace"]).toBe("\x7f");
    expect(CHIP_BYTES["chip:tab"]).toBe("\t");
    expect(CHIP_BYTES["chip:ctrlc"]).toBe("\x03");
    expect(CHIP_BYTES["chip:esc"]).toBe("\x1b");
  });

  // BOTH ARMS OF THE CURSOR-KEY MODE. Asserting only the CSI form also passes for a resolver that
  // ignores the mode entirely, which is precisely the bug this replaced: the arrows were hardcoded
  // `\x1b[A` and were the WRONG sequence inside vi, less and most full-screen TUIs — the apps a
  // wearer needs arrows for in the first place.
  it("resolves the four cursor keys to CSI in normal mode", () => {
    expect(chipBytes("chip:up", false)).toBe("\x1b[A");
    expect(chipBytes("chip:down", false)).toBe("\x1b[B");
    expect(chipBytes("chip:right", false)).toBe("\x1b[C");
    expect(chipBytes("chip:left", false)).toBe("\x1b[D");
  });

  it("resolves them to SS3 in application cursor mode", () => {
    expect(chipBytes("chip:up", true)).toBe("\x1bOA");
    expect(chipBytes("chip:down", true)).toBe("\x1bOB");
    expect(chipBytes("chip:right", true)).toBe("\x1bOC");
    expect(chipBytes("chip:left", true)).toBe("\x1bOD");
  });

  it("leaves a non-cursor chip alone in both modes", () => {
    expect(chipBytes("chip:esc", false)).toBe("\x1b");
    expect(chipBytes("chip:esc", true)).toBe("\x1b");
  });

  it("resolves nothing for an id that is not a chip", () => {
    expect(chipBytes("chip:nope", false)).toBeUndefined();
  });

  it("has bytes for every chip the nav order exposes", async () => {
    // Guards the seam between the two: a chip in the order with no bytes is a control that focuses,
    // activates, and silently does nothing. Pinned through `chipBytes` rather than against
    // CHIP_BYTES directly, because the cursor keys now resolve through CHIP_CSI — the invariant is
    // "every chip resolves to bytes", which is what it always meant.
    const { navOrder } = await import("../src/client/spatial-nav");
    const chips = navOrder({
      screen: "terminal", sources: [], terminals: [], paletteOpen: false, settingsOpen: false, active: true,
      paletteEntries: [], termEmpty: [], dialog: null,
    }).filter((id) => id.startsWith("chip:"));
    expect(chips.length).toBeGreaterThan(0);
    for (const id of chips) expect(chipBytes(id, false), id).toBeTypeOf("string");
  });

  it("exposes no chip bytes the nav order cannot reach", async () => {
    // The other direction: bytes with no control are dead weight nobody can fire. BOTH tables.
    const { TERMINAL_CHIPS } = await import("../src/client/spatial-nav");
    for (const id of [...Object.keys(CHIP_BYTES), ...Object.keys(CHIP_CSI)]) {
      expect(TERMINAL_CHIPS, id).toContain(id);
    }
  });
});
