import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { Terminal } from "@xterm/xterm";
import { BgCorners, cornerRadiusCss, roundedCorner, spanCorners } from "../src/client/bg-corners";
import { xtermDomRenderer } from "../src/client/overscan-rows";

/// Background blocks round their outer corners (bg-corners.ts): the rule, pure, and then against the REAL
/// xterm.js the product ships — its private DOM renderer's row factory builds the spans this rounds. Where
/// the rounded corners land in pixels only a browser can see: `e2e/term-bg-corners-check.mjs`.

beforeAll(() => {
  (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
});

/// A grid of strings, `#` filled and anything else default, as the rule's `filled`.
const grid = (rows: string[]) => (x: number, y: number) => rows[y]?.[x] === "#";

describe("spanCorners — a filled cell rounds a corner when both neighbours at that corner are default", () => {
  it("rounds all four corners of a lone filled run", () => {
    const f = grid([
      "......",
      "..###.",
      "......"]);
    expect(spanCorners(f, 2, 4, 1)).toEqual({ tl: true, tr: true, br: true, bl: true });
  });

  it("rounds only the OUTER corners of a block two rows tall", () => {
    const f = grid([
      "####..",
      "####..",
      "......"]);
    expect(spanCorners(f, 0, 3, 0)).toEqual({ tl: true, tr: true, br: false, bl: false });
    expect(spanCorners(f, 0, 3, 1)).toEqual({ tl: false, tr: false, br: true, bl: true });
  });

  it("leaves a run with a filled horizontal neighbour square on that side — a word inside a line", () => {
    const f = grid([
      "......",
      "######",
      "......"]);
    // Cells 2-3 as their own span (another shade of the same line): filled on both sides.
    expect(spanCorners(f, 2, 3, 1)).toEqual({ tl: false, tr: false, br: false, bl: false });
    expect(spanCorners(f, 0, 1, 1)).toEqual({ tl: true, tr: false, br: false, bl: true });
    expect(spanCorners(f, 4, 5, 1)).toEqual({ tl: false, tr: true, br: true, bl: false });
  });

  it("rounds the convex corners of an L and leaves its concave one alone", () => {
    const f = grid([
      "##....",
      "####..",
      "......"]);
    expect(spanCorners(f, 0, 1, 0)).toEqual({ tl: true, tr: true, br: false, bl: false });
    // Row 1's top-right: its right neighbour and the cell above (x=3, y=0) are default.
    expect(spanCorners(f, 0, 3, 1)).toEqual({ tl: false, tr: true, br: true, bl: true });
  });

  it("treats the grid's edges as default, and never rounds a default run", () => {
    const f = grid(["###"]);
    expect(spanCorners(f, 0, 2, 0)).toEqual({ tl: true, tr: true, br: true, bl: true });
    expect(spanCorners(grid(["..."]), 0, 2, 0)).toEqual({ tl: false, tr: false, br: false, bl: false });
  });
});

describe("cornerRadiusCss", () => {
  it("is empty with no corner, else the four radii clockwise from the top left", () => {
    expect(cornerRadiusCss({ tl: false, tr: false, br: false, bl: false })).toBe("");
    expect(cornerRadiusCss({ tl: true, tr: false, br: true, bl: false })).toBe("3px 0px 3px 0px");
    expect(cornerRadiusCss({ tl: true, tr: true, br: true, bl: true }, 3)).toBe("3px 3px 3px 3px");
  });
});

// ── a real xterm.js ──────────────────────────────────────────────────────────────────────────────────

const E = "\x1b";
const RED = `${E}[48;5;52m`, GREEN = `${E}[48;5;22m`, WORD = `${E}[48;5;28m`, OFF = `${E}[m`;
let open: Terminal[] = [];
afterEach(() => { for (const t of open) t.dispose(); open = []; document.body.replaceChildren(); });

async function terminal(content: string, cols = 12, rows = 6): Promise<Terminal> {
  const el = document.createElement("div");
  document.body.append(el);
  const term = new Terminal({ cols, rows });
  open.push(term);
  term.open(el);
  await new Promise<void>((r) => term.write(content, r));
  return term;
}

/// Each screen row's spans as `[text, border-radius]`.
function radii(term: Terminal): Array<Array<[string, string]>> {
  return [...term.element!.querySelectorAll(".xterm-rows > div")].map((row) =>
    [...row.children].map((s) => [s.textContent ?? "", (s as HTMLElement).style.borderRadius]));
}

describe("BgCorners over a real xterm.js", () => {
  it("rounds a diff block's outer corners — a removed line over an added one with a word highlighted", async () => {
    const term = await terminal(
      `ctx\r\n${RED}-aaaa   ${OFF}\r\n${GREEN}+bb${WORD}cc${GREEN}dd ${OFF}\r\nctx\r\n`);
    const corners = new BgCorners(term);
    xtermDomRenderer(term)!.renderRows(0, term.rows - 1);
    const r = radii(term);
    expect(r[0]).toEqual([["ctx", ""]]);
    // The removed line: its top corners only — green is below it.
    expect(r[1]).toEqual([["-aaaa   ", "3px 3px 0px 0px"]]);
    // The added line: its bottom corners only, and the highlighted word square.
    expect(r[2]).toEqual([["+bb", "0px 0px 0px 3px"], ["cc", ""], ["dd ", "0px 0px 3px 0px"]]);
    expect(r[3]).toEqual([["ctx", ""]]);
    corners.dispose();
  });

  it("keeps a row that was NOT redrawn right when its neighbour changes", async () => {
    const term = await terminal(`ctx\r\n${RED}-aaaa   ${OFF}\r\n`);
    const corners = new BgCorners(term);
    const r = xtermDomRenderer(term)!;
    r.renderRows(0, term.rows - 1);
    expect(radii(term)[1]).toEqual([["-aaaa   ", "3px 3px 3px 3px"]]);
    // A line lands under it and ONLY that row is redrawn, as xterm.js does for new output.
    await new Promise<void>((res) => term.write(`${GREEN}+bbbbbbb${OFF}\r\n`, res));
    r.renderRows(2, 2);
    expect(radii(term)[1]).toEqual([["-aaaa   ", "3px 3px 0px 0px"]]);
    expect(radii(term)[2]).toEqual([["+bbbbbbb", "0px 0px 3px 3px"]]);
    corners.dispose();
  });

  it("finds a wide glyph's cells: the run's right edge is the glyph's second cell", async () => {
    // xterm.js trims the row after the glyph's FIRST cell (cell 1), so its second (cell 2, red too) is
    // never read; read as ending at cell 1, the span's right neighbour would be red and stay square.
    // jsdom measures no glyph, so `a` and `字` share one span here; a browser draws them as two
    // (`e2e/term-bg-corners-check.mjs`).
    const term = await terminal(`\r\n${RED}a字${OFF}\r\n`);
    const corners = new BgCorners(term);
    xtermDomRenderer(term)!.renderRows(0, term.rows - 1);
    expect(radii(term)[1]).toEqual([["a字", "3px 3px 3px 3px"]]);
    corners.dispose();
  });

  it("leaves a selected span square — the selection is painted over the block", async () => {
    const term = await terminal(`\r\n${RED}-aaaa   ${OFF}\r\n`);
    const corners = new BgCorners(term);
    const r = xtermDomRenderer(term)! as unknown as { _rowFactory: { handleSelectionChanged(s: [number, number], e: [number, number], col: boolean): void };
      renderRows(a: number, b: number): void };
    r._rowFactory.handleSelectionChanged([0, 1], [8, 1], false);
    r.renderRows(0, term.rows - 1);
    expect(radii(term)[1]!.every(([, radius]) => radius === "")).toBe(true);
    corners.dispose();
  });

  it("puts xterm.js back exactly as it was when disposed", async () => {
    const term = await terminal(`\r\n${RED}-aaaa   ${OFF}\r\n`);
    const r = xtermDomRenderer(term)! as unknown as { _rowFactory: Record<string, unknown> };
    const doc = r._rowFactory._document;
    const corners = new BgCorners(term);
    expect(Object.prototype.hasOwnProperty.call(r._rowFactory, "createRow")).toBe(true);
    corners.dispose();
    expect(Object.prototype.hasOwnProperty.call(r._rowFactory, "createRow")).toBe(false);
    expect(r._rowFactory._document).toBe(doc);
    xtermDomRenderer(term)!.renderRows(0, term.rows - 1);
    expect(radii(term)[1]).toEqual([["-aaaa   ", ""]]);
  });
});

describe("a table's light corners are drawn as their rounded arcs", () => {
  it("maps ┌ ┐ └ ┘ to ╭ ╮ ╰ ╯ and nothing else", () => {
    expect([..."┌┐└┘"].map((c) => String.fromCodePoint(roundedCorner(c.codePointAt(0)!))).join("")).toBe("╭╮╰╯");
    // The joints, the lines, heavy and double corners (no rounded form), the arcs themselves, text.
    for (const c of "─│┬┴├┤┼┏┓┗┛╔╗╚╝╭╮╰╯a ") expect(roundedCorner(c.codePointAt(0)!)).toBe(c.codePointAt(0));
  });

  it("draws a table's outer corners rounded and its joints as they are — on screen only", async () => {
    const table = ["┌──┬──┐", "│ab│cd│", "├──┼──┤", "└──┴──┘"];
    const term = await terminal(`${table.join("\r\n")}\r\n`);
    const corners = new BgCorners(term);
    xtermDomRenderer(term)!.renderRows(0, term.rows - 1);
    const shown = () => radii(term).slice(0, 4).map((row) => row.map(([text]) => text).join("").trimEnd());
    expect(shown()).toEqual(["╭──┬──╮", "│ab│cd│", "├──┼──┤", "╰──┴──╯"]);
    // The buffer — what a copy, the selection and links read — keeps the characters the program wrote.
    const buf = term.buffer.active;
    expect(table.map((_, y) => buf.getLine(y)!.translateToString(true))).toEqual(table);
    term.selectAll();
    expect(term.getSelection()).toContain("┌──┬──┐");
    corners.dispose();
    xtermDomRenderer(term)!.renderRows(0, term.rows - 1);
    expect(shown()[0]).toBe("┌──┬──┐");
  });

  it("keeps a corner's colours and attributes — only the code point changes", async () => {
    const term = await terminal(`${RED}\x1b[1m┌┐${OFF}\r\n`);
    const corners = new BgCorners(term);
    xtermDomRenderer(term)!.renderRows(0, term.rows - 1);
    const span = term.element!.querySelector(".xterm-rows > div > span") as HTMLElement;
    expect(span.textContent).toBe("╭╮");
    expect(span.classList.contains("xterm-bold")).toBe(true);
    expect(span.className).toMatch(/xterm-bg-52/);
    corners.dispose();
  });
});


it('draws horizontal box rules as one cell-aligned stroke without changing text or buffer cells',async()=>{
 const term=await terminal('─'.repeat(8)+'\r\n--- text ─',12,6);
 const corners=new BgCorners(term);
 const r=xtermDomRenderer(term)! as unknown as {dimensions:{css:{cell:{width:number}}}};
 r.dimensions.css.cell.width=8.4;
 xtermDomRenderer(term)!.renderRows(0,term.rows-1);
 const rule=term.element!.querySelector<HTMLElement>('.xterm-horizontal-rule')!;
 expect(rule.textContent).toBe('─'.repeat(8));
 expect(parseFloat(rule.style.width)).toBeCloseTo(8*8.4);
 expect(term.buffer.active.getLine(0)!.translateToString(true)).toBe('─'.repeat(8));
 expect([...term.element!.querySelectorAll('.xterm-horizontal-rule')].every(el=>/^─+$/.test(el.textContent!))).toBe(true);
 expect(term.element!.querySelector('.xterm-rows')!.textContent).toContain('--- text');
 corners.dispose();
});
