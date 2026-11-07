import type { Terminal } from "@xterm/xterm";

/// ROWS DRAWN INTO THE TERMINAL'S INSET while smooth scrolling is on (asked for 2026-09-29).
///
/// xterm.js draws exactly one screen of rows. Shifted by a fraction of a row (`smooth-scroll.ts`), that
/// left the inset around the grid — `#xterm`'s padding — empty mid-scroll: the text stopped at a hard
/// edge up to half a row inside the inset, where the next line should already have been coming into
/// view. This draws the buffer's lines ABOVE and BELOW the screen into that space, so text runs on to
/// the edge of the terminal's box and is cut off there — at the tab bar, the status bar, the key strip —
/// by `#xterm { overflow: clip }` (style.css), as a native scroll view is cut off by its bars.
///
/// The rows are xterm.js's OWN: its DOM renderer's row factory builds them exactly as it builds a row of
/// the screen (colours, attributes, wide glyphs, the selection, the cursor), from the same buffer state,
/// right after EVERY redraw of its rows — by following the renderer's `renderRows`, the one method they
/// all go through. `term.onRender` is not enough: a selection reaches the renderer an animation frame
/// after `onSelectionChange`, and it and a focus change redraw the rows directly, with no event
/// (measured: a selection never reached these rows). They live INSIDE `.xterm-rows`, so every rule
/// xterm.js injects for its rows applies to them, and inside `.xterm-screen`, so they move with the
/// shift. Their containers are not `div`s: `.xterm-rows > div` is xterm.js's own screen of rows to every
/// check that reads it, and stays exactly that. `pointer-events` is off for all of `.xterm-rows`, so a
/// press in the inset lands where it did before.
///
/// OFF with smooth scrolling, so the option-off terminal is exactly as it was. ON, a view at rest shows
/// the neighbouring lines in the inset too — the terminal is a window onto the buffer that the panels
/// cut off, not a framed grid — so nothing appears or vanishes when a scroll settles.

/// Rows beyond one edge: never more than this, so a layout with no clipping box near the grid draws a
/// few rows too many rather than the scrollback.
export const OVERSCAN_MAX_ROWS = 4;

/// How many rows to draw beyond one edge of the grid when the clip edge is `spacePx` away: enough to
/// reach it, plus the one row a shift of up to a row uncovers. None without a measured cell.
/// `extra`: rows allowed past the cap — a held resize's gap (hold-shift.ts), which the scrollback fills.
export function overscanCount(spacePx: number, cellPx: number, extra = 0): number {
  if (!(cellPx > 0) || !Number.isFinite(spacePx)) return 0;
  const reach = Math.ceil(Math.max(0, spacePx) / cellPx - 1e-6);
  return Math.min(OVERSCAN_MAX_ROWS + Math.max(0, extra), reach + 1);
}

type Disposable = { dispose(): void };

/// xterm.js 6's DOM renderer, as far as drawing a row needs it: the members its own `renderRows` reads.
/// PRIVATE, like the Viewport `smooth-scroll.ts` reads — names the shipped bundle keeps, asserted
/// against the real xterm.js by `overscan-rows.test.ts`.
interface DomRenderer {
  renderRows(start: number, end: number): void;
  _rowFactory: { createRow(line: unknown, row: number, isCursorRow: boolean, cursorStyle: unknown, cursorInactiveStyle: unknown,
    cursorX: number, cursorBlink: unknown, cellWidth: number, widthCache: unknown, linkStart: number, linkEnd: number): HTMLElement[] };
  _rowContainer: HTMLElement;
  _widthCache: unknown;
  dimensions: { css: { cell: { width: number; height: number }; canvas: { width: number } } };
  _bufferService: { cols: number; rows: number; buffer: { ybase: number; ydisp: number; x: number; y: number; lines: { length: number; get(i: number): unknown } } };
  _coreService: { decPrivateModes: { cursorBlink?: boolean; cursorStyle?: string } };
  _optionsService: { rawOptions: { cursorBlink?: boolean; cursorStyle?: string; cursorInactiveStyle?: string } };
}

/// The DOM renderer of an OPEN xterm.js, or null — not open yet, another renderer, or an upgrade that
/// moved these. The overscan then draws nothing, and the terminal is as it was.
export function xtermDomRenderer(term: Terminal): DomRenderer | null {
  const r = (term as unknown as { _core?: { _renderService?: { _renderer?: { value?: Partial<DomRenderer> } } } })
    ._core?._renderService?._renderer?.value;
  if (!r || typeof r.renderRows !== "function" || typeof r._rowFactory?.createRow !== "function" || !(r._rowContainer instanceof HTMLElement)
    || !r._widthCache || !r.dimensions?.css?.cell || !r._bufferService?.buffer?.lines
    || !r._coreService?.decPrivateModes || !r._optionsService?.rawOptions) return null;
  return r as DomRenderer;
}

/// One xterm.js instance's rows beyond its screen.
export class OverscanRows {
  private on: boolean;
  private disposed = false;
  private readonly above: HTMLElement;
  private readonly below: HTMLElement;
  /// Rows to draw at each edge, and what they were measured for: a new cell height or row count
  /// measures again.
  private counts = { above: 0, below: 0, cell: 0, rows: 0 };
  /// Rows a HELD resize moved the picture down (`holdShift`): the gap it opens above is filled from the
  /// scrollback, as the host's snapshot will fill it.
  private extraAbove = 0;
  private stale = true;
  /// The renderer whose `renderRows` this follows, and how to put it back.
  private hooked: { r: DomRenderer; own: boolean; orig: DomRenderer["renderRows"] } | null = null;
  private readonly subs: Disposable[];
  /// Watches the terminal and its clip box for a layout change that moves the clip edge without
  /// redrawing a row (the keyboard, a rotation, the inset). Only while ON: finding the clip box reads
  /// every ancestor's computed style, which cost jsdom's query test 1.1 s → 4.0 s for terminals that
  /// never draw a row beyond the screen.
  private ro: ResizeObserver | null = null;
  private watching: HTMLElement | null = null;

  constructor(private readonly term: Terminal, enabled: boolean) {
    this.on = enabled;
    const doc = term.element?.ownerDocument ?? document;
    this.above = doc.createElement("rdev-overscan");
    this.below = doc.createElement("rdev-overscan");
    for (const el of [this.above, this.below]) el.style.cssText = "display:block;position:absolute;left:0";
    this.subs = [term.onResize(() => { this.stale = true; })];
    if (enabled) this.draw();
  }

  get enabled(): boolean { return this.on; }

  /// The picture was moved by a held resize (xterm-view.ts's `holdShift` — a transform no observer sees): measure
  /// again, and draw `extraAbove` rows past the cap above the screen.
  relayout(extraAbove: number): void {
    if (this.disposed) return;
    this.extraAbove = Math.max(0, extraAbove);
    this.stale = true;
    this.draw();
  }

  setEnabled(on: boolean): void {
    if (this.disposed || on === this.on) return;
    this.on = on;
    this.stale = true;
    this.draw();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    for (const d of this.subs) d.dispose();
    this.unhook();
    this.unwatch();
    this.above.remove();
    this.below.remove();
  }

  /// Build the rows beyond the screen from the buffer as xterm.js just drew it — its `renderRows`, for
  /// the lines above `ydisp` and below the screen's last row.
  private draw(): void {
    if (this.disposed) return;
    const r = xtermDomRenderer(this.term);
    if (!this.on || !r) { this.unhook(); this.unwatch(); this.above.remove(); this.below.remove(); return; }
    this.hook(r);
    const cell = r.dimensions.css.cell.height, rows = r._bufferService.rows;
    if (this.stale || cell !== this.counts.cell || rows !== this.counts.rows) this.measure(r);
    const host = r._rowContainer;
    if (this.above.parentElement !== host) host.append(this.above);
    if (this.below.parentElement !== host) host.append(this.below);

    const buffer = r._bufferService.buffer;
    const cursorRow = buffer.ybase + buffer.y;
    const cursorX = Math.min(buffer.x, r._bufferService.cols - 1);
    const blink = r._coreService.decPrivateModes.cursorBlink ?? r._optionsService.rawOptions.cursorBlink;
    const style = r._coreService.decPrivateModes.cursorStyle ?? r._optionsService.rawOptions.cursorStyle;
    const inactive = r._optionsService.rawOptions.cursorInactiveStyle;
    const width = `${r.dimensions.css.canvas.width}px`, height = `${cell}px`;
    const fill = (box: HTMLElement, n: number, top: number, first: number): void => {
      box.style.top = `${top}px`;
      while (box.children.length > n) box.lastElementChild!.remove();
      while (box.children.length < n) box.append(box.ownerDocument.createElement("div"));
      for (let i = 0; i < n; i++) {
        const el = box.children[i] as HTMLElement;
        const s = el.style;
        if (s.height !== height) { s.width = width; s.height = height; s.lineHeight = height; s.overflow = "hidden"; }
        else if (s.width !== width) s.width = width;
        const row = first + i;
        const line = row >= 0 && row < buffer.lines.length ? buffer.lines.get(row) : undefined;
        if (!line) { el.replaceChildren(); continue; }
        el.replaceChildren(...r._rowFactory.createRow(line, row, row === cursorRow, style, inactive, cursorX, blink,
          r.dimensions.css.cell.width, r._widthCache, -1, -1));
      }
    };
    const { above, below } = this.counts;
    fill(this.above, above, -above * cell, buffer.ydisp - above);
    fill(this.below, below, rows * cell, buffer.ydisp + rows);
  }

  /// Draw after every `renderRows` of `r` — an own property shadowing the renderer's method, removed again
  /// by `unhook`. It looks the method up at call time, so a renderer xterm.js replaced is simply followed.
  /// This runs INSIDE xterm.js's redraw, so a throw here must never reach it: the screen's rows are
  /// already drawn, and a failure turns these rows off, once, rather than breaking every redraw after it.
  private hook(r: DomRenderer): void {
    if (this.hooked?.r === r) return;
    this.unhook();
    const own = Object.prototype.hasOwnProperty.call(r, "renderRows");
    const orig = r.renderRows;
    const draw = () => {
      try { this.draw(); } catch (e) {
        console.error("[overscan] drawing the rows beyond the screen failed; turning them off", e);
        this.on = false;
        this.unhook(); this.unwatch(); this.above.remove(); this.below.remove();
      }
    };
    r.renderRows = function (this: DomRenderer, start: number, end: number) { orig.call(this, start, end); draw(); };
    this.hooked = { r, own, orig };
  }

  private unhook(): void {
    const h = this.hooked;
    if (!h) return;
    this.hooked = null;
    if (h.own) h.r.renderRows = h.orig;
    else delete (h.r as Partial<DomRenderer>).renderRows;
  }

  private watch(el: HTMLElement, clip: HTMLElement): void {
    if (this.watching === clip || typeof ResizeObserver !== "function") return;
    this.unwatch();
    this.ro = new ResizeObserver(() => { this.stale = true; this.draw(); });
    this.ro.observe(el);
    this.ro.observe(clip);
    this.watching = clip;
  }

  private unwatch(): void {
    this.ro?.disconnect();
    this.ro = null;
    this.watching = null;
  }

  /// How far the clip edges are from the grid, in rows. The grid is measured where it sits UNSHIFTED —
  /// the screen's transform is the smooth scroll's fraction, not layout.
  private measure(r: DomRenderer): void {
    const cell = r.dimensions.css.cell.height, rows = r._bufferService.rows;
    this.counts = { above: 0, below: 0, cell, rows };
    this.stale = false;
    const el = this.term.element, screen = r._rowContainer.parentElement;
    const clip = el ? clipBox(el) : null;
    if (el && clip) this.watch(el, clip);
    if (!el || !screen || !clip || !(cell > 0)) return;
    const view = el.ownerDocument.defaultView;
    const t = view?.getComputedStyle(screen).transform;
    const shift = t && t !== "none" && view?.DOMMatrixReadOnly ? new view.DOMMatrixReadOnly(t).m42 : 0;
    const top = r._rowContainer.getBoundingClientRect().top - shift;
    const c = clip.getBoundingClientRect();
    const clipTop = c.top + clip.clientTop, clipBottom = clipTop + clip.clientHeight;
    this.counts.above = overscanCount(top - clipTop, cell, this.extraAbove);
    this.counts.below = overscanCount(clipBottom - (top + rows * cell), cell);
  }
}

/// The nearest ancestor that clips its overflow: where the rows beyond the screen stop showing.
export function clipBox(from: HTMLElement): HTMLElement | null {
  const view = from.ownerDocument.defaultView;
  for (let el = from.parentElement; el; el = el.parentElement) {
    const cs = view?.getComputedStyle(el);
    const o = cs?.overflowY || cs?.overflow;   // a browser always has the longhand; jsdom only the shorthand
    if (o && o !== "visible") return el;
  }
  return null;
}
