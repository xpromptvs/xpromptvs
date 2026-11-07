import type { IBufferCell, IBufferLine, Terminal } from "@xterm/xterm";
import { xtermDomRenderer } from "./overscan-rows";

/// BACKGROUND BLOCKS ROUND THEIR OUTER CORNERS (asked for 2026-09-29): a diff's removed and added lines,
/// a status bar, anything a program paints with a background, reads as a shape rather than a stack of
/// hard-edged rows.
///
/// THE RULE IS PER CELL. A cell with a non-default background rounds a corner when both of its
/// neighbours at that corner — the one beside it and the one above or below it — have the default
/// background (outside the grid counts as default). So a block rounds only its OUTER corners: two
/// differently coloured lines stacked into one block (a removed line over an added one) stay square
/// where they meet, a word highlighted inside a line stays square, and a concave corner is left alone.
///
/// WHY IT FITS xterm.js's DOM RENDERER EXACTLY. It draws a row as spans, starting a new one wherever a
/// cell's background (or anything else it draws) changes (`DomRendererRowFactory.createRow`), each an
/// `inline-block` exactly as tall as the row and, through letter-spacing, exactly as wide as its cells.
/// A corner the rule rounds needs a default neighbour BESIDE the cell — a different background — so it
/// always falls at the start or end of a span, where `border-radius` on that span rounds it exactly and
/// clips only the background (never a glyph).
///
/// WHAT xterm.js DOES NOT SAY is which cells a span covers. This follows its row factory (PRIVATE, like
/// `overscan-rows.ts`, asserted against the shipped bundle by `bg-corners.test.ts`): while a row is
/// built, the cell it is reading (`loadCell(x)`, called for every cell in order) is recorded, and so is
/// each span it creates (`_document.createElement`, just after reading the span's first cell) — which
/// gives each span its first cell exactly, wide glyphs included; it ends where the next one starts.
///
/// A ROW's CORNERS DEPEND ON ITS NEIGHBOURS, which xterm.js does not redraw when that row changes. So
/// building a row also restyles the rows above and below it from their spans' recorded cells and the
/// buffer as it is now — style writes only, no layout read.
///
/// A span in the SELECTION stays square: the selection is painted over the block (as the spans'
/// background), and follows its own shape.
///
/// AND A TABLE ROUNDS ITS OUTER CORNERS (asked for 2026-10-10): a LIGHT box-drawing corner — `┌ ┐ └ ┘` —
/// is DRAWN as its rounded arc, `╭ ╮ ╰ ╯`. Per cell, like the rule above: a corner has only two arms, so in
/// a table drawn in light lines it is only ever an OUTER corner (the joints are `┬ ┴ ├ ┤ ┼`), and a rule
/// that reads no neighbour keeps every row the row cache (row-cache.ts) reuses right. Heavy and double
/// corners have no rounded form in Unicode and stay square. ON SCREEN ONLY: the factory's scratch cell is
/// rewritten after `loadCell` reads it (never the buffer), so a copy, the selection, links and the
/// accessibility tree keep the character the program wrote. The arc comes from the same face as the rest
/// of the box (the DOM renderer draws box drawing from the font stack's fallback — Menlo on Apple — and
/// letter-spaces every glyph onto its cells). The WebGPU renderer does not come through here: it draws every
/// light corner, `┌` and `╭` alike, as a circular arc of THIS file's radius (webgpu/box-corners.ts).

/// The corner radius, in CSS px (a point on Apple devices): 3, asked for after a day at 2. A cell narrower
/// than twice it (a phone's small font) has its radii scaled down by the browser to fit, as CSS does.
export const BG_CORNER_RADIUS_PX = 3;

/// A light box-drawing corner's rounded arc, by code point.
const ROUNDED_CORNER: ReadonlyMap<number, number> = new Map([
  [0x250c, 0x256d],   // ┌ → ╭
  [0x2510, 0x256e],   // ┐ → ╮
  [0x2514, 0x2570],   // └ → ╰
  [0x2518, 0x256f],   // ┘ → ╯
]);

/// The code point to DRAW for `code`: a light corner's rounded arc, anything else itself.
export function roundedCorner(code: number): number {
  return ROUNDED_CORNER.get(code) ?? code;
}

/// xterm.js's cell `content` bits (`Content` in its buffer constants — PRIVATE): the code point, and the
/// flag that says the cell's characters live in `combinedData` instead.
const CODEPOINT_MASK = 0x1fffff, IS_COMBINED_MASK = 0x200000;

/// Round the light corner the factory's SCRATCH cell holds: its code point replaced, its width, flags and
/// attributes kept. A cell of combined characters is left alone.
function roundCellCorner(cell: unknown): void {
  const c = cell as { content?: unknown } | null;
  const content = c?.content;
  if (typeof content !== "number" || content & IS_COMBINED_MASK) return;
  const round = ROUNDED_CORNER.get(content & CODEPOINT_MASK);
  if (round !== undefined) c!.content = (content & ~CODEPOINT_MASK) | round;
}

export interface Corners { tl: boolean; tr: boolean; br: boolean; bl: boolean }
const SQUARE: Corners = Object.freeze({ tl: false, tr: false, br: false, bl: false });

/// Which corners of a span covering cells `start`…`end` of row `y` round, from `filled(x, y)` (false off
/// the grid). The span's cells share one background, so its left corners are `start`'s and its right
/// corners `end`'s.
export function spanCorners(filled: (x: number, y: number) => boolean, start: number, end: number, y: number): Corners {
  const left = filled(start, y) && !filled(start - 1, y);
  const right = filled(end, y) && !filled(end + 1, y);
  if (!left && !right) return SQUARE;
  return {
    tl: left && !filled(start, y - 1),
    tr: right && !filled(end, y - 1),
    br: right && !filled(end, y + 1),
    bl: left && !filled(start, y + 1),
  };
}

/// `border-radius` for `c`, clockwise from the top left; empty for none.
export function cornerRadiusCss(c: Corners, radiusPx = BG_CORNER_RADIUS_PX): string {
  if (!c.tl && !c.tr && !c.br && !c.bl) return "";
  const v = (on: boolean) => (on ? `${radiusPx}px` : "0px");
  return `${v(c.tl)} ${v(c.tr)} ${v(c.br)} ${v(c.bl)}`;
}

type Disposable = { dispose(): void };

/// A buffer line as the row factory reads it.
interface RowLine { loadCell(x: number, cell: unknown): unknown }

/// xterm.js 6's DOM row factory and renderer, as far as this needs them. PRIVATE.
interface RowFactory {
  createRow(line: RowLine, row: number, ...rest: unknown[]): HTMLElement[];
  _document: Document;
  _isCellInSelection?(x: number, y: number): boolean;
}
interface CornerRenderer {
  dimensions?: { css: { cell: { width:number } } };
  _rowFactory: RowFactory;
  _rowElements: HTMLElement[];
  _bufferService: { buffer: { ydisp: number } };
}

/// The renderer of an OPEN xterm.js with everything this needs, or null — the corners then stay square.
function cornerRenderer(term: Terminal): CornerRenderer | null {
  const r = xtermDomRenderer(term) as unknown as Partial<CornerRenderer> | null;
  const f = r?._rowFactory as Partial<RowFactory> | undefined;
  if (!r || !f || typeof f.createRow !== "function" || typeof f._document?.createElement !== "function"
    || !Array.isArray(r._rowElements) || typeof r._bufferService?.buffer?.ydisp !== "number") return null;
  return r as CornerRenderer;
}

const hasOwn = (o: object, k: string) => Object.prototype.hasOwnProperty.call(o, k);

/// What a row being built has read: the cell it is on, the last cell anything it read covers, and the
/// cell each span it created starts at.
interface Recording { x: number; max: number; starts: Map<Element, number> }

/// One xterm.js instance's rounded corners: its background blocks' and its tables'.
export class BgCorners {
  private disposed = false;
  private broken = false;
  /// The row factory this follows, and how to put it back.
  private hooked: { f: RowFactory; own: boolean; orig: RowFactory["createRow"]; doc: Document; docOwn: boolean } | null = null;
  /// Each span's cells, `[first, last]`, recorded when its row was built.
  private readonly ranges = new WeakMap<Element, [number, number]>();
  /// The `border-radius` this last wrote on a span, so a restyle that changes nothing writes nothing.
  private readonly applied = new WeakMap<Element, string>();
  private readonly subs: Disposable[];
  private cell: IBufferCell | undefined;

  constructor(private readonly term: Terminal, private readonly radiusPx = BG_CORNER_RADIUS_PX) {
    // A renderer xterm.js replaced is followed at its next frame.
    this.subs = [term.onRender(() => this.follow())];
    this.follow();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    for (const d of this.subs) d.dispose();
    if (this.unhook()) this.redraw();
  }

  private follow(): void {
    if (this.disposed || this.broken) return;
    const r = cornerRenderer(this.term);
    if (!r) { if (this.unhook()) this.redraw(); return; }
    if (this.hooked?.f === r._rowFactory) return;
    this.unhook();
    this.hook(r);
    this.redraw();   // rows drawn before this have no recorded cells
  }

  /// Build every row through `r`'s factory while recording, then round its spans and restyle its
  /// neighbours. Own properties shadowing the factory's method and document, removed again by `unhook`.
  /// This runs INSIDE xterm.js's redraw, so a throw here must never reach it: the row is already built,
  /// and a failure turns the corners off, once, rather than breaking every redraw after it.
  private hook(r: CornerRenderer): void {
    const f = r._rowFactory;
    const own = hasOwn(f, "createRow"), orig = f.createRow;
    const docOwn = hasOwn(f, "_document"), doc = f._document;
    let rec: Recording | null = null;
    f._document = new Proxy(doc, {
      get(target, key) {
        if (key === "createElement") {
          return (tag: string, options?: ElementCreationOptions) => {
            const el = target.createElement(tag, options);
            if (rec && tag === "span") rec.starts.set(el, rec.x);
            return el;
          };
        }
        const v: unknown = Reflect.get(target, key);
        return typeof v === "function" ? (v as (...a: unknown[]) => unknown).bind(target) : v;
      },
    });
    const self = this;
    f.createRow = function (this: RowFactory, line: RowLine, row: number, ...rest: unknown[]): HTMLElement[] {
      if (rec) return orig.call(this, line, row, ...rest);   // re-entered: build it plainly
      const mine: Recording = { x: -1, max: -1, starts: new Map() };
      rec = mine;
      const lineOwn = hasOwn(line, "loadCell"), load = line.loadCell;
      line.loadCell = function (this: RowLine, x: number, cell: unknown) {
        mine.x = x;
        const loaded = load.call(this, x, cell);
        roundCellCorner(cell);
        // A WIDE glyph's second cell is its own: xterm.js trims a row after the glyph's FIRST cell
        // (`getNoBgTrimmedLength`), so the cell it covers is never read on its own.
        const w = typeof (cell as { getWidth?: unknown })?.getWidth === "function" ? (cell as { getWidth(): number }).getWidth() : 1;
        const last = x + Math.max(1, w) - 1;
        if (last > mine.max) mine.max = last;
        return loaded;
      };
      let els: HTMLElement[];
      try { els = orig.call(this, line, row, ...rest); } finally {
        rec = null;
        if (lineOwn) line.loadCell = load; else delete (line as Partial<RowLine>).loadCell;
      }
      try { self.built(r, els, mine, row); } catch (e) { self.fail(e); }
      return els;
    };
    this.hooked = { f, own, orig, doc, docOwn };
  }

  /// Put the factory back; true if there was one to put back.
  private unhook(): boolean {
    const h = this.hooked;
    if (!h) return false;
    this.hooked = null;
    if (h.own) h.f.createRow = h.orig; else delete (h.f as Partial<RowFactory>).createRow;
    if (h.docOwn) h.f._document = h.doc; else delete (h.f as Partial<RowFactory>)._document;
    return true;
  }

  private fail(e: unknown): void {
    console.error("[bg-corners] rounding background corners failed; turning them off", e);
    this.broken = true;
    if (this.unhook()) this.redraw();
  }

  /// Redraw every row of an open terminal — plainly after an unhook, recorded after a hook.
  private redraw(): void {
    try { if (this.term.element) this.term.refresh(0, this.term.rows - 1); } catch { /* disposed underneath */ }
  }

  /// A row was just built: record its spans' cells, round them, and restyle the rows beside it.
  private built(r: CornerRenderer, els: HTMLElement[], rec: Recording, row: number): void {
    for (let i = 0; i < els.length; i++) {
      const el = els[i]!, start = rec.starts.get(el);
      if (start === undefined) continue;
      const next = i + 1 < els.length ? rec.starts.get(els[i + 1]!) : undefined;
      const end=Math.max(start, next !== undefined ? next - 1 : rec.max);
      this.ranges.set(el, [start, end]);
      // Font box-drawing glyphs overhang when xterm compresses a fallback face onto
      // narrower cells. Dim glyphs then composite twice at every join. Draw a run
      // as one stroke; keep its text and buffer cells intact for selection/copy.
      const cellWidth=r.dimensions?.css.cell.width;
      if(cellWidth && /^─+$/.test(el.textContent??'')){
        el.classList.add('xterm-horizontal-rule');
        el.style.width=`${(end-start+1)*cellWidth}px`;
      }
    }
    const filled = this.filledNear(row);
    this.style(r, els, row, filled);
    for (const y of [row - 1, row + 1]) {
      const at = y - r._bufferService.buffer.ydisp;
      const el = at >= 0 && at < r._rowElements.length ? r._rowElements[at] : undefined;
      if (el) this.style(r, [...el.children] as HTMLElement[], y, this.filledNear(y));
    }
  }

  private style(r: CornerRenderer, spans: HTMLElement[], row: number, filled: (x: number, y: number) => boolean): void {
    const inSelection = r._rowFactory._isCellInSelection;
    for (const span of spans) {
      const range = this.ranges.get(span);
      if (!range) continue;
      const selected = typeof inSelection === "function"
        && (inSelection.call(r._rowFactory, range[0], row) || inSelection.call(r._rowFactory, range[1], row));
      const css = selected ? "" : cornerRadiusCss(spanCorners(filled, range[0], range[1], row), this.radiusPx);
      if ((this.applied.get(span) ?? "") === css) continue;
      span.style.borderRadius = css;
      // A span left with no inline style carries none — as the factory builds it, so a row the row cache
      // (row-cache.ts) moved and this restyled is the same markup as one built there.
      if (span.getAttribute("style") === "") span.removeAttribute("style");
      this.applied.set(span, css);
    }
  }

  /// `filled(x, y)` for rows `row - 1`…`row + 1` of the active buffer: a non-default background, or
  /// inverse video (whose background is the foreground). Off the grid is default.
  private filledNear(row: number): (x: number, y: number) => boolean {
    const buffer = this.term.buffer.active, cols = this.term.cols;
    const cell = this.cell ??= buffer.getNullCell();
    const lines = new Map<number, IBufferLine | undefined>();
    const line = (y: number): IBufferLine | undefined => {
      if (!lines.has(y)) lines.set(y, y >= 0 && y < buffer.length ? buffer.getLine(y) : undefined);
      return lines.get(y);
    };
    return (x, y) => {
      if (x < 0 || x >= cols || y < row - 1 || y > row + 1) return false;
      const c = line(y)?.getCell(x, cell);
      return !!c && (!c.isBgDefault() || c.isInverse() !== 0);
    };
  }
}
