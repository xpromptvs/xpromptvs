import { describe, expect, it } from "vitest";
import { Terminal, type IBufferCell } from "@xterm/xterm";
import { Flag, Selection, attrColor, newResolved, resolveCell, type CellLike, type Override, type Palette } from "../src/client/webgpu/cell-model";

// The WebGPU renderer's colours and lines, read from a REAL xterm.js's cells — the attribute packing is
// xterm.js's, so the input must be what xterm.js writes, never hand-built words.

const ansi = Uint32Array.from({ length: 256 }, (_, i) => ((0x100000 + i * 0x10101) << 8 | 0xff) >>> 0);
const palette: Palette = {
  foreground: 0xd0d0d0ff, background: 0x1e1e1eff, cursor: 0xf0f0f0ff, cursorAccent: 0x101010ff,
  selection: 0x3a4b5c99, selectionInactive: 0x2a2a2a99, selectionForeground: null, ansi,
};

async function written(text: string, cols = 40): Promise<{ at(x: number, y?: number): IBufferCell & CellLike }> {
  const term = new Terminal({ cols, rows: 4, allowProposedApi: true });
  await new Promise<void>((r) => term.write(text, r));
  const cell = term.buffer.active.getNullCell() as IBufferCell & CellLike;
  return { at(x, y = 0) { term.buffer.active.getLine(y)!.getCell(x, cell); return cell; } };
}

const resolve = (c: CellLike, opts: { selected?: boolean; focused?: boolean; boldBright?: boolean; bottom?: Override; top?: Override; p?: Palette } = {}) =>
  resolveCell(c, opts.p ?? palette, opts.selected ?? false, opts.focused ?? true, opts.boldBright ?? true, newResolved(),
    opts.bottom ?? null, opts.top ?? null);

describe("colours", () => {
  it("a plain cell: the theme's foreground, the default background (nothing drawn), a glyph", async () => {
    const t = await written("a b");
    expect(resolve(t.at(0))).toMatchObject({ fg: palette.foreground, bg: 0, flags: 0, glyph: true, bold: false, italic: false });
    expect(resolve(t.at(1)).glyph, "a space draws nothing").toBe(false);
    expect(resolve(t.at(5)).glyph, "an empty cell draws nothing").toBe(false);
  });

  it("palette, 256 and truecolour, for both", async () => {
    const t = await written("\x1b[31;42ma\x1b[38;5;200;48;5;17mb\x1b[38;2;1;2;3;48;2;250;251;252mc");
    expect(resolve(t.at(0))).toMatchObject({ fg: ansi[1], bg: ansi[2] });
    expect(resolve(t.at(1))).toMatchObject({ fg: ansi[200], bg: ansi[17] });
    expect(resolve(t.at(2))).toMatchObject({ fg: 0x010203ff, bg: 0xfafbfcff });
  });

  it("bold draws palette 0-7 as 8-15 — only with drawBoldTextInBrightColors, only P16", async () => {
    const t = await written("\x1b[1;31ma\x1b[1;38;5;1mb");
    expect(resolve(t.at(0)).fg).toBe(ansi[9]);
    expect(resolve(t.at(0), { boldBright: false }).fg).toBe(ansi[1]);
    expect(resolve(t.at(1)).fg, "a 256-colour index is not brightened").toBe(ansi[1]);
    expect(resolve(t.at(0)).bold).toBe(true);
  });

  it("inverse swaps them — a default foreground becomes the theme's background and the reverse", async () => {
    const t = await written("\x1b[7ma\x1b[31mb");
    expect(resolve(t.at(0))).toMatchObject({ fg: palette.background, bg: palette.foreground });
    expect(resolve(t.at(1))).toMatchObject({ fg: palette.background, bg: ansi[1] });
  });

  it("dim draws the foreground at half alpha — but not under a selection (the DOM renderer's look)", async () => {
    const t = await written("\x1b[2ma");
    expect(resolve(t.at(0)).fg).toBe(((palette.foreground >>> 8) << 8 | 0x80) >>> 0);
    expect(resolve(t.at(0), { selected: true }).fg).toBe(palette.foreground);
  });

  it("a selected cell takes the OPAQUE selection colour, focused or not, and the selection foreground if any", async () => {
    const t = await written("\x1b[41ma");
    expect(resolve(t.at(0), { selected: true }).bg, "replaces, never blends").toBe(0x3a4b5cff);
    expect(resolve(t.at(0), { selected: true, focused: false }).bg).toBe(0x2a2a2aff);
    expect(resolve(t.at(0), { selected: true, p: { ...palette, selectionForeground: 0x112233ff } }).fg).toBe(0x112233ff);
  });

  it("decorations: 'bottom' under the selection, 'top' over it", async () => {
    const t = await written("a");
    const deco = { bg: 0xaabbccff, fg: 0x010101ff };
    expect(resolve(t.at(0), { bottom: deco })).toMatchObject({ bg: deco.bg, fg: deco.fg });
    expect(resolve(t.at(0), { bottom: deco, selected: true }).bg, "the selection wins over a bottom one").toBe(0x3a4b5cff);
    expect(resolve(t.at(0), { top: deco, selected: true }).bg, "a top one wins over the selection").toBe(deco.bg);
  });

  it("invisible draws no glyph", async () => {
    const t = await written("\x1b[8ma");
    expect(resolve(t.at(0)).glyph).toBe(false);
  });

  it("a default colour attribute is null; a palette one its entry", () => {
    expect(attrColor(0, palette)).toBeNull();
    expect(attrColor(0x1000000 | 3, palette)).toBe(ansi[3]);
  });
});

describe("lines", () => {
  it("underline styles as xterm.js stores them, with their own colour", async () => {
    const t = await written("\x1b[4ma\x1b[4:2mb\x1b[4:3mc\x1b[4:4md\x1b[4:5me\x1b[0m\x1b[4;58;2;9;8;7mf");
    expect([0, 1, 2, 3, 4].map((x) => resolve(t.at(x)).flags & Flag.UNDERLINE_MASK)).toEqual([1, 2, 3, 4, 5]);
    const f = resolve(t.at(5));
    expect(f.underline, "SGR 58's colour").toBe(0x090807ff);
    expect(resolve(t.at(0)).underline, "otherwise the foreground").toBe(palette.foreground);
  });

  it("strikethrough and overline", async () => {
    const t = await written("\x1b[9ma\x1b[0;53mb");
    expect(resolve(t.at(0)).flags & Flag.STRIKE).toBeTruthy();
    expect(resolve(t.at(1)).flags & Flag.OVERLINE).toBeTruthy();
  });

  it("an OSC 8 link's cells are dashed with no SGR 4 — xterm.js's own `isUnderline()`", async () => {
    const t = await written("\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\ x");
    expect(resolve(t.at(0)).flags & Flag.UNDERLINE_MASK).toBe(5);
    expect(resolve(t.at(5)).flags & Flag.UNDERLINE_MASK, "not after it").toBe(0);
  });

  it("SGR 24 ends an underline", async () => {
    const t = await written("\x1b[4:3ma\x1b[24mb");
    expect(resolve(t.at(1)).flags & Flag.UNDERLINE_MASK).toBe(0);
  });
});

describe("the selection model (xterm.js's SelectionRenderModel)", () => {
  it("normal: the first row from its column, the rows between whole, the last row up to its column", () => {
    const s = new Selection();
    s.update([5, 10], [3, 12], false);
    expect([s.has(4, 10), s.has(5, 10), s.has(0, 11), s.has(79, 11), s.has(2, 12), s.has(3, 12)]).toEqual([false, true, true, true, true, false]);
    expect(s.has(5, 9) || s.has(0, 13)).toBe(false);
  });

  it("one row; an empty selection; column mode either way round", () => {
    const s = new Selection();
    s.update([2, 4], [6, 4], false);
    expect([s.has(1, 4), s.has(2, 4), s.has(5, 4), s.has(6, 4)]).toEqual([false, true, true, false]);
    s.update([3, 3], [3, 3], false);
    expect(s.has(3, 3)).toBe(false);
    s.update([8, 1], [4, 3], true);
    expect([s.has(4, 2), s.has(7, 2), s.has(8, 2), s.has(5, 0)]).toEqual([true, true, false, false]);
  });
});

