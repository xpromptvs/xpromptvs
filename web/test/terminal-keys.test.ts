import { describe, expect, it } from "vitest";
import {
  applyHeldMods, csiBytes, ctrlByte, termBytes,
  TERMINAL_KEYS, TERMINAL_KEYS_MORE,
} from "../src/client/terminal-keys";

const byId = (id: string) => {
  const d = [...TERMINAL_KEYS, ...TERMINAL_KEYS_MORE].find((k) => k.id === id);
  if (!d || d.kind !== "key") throw new Error(`no key ${id}`);
  return d;
};

describe("ctrlByte", () => {
  it("maps letters to 0x01..0x1a, case-insensitively", () => {
    expect(ctrlByte("a")).toBe("\x01");
    expect(ctrlByte("c")).toBe("\x03");
    expect(ctrlByte("C")).toBe("\x03");
    expect(ctrlByte("z")).toBe("\x1a");
  });
  it("maps the punctuation control codes", () => {
    expect(ctrlByte("@")).toBe("\x00");
    expect(ctrlByte(" ")).toBe("\x00");
    expect(ctrlByte("[")).toBe("\x1b");
    expect(ctrlByte("\\")).toBe("\x1c");
    expect(ctrlByte("]")).toBe("\x1d");
    expect(ctrlByte("^")).toBe("\x1e");
    expect(ctrlByte("_")).toBe("\x1f");
    expect(ctrlByte("?")).toBe("\x7f");
  });
  it("returns null for a character with no control code rather than guessing", () => {
    expect(ctrlByte("5")).toBeNull();
    expect(ctrlByte("é")).toBeNull();
  });
});

describe("csiBytes — cursor-key mode", () => {
  // BOTH ARMS. The normal-mode assertion alone passes for a function that ignores appCursor
  // entirely, which is exactly the bug the glasses CHIP_BYTES table has today.
  it("uses CSI in normal mode", () => {
    expect(csiBytes("A", false)).toBe("\x1b[A");
    expect(csiBytes("D", false)).toBe("\x1b[D");
  });
  it("uses SS3 in application cursor mode", () => {
    expect(csiBytes("A", true)).toBe("\x1bOA");
    expect(csiBytes("D", true)).toBe("\x1bOD");
  });
});

describe("termBytes", () => {
  it("returns the literal bytes for a fixed key", () => {
    expect(termBytes(byId("esc"), false)).toBe("\x1b");
    expect(termBytes(byId("tab"), false)).toBe("\t");
    expect(termBytes(byId("ctrl-c"), false)).toBe("\x03");
  });
  it("routes arrows through cursor-key mode", () => {
    expect(termBytes(byId("up"), false)).toBe("\x1b[A");
    expect(termBytes(byId("up"), true)).toBe("\x1bOA");
  });
  it("routes Home/End through cursor-key mode too", () => {
    expect(termBytes(byId("home"), false)).toBe("\x1b[H");
    expect(termBytes(byId("home"), true)).toBe("\x1bOH");
  });
  it("PgUp/PgDn are CSI ~ sequences and are NOT cursor-key-mode dependent", () => {
    expect(termBytes(byId("pgup"), false)).toBe("\x1b[5~");
    expect(termBytes(byId("pgup"), true)).toBe("\x1b[5~");
  });
  it("F1-F4 are SS3 and F5+ are CSI ~, with the historical gaps", () => {
    expect(termBytes(byId("f1"), false)).toBe("\x1bOP");
    expect(termBytes(byId("f5"), false)).toBe("\x1b[15~");
    expect(termBytes(byId("f11"), false)).toBe("\x1b[23~");
    expect(termBytes(byId("f12"), false)).toBe("\x1b[24~");
  });
});

describe("applyHeldMods", () => {
  it("passes data through untouched with no modifiers", () => {
    expect(applyHeldMods("a", 0)).toBe("a");
  });
  it("ctrl (2) turns a typed letter into its control byte", () => {
    expect(applyHeldMods("c", 2)).toBe("\x03");
  });
  it("alt (4) prefixes ESC", () => {
    expect(applyHeldMods("b", 4)).toBe("\x1bb");
  });
  it("ctrl+alt is ESC then the control byte", () => {
    expect(applyHeldMods("c", 6)).toBe("\x1b\x03");
  });
  it("passes a character with no control code through UNCHANGED rather than guessing", () => {
    expect(applyHeldMods("5", 2)).toBe("5");
  });
  it("ignores meta — ⌘ means nothing to a PTY", () => {
    expect(applyHeldMods("a", 8)).toBe("a");
  });
  // The soft keyboard sends no Shift of its own: a strip ⇧ held while typing makes the letter a capital.
  it("shift makes a typed letter a capital, and leaves a capital, a digit or a symbol as it is", () => {
    expect(applyHeldMods("a", 1)).toBe("A");
    expect(applyHeldMods("A", 1)).toBe("A");
    expect(applyHeldMods("5", 1)).toBe("5");
    expect(applyHeldMods("ß", 1)).toBe("ß");                  // "SS" is two characters: not a keystroke
  });
  // ⇧ + the soft keyboard's Return: ESC CR, what Claude Code's /terminal-setup binds Shift+Enter to (a
  // NEW LINE). xterm.js itself sends a plain CR for Shift+Enter — which SUBMITS the prompt.
  it("shift + Return is ESC CR (a new line in Claude Code), not a plain CR", () => {
    expect(applyHeldMods("\r", 1)).toBe("\x1b\r");
    expect(applyHeldMods("\r", 1 | 4)).toBe("\x1b\r");
  });
  // BOTH MODIFIERS. The ctrl arm alone does not exercise the length guard at all — `ctrlByte`
  // rejects a multi-char string on its own, so deleting the guard still passes. Only the ALT arm
  // catches it: without the guard a pasted "hello" goes out as ESC-hello.
  it("leaves a multi-character chunk alone under ctrl: a paste is not a keystroke", () => {
    expect(applyHeldMods("hello", 2)).toBe("hello");
  });
  it("leaves a multi-character chunk alone under alt — the arm that guards the paste", () => {
    expect(applyHeldMods("hello", 4)).toBe("hello");
  });
  it("leaves an escape sequence xterm produced itself alone", () => {
    expect(applyHeldMods("\x1b[A", 4)).toBe("\x1b[A");
  });
});

describe("the tables", () => {
  it("row 1 carries exactly the keys a shell cannot do without", () => {
    expect(TERMINAL_KEYS.map((k) => k.id))
      .toEqual(["esc", "tab", "ctrl", "alt", "shift", "left", "down", "up", "right"]);
  });
  // ⇧ IS here: the soft keyboard sends no Shift, and Shift+Tab, Shift+arrows and Shift+Return are
  // real chords (Shift+Tab cycles Claude Code's modes). ⌘ still means nothing to a PTY.
  it("has ⇧ but no ⌘", () => {
    const mods = [...TERMINAL_KEYS, ...TERMINAL_KEYS_MORE]
      .filter((k) => k.kind === "mod").map((k) => k.id);
    expect(mods).toEqual(["ctrl", "alt", "shift"]);
  });
  it("every non-modifier entry produces bytes — a dead key is worse than no key", () => {
    for (const d of [...TERMINAL_KEYS, ...TERMINAL_KEYS_MORE]) {
      if (d.kind !== "key") continue;
      expect(termBytes(d, false), `${d.id} produced nothing`).not.toBe("");
    }
  });
  it("every entry has a unique id — a duplicate silently shadows in byId lookups", () => {
    const ids = [...TERMINAL_KEYS, ...TERMINAL_KEYS_MORE].map((k) => k.id);
    expect(new Set(ids).size).toBe(ids.length);
  });
});
