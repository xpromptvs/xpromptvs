import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { Terminal } from "@xterm/xterm";
import { suppressHiddenDomRendering } from "../src/client/hidden-dom-render";
import { RevealDraw } from "../src/client/reveal-draw";
import { RowCache } from "../src/client/row-cache";
import { xtermDomRenderer } from "../src/client/overscan-rows";

/// A terminal coming into view is drawn before its first paint (reveal-draw.ts). In a browser that means
/// INSIDE the ResizeObserver callback of the rendering update that shows it — so here the observer is
/// fired by hand and the rows must be right SYNCHRONOUSLY, with no frame let run. The browser measurement
/// (the painted frame, both engines) is e2e/term-reveal-check.mjs. This also asserts the PRIVATE xterm.js
/// members it reads against the REAL xterm.js the product ships.

/// Every glyph's width as xterm.js measures it (`offsetWidth`); 0 is a terminal inside `display: none`.
let glyphPx = 7;

type Observer = { cb: (e: unknown[]) => void; targets: Element[] };
/// xterm.js pauses its renderer by an IntersectionObserver on `.xterm-screen`; fired by hand.
const ios: Observer[] = [];
/// RevealDraw's ResizeObserver on `.xterm`; fired by hand with the element's new content box.
const ros: Observer[] = [];
const outOfView = (el: Element) => { for (const o of ios) if (o.targets.includes(el)) o.cb([{ isIntersecting: false, intersectionRatio: 0, target: el }]); };
const resized = (el: Element, width: number, height: number) => {
  for (const o of ros) if (o.targets.includes(el)) o.cb([{ target: el, contentRect: { width, height } }]);
};
const stub = (list: Observer[]) => class {
  private readonly o: Observer;
  constructor(cb: (e: unknown[]) => void) { this.o = { cb, targets: [] }; list.push(this.o); }
  observe(el: Element) { this.o.targets.push(el); }
  unobserve(el: Element) { this.o.targets = this.o.targets.filter((t) => t !== el); }
  disconnect() { this.o.targets = []; }
};

beforeAll(() => {
  (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  Object.defineProperty(HTMLElement.prototype, "offsetWidth", { configurable: true, get(this: HTMLElement) { return glyphPx * (this.textContent?.length ?? 0); } });
  for (const [name, list] of [["IntersectionObserver", ios], ["ResizeObserver", ros]] as const) {
    (window as unknown as Record<string, unknown>)[name] = (globalThis as unknown as Record<string, unknown>)[name] = stub(list);
  }
});

let opened: Terminal[] = [];
afterEach(() => { for (const t of opened) t.dispose(); opened = []; document.body.replaceChildren(); glyphPx = 7; ios.length = 0; ros.length = 0; });

function terminal(): Terminal {
  const el = document.createElement("div");
  document.body.append(el);
  const term = new Terminal({ cols: 30, rows: 8, scrollback: 200, allowProposedApi: true });
  opened.push(term);
  term.open(el);
  return term;
}
const write = (t: Terminal, s: string) => new Promise<void>((r) => t.write(s, r));
const html = (t: Terminal) => [...t.element!.querySelectorAll(".xterm-rows > div")].map((d) => d.innerHTML);
const text = (t: Terminal) => [...t.element!.querySelectorAll(".xterm-rows > div")].map((d) => d.textContent);
const screen = (t: Terminal) => t.element!.querySelector(".xterm-screen")!;
const renderRows = (t: Terminal) => xtermDomRenderer(t) as unknown as { renderRows(a: number, b: number): void };
/// Let the redraws xterm.js scheduled itself (on animation frames) run.
const settle = () => new Promise<void>((r) => setTimeout(r, 60));
type Service = { _isPaused: boolean; _handleIntersectionChange: unknown; _needsFullRefresh: boolean;
  _renderDebouncer: { _rowStart?: number; _animationFrame?: number; _innerRefresh: unknown } };
const service = (t: Terminal) => (t as unknown as { _core: { _renderService: Service } })._core._renderService;

const E = "\x1b";
const lines = (tag: string, n: number) =>
  Array.from({ length: n }, (_, i) => `${E}[3${1 + (i % 6)}m${tag} ${i}${E}[m plain ${i % 3 ? "x" : "字"}`).join("\r\n");

/// A terminal hidden and PAUSED by xterm.js's own observer, then given output that scrolls: its rows are
/// rebuilt anyway (the selection service's redraw ignores the pause), from glyphs measured 0. `reference`
/// is the same output built in view.
async function hiddenWithOutput(): Promise<{ t: Terminal; reference: Terminal; reveal: RevealDraw; cache: RowCache }> {
  const t = terminal();
  const cache = new RowCache(t);
  const reveal = new RevealDraw(t);
  await write(t, lines("before", 12));
  resized(t.element!, 240, 136);     // shown
  await settle();
  resized(t.element!, 0, 0);         // display: none
  outOfView(screen(t));
  glyphPx = 0;
  await write(t, `\r\n${lines("hidden", 12)}`);
  await settle();
  glyphPx = 7;
  const reference = terminal();
  await write(reference, `${lines("before", 12)}\r\n${lines("hidden", 12)}`);
  renderRows(reference).renderRows(0, reference.rows - 1);
  await settle();
  return { t, reference, reveal, cache };
}

describe("RevealDraw over a real xterm.js", () => {
  it("finds the members it reads: the pause, xterm.js's own resume, and the pending frame", async () => {
    const t = terminal();
    const s = service(t);
    expect(typeof s._isPaused).toBe("boolean");
    expect(typeof s._handleIntersectionChange).toBe("function");
    expect(typeof s._renderDebouncer._innerRefresh).toBe("function");
    t.refresh(0, t.rows - 1);
    expect(s._renderDebouncer._rowStart, "a refresh pends its rows").toBe(0);
    expect(s._renderDebouncer._animationFrame, "…on an animation frame").not.toBeUndefined();
    outOfView(screen(t));
    expect(s._isPaused, "xterm.js's observer pauses it").toBe(true);
  });

  it("a paused hidden terminal still rebuilds its rows on output — spaced out (the case this exists for)", async () => {
    const { t, reference } = await hiddenWithOutput();
    expect(service(t)._isPaused).toBe(true);
    expect(text(t), "the rows show the CURRENT text").toEqual(text(reference));
    expect(html(t), "built from glyphs measured 0, they differ — else this test proves nothing").not.toEqual(html(reference));
  });

  it("coming into view draws every row at once — inside the observer's callback, before any frame", async () => {
    const { t, reference } = await hiddenWithOutput();
    resized(t.element!, 240, 136);
    // No await: what a paint after this callback would show.
    expect(service(t)._isPaused, "resumed as xterm.js's own observer would").toBe(false);
    expect(html(t)).toEqual(html(reference));
    expect(service(t)._renderDebouncer._rowStart, "nothing left pending for a later frame").toBeUndefined();
    await settle();
    expect(html(t)).toEqual(html(reference));
  });

  it("only coming into view draws: a resize while shown or while hidden does not", async () => {
    const { t } = await hiddenWithOutput();
    let passes = 0;
    const r = renderRows(t), orig = r.renderRows.bind(r);
    r.renderRows = (a, b) => { passes++; orig(a, b); };
    resized(t.element!, 0, 0);
    expect(passes, "still hidden").toBe(0);
    resized(t.element!, 240, 136);
    expect(passes, "came into view").toBe(1);
    resized(t.element!, 300, 136);
    expect(passes, "a resize while shown").toBe(1);
    resized(t.element!, 0, 0);
    resized(t.element!, 240, 136);
    expect(passes, "hidden and shown again").toBe(2);
  });

  it("a fresh instance written hidden, before xterm.js's observer ever paused it, is drawn right too", async () => {
    // A hidden tab's snapshot: built in the frame before the first IntersectionObserver report, so nothing
    // is pending in xterm.js when it is shown — only a redraw on coming into view fixes its rows.
    // The CELL keeps its width while hidden — a browser measures it on a canvas — so only the glyphs are 0.
    const t = terminal();
    const cache = new RowCache(t);
    const reveal = new RevealDraw(t);
    glyphPx = 0;
    await write(t, lines("snap", 12));
    renderRows(t).renderRows(0, t.rows - 1);   // xterm.js's first render, in the frame before it pauses
    await settle();
    glyphPx = 7;
    const reference = terminal();
    await write(reference, lines("snap", 12));
    renderRows(reference).renderRows(0, reference.rows - 1);
    await settle();
    expect(html(t), "built unmeasured, it differs").not.toEqual(html(reference));
    resized(t.element!, 240, 136);
    expect(html(t)).toEqual(html(reference));
    reveal.dispose();
    cache.dispose();
  });

  it("disposed, it draws nothing", async () => {
    const { t, reference, reveal } = await hiddenWithOutput();
    reveal.dispose();
    resized(t.element!, 240, 136);
    expect(html(t)).not.toEqual(html(reference));
  });

  it("without xterm.js's internals (an upgrade) it still asks for every row", () => {
    const el = document.createElement("div");
    document.body.append(el);
    const asked: [number, number][] = [];
    const fake = { element: el, rows: 5, refresh: (a: number, b: number) => asked.push([a, b]) };
    const reveal = new RevealDraw(fake as unknown as Terminal);
    resized(el, 100, 50);
    expect(asked).toEqual([[0, 4]]);
    reveal.dispose();
  });
});


describe("hidden DOM render suppression", () => {
  it("keeps parsing, replies and resize live without building rows, then reveals current content", async () => {
    const t = terminal();
    let shown = false;
    t.element!.getClientRects = () => (shown ? [{}] : []) as unknown as DOMRectList;
    const r = renderRows(t), original = r.renderRows;
    let paints = 0;
    r.renderRows = function(a, b) { paints++; original.call(this, a, b); };
    const restore = suppressHiddenDomRendering(t);
    const reveal = new RevealDraw(t);
    const replies: string[] = [];
    t.onData(bytes => replies.push(bytes));
    await write(t, lines("hidden-live", 20) + "\x1b[6n");
    t.resize(32, 9);
    r.renderRows(0, t.rows - 1);
    await settle();
    expect(paints).toBe(0);
    expect(t.buffer.active.getLine(t.buffer.active.baseY + t.buffer.active.cursorY)?.translateToString(true)).toContain("hidden-live");
    expect(replies.some(bytes => /\x1b\[\d+;\d+R/.test(bytes))).toBe(true);
    shown = true;
    resized(t.element!, 240, 136);
    expect(paints).toBeGreaterThan(0);
    expect(text(t).join("\n")).toContain("hidden-live");
    restore(); reveal.dispose();
    shown = false;
    const before = paints;
    r.renderRows(0, t.rows - 1);
    expect(paints).toBe(before + 1);
  });
});
