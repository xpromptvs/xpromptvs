import { describe, expect, it } from "vitest";
import { Terminal, type ITheme } from "@xterm/xterm";
import { PredictionOverlay, cellColorAttrs, resolveCellColors, type CellColorAttrs } from "../src/client/prediction-overlay";
import { xtermTheme } from "../src/client/xterm-view";

const DARK = xtermTheme("dark");
const LIGHT = xtermTheme("light");

const plain: CellColorAttrs = { fgMode: "default", fg: 0, bgMode: "default", bg: 0, inverse: false, bold: false, dim: false };

describe("resolveCellColors — a covered cell's colours, as xterm.js paints them", () => {
  it("a default cell is the THEME's background and foreground — never black", () => {
    expect(resolveCellColors(plain, DARK)).toEqual({ fg: DARK.foreground, bg: DARK.background, fgAlpha: 1 });
    expect(resolveCellColors(plain, LIGHT)).toEqual({ fg: LIGHT.foreground, bg: LIGHT.background, fgAlpha: 1 });
  });
  it("a palette background is the theme's ANSI colour (0–15) or its extended slot (16–255)", () => {
    expect(resolveCellColors({ ...plain, bgMode: "palette", bg: 4 }, DARK).bg).toBe(DARK.blue);
    expect(resolveCellColors({ ...plain, bgMode: "palette", bg: 52 }, DARK).bg).toBe(DARK.extendedAnsi![52 - 16]);
    expect(resolveCellColors({ ...plain, bgMode: "palette", bg: 196 }, LIGHT).bg).toBe("#ff0000");   // the cube
  });
  it("an RGB background is that colour", () => {
    expect(resolveCellColors({ ...plain, bgMode: "rgb", bg: 0x12345a }, DARK).bg).toBe("#12345a");
  });
  it("INVERSE swaps them, as xterm.js draws it", () => {
    expect(resolveCellColors({ ...plain, inverse: true }, DARK)).toEqual({ fg: DARK.background, bg: DARK.foreground, fgAlpha: 1 });
  });
  // BOLD-AS-BRIGHT and DIM, as xterm.js 6's DOM renderer draws them (DomRendererRowFactory.createRow,
  // minimumContrastRatio 1): a bold cell's PALETTE foreground 0–7 is drawn 8–15 when
  // `drawBoldTextInBrightColors` (default on) — after the inverse swap, the foreground only; a dim cell's
  // text is drawn at half alpha, except an RGB foreground (its inline colour beats the `.xterm-dim` class).
  it("BOLD-AS-BRIGHT: a bold palette foreground 0–7 is drawn 8–15", () => {
    // the dark theme's bright colours are its plain ones except black, so the light theme carries red
    expect([LIGHT.brightRed, DARK.brightBlack]).not.toEqual([LIGHT.red, DARK.black]);
    expect(resolveCellColors({ ...plain, fgMode: "palette", fg: 1, bold: true }, LIGHT).fg).toBe(LIGHT.brightRed);
    expect(resolveCellColors({ ...plain, fgMode: "palette", fg: 0, bold: true }, DARK).fg).toBe(DARK.brightBlack);
  });
  it("…only when the option is on, only 0–7, only a palette foreground", () => {
    expect(resolveCellColors({ ...plain, fgMode: "palette", fg: 1, bold: true }, LIGHT, false).fg).toBe(LIGHT.red);
    expect(resolveCellColors({ ...plain, fgMode: "palette", fg: 1 }, LIGHT).fg).toBe(LIGHT.red);
    expect(resolveCellColors({ ...plain, fgMode: "palette", fg: 9, bold: true }, LIGHT).fg).toBe(LIGHT.brightRed);
    expect(resolveCellColors({ ...plain, fgMode: "palette", fg: 52, bold: true }, DARK).fg).toBe(DARK.extendedAnsi![52 - 16]);
    expect(resolveCellColors({ ...plain, fgMode: "rgb", fg: 0x000001, bold: true }, LIGHT).fg).toBe("#000001");
    expect(resolveCellColors({ ...plain, bold: true }, LIGHT).fg).toBe(LIGHT.foreground);
    expect(resolveCellColors({ ...plain, bgMode: "palette", bg: 1, bold: true }, LIGHT).bg).toBe(LIGHT.red);   // never the background
  });
  it("…after the INVERSE swap: a bold inverse cell brightens what became its foreground", () => {
    expect(resolveCellColors({ ...plain, bgMode: "palette", bg: 1, inverse: true, bold: true }, LIGHT))
      .toEqual({ fg: LIGHT.brightRed, bg: LIGHT.foreground, fgAlpha: 1 });
  });
  it("DIM: the text at half alpha — a default or palette foreground, never an RGB one", () => {
    expect(resolveCellColors({ ...plain, dim: true }, DARK)).toEqual({ fg: DARK.foreground, bg: DARK.background, fgAlpha: 0.5 });
    expect(resolveCellColors({ ...plain, fgMode: "palette", fg: 2, dim: true }, DARK).fgAlpha).toBe(0.5);
    expect(resolveCellColors({ ...plain, inverse: true, dim: true }, DARK).fgAlpha).toBe(0.5);
    expect(resolveCellColors({ ...plain, fgMode: "rgb", fg: 0x123456, dim: true }, DARK).fgAlpha).toBe(1);
  });
  it("an absent theme falls back to xterm.js's own defaults", () => {
    expect(resolveCellColors(plain, undefined)).toEqual({ fg: "#ffffff", bg: "#000000", fgAlpha: 1 });
  });
});

describe("cellColorAttrs — read from a REAL xterm.js buffer", () => {
  const E = "\x1b";
  const colorsAt = async (seq: string, theme: ITheme) => {
    const term = new Terminal({ cols: 20, rows: 2, allowProposedApi: true });
    await new Promise<void>((r) => term.write(`${seq}x${E}[m`, r));
    const cell = term.buffer.active.getLine(0)?.getCell(0);
    term.dispose();
    return resolveCellColors(cellColorAttrs(cell), theme);
  };
  it("default, palette (SGR 44, 48;5;52), RGB (48;2) and inverse cells resolve as xterm.js paints them", async () => {
    expect(await colorsAt("", DARK)).toEqual({ fg: DARK.foreground, bg: DARK.background, fgAlpha: 1 });
    expect((await colorsAt(`${E}[44m`, DARK)).bg).toBe(DARK.blue);
    expect((await colorsAt(`${E}[48;5;52m`, DARK)).bg).toBe(DARK.extendedAnsi![52 - 16]);
    expect((await colorsAt(`${E}[48;2;18;52;90m`, DARK)).bg).toBe("#12345a");
    expect(await colorsAt(`${E}[31;7m`, LIGHT)).toEqual({ fg: LIGHT.background, bg: LIGHT.red, fgAlpha: 1 });
  });
  it("bold (SGR 1) and dim (SGR 2) are read from the cell", async () => {
    expect((await colorsAt(`${E}[1;31m`, LIGHT)).fg).toBe(LIGHT.brightRed);
    expect((await colorsAt(`${E}[2;32m`, DARK))).toEqual({ fg: DARK.green, bg: DARK.background, fgAlpha: 0.5 });
  });
  it("a cell past the line's end is a default cell", () => {
    expect(cellColorAttrs(undefined)).toEqual(plain);
  });
});

/// A terminal just big enough for the overlay: a buffer whose cells report `attrs(row, col)`, and
/// decorations whose `onRender` the test runs against a real element.
function fakeTerm(theme: ITheme, attrs: (row: number, col: number) => CellColorAttrs, cols = 20) {
  const rendered: HTMLElement[] = [];
  const cellOf = (a: CellColorAttrs) => ({
    isFgDefault: () => a.fgMode === "default", isFgPalette: () => a.fgMode === "palette", isFgRGB: () => a.fgMode === "rgb",
    isBgDefault: () => a.bgMode === "default", isBgPalette: () => a.bgMode === "palette", isBgRGB: () => a.bgMode === "rgb",
    getFgColor: () => a.fg, getBgColor: () => a.bg, isInverse: () => (a.inverse ? 1 : 0),
    isBold: () => (a.bold ? 1 : 0), isDim: () => (a.dim ? 1 : 0),
  });
  const term = {
    cols,
    options: { theme },
    buffer: { active: { baseY: 0, cursorY: 0, getLine: (r: number) => ({ getCell: (c: number) => cellOf(attrs(r, c)) }) } },
    registerMarker: (offset: number) => ({ line: offset, dispose() {} }),
    registerDecoration: (opts: { marker: { line: number }; x: number; width: number }) => ({
      dispose() {},
      onRender(cb: (el: HTMLElement) => void) {
        const el = document.createElement("div");
        el.dataset.row = String(opts.marker.line); el.dataset.x = String(opts.x); el.dataset.width = String(opts.width);
        cb(el); rendered.push(el);
      },
    }),
  };
  return { term: term as unknown as Terminal, rendered };
}
const FONT = { fontFamily: "monospace", fontSize: 14, cellHeight: 18 };

describe("PredictionOverlay — paints in the covered cells' colours", () => {
  it("keeps confirmed text at full opacity while dimming only speculative cells", () => {
    const { term, rendered } = fakeTerm(DARK, () => plain);
    new PredictionOverlay(term, FONT).show(0, 2, "hellox", false, 6, [false, false, false, false, false, true]);
    expect(rendered[0]!.textContent).toBe("hello");
    expect(rendered[0]!.style.color).toBe("rgb(240, 238, 241)");
    expect(rendered[1]!.textContent).toBe("x");
    expect(rendered[1]!.style.color).toBe("rgba(240, 238, 241, 0.6)");
  });
  it("THE BLACK-CELL BUG: a predicted character over a default cell has the THEME's background", () => {
    const { term, rendered } = fakeTerm(DARK, () => plain);
    new PredictionOverlay(term, FONT).show(0, 0, "ab", false);
    expect(rendered.length).toBeGreaterThan(0);
    for (const el of rendered) expect(el.style.background).not.toBe("rgb(0, 0, 0)");
    expect(rendered[0]!.style.background).toBe("rgb(24, 24, 23)");          // DARK.background #181817
  });
  it("over a COLOURED stretch each cell keeps its own background (the run splits where it changes)", () => {
    // cells 0–1 default, 2–3 blue (palette 4)
    const { term, rendered } = fakeTerm(DARK, (_r, c) => (c >= 2 ? { ...plain, bgMode: "palette", bg: 4 } : plain));
    new PredictionOverlay(term, FONT).show(0, 0, "abcd", false);
    const byX = new Map(rendered.map((el) => [el.dataset.x, el]));
    expect(byX.get("0")!.style.background).toBe("rgb(24, 24, 23)");
    expect(byX.get("0")!.dataset.width).toBe("2");
    expect(byX.get("2")!.style.background).toBe("rgb(135, 217, 228)");      // DARK.blue #87d9e4
    expect(byX.get("2")!.dataset.width).toBe("2");
  });
  it("the ghost text is the cell's foreground, dimmed — on the light theme too", () => {
    const { term, rendered } = fakeTerm(LIGHT, () => plain);
    new PredictionOverlay(term, FONT).show(0, 0, "x", false);
    expect(rendered[0]!.style.background).toBe("rgb(255, 255, 255)");        // LIGHT.background
    expect(rendered[0]!.style.color).toBe("rgba(10, 10, 10, 0.6)");          // LIGHT.foreground, dimmed
  });
  it("a ghost over a BOLD red cell is drawn bright red, over a DIM cell at half the ghost's alpha", () => {
    const attrs = (_r: number, c: number): CellColorAttrs =>
      c === 0 ? { ...plain, fgMode: "palette", fg: 1, bold: true } : { ...plain, dim: true };
    const { term, rendered } = fakeTerm(LIGHT, attrs);
    new PredictionOverlay(term, FONT).show(0, 0, "ab", false);
    const byX = new Map(rendered.map((el) => [el.dataset.x, el]));
    expect(byX.get("0")!.style.color).toBe("rgba(224, 64, 47, 0.6)");     // LIGHT.brightRed #e0402f, the ghost's alpha
    expect(byX.get("1")!.style.color).toBe("rgba(10, 10, 10, 0.3)");       // LIGHT.foreground #0a0a0a, dim × ghost
  });
  it("an anchor in the PENDING-WRAP column (cursorX === cols) starts on the next row, every character in its cell", () => {
    const { term, rendered } = fakeTerm(DARK, () => plain, 10);
    new PredictionOverlay(term, FONT).show(0, 10, "abc", false);
    expect(rendered.map((el) => [el.dataset.row, el.dataset.x, el.textContent])).toEqual([["1", "0", "abc"]]);
  });
  it("a prediction past the right edge continues at column 0 of the next row", () => {
    const { term, rendered } = fakeTerm(DARK, () => plain, 10);
    new PredictionOverlay(term, FONT).show(0, 8, "abcd", true);
    expect(rendered.map((el) => [el.dataset.row, el.dataset.x, el.textContent])).toEqual([["0", "8", "ab"], ["1", "0", "cd"], ["1", "2", " "]]);
  });
  it("erases a deleted suffix while keeping the cursor before the padding", () => {
    const { term, rendered } = fakeTerm(DARK, () => plain);
    new PredictionOverlay(term, FONT).show(0, 2, "ac  ", true, 1);
    expect(rendered.map(el => [el.dataset.x, el.textContent])).toEqual([["2", "ac  "], ["3", "c"]]);
  });
  it("the block cursor is the theme's cursor and cursor accent", () => {
    const { term, rendered } = fakeTerm(DARK, () => plain);
    new PredictionOverlay(term, FONT).show(0, 0, "a", true);
    const cursor = rendered.find((el) => el.dataset.x === "1")!;
    expect(cursor.style.background).toBe("rgb(240, 238, 241)");              // DARK.cursor #f0eef1
    expect(cursor.style.color).toBe("rgb(24, 24, 23)");                      // DARK.cursorAccent #181817
  });
});

it("paints alternate-screen text and cursor outside xterm's hidden decoration layer", () => {
  const { term, rendered } = fakeTerm(DARK, () => plain);
  const element = document.createElement("div");
  element.innerHTML = '<div class="xterm-screen"></div>';
  Object.assign(term, { element, _core: { _renderService: { dimensions: { css: { cell: { width: 8, height: 18 } } } } } });
  Object.assign(term.buffer.active, { type: "alternate", viewportY: 0 });
  const overlay = new PredictionOverlay(term, FONT);
  overlay.show(2, 2, "hell ", true, 2);
  const runs = element.querySelectorAll<HTMLElement>(".prediction-overlay-run");
  expect(rendered).toHaveLength(0);
  expect(runs).toHaveLength(2);
  expect(runs[0]!.textContent).toBe("hell ");
  expect(runs[0]!.style.left).toBe("16px");
  expect(runs[0]!.style.top).toBe("36px");
  expect(runs[0]!.style.width).toBe("40px");
  expect(runs[1]!.style.left).toBe("32px");
  expect(runs[1]!.textContent).toBe("l");
  overlay.clear();
  expect(element.querySelectorAll(".prediction-overlay-run")).toHaveLength(0);
});
