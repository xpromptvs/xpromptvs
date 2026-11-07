import type { Terminal } from "@xterm/xterm";
import { xtermDomRenderer } from "./overscan-rows";

/// A REDRAW REUSES THE ROWS IT WOULD ONLY HAVE MOVED (2026-09-29).
///
/// xterm.js's DOM renderer redraws every row of the screen whenever the view scrolls by a line —
/// `DomRenderer.renderRows(0, rows - 1)`, each row built afresh by its row factory (`createRow`: a span per
/// run of like cells, classes, inline colours, text) — and MEASURED, it does so TWICE: the selection
/// service's `handleSelectionChanged` redraws every row on every scroll, selection or none, then the
/// render debouncer does. After a scroll by k lines all but k of those rows are exactly rows that were
/// just on screen, one place over (and the second pass's are the first's); with smooth scrolling a flick
/// crosses a row nearly every frame, so a 50-row screen was rebuilt ~240 times a second, and the garbage
/// with it.
///
/// This caches FOR ONE PASS. When `renderRows(start, end)` begins, the rows about to be redrawn are
/// indexed by the buffer line each was built from; when the pass asks `createRow` for a line that one of
/// them was built from, from the SAME cells (the line's `_data`, compared in full, plus its combined
/// characters and extended attributes) and the SAME state (the cursor on it, where, and whether it is
/// drawn at all, its selected range, a hovered link, the cell width, the glyph widths' generation, the
/// theme — counted by `onChangeColors`, since xterm.js mutates its colours in place — the font options,
/// focus), its existing spans are returned instead — the check
/// allocating nothing for an ordinary row, since garbage is half of what this saves: `renderRows` then
/// moves them into place. Each is reused at most once, and ONLY a row inside the pass's range is a source:
/// a partial redraw (the cursor's row) must never take spans from a row it is not redrawing, or that row
/// is left blank. While a decoration exists (the prediction overlay's) or a character joiner is
/// registered, nothing is reused: both change a row's spans by cell, outside the line's data.
///
/// THE GLYPH WIDTHS ARE STATE TOO, AND A BROWSER CAN MEASURE THEM WRONG. The row factory spaces each glyph
/// by its cells' width minus its measured width (`WidthCache`, by `offsetWidth`), and inside `display: none`
/// every glyph measures 0: xterm.js caches no 0 and measures again at its next build, but the row built
/// then spaces every glyph a whole cell apart. A hidden terminal builds such rows — a fresh instance written
/// hidden (a snapshot after a change of driver) in the frame before xterm.js's IntersectionObserver pauses
/// it, and a paused one on every scroll by a line (the selection service's redraw ignores the pause). The
/// first version of this cache made them PERMANENT (reported the same day, switching one host between
/// Chrome and Safari: double-spaced wherever the output had not changed — a scroll got the same rows back).
/// So a row built from a glyph measured 0 is never kept, and a cleared width cache (a change of font or
/// pixel ratio: `clear()` replaces its `_holey`) invalidates every row. Coming into view redraws every row
/// before the first paint (reveal-draw.ts); this cache's own IntersectionObserver did that until
/// 2026-10-02, a frame late — its callback is a task after the paint that shows the terminal.
///
/// It sits UNDER `bg-corners.ts` (which hooks the same `createRow` and sees a reused row like a built
/// one — the spans' recorded cells still apply, and it restyles the neighbours) and under
/// `overscan-rows.ts` (whose rows are drawn after the pass and are always built). PRIVATE, like both,
/// asserted against the shipped xterm.js by `row-cache.test.ts` — which also renders every change a
/// cached and a plain terminal see and requires IDENTICAL HTML. A renderer without these members (an
/// upgrade) is left alone.
///
/// What it does NOT save: a moved span leaves its row and joins another, so the browser styles and lays
/// it out again. It saves building the rows in JavaScript and the garbage they left.

/// A buffer line as the row factory reads it. PRIVATE fields.
interface CacheLine {
  length: number;
  _data?: Uint32Array;
  _combined?: Record<number, string>;
  _extendedAttrs?: Record<number, unknown>;
}

interface RowFactory {
  createRow(line: CacheLine, row: number, ...rest: unknown[]): HTMLElement[];
  defaultSpacing?: number;
  _selectionStart?: [number, number];
  _selectionEnd?: [number, number];
  _columnSelectMode?: boolean;
  _themeService: { onChangeColors(fn: () => void): { dispose(): void } };
  _optionsService: { rawOptions: Record<string, unknown> };
  _coreBrowserService: { isFocused: boolean };
  _coreService: { isCursorHidden: boolean; isCursorInitialized: boolean };
  _decorationService: { decorations: IterableIterator<unknown> };
  _characterJoinerService?: { _characterJoiners?: unknown[] };
}
interface CacheRenderer {
  renderRows(start: number, end: number): void;
  _rowFactory: RowFactory;
  _rowElements: HTMLElement[];
}

function cacheRenderer(term: Terminal): CacheRenderer | null {
  const r = xtermDomRenderer(term) as unknown as Partial<CacheRenderer> | null;
  const f = r?._rowFactory as Partial<RowFactory> | undefined;
  if (!r || !f || typeof r.renderRows !== "function" || !Array.isArray(r._rowElements) || typeof f.createRow !== "function"
    || typeof f._themeService?.onChangeColors !== "function" || !f._optionsService?.rawOptions || !f._coreBrowserService || !f._coreService
    || typeof f._decorationService?.decorations?.[Symbol.iterator] !== "function") return null;
  return r as CacheRenderer;
}

const hasOwn = (o: object, k: string) => Object.prototype.hasOwnProperty.call(o, k);

/// xterm.js's `WidthCache` as the row factory uses it: a glyph's width in CSS px. PRIVATE.
interface WidthCacheLike { get(c: string, bold: boolean | number, italic: boolean | number): number; _holey?: unknown }

/// What a row was built from, kept with its spans: the line, its cells and extras, and the state — the
/// glyph widths' generation (`gen`), the terminal-wide part (`base`), the cell width, and what is
/// particular to this row (`key`).
interface RowRecord { line: CacheLine; data: Uint32Array; extras: Extras | null; gen: unknown; base: string; width: unknown; key: string; spans: HTMLElement[] }

/// Counters, read by the scroll probe: passes, rows built and reused (a blank row builds no span and counts
/// as neither), and the time spent in passes.
export interface RowCacheStats { passes: number; built: number; reused: number; ms: number }

/// The line's cells as a comparable copy, or null for a line without the private data.
function cells(line: CacheLine): Uint32Array | null {
  const d = line._data;
  return d instanceof Uint32Array && d.length >= line.length * 3 ? d : null;
}

/// Combined characters and extended attributes (underline style and colour, links): outside `_data`. An
/// OSC 8 link gives EVERY cell it covers an entry, so they are kept flat — each extended entry as its two
/// numbers, `ext` (style, colour, variant) and `urlId` — and compared in place: a reuse check allocates
/// nothing. Null for a line with neither, the usual case.
type Extras = (string | number)[];
type Ext = { ext?: unknown; urlId?: unknown } | undefined;

function extrasOf(line: CacheLine): Extras | null {
  let x: Extras | null = null;
  const c = line._combined, e = line._extendedAttrs;
  if (c) for (const k in c) (x ??= []).push("c", k, c[k]!);
  if (e) {
    for (const k in e) {
      const a = e[k] as Ext;
      if (!a) continue;
      if (typeof a.ext === "number" && typeof a.urlId === "number") (x ??= []).push("e", k, a.ext, a.urlId);
      else (x ??= []).push("j", k, JSON.stringify(a));
    }
  }
  return x;
}

function sameExtras(x: Extras | null, line: CacheLine): boolean {
  let i = 0;
  const c = line._combined, e = line._extendedAttrs;
  if (c) {
    for (const k in c) {
      if (!x || x[i] !== "c" || x[i + 1] !== k || x[i + 2] !== c[k]) return false;
      i += 3;
    }
  }
  if (e) {
    for (const k in e) {
      const a = e[k] as Ext;
      if (!a) continue;
      if (typeof a.ext === "number" && typeof a.urlId === "number") {
        if (!x || x[i] !== "e" || x[i + 1] !== k || x[i + 2] !== a.ext || x[i + 3] !== a.urlId) return false;
        i += 4;
      } else {
        if (!x || x[i] !== "j" || x[i + 1] !== k || x[i + 2] !== JSON.stringify(a)) return false;
        i += 3;
      }
    }
  }
  return i === (x?.length ?? 0);
}

export class RowCache {
  readonly stats: RowCacheStats = { passes: 0, built: 0, reused: 0, ms: 0 };
  private disposed = false;
  private hooked: { r: CacheRenderer; f: RowFactory; renderRows: CacheRenderer["renderRows"]; createRow: RowFactory["createRow"];
    ownRender: boolean; ownCreate: boolean; colors: { dispose(): void } } | null = null;
  private readonly records = new WeakMap<Element, RowRecord>();
  /// The pass in progress: its reusable rows by the line each was built from. Null between passes.
  private pass: { sources: Map<CacheLine, RowRecord>; reuse: boolean; base: string } | null = null;
  private colorEpoch = 0;
  private readonly sub: { dispose(): void };

  constructor(private readonly term: Terminal) {
    // A renderer xterm.js replaced is followed at its next frame.
    this.sub = term.onRender(() => this.follow());
    this.follow();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.sub.dispose();
    this.unhook();
  }

  private follow(): void {
    if (this.disposed) return;
    const r = cacheRenderer(this.term);
    if (this.hooked && this.hooked.r === r && this.hooked.f === r?._rowFactory) return;
    this.unhook();
    if (r) this.hook(r);
  }

  private hook(r: CacheRenderer): void {
    const f = r._rowFactory;
    const ownRender = hasOwn(r, "renderRows"), renderRows = r.renderRows;
    const ownCreate = hasOwn(f, "createRow"), createRow = f.createRow;
    const colors = f._themeService.onChangeColors(() => { this.colorEpoch++; });
    const self = this;
    const renderWrapper = function (this: CacheRenderer, start: number, end: number): void {
      if (self.hooked?.r !== r || self.pass) { renderRows.call(this, start, end); return; }   // inert, or re-entered
      self.pass = self.open(r, start, end);
      const t0 = performance.now();
      try { renderRows.call(this, start, end); } finally {
        self.pass = null;
        self.stats.passes++;
        self.stats.ms += performance.now() - t0;
      }
    };
    const createWrapper = function (this: RowFactory, line: CacheLine, row: number, ...rest: unknown[]): HTMLElement[] {
      if (self.hooked?.f !== f) return createRow.call(this, line, row, ...rest);   // inert
      const pass = self.pass;
      const base = pass ? pass.base : self.base(f), width = rest[5], key = self.key(f, row, rest);
      // The glyph widths the row factory spaces by: xterm.js's `WidthCache`, whose `clear()` (a change of
      // font or pixel ratio) replaces `_holey` — so that object is the widths' generation.
      const wc = rest[6] as WidthCacheLike | undefined, gen = wc?._holey;
      const data = cells(line);
      if (pass?.reuse && data && gen !== undefined) {
        const rec = pass.sources.get(line);
        if (rec && rec.gen === gen && rec.base === base && rec.width === width && rec.key === key
          && rec.data.length === line.length * 3 && sameCells(rec.data, data) && sameExtras(rec.extras, line)) {
          pass.sources.delete(line);
          self.stats.reused++;
          return rec.spans.slice();
        }
      }
      // The row factory spaces each glyph by its cells' width minus its measured width (`WidthCache`,
      // by `offsetWidth`): inside `display: none` a glyph measures 0 and is spaced a whole cell apart.
      // xterm.js caches no 0 and measures again at its next build; a row built from one is never kept.
      let measured = typeof wc?.get === "function" && gen !== undefined;
      if (measured) {
        rest[6] = { get: (c: string, b: boolean | number, i: boolean | number) => {
          const w = wc!.get(c, b, i);
          if (!(w > 0)) measured = false;
          return w;
        } };
      }
      const els = createRow.call(this, line, row, ...rest);
      if (els.length === 0) return els;   // a blank row: nothing built, nothing to reuse
      self.stats.built++;
      if (!measured) return els;
      if (data) {
        self.records.set(els[0]!, { line, data: data.slice(0, line.length * 3), extras: extrasOf(line), gen, base, width, key, spans: els });
      }
      return els;
    };
    r.renderRows = renderWrapper;
    f.createRow = createWrapper;
    this.hooked = { r, f, renderRows, createRow, ownRender, ownCreate, colors };
    // Remember what to take off: only OUR wrappers, and only while they are still the ones installed —
    // one installed on top of them since (bg-corners, overscan-rows) keeps calling them, inert.
    this.wrappers = { renderWrapper, createWrapper };
  }

  private wrappers: { renderWrapper: CacheRenderer["renderRows"]; createWrapper: RowFactory["createRow"] } | null = null;

  private unhook(): void {
    const h = this.hooked, w = this.wrappers;
    if (!h || !w) return;
    this.hooked = null;
    this.wrappers = null;
    this.pass = null;
    h.colors.dispose();
    if (h.r.renderRows === w.renderWrapper) {
      if (h.ownRender) h.r.renderRows = h.renderRows; else delete (h.r as Partial<CacheRenderer>).renderRows;
    }
    if (h.f.createRow === w.createWrapper) {
      if (h.ownCreate) h.f.createRow = h.createRow; else delete (h.f as Partial<RowFactory>).createRow;
    }
  }

  /// Index the rows `start`…`end` — the ones this pass redraws, and so the only ones it may take from.
  private open(r: CacheRenderer, start: number, end: number): NonNullable<RowCache["pass"]> {
    const f = r._rowFactory;
    const sources = new Map<CacheLine, RowRecord>(), base = this.base(f);
    const joiners = f._characterJoinerService?._characterJoiners?.length ?? 0;
    const decorated = !f._decorationService.decorations.next().done;
    if (joiners > 0 || decorated) return { sources, reuse: false, base };
    for (let y = Math.max(0, start); y <= end && y < r._rowElements.length; y++) {
      const div = r._rowElements[y]!;
      const first = div.firstElementChild;
      const rec = first ? this.records.get(first) : undefined;
      // Only a row still showing exactly what it was built as.
      if (rec && div.childElementCount === rec.spans.length && div.lastElementChild === rec.spans[rec.spans.length - 1]) {
        sources.set(rec.line, rec);
      }
    }
    return { sources, reuse: true, base };
  }

  /// What every row's spans depend on besides its line: the theme (counted), the options the factory
  /// reads, the default letter spacing. The same for a whole pass, so a pass computes it once.
  private base(f: RowFactory): string {
    const o = f._optionsService.rawOptions;
    return `${this.colorEpoch}|${String(o.drawBoldTextInBrightColors)}|${String(o.minimumContrastRatio)}|${String(f.defaultSpacing)}|` +
      `${String(o.fontFamily)}|${String(o.fontSize)}|${String(o.fontWeight)}|${String(o.fontWeightBold)}|${String(o.letterSpacing)}|` +
      `${String(o.lineHeight)}`;
  }

  /// What is particular to this row: a hovered link on it, the cursor on it and how it draws, the selected
  /// range if the row is in it. Empty — nothing allocated — for every other row.
  private key(f: RowFactory, row: number, rest: unknown[]): string {
    const [isCursorRow, cursorStyle, cursorInactiveStyle, cursorX, cursorBlink, , , linkStart, linkEnd] = rest;
    let s = "";
    if (linkStart !== -1 || linkEnd !== -1) s += `|l${String(linkStart)},${String(linkEnd)}`;
    const focused = f._coreBrowserService.isFocused;
    if (isCursorRow) {
      // Whether it is drawn at all: hidden by DECTCEM (`?25l`, where it stands), or not yet shown.
      const c = f._coreService;
      s += `|c${String(cursorX)},${String(cursorStyle)},${String(cursorInactiveStyle)},${String(cursorBlink)},${focused},` +
        `${String(c.isCursorHidden)},${String(c.isCursorInitialized)}`;
    }
    const a = f._selectionStart, b = f._selectionEnd;
    if (a && b && row >= Math.min(a[1], b[1]) && row <= Math.max(a[1], b[1])) {
      s += `|s${a[0]},${a[1]},${b[0]},${b[1]},${String(f._columnSelectMode)},${focused}`;
    }
    return s;
  }
}

function sameCells(a: Uint32Array, b: Uint32Array): boolean {
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
