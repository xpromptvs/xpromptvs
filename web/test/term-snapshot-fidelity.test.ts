// THE serializer's core check. For every corpus case: one headless xterm.js fed the ORIGINAL byte
// stream, a FRESH one fed what the Swift emitter made of SwiftTerm's snapshot of that stream — and the
// two must be equal in every cell (char, width, attributes), wrap flag, cursor, mode, region, tab stop,
// saved cursor and charset, and in scrollback length. The emitted bytes are committed fixtures,
// written by //tools/TermSnapshotFixtures and kept fresh by TermSnapshotFixtureTests.
import { beforeAll, describe, expect, it } from "vitest";
// @ts-expect-error - node modules not typed in this project
import { readFileSync } from "node:fs";
// @ts-expect-error - node modules not typed in this project
import { fileURLToPath } from "node:url";
// @ts-expect-error - node modules not typed in this project
import { dirname, resolve } from "node:path";
import type { Terminal as XTerm } from "@xterm/xterm";
import { captureState, diffStates, type XtermState } from "./lib/xterm-state";
import { loadRdevUnicode } from "../src/client/term-unicode";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIX = resolve(__dirname, "../../protocol/fixtures");
const manifest = JSON.parse(readFileSync(resolve(FIX, "term-corpus/manifest.json"), "utf8")) as { name: string; cols: number; rows: number }[];
const original = (name: string) => new Uint8Array(readFileSync(resolve(FIX, `term-corpus/${name}.bin`)));
const emitted = (name: string) => new Uint8Array(readFileSync(resolve(FIX, `term-snapshot/${name}.emitted.bin`)));

let Terminal: typeof XTerm;
beforeAll(async () => {
  HTMLCanvasElement.prototype.getContext = (() => null) as typeof HTMLCanvasElement.prototype.getContext;
  ({ Terminal } = await import("@xterm/xterm"));
});

// The product's options (web/src/client/xterm-view.ts) that change parsing or state — its glyph
// widths included (`loadRdevUnicode`, which `mountXterm` runs on every instance).
const fresh = (cols: number, rows: number, unicode = true) => {
  const t = new Terminal({ cols, rows, scrollback: 5000, cursorBlink: true, allowProposedApi: true });
  if (unicode) loadRdevUnicode(t);
  return t;
};
const write = (t: XTerm, b: Uint8Array | string) => new Promise<void>((r) => t.write(b, r));
async function stateOf(cols: number, rows: number, bytes: Uint8Array | string, unicode = true): Promise<XtermState> {
  const t = fresh(cols, rows, unicode);
  await write(t, bytes);
  const s = captureState(t);
  t.dispose();
  return s;
}

describe("a fresh xterm.js fed the emitted snapshot equals one fed the original stream", () => {
  it("covers the corpus", () => { expect(manifest.length).toBe(34); });            // scripts/gen_term_corpus.py's exact count
  for (const c of manifest) {
    it(c.name, async () => {
      const a = await stateOf(c.cols, c.rows, original(c.name));
      const b = await stateOf(c.cols, c.rows, emitted(c.name));
      expect(diffStates(a, b)).toEqual([]);
    });
  }
});

describe("the comparison is not vacuous", () => {
  it("the corpus exercises what it claims to", async () => {
    // 8-bit C1 is read as controls, not printed (docs/terminal.md, "8-bit C1"): the C1 CSI coloured
    // "red" and left no trace; SOS/PM/APC hid their text; the NEL that aborted a CSI started a row.
    const c1 = await stateOf(40, 10, original("c1-controls"));
    const text = c1.normal.lines.map((l) => l.cells.map((c) => JSON.parse(c.slice(0, c.indexOf('":') + 1)) as string).join("").trimEnd());
    expect(text[0]).toBe("aredb");
    expect(text.join("|")).not.toContain("hidden");
    expect(text.some((t) => t.startsWith("m-not-red"))).toBe(true);
    const sgr = await stateOf(80, 24, original("sgr-torture"));
    const cells = sgr.normal.lines.flatMap((l) => l.cells);
    expect(cells.some((c) => c.includes("/b"))).toBe(true);                       // bold
    expect(cells.some((c) => c.includes("rgb"))).toBe(true);                      // truecolor
    expect(cells.some((c) => c.includes("/u3/"))).toBe(true);                     // curly underline
    expect(cells.some((c) => c.startsWith('"":1:d/p4/'))).toBe(true);            // erased with a background
    const alt = await stateOf(80, 24, original("alt-screen-vim"));
    expect(alt.activeIsAlt).toBe(true);
    expect(alt.normal.lines.length).toBeGreaterThan(300);
    const region = await stateOf(80, 24, original("scroll-region-origin"));
    expect([region.normal.scrollTop, region.normal.scrollBottom, region.modes.originMode]).toEqual([2, 19, true]);
    const wrapped = await stateOf(80, 24, original("wrapped-lines"));
    expect(wrapped.normal.lines.some((l) => l.wrapped)).toBe(true);
    const pending = await stateOf(20, 5, original("pending-wrap"));
    expect(pending.cursor.x).toBe(20);
    // The shapes the SwiftTerm patch and the capture were fixed for (task 5): stops past column 80, a
    // DECSC in pending wrap, an alt screen filled with the pen's background, and a re-entered one.
    const wide = await stateOf(100, 30, original("htop-like"));
    expect(wide.normal.tabs).toContain(96);
    const decsc = await stateOf(20, 5, original("decsc-pending-wrap"));
    expect(decsc.normal.saved.x).toBe(20);
    const altBg = await stateOf(40, 10, original("alt-saved-cursor-bg"));
    expect(altBg.alt!.lines.flatMap((l) => l.cells).some((c) => c.startsWith('"":1:d/p5/'))).toBe(true);
    const reentry = await stateOf(40, 10, original("alt-screen-reentry"));
    expect([reentry.activeIsAlt, reentry.cursor.hidden, reentry.alt!.tabs]).toEqual([true, true, [0, 8, 16, 24, 32]]);
    // Scrollback FULL (5000 + 5 rows) and the wrapped line long evicted: every recycle after it must
    // leave a fresh, unwrapped line (SwiftTerm kept the evicted line's wrap flag; patch fix 5).
    const recycled = await stateOf(20, 5, original("recycled-wrapped-line"));
    expect([recycled.normal.lines.length, recycled.normal.lines.some((l) => l.wrapped)]).toEqual([5005, false]);
    // Glyph widths (docs/terminal.md, "Glyph widths"): VS16, ZWJ, a skin tone on a text-default base
    // and a flag each ONE wide cell, a lone regional indicator one column, and at the margin a VS16
    // that moved its heart to the next row.
    const emoji = (await stateOf(40, 12, original("emoji-widths"))).normal.lines.flatMap((l) => l.cells);
    for (const g of ["\u2764\uFE0F", "\u{1F469}\u200D\u{1F4BB}", "\u261D\u{1F3FD}", "\u{1F1FA}\u{1F1F8}", "\u{1FAE0}"]) {
      expect(emoji.some((c) => c.startsWith(`${JSON.stringify(g)}:2:`))).toBe(true);
    }
    expect(emoji.some((c) => c.startsWith(`${JSON.stringify("\u{1F1FA}")}:1:`))).toBe(true);
    // The joins the client keeps apart to follow SwiftTerm: a letter's ZWJ before an emoji, L + L, and
    // a spacing glyph after a Prepend character.
    const joinsCells = (await stateOf(80, 40, original("grapheme-joins"))).normal.lines.flatMap((l) => l.cells);
    for (const g of ["a\u200D", "\u1100", "\u0D4E"]) {
      expect(joinsCells.some((c) => c.startsWith(`${JSON.stringify(g)}:`))).toBe(true);
    }
    const margin = await stateOf(20, 6, original("emoji-margin"));
    expect(margin.normal.lines[1]!.wrapped).toBe(true);
    expect(margin.normal.lines[1]!.cells[0]!.startsWith(`${JSON.stringify("\u2764\uFE0F")}:2:`)).toBe(true);
  });

  // The client's glyph widths are what make the emoji cases agree: counted as xterm.js 6 counts by
  // default (Unicode 6, no graphemes), the host's snapshot of the same stream lands elsewhere.
  it("negative control: glyph widths — the emoji cases differ when the client counts Unicode 6", async () => {
    for (const name of ["emoji-widths", "emoji-margin"]) {
      const c = manifest.find((m) => m.name === name)!;
      const a = await stateOf(c.cols, c.rows, original(name), false);
      const b = await stateOf(c.cols, c.rows, emitted(name), false);
      expect(diffStates(a, b).length).toBeGreaterThan(0);
    }
  });

  // NEGATIVE CONTROLS — each drops or changes one thing the emitter restates, and the comparison must
  // see it; `path`, when given, is where it must see it (so a control cannot pass on a side effect).
  const mutations: [label: string, name: string, mutate: (s: string) => string, path?: string][] = [
    ["scroll region", "scroll-region-origin", (s) => s.replace(/\x1b\[3;20r/, "")],
    ["alt screen", "alt-screen-vim", (s) => s.replace("\x1b[?1049h", "")],
    ["wrap flag", "wrapped-lines", (s) => s.replace(/(\d{3}abcdefghij)/, "\r\n$1")],
    ["a boolean mode", "claude-like-tui", (s) => s.replace("\x1b[?1004h", "\x1b[?1004l")],
    ["charsets", "charsets", (s) => s.replace("\x1b)0", "\x1b)B")],
    ["cell attributes", "sgr-torture", (s) => s.replace("\x1b[4;58;5;196m", "\x1b[4;58;5;197m"), "$.normal.lines"],
    ["cursor position", "sgr-torture", (s) => s.replace("\x1b[9;9H", "\x1b[9;10H"), "$.cursor.x"],
    ["cursor style", "cursor-style", (s) => s.replace("\x1b[6 q", ""), "$.cursor.style"],
    ["cursor visibility", "cursor-style", (s) => s.replace("\x1b[?25l", "\x1b[?25h"), "$.cursor.hidden"],
    ["tab stops", "tab-stops", (s) => s.replace("\x1b[1;30H\x1bH", ""), "$.normal.tabs"],
    ["saved cursor", "decsc-pending-wrap", (s) => s.replace("\x1b7", ""), "$.normal.saved"],
    ["mouse protocol", "mouse-modes", (s) => s.replace("\x1b[?1003h", "\x1b[?1000h"), "$.mouse.protocol"],
    ["mouse encoding", "mouse-modes", (s) => s.replace("\x1b[?1016h", "\x1b[?1006h"), "$.mouse.encoding"],
    ["pen", "sgr-torture", (s) => s.replace(/\x1b\[1;31m$/, ""), "$.pen"],
    ["a join kept apart (NUL)", "emoji-split", (s) => s.replace("\x00", ""), "$.normal.lines"],
  ];
  for (const [label, name, mutate, path] of mutations) {
    it(`negative control: ${label} (${name}) with one statement changed differs`, async () => {
      const c = manifest.find((m) => m.name === name)!;
      const text = new TextDecoder().decode(emitted(name));
      const mutated = mutate(text);
      expect(mutated).not.toBe(text);                                               // the mutation reached the bytes
      const a = await stateOf(c.cols, c.rows, original(name));
      const b = await stateOf(c.cols, c.rows, mutated);
      const diff = diffStates(a, b);
      expect(diff.length).toBeGreaterThan(0);
      if (path) expect(diff.some((d) => d.startsWith(path))).toBe(true);
    });
  }

  // A renamed LEAF in an xterm.js upgrade reads `undefined` on BOTH sides and compares equal, so a
  // class would go vacuous with every test green. No captured leaf may be undefined.
  it("no captured field reads undefined", async () => {
    const undef = (v: unknown, path: string, out: string[]): string[] => {
      if (v === undefined) out.push(path);
      else if (typeof v === "object" && v !== null) for (const [k, x] of Object.entries(v)) undef(x, `${path}.${k}`, out);
      return out;
    };
    for (const c of manifest) {
      const s = await stateOf(c.cols, c.rows, original(c.name));
      expect(undef(s, `${c.name}:$`, [])).toEqual([]);
    }
  });
});
