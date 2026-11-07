import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { Terminal } from "@xterm/xterm";
import { RowCache } from "../src/client/row-cache";
import { BgCorners } from "../src/client/bg-corners";
import { xtermDomRenderer } from "../src/client/overscan-rows";

/// The row cache (row-cache.ts) lets a redraw reuse a row's spans when the row it is about to build was
/// just on screen, built from the same cells and the same state. Its whole risk is a STALE row, so the
/// main test is DIFFERENTIAL: the same writes, scrolls, selections, theme changes and partial redraws go
/// to a terminal with the cache and one without, and after every step the two render IDENTICAL HTML.

/// Every glyph's width as xterm.js measures it (`WidthCache`: a run of it, by `offsetWidth`). jsdom lays
/// nothing out, so it is stubbed: 0 is a terminal inside `display: none` (a hidden tab), where a browser
/// measures every glyph 0 and xterm.js spaces it by a whole cell.
let glyphPx = 7;

/// IntersectionObservers, never fired: xterm.js pauses its renderer by one, so a terminal here never pauses.
/// Coming into view is reveal-draw.ts's (`reveal-draw.test.ts`).
const observers: { cb: (e: Partial<IntersectionObserverEntry>[]) => void; targets: Element[] }[] = [];

beforeAll(() => {
  (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
  Object.defineProperty(HTMLElement.prototype, "offsetWidth", { configurable: true, get(this: HTMLElement) { return glyphPx * (this.textContent?.length ?? 0); } });
  (window as unknown as { IntersectionObserver: unknown }).IntersectionObserver = (globalThis as unknown as { IntersectionObserver: unknown }).IntersectionObserver = class {
    private readonly o: (typeof observers)[number];
    constructor(cb: (e: Partial<IntersectionObserverEntry>[]) => void) { this.o = { cb, targets: [] }; observers.push(this.o); }
    observe(el: Element) { this.o.targets.push(el); }
    unobserve(el: Element) { this.o.targets = this.o.targets.filter((t) => t !== el); }
    disconnect() { this.o.targets = []; }
  };
});

let opened: Terminal[] = [];
afterEach(() => { for (const t of opened) t.dispose(); opened = []; document.body.replaceChildren(); glyphPx = 7; observers.length = 0; });

function terminal(cols = 30, rows = 8): Terminal {
  const el = document.createElement("div");
  document.body.append(el);
  const term = new Terminal({ cols, rows, scrollback: 200, allowProposedApi: true });
  opened.push(term);
  term.open(el);
  return term;
}
const write = (t: Terminal, s: string) => new Promise<void>((r) => t.write(s, r));
type Renderer = { renderRows(a: number, b: number): void;
  _rowFactory: { handleSelectionChanged(s: [number, number] | undefined, e: [number, number] | undefined, col: boolean): void } };
const renderer = (t: Terminal) => xtermDomRenderer(t) as unknown as Renderer;
/// Scroll the view by `k` lines. `Terminal.scrollLines` goes through the Viewport's pixel position, and
/// jsdom measures a cell 0 px tall, so it moves nothing there: this is the buffer move it ends in.
const scroll = (t: Terminal, k: number) =>
  (t as unknown as { _core: { _bufferService: { scrollLines(k: number): void } } })._core._bufferService.scrollLines(k);
const toBottom = (t: Terminal) => scroll(t, t.buffer.active.baseY - t.buffer.active.viewportY);
const widthCache = (t: Terminal) => (xtermDomRenderer(t) as unknown as { _widthCache: { clear(): void } })._widthCache;
const html = (t: Terminal) => [...t.element!.querySelectorAll(".xterm-rows > div")].map((d) => d.innerHTML);
const spans = (t: Terminal) => [...t.element!.querySelectorAll(".xterm-rows > div > span")];

const E = "\x1b";
/// Lines with everything a row's picture depends on: colours, backgrounds, bold/italic/underline styles,
/// a wide glyph, a combining mark, an emoji — and a PALETTE underline colour, the one theme colour the
/// row factory writes inline (every other palette colour is a class), so a theme change reaches the markup.
/// (Its single-cell glyph is a table's corner or joint — bg-corners.ts draws a corner rounded, a glyph a
/// reused row must carry exactly as a built one does.)
const line = (i: number) =>
  `${E}[38;5;${(i * 7) % 200 + 20}m${String(i).padStart(3)} ${E}[1mbold${E}[22m ${E}[48;5;${i % 3 ? 22 : 52}m bg ${E}[49m ` +
  `${E}[4:3m${E}[58;5;1mcurly${E}[59m${E}[24m 字 é ${i % 4 === 0 ? "🙂" : ["┌", "┘", "┼"][i % 3]} ${E}[3mit${E}[m`;

/// Let the redraws xterm.js scheduled itself (on animation frames — after a write, the cursor's rows) run.
const settle = () => new Promise<void>((r) => setTimeout(r, 60));

/// Apply `step` to both terminals, let each settle, and require identical rendered rows. Settling each
/// before comparing matters: a redraw xterm.js scheduled for one terminal but not yet run for the other
/// is a difference in TIME, not in what the two render.
async function same(a: Terminal, b: Terminal, what: string, step: (t: Terminal) => void | Promise<void>): Promise<void> {
  await step(a);
  await settle();
  await step(b);
  await settle();
  expect(html(a), what).toEqual(html(b));
}

async function differential(withCorners: boolean): Promise<void> {
  const a = terminal(), b = terminal();
  const cache = new RowCache(a);
  const corners = withCorners ? [new BgCorners(a), new BgCorners(b)] : [];
  const full = (t: Terminal) => renderer(t).renderRows(0, t.rows - 1);
  await same(a, b, "the first screen", async (t) => { await write(t, Array.from({ length: 40 }, (_, i) => line(i)).join("\r\n")); full(t); });
  for (const k of [-1, -3, -1, 2, -5, 1, 7]) {
    const y = a.buffer.active.viewportY;
    await same(a, b, `a scroll by ${k}`, (t) => { scroll(t, k); full(t); });
    expect(a.buffer.active.viewportY, `the scroll by ${k} moved the view`).toBe(y + k);
  }
  await same(a, b, "output arriving while scrolled back", async (t) => { scroll(t, -3); await write(t, `\r\n${line(99)}\r\n${line(98)}`); full(t); });
  await same(a, b, "a scroll after it", (t) => { scroll(t, -2); full(t); });
  await same(a, b, "a line changed in place, redrawn alone", async (t) => {
    toBottom(t);
    full(t);
    await write(t, `${E}[3;1H${E}[31mCHANGED${E}[m`);
    renderer(t).renderRows(2, 2);
  });
  await same(a, b, "the same line's colour changed, text the same", async (t) => {
    await write(t, `${E}[3;1H${E}[32mCHANGED${E}[m`);
    renderer(t).renderRows(2, 2);
  });
  await same(a, b, "an underline added in place", async (t) => {
    await write(t, `${E}[3;1H${E}[32;4:3mCHANGED${E}[m`);
    renderer(t).renderRows(2, 2);
  });
  // The same cells, colours and flags: only the underline's STYLE, which lives outside the line's cells.
  await same(a, b, "only that underline's style changed", async (t) => {
    await write(t, `${E}[3;1H${E}[32;4:4mCHANGED${E}[m`);
    renderer(t).renderRows(2, 2);
  });
  await same(a, b, "a selection across three rows", (t) => {
    const top = t.buffer.active.viewportY;
    renderer(t)._rowFactory.handleSelectionChanged([4, top + 2], [9, top + 4], false);
    full(t);
  });
  await same(a, b, "a scroll with the selection held", (t) => { scroll(t, -1); full(t); });
  await same(a, b, "the selection cleared", (t) => { renderer(t)._rowFactory.handleSelectionChanged(undefined, undefined, false); full(t); });
  await same(a, b, "a theme change", (t) => { t.options.theme = { red: "#ff0000", green: "#00ff00", background: "#101010" }; full(t); });
  await same(a, b, "a scroll after the theme change", (t) => { scroll(t, 1); full(t); });
  // Output built while nothing can be measured (a hidden tab: every NEW glyph measures 0 — xterm.js caches
  // no 0), then redrawn once it can: the redraw must be what xterm.js builds then, not the spaced-out rows.
  await same(a, b, "output built unmeasured, then redrawn measured", async (t) => {
    glyphPx = 0;
    await write(t, `\r\nΣΨΩ ÆØÅ þð\r\nλμν ßœ`);
    full(t);
    glyphPx = 7;
    full(t);
  });
  // xterm.js clears its width cache on a change of font or pixel ratio; the rows must follow it.
  await same(a, b, "the width cache cleared with every glyph a pixel wider", (t) => { glyphPx = 8; widthCache(t).clear(); full(t); glyphPx = 7; });
  await same(a, b, "…and cleared back", (t) => { widthCache(t).clear(); full(t); });
  // The cursor drawn (as after a keystroke), then hidden and shown where it stands.
  await same(a, b, "the cursor hidden where it stands", async (t) => {
    (t as unknown as { _core: { coreService: { isCursorInitialized: boolean } } })._core.coreService.isCursorInitialized = true;
    const y = t.buffer.active.cursorY;
    renderer(t).renderRows(y, y);
    await write(t, `${E}[?25l`);
    renderer(t).renderRows(y, y);
  });
  await same(a, b, "…and shown again", async (t) => {
    const y = t.buffer.active.cursorY;
    await write(t, `${E}[?25h`);
    renderer(t).renderRows(y, y);
  });
  await same(a, b, "the cursor moving, its two rows redrawn", async (t) => {
    toBottom(t);
    full(t);
    const y = t.buffer.active.cursorY;
    await write(t, `${E}[${y};1H`);
    renderer(t).renderRows(Math.max(0, y - 1), y);
  });
  cache.dispose();
  for (const c of corners) c.dispose();
}

describe("RowCache over a real xterm.js — the cached terminal renders EXACTLY what a plain one does", () => {
  it("through scrolls, output, in-place changes, selection, a theme change and the cursor", async () => {
    await differential(false);
  });

  it("…and with the background corners rounding over it (bg-corners.ts), neighbours restyled included", async () => {
    await differential(true);
  });
});

describe("RowCache — what it saves and what it never does", () => {
  it("REUSES the rows a scroll only moves: after a one-line scroll every row but one keeps its spans", async () => {
    const t = terminal();
    const cache = new RowCache(t);
    await write(t, Array.from({ length: 40 }, (_, i) => line(i)).join("\r\n"));
    renderer(t).renderRows(0, t.rows - 1);
    const before = new Set(spans(t));
    const reused = cache.stats.reused, built = cache.stats.built, y = t.buffer.active.viewportY;
    scroll(t, -1);
    renderer(t).renderRows(0, t.rows - 1);
    expect(t.buffer.active.viewportY).toBe(y - 1);
    const after = spans(t);
    const kept = after.filter((s) => before.has(s)).length;
    const perRow = after.length / t.rows;
    expect(kept).toBeGreaterThanOrEqual(Math.floor(perRow * (t.rows - 1)) - 1);
    // xterm.js may also have scheduled its own redraw of the scroll; each pass reuses all but the new row.
    expect(cache.stats.reused - reused).toBeGreaterThanOrEqual(t.rows - 1);
    expect(cache.stats.built - built).toBeLessThanOrEqual(2);
    cache.dispose();
  });

  it("never takes a row's spans for a partial redraw that does not include that row — identical lines stay drawn", async () => {
    const t = terminal();
    const cache = new RowCache(t);
    await write(t, "same text here\r\nother\r\nsame text here\r\n");
    renderer(t).renderRows(0, t.rows - 1);
    const third = t.element!.querySelectorAll(".xterm-rows > div")[2]!;
    const thirdSpans = [...third.children];
    // Row 1 changes and ONLY row 1 is redrawn; row 3 was built from the same kind of cells.
    await write(t, `${E}[2;1H${E}[Ksame text here`);
    renderer(t).renderRows(1, 1);
    expect([...third.children]).toEqual(thirdSpans);
    expect(third.textContent).toContain("same text here");
    cache.dispose();
  });

  it("never takes a row's spans in the window between a scroll and its full redraw — a row redrawn alone there", async () => {
    const t = terminal();
    const cache = new RowCache(t);
    await write(t, Array.from({ length: 40 }, (_, i) => line(i)).join("\r\n"));
    renderer(t).renderRows(0, t.rows - 1);
    const rows = () => [...t.element!.querySelectorAll(".xterm-rows > div")];
    const third = [...rows()[2]!.children];
    const text = rows()[2]!.textContent;
    // The view moves up a line; xterm.js's own redraw of it is only SCHEDULED. Row 3 is redrawn alone
    // first (as the cursor's row is): the line it now shows is still drawn in row 2, which this pass does
    // not redraw — so row 2 must keep its spans, not be emptied into row 3.
    scroll(t, -1);
    renderer(t).renderRows(3, 3);
    expect([...rows()[2]!.children]).toEqual(third);
    expect(rows()[2]!.textContent).toBe(text);
    expect(rows()[3]!.textContent).toBe(text);
    cache.dispose();
  });

  it("reuses nothing while a decoration exists — the prediction overlay's are drawn per cell", async () => {
    const t = terminal();
    const cache = new RowCache(t);
    await write(t, Array.from({ length: 40 }, (_, i) => line(i)).join("\r\n"));
    renderer(t).renderRows(0, t.rows - 1);
    const marker = t.registerMarker(0)!;
    const deco = t.registerDecoration({ marker, x: 0, width: 2 })!;
    const reused = cache.stats.reused;
    scroll(t, -1);
    renderer(t).renderRows(0, t.rows - 1);
    expect(cache.stats.reused).toBe(reused);
    deco.dispose();
    cache.dispose();
  });

  it("puts xterm.js back exactly as it was when disposed", async () => {
    const t = terminal();
    const r = xtermDomRenderer(t)! as unknown as { renderRows: unknown; _rowFactory: Record<string, unknown> };
    const cache = new RowCache(t);
    expect(Object.prototype.hasOwnProperty.call(r, "renderRows")).toBe(true);
    expect(Object.prototype.hasOwnProperty.call(r._rowFactory, "createRow")).toBe(true);
    cache.dispose();
    expect(Object.prototype.hasOwnProperty.call(r, "renderRows")).toBe(false);
    expect(Object.prototype.hasOwnProperty.call(r._rowFactory, "createRow")).toBe(false);
  });
});
