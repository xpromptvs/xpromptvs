// THE CLIENT'S GLYPH WIDTHS (docs/terminal.md, "Glyph widths"). A restored screen places every cell at
// the column the HOST's emulator put it — SwiftTerm for a `pty:` tab, tmux for a `tmux:` tab — and the
// client's xterm.js must count the same columns, or every cell after a disagreeing glyph lands in the
// wrong place (and the cursor with it). `loadRdevUnicode` is what every product instance runs; these
// are the widths it must give, measured 2026-09-27 against SwiftTerm (as patched) and tmux 3.7c.
import { beforeAll, describe, expect, it, vi } from "vitest";
import type { Terminal as XTerm } from "@xterm/xterm";
import widths from "../../protocol/fixtures/term-widths.json";
import { loadRdevUnicode, rdevUnicodeProvider, RDEV_UNICODE_VERSION } from "../src/client/term-unicode";

let Terminal: typeof XTerm;
beforeAll(async () => {
  HTMLCanvasElement.prototype.getContext = (() => null) as typeof HTMLCanvasElement.prototype.getContext;
  ({ Terminal } = await import("@xterm/xterm"));
});

type Setup = "rdev" | "graphemes-only" | "none";
const write = (t: XTerm, s: string) => new Promise<void>((r) => t.write(s, r));

/// Columns `s` takes after an "a" (which keeps a leading joiner off column 0), by where an "X" lands.
async function columns(s: string, setup: Setup = "rdev"): Promise<number> {
  const t = new Terminal({ cols: 40, rows: 3, allowProposedApi: true });
  if (setup === "rdev") loadRdevUnicode(t);
  if (setup === "graphemes-only") {
    const { UnicodeGraphemesAddon } = await import("@xterm/addon-unicode-graphemes");
    t.loadAddon(new UnicodeGraphemesAddon());
  }
  await write(t, "a" + s + "X");
  const line = t.buffer.active.getLine(0)!;
  let x = -1;
  for (let i = 0; i < 40; i++) if (line.getCell(i)?.getChars() === "X") { x = i; break; }
  t.dispose();
  return x - 1;
}

/// [label, text, columns] — the model's widths: SwiftTerm as patched (and tmux, except where noted in
/// docs/terminal.md's Known limits).
const MODEL: [string, string, number][] = [
  ["CJK", "\u4E2D", 2],
  ["emoji presentation, Unicode 6", "\u{1F600}", 2],
  ["emoji presentation, Unicode 11", "\u{1F970}", 2],
  ["emoji presentation, Unicode 14 (the addon's own data says 1)", "\u{1FAE0}", 2],
  ["emoji presentation, Unicode 15", "\u{1FA77}", 2],
  ["East Asian Wide since Unicode 16", "\u2630", 2],
  ["text presentation", "\u2764", 1],
  ["VS16 on a text-presentation base", "\u2764\uFE0F", 2],
  ["VS16 on ☀", "\u2600\uFE0F", 2],
  ["VS16 on ✔", "\u2714\uFE0F", 2],
  ["VS16 on a letter", "x\uFE0F", 2],
  ["keycap", "1\uFE0F\u20E3", 2],
  ["VS15 does not narrow", "\u231A\uFE0E", 2],
  ["skin tone", "\u{1F44D}\u{1F3FD}", 2],
  ["skin tone on a text-default base", "\u261D\u{1F3FD}", 2],
  ["ZWJ pair", "\u{1F469}\u200D\u{1F4BB}", 2],
  ["ZWJ family", "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}", 2],
  ["ZWJ with a skin tone", "\u{1F9D1}\u{1F3FD}\u200D\u{1F4BB}", 2],
  ["VS16 + ZWJ", "\u{1F3F3}\uFE0F\u200D\u{1F308}", 2],
  ["ZWJ, no VS16: the base's one column", "\u2764\u200D\u{1F525}", 1],
  // UAX #29's GB11 joins an emoji after a ZWJ only when a pictograph came before it (Swift, SwiftTerm,
  // Intl.Segmenter and wcwidth agree); the addon's shortcut joined `a` ZWJ 😀 into one column.
  ["letter, ZWJ, emoji: no join", "a\u200D\u{1F600}", 3],
  ["CJK, ZWJ, emoji: no join", "\u4E2D\u200D\u{1F600}", 4],
  // Old-Korean conjoining L+L (and L + a syllable): two wide cells, as SwiftTerm, wcwidth and tmux
  // count them; the addon joined them into one. L + V still joins.
  ["Hangul L + L: no join", "\u1100\u1100", 4],
  ["Hangul L + LV syllable: no join", "\u1100\uAC00", 4],
  ["Hangul L + V joins", "\u1100\u1161", 2],
  ["tag sequence", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}", 2],
  ["flag", "\u{1F1FA}\u{1F1F8}", 2],
  ["lone regional indicator", "\u{1F1FA}", 1],
  ["three regional indicators", "\u{1F1FA}\u{1F1F8}\u{1F1EC}", 3],
  ["combining mark", "e\u0301", 1],
  ["spacing mark", "\u0915\u093F", 1],
  ["conjoining jamo", "\u1112\u1161\u11AB", 2],
  ["ZWSP", "\u200B", 0],
  ["LRM", "\u200E", 0],
  ["BOM", "\uFEFF", 0],
  ["ambiguous ①", "\u2460", 1],
  ["ambiguous ★", "\u2605", 1],
  ["box drawing", "\u2500", 1],
  ["claude ⏺", "\u23FA", 1],
  // Nothing joins across a control or a sequence (xterm.js zeroes its join state on each): the joiner
  // stands alone, as rdev's SwiftTerm patch writes it (SwiftTermAccessorTests, the same cases).
  ["❤, SGR, an orphan VS16", "\u2764\x1b[31m\uFE0F", 2],
  ["👍, SGR, a modifier alone", "\u{1F44D}\x1b[44m\u{1F3FD}", 4],
  ["🇺, SGR, 🇸", "\u{1F1FA}\x1b[31m\u{1F1F8}", 2],
  ["👩, SGR, an orphan ZWJ, 💻", "\u{1F469}\x1b[31m\u200D\u{1F4BB}", 5],
  ["a mark after BEL", "\x07\u0301", 1],
  ["a mark after an OSC", "\x1b]0;t\x07\u0301", 1],
];

describe("the client counts the model's columns", () => {
  for (const [label, text, want] of MODEL) {
    it(label, async () => { expect(await columns(text)).toBe(want); });
  }

  it("is what the product mounts: the active version is rdev's", () => {
    const t = new Terminal({ allowProposedApi: true });
    loadRdevUnicode(t);
    expect(t.unicode.activeVersion).toBe(RDEV_UNICODE_VERSION);
    t.dispose();
  });

  // NEGATIVE CONTROLS: the setups this replaced, each of which must miss the model somewhere, so the
  // assertions above are not satisfied by any xterm.js at all.
  it("negative control: xterm.js 6's default Unicode 6 table misses emoji, VS16 and ZWJ", async () => {
    const wrong = [];
    for (const [label, text, want] of MODEL) if ((await columns(text, "none")) !== want) wrong.push(label);
    expect(wrong).toEqual(expect.arrayContaining(["emoji presentation, Unicode 6", "VS16 on a text-presentation base", "ZWJ family"]));
  });
  it("negative control: the graphemes addon alone misses Unicode 14+ and zero-width format characters", async () => {
    const wrong = [];
    for (const [label, text, want] of MODEL) if ((await columns(text, "graphemes-only")) !== want) wrong.push(label);
    expect(wrong).toEqual(expect.arrayContaining([
      "emoji presentation, Unicode 14 (the addon's own data says 1)", "East Asian Wide since Unicode 16", "ZWSP",
      "ZWJ, no VS16: the base's one column",
    ]));
  });
});

describe("every scalar's own width is the host's (protocol/fixtures/term-widths.json)", () => {
  const within = (r: number[][], c: number) => {
    let lo = 0, hi = r.length - 1;
    while (lo <= hi) { const m = (lo + hi) >> 1; if (c < r[m]![0]!) hi = m - 1; else if (c > r[m]![1]!) lo = m + 1; else return true; }
    return false;
  };
  const want = (c: number) => (within(widths.wide, c) ? 2 : within(widths.zero, c) ? 0 : 1);

  it("wcwidth, for every scalar from U+00A0", () => {
    const p = rdevUnicodeProvider();
    const bad: string[] = [];
    for (let c = 0xa0; c <= 0x10ffff; c++) {
      if (c >= 0xd800 && c <= 0xdfff) continue;
      if (p.wcwidth(c) !== want(c) && bad.length < 10) bad.push(c.toString(16));
    }
    expect(bad).toEqual([]);
  });

  it("printed after a letter, for every scalar that does not join it", () => {
    const p = rdevUnicodeProvider();
    const a = p.charProperties(0x61, 0);
    const bad: string[] = [];
    for (let c = 0xa0; c <= 0x10ffff; c++) {
      if (c >= 0xd800 && c <= 0xdfff) continue;
      const v = p.charProperties(c, a);
      const joined = (v & 1) !== 0;
      // A zero-width scalar JOINS (it has to: xterm.js advances the cursor past any cell it writes).
      if (want(c) === 0 ? !joined : !joined && ((v >> 1) & 3) !== want(c)) { if (bad.length < 10) bad.push(c.toString(16)); }
    }
    expect(bad).toEqual([]);
  });

  it("the table is not vacuous", () => {
    expect(widths.wide.length).toBeGreaterThan(100);
    expect(widths.zero.length).toBeGreaterThan(300);
    expect(want(0x1fae0)).toBe(2);
    expect(want(0x1f1fa)).toBe(1);
    expect(want(0x200b)).toBe(0);
  });
});

describe("the product wiring", () => {
  it("mountXterm loads rdev's widths: an emoji is two columns in a mounted instance", async () => {
    (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
    (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
    const { mountXterm } = await import("../src/client/xterm-view");   // after beforeAll's canvas stub
    const el = document.createElement("div");
    document.body.append(el);
    const v = mountXterm(el, { onData: () => {}, onFit: () => {}, theme: "dark" });
    expect(v.term.unicode.activeVersion).toBe(RDEV_UNICODE_VERSION);
    await v.writeAsync("\u{1F600}\u{1FAE0}X");
    expect(v.cellAt(0, 4)).toBe("X");
    v.dispose(); el.remove();
  });

  it("mountXterm with widths: \"tmux\" loads tmux's: ☝ is two columns", async () => {
    const { mountXterm } = await import("../src/client/xterm-view");
    const el = document.createElement("div");
    document.body.append(el);
    const v = mountXterm(el, { onData: () => {}, onFit: () => {}, theme: "dark", widths: "tmux" });
    await v.writeAsync("\u261DX");
    expect(v.cellAt(0, 2)).toBe("X");
    v.dispose(); el.remove();
  });

  it("a provider that cannot be built falls back to xterm.js's default, logged ONCE, and the terminal still works", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const boom = () => { throw new Error("stand-in lacks something"); };
      const a = new Terminal({ cols: 20, rows: 2, allowProposedApi: true });
      const b = new Terminal({ cols: 20, rows: 2, allowProposedApi: true });
      expect(loadRdevUnicode(a, boom)).toBe(false);
      expect(loadRdevUnicode(b, boom)).toBe(false);
      expect(a.unicode.activeVersion).toBe("6");
      expect(err).toHaveBeenCalledTimes(1);
      expect(String(err.mock.calls[0]![0])).toMatch(/falling back.*will not line up/);
      await write(a, "ok\u4E2DX");
      expect(a.buffer.active.getLine(0)!.getCell(4)!.getChars()).toBe("X");
      a.dispose(); b.dispose();
      const c = new Terminal({ allowProposedApi: true });
      expect(loadRdevUnicode(c)).toBe(true);
      c.dispose();
    } finally {
      err.mockRestore();
    }
  });
});
