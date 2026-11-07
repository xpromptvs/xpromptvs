// A TMUX TAB COUNTS AS TMUX DOES (docs/terminal.md, "tmux tabs count as tmux does"). tmux decides where a
// tmux app's cursor goes and its `%output` is what the client draws, so a tmux tab's xterm.js follows
// tmux's widths and joins — not the SwiftTerm model a `pty:` tab follows. The expected cursors are
// tmux's own, measured by scripts/measure_tmux_glyphs.py into protocol/fixtures/tmux-glyphs.json.
import { beforeAll, describe, expect, it } from "vitest";
import type { Terminal as XTerm } from "@xterm/xterm";
import tmux from "../../protocol/fixtures/tmux-glyphs.json";
import widths from "../../protocol/fixtures/term-widths.json";
import { loadRdevUnicode, loadTmuxUnicode, RDEV_TMUX_UNICODE_VERSION, tmuxUnicodeProvider } from "../src/client/term-unicode";

let Terminal: typeof XTerm;
beforeAll(async () => {
  HTMLCanvasElement.prototype.getContext = (() => null) as typeof HTMLCanvasElement.prototype.getContext;
  ({ Terminal } = await import("@xterm/xterm"));
});
const write = (t: XTerm, s: string) => new Promise<void>((r) => t.write(s, r));

async function cursorAfter(text: string, flavour: "tmux" | "pty"): Promise<[number, number]> {
  const t = new Terminal({ cols: 20, rows: 5, allowProposedApi: true });
  if (flavour === "tmux") loadTmuxUnicode(t); else loadRdevUnicode(t);
  await write(t, text);
  const b = t.buffer.active;
  const at: [number, number] = [b.cursorX, b.cursorY];
  t.dispose();
  return at;
}

/// What xterm.js CANNOT do as tmux does (docs/terminal.md, Known limits): tmux DROPS a zero-width
/// scalar at column 0, and xterm.js writes a cell for any character it is given and advances past it.
/// Pinned, so the list stays exact: each must be off by exactly that one column.
const UNMIRRORABLE = new Set(["mark at column 0 (after CR)", "mark at column 0 (after CRLF)", "ZWSP at column 0"]);

describe("a tmux tab's cursor lands where tmux's does", () => {
  it("covers the measured samples", () => { expect(tmux.samples.length).toBeGreaterThan(50); });
  for (const s of tmux.samples) {
    it(s.name, async () => {
      const [x, y] = await cursorAfter(s.text, "tmux");
      if (UNMIRRORABLE.has(s.name)) expect([x, y]).toEqual([s.x + 1, s.y]);
      else expect([x, y]).toEqual([s.x, s.y]);
    });
  }

  it("negative control: the pty model misses tmux on its own rules", async () => {
    const wrong: string[] = [];
    for (const s of tmux.samples) {
      const [x, y] = await cursorAfter(s.text, "pty");
      if (x !== s.x || y !== s.y) wrong.push(s.name);
    }
    expect(wrong).toEqual(expect.arrayContaining([
      "SGR between 👍 and 🏽", "☝ alone", "letter ZWJ CJK", "VS16 widening in the last column",
      "BS before ZWSP", "CUP back before a mark", "Hangul filler",
    ]));
  });

  // The server's width options arrive IN BAND ahead of a tmux tab's snapshot (TmuxGlyphOptions.osc,
  // `OSC 9910`), measured on tmux 3.7c: VS16 not widening, and per-scalar widths.
  it("the server's width options, in band, change the count as they change tmux's", async () => {
    const osc = (o: string) => `\x1b]9910;${o}\x07`;
    expect(await cursorAfter("x\uFE0FX", "tmux")).toEqual([3, 0]);
    expect(await cursorAfter(osc("vs16wide=off;widths=") + "x\uFE0FX", "tmux")).toEqual([2, 0]);
    expect(await cursorAfter(osc("vs16wide=off;widths=") + "\u2764\uFE0FX", "tmux")).toEqual([2, 0]);
    expect(await cursorAfter("\u261DX", "tmux")).toEqual([3, 0]);
    expect(await cursorAfter(osc("vs16wide=on;widths=U+261D=1") + "\u261DX", "tmux")).toEqual([2, 0]);
    expect(await cursorAfter(osc("vs16wide=on;widths=U+1F600-U+1F602=1,U+0301=1") + "\u{1F601}e\u0301X", "tmux")).toEqual([4, 0]);
    // Only the FIRST sequence of a fresh instance is the host's statement (every snapshot builds a
    // fresh instance and carries the whole set): a second one right after it is ignored.
    expect(await cursorAfter(osc("vs16wide=on;widths=U+261D=1") + osc("vs16wide=on;widths=") + "\u261DX", "tmux")).toEqual([2, 0]);
  });

  // A program in a tmux tab can print its own OSC 9910 (tmux forwards pane bytes raw). It must change
  // nothing: the statement counts only as the first bytes a fresh instance parses \u2014 the host's
  // snapshot \u2014 never from the live stream (final review I2, 2026-09-27).
  it("a statement anywhere but first \u2014 forged by a program in the pane \u2014 is ignored", async () => {
    const osc = (o: string) => `\x1b]9910;${o}\x07`;
    expect(await cursorAfter("a" + osc("vs16wide=on;widths=U+261D=1") + "\u261DX", "tmux")).toEqual([4, 0]);
    expect(await cursorAfter("\x1b[m" + osc("vs16wide=off;widths=") + "x\uFE0FX", "tmux")).toEqual([3, 0]);
  });

  // \u2026and even the first one is CAPPED (4 KB, 256 ranges): past the cap entries are ignored, so no
  // statement can make every glyph a linear scan over millions of entries on the page's main thread.
  it("a statement's width list is capped", async () => {
    const osc = (o: string) => `\x1b]9910;${o}\x07`;
    const junk = (n: number) => Array.from({ length: n }, (_, i) => `U+${(0xe000 + i).toString(16)}=0`).join(",");
    expect(await cursorAfter(osc(`vs16wide=on;widths=U+261D=1,${junk(200)}`) + "\u261DX", "tmux")).toEqual([2, 0]);
    expect(await cursorAfter(osc(`vs16wide=on;widths=${junk(256)},U+261D=1`) + "\u261DX", "tmux")).toEqual([3, 0]);
    const t0 = performance.now();
    const huge = osc(`vs16wide=on;widths=${junk(400_000)},U+261D=1`);
    expect(await cursorAfter(huge + "\u261D".repeat(2000) + "X", "tmux")).toEqual([1, 4]);
    expect(performance.now() - t0).toBeLessThan(5000);
  });

  // An SGR before every glyph (a coloured TUI border) used to cost one BUFFER read per glyph: after a
  // sequence xterm.js hands the provider no state, and a non-joiner joins only a cell ending in a ZWJ.
  // An instance never given a ZWJ has no such cell, so it reads nothing — and one that has been given
  // one (whatever width `codepoint-widths` gives it) still reads, and still joins across the sequence.
  it("reads the buffer after a sequence only when a join is possible", async () => {
    const t = new Terminal({ cols: 120, rows: 5, allowProposedApi: true });
    loadTmuxUnicode(t);
    let reads = 0;
    for (const b of [t.buffer.normal, t.buffer.alternate]) {
      const getLine = b.getLine.bind(b);
      (b as { getLine: typeof b.getLine }).getLine = (y: number) => { reads++; return getLine(y); };
    }
    await write(t, "\x1b[31m\u2500".repeat(50) + "\x1b[32m\u{1F600}".repeat(20));
    expect([t.buffer.active.cursorX, reads]).toEqual([90, 0]);
    await write(t, "\x1b[31m\u{1F44D}\x1b[32m\u{1F3FD}");            // a joiner still reads
    expect(reads).toBeGreaterThan(0);
    t.dispose();
    const osc = (o: string) => `\x1b]9910;${o}\x07`;
    expect(await cursorAfter("a\u200D\x1b[31m\u4E2DX", "tmux")).toEqual([2, 0]);
    expect(await cursorAfter("\u4E2D\x1b[31m\u4E2Da\u200D\x1b[m\u{1F600}X", "tmux")).toEqual([6, 0]);
    expect(await cursorAfter(osc("vs16wide=on;widths=U+200D=1") + "\u200D\x1b[31m\u4E2DX", "tmux")).toEqual([2, 0]);
  });

  it("is a tmux tab's own version", () => {
    const t = new Terminal({ allowProposedApi: true });
    loadTmuxUnicode(t);
    expect(t.unicode.activeVersion).toBe(RDEV_TMUX_UNICODE_VERSION);
    t.dispose();
  });
});

describe("every scalar's own width is tmux's", () => {
  it("the host table, with tmux's measured exceptions", () => {
    const within = (r: number[][], c: number) => r.some(([a, b]) => a! <= c && c <= b!);
    const p = tmuxUnicodeProvider(new Terminal({ allowProposedApi: true }));
    const wide = new Set(tmux.wide), zero = new Set(tmux.zero);
    const bad: string[] = [];
    for (let c = 0xa0; c <= 0x2ffff; c++) {
      if (c >= 0xd800 && c <= 0xdfff) continue;
      const want = wide.has(c) ? 2 : zero.has(c) ? 0 : within(widths.wide, c) ? 2 : within(widths.zero, c) ? 0 : 1;
      if (p.wcwidth(c) !== want && bad.length < 10) bad.push(c.toString(16));
    }
    expect(bad).toEqual([]);
    expect(tmux.wide).toContain(0x261d);
    expect(tmux.modifierBases).toContain(0x1f44d);
    expect(tmux.modifierBases).not.toContain(0x261d);
  });
});
