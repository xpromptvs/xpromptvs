import type { Terminal } from "@xterm/xterm";

/// A TERMINAL COMING INTO VIEW IS DRAWN BEFORE ITS FIRST PAINT (2026-10-02).
///
/// Switching to a terminal tab that had output while it was hidden showed, for one frame, its rows with
/// every letter a whole cell apart — then the right ones (reported 2026-10-01). Two xterm.js 6 behaviours
/// make that frame, MEASURED in Chromium and WebKit (`e2e/term-reveal-check.mjs`):
///
/// - **A HIDDEN TERMINAL STILL BUILDS ROWS, AND BUILDS THEM WRONG.** Its renderer pauses while its
///   IntersectionObserver says it is out of view, but the selection service redraws every row on each
///   scroll by a line, selection or none (`SelectionService.refresh` → `RenderService.handleSelectionChanged`
///   → `DomRenderer.handleSelectionChanged` → `renderRows`), past the pause. Inside `display: none` every
///   glyph measures 0, so each row built then spaces its glyphs a cell apart (row-cache.ts, "THE GLYPH
///   WIDTHS"), with the CURRENT text. A fresh instance written hidden (a hidden tab's snapshot) builds them
///   too, in the frame before the observer first reports.
/// - **IT IS REDRAWN ONLY AFTER THE FIRST PAINT.** An IntersectionObserver's callback is a TASK queued by
///   the rendering update that shows the terminal — after that update has painted — so xterm.js resumes
///   (and row-cache.ts used to redraw) a frame late.
///
/// So this watches the terminal's element with a ResizeObserver, whose callback runs INSIDE that rendering
/// update, after layout and before paint: when the element goes from no box to a box, it resumes the
/// renderer as xterm.js's own observer would (`_handleIntersectionChange` — measuring the font if it was
/// opened hidden, applying a resize it held), asks for every row, and draws them NOW — the frame xterm.js
/// had pending (`RenderDebouncer._innerRefresh`, as `drawNow` in smooth-scroll.ts), since a frame asked for
/// from here would come after this paint. Every glyph measures right by then: the box exists. The row
/// cache keeps none built from a 0, so they are all rebuilt, and an unchanged row built measured is reused.
/// Every way a terminal comes into view goes through here — a tab switch, the terminal surface after the
/// window surface on a phone, leaving a window's full screen.
///
/// PRIVATE, asserted against the shipped xterm.js by `reveal-draw.test.ts`. Without those members (an
/// upgrade) it still asks for every row — drawn a frame late, which is where it was before this existed.

/// xterm.js's `RenderService`, the members this reads. PRIVATE.
interface RevealRenderService {
  _isPaused?: boolean;
  _handleIntersectionChange?(entry: { isIntersecting: boolean; intersectionRatio: number }): void;
  _renderDebouncer?: { _rowStart?: number; _animationFrame?: number; _innerRefresh?(): void };
}

function renderService(term: Terminal): RevealRenderService | null {
  return (term as unknown as { _core?: { _renderService?: RevealRenderService } })._core?._renderService ?? null;
}

/// Whether `el` has a box — false inside `display: none`, or detached.
function hasBox(el: Element): boolean { return el.getClientRects().length > 0; }

export class RevealDraw {
  private disposed = false;
  private readonly ro: ResizeObserver | null;
  /// Whether the element had a box at the last notification (at construction, read once).
  private shown: boolean;

  constructor(private readonly term: Terminal) {
    const el = term.element, RO = el?.ownerDocument.defaultView?.ResizeObserver;
    this.shown = !!el && hasBox(el);
    this.ro = el && RO ? new RO((entries) => {
      if (this.disposed) return;
      const box = entries[entries.length - 1]!.contentRect;
      const shown = box.width > 0 && box.height > 0;
      const came = shown && !this.shown;
      this.shown = shown;
      if (came) this.draw();
    }) : null;
    if (el) this.ro?.observe(el);
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.ro?.disconnect();
  }

  /// Resume, ask for every row, and draw them now.
  private draw(): void {
    const term = this.term, rs = renderService(term);
    if (rs?._isPaused === true && typeof rs._handleIntersectionChange === "function") {
      rs._handleIntersectionChange({ isIntersecting: true, intersectionRatio: 1 });
    }
    term.refresh(0, term.rows - 1);
    const d = rs?._renderDebouncer;
    if (!d || typeof d._innerRefresh !== "function" || d._rowStart === undefined || d._animationFrame === undefined) return;
    // Its frame, run now — the same work, the same order — and not again.
    term.element?.ownerDocument.defaultView?.cancelAnimationFrame(d._animationFrame);
    d._innerRefresh();
  }
}
