import { beforeAll, describe, expect, it } from "vitest";
import { Terminal } from "@xterm/xterm";
import { OVERSCAN_MAX_ROWS, OverscanRows, overscanCount, xtermDomRenderer } from "../src/client/overscan-rows";

/// The rows beyond xterm.js's screen (overscan-rows.ts) are built by its PRIVATE DOM renderer's row
/// factory. This asserts those internals against the REAL xterm.js the product ships, and that the rows
/// hold the right lines. Where they land and what clips them only a browser can see:
/// `e2e/term-smooth-scroll-check.mjs`, the inset arm.

beforeAll(() => {
  (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
});

describe("overscanCount", () => {
  it("reaches the clip edge and adds the row a shift of up to a row uncovers", () => {
    expect(overscanCount(0, 16)).toBe(1);
    expect(overscanCount(8, 16)).toBe(2);
    expect(overscanCount(16, 16)).toBe(2);
    expect(overscanCount(16.5, 16)).toBe(3);
    expect(overscanCount(20, 20)).toBe(2);
    expect(overscanCount(-5, 16)).toBe(1);   // the grid overhangs the clip edge
  });

  it("draws nothing without a measured cell, and never more than the cap", () => {
    expect(overscanCount(20, 0)).toBe(0);
    expect(overscanCount(Number.NaN, 16)).toBe(0);
    expect(overscanCount(10_000, 16)).toBe(OVERSCAN_MAX_ROWS);
  });
});

/// A real xterm.js, opened inside a box that clips, filled with `line N` rows, and scrolled back so the
/// screen starts at buffer row `top`.
async function opened(top: number): Promise<{ term: Terminal; clip: HTMLElement }> {
  const clip = document.createElement("div");
  clip.style.overflow = "hidden";
  const el = document.createElement("div");
  clip.append(el);
  document.body.append(clip);
  const term = new Terminal({ cols: 20, rows: 5 });
  term.open(el);
  (term as unknown as { _core: { _renderService: { dimensions: { css: { cell: { height: number } } } } } })
    ._core._renderService.dimensions.css.cell.height = 17;
  await new Promise<void>((r) => term.write(Array.from({ length: 40 }, (_, i) => `line ${i}`).join("\r\n"), r));
  term.scrollToLine(top);
  return { term, clip };
}

/// What each row beyond the screen shows, above then below.
function beyond(clip: HTMLElement): string[][] {
  return [...clip.querySelectorAll("rdev-overscan")].map((o) => [...o.children].map((d) => (d.textContent ?? "").trim()));
}

/// Redraw the screen the way xterm.js does — the path the rows beyond it follow.
function redraw(term: Terminal): void {
  xtermDomRenderer(term)!.renderRows(0, term.rows - 1);
}

describe("xtermDomRenderer over a real xterm.js", () => {
  it("finds the DOM renderer and every member a row needs once the terminal is open", async () => {
    const { term } = await opened(0);
    expect(xtermDomRenderer(term)).not.toBeNull();
    term.dispose();
  });

  it("is null before the terminal is open, and for an xterm.js without those internals", () => {
    expect(xtermDomRenderer(new Terminal())).toBeNull();
    const fake = { _core: { _renderService: { _renderer: { value: { renderRows() {}, _rowFactory: {} } } } } };
    expect(xtermDomRenderer(fake as unknown as Terminal)).toBeNull();
  });
});

describe("OverscanRows over a real xterm.js", () => {
  it("draws the line above the screen and the line below it, inside xterm.js's row container", async () => {
    const { term, clip } = await opened(10);
    const o = new OverscanRows(term, true);
    redraw(term);
    expect(beyond(clip)).toEqual([["line 9"], ["line 15"]]);
    // Not `div`s: `.xterm-rows > div` stays xterm.js's own screen of rows.
    expect(clip.querySelectorAll(".xterm-rows > div")).toHaveLength(5);
    expect(clip.querySelector(".xterm-rows > rdev-overscan")).not.toBeNull();
    o.dispose();
    term.dispose();
  });

  it("follows the screen as it scrolls, and has nothing to draw past either end of the buffer", async () => {
    const { term, clip } = await opened(10);
    const o = new OverscanRows(term, true);
    term.scrollToLine(20);
    redraw(term);
    expect(beyond(clip)).toEqual([["line 19"], ["line 25"]]);
    term.scrollToTop();
    redraw(term);
    expect(beyond(clip)).toEqual([[""], ["line 5"]]);
    term.scrollToBottom();
    redraw(term);
    expect(beyond(clip)).toEqual([["line 34"], [""]]);
    o.dispose();
    term.dispose();
  });

  it("draws nothing beyond the alt screen, which has no lines there", async () => {
    const { term, clip } = await opened(10);
    const o = new OverscanRows(term, true);
    await new Promise<void>((r) => term.write("\x1b[?1049h\x1b[Halt", r));
    redraw(term);
    expect(beyond(clip).flat().join("")).toBe("");
    o.dispose();
    term.dispose();
  });

  it("never breaks xterm.js's own redraw: a failure turns the rows off and leaves the renderer as it was", async () => {
    const { term, clip } = await opened(10);
    const r = xtermDomRenderer(term)!;
    const o = new OverscanRows(term, true);
    redraw(term);
    const factory = r._rowFactory.createRow;
    // Only the rows BEYOND the screen fail: the screen's own go through the same factory.
    const y = term.buffer.active.viewportY;
    r._rowFactory.createRow = function (this: unknown, ...a: Parameters<typeof factory>) {
      if (a[1] < y || a[1] >= y + term.rows) throw new Error("boom");
      return factory.apply(this, a);
    };
    const err = console.error;
    const logged: unknown[] = [];
    console.error = (...a: unknown[]) => { logged.push(a[0]); };
    try {
      expect(() => redraw(term)).not.toThrow();
      expect(() => redraw(term)).not.toThrow();
    } finally { console.error = err; r._rowFactory.createRow = factory; }
    expect(logged).toHaveLength(1);
    expect(o.enabled).toBe(false);
    expect(beyond(clip)).toEqual([]);
    expect(Object.prototype.hasOwnProperty.call(r, "renderRows")).toBe(false);
    expect(clip.querySelector(".xterm-rows > div")?.textContent?.trim()).toBe("line 10");
    o.dispose();
    term.dispose();
  });

  it("is off with smooth scrolling: nothing drawn, and the renderer left exactly as it was", async () => {
    const { term, clip } = await opened(10);
    const r = xtermDomRenderer(term)!;
    const proto = Object.getPrototypeOf(r).renderRows;
    const o = new OverscanRows(term, false);
    redraw(term);
    expect(beyond(clip)).toEqual([]);
    expect(Object.prototype.hasOwnProperty.call(r, "renderRows")).toBe(false);
    o.setEnabled(true);
    redraw(term);
    expect(beyond(clip)).toEqual([["line 9"], ["line 15"]]);
    expect(r.renderRows).not.toBe(proto);
    o.setEnabled(false);
    expect(beyond(clip)).toEqual([]);
    expect(r.renderRows).toBe(proto);
    o.setEnabled(true);
    o.dispose();
    expect(beyond(clip)).toEqual([]);
    expect(Object.prototype.hasOwnProperty.call(r, "renderRows")).toBe(false);
    term.dispose();
  });
});
