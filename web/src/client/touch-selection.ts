import type { Terminal } from "@xterm/xterm";
import { CLICK_SWALLOW_MS } from "./press-hold";

/// **SELECTING TERMINAL TEXT WITH A FINGER** (2026-10-04, asked for; docs/client-web.md, "Selecting text on a
/// touch screen"). xterm.js selects only with a mouse, so a phone could not copy anything out of a terminal.
///
/// - A HOLD on text (press-hold.ts's, the one that opens the paste menu) selects the WORD under the finger — the
///   terminal's own word rule (`wordSeparator`) — and the menu opens with Copy first, at the selection. A hold on
///   blank space selects nothing: the paste menu, as before.
/// - KEEPING THE FINGER DOWN AND MOVING extends it, from the word, as iOS does: the menu steps aside while it
///   moves and comes back when the finger lifts.
/// - Two HANDLES (`.term-sel-handle`, the start's knob above, the end's below) adjust either end; a handle press
///   closes the menu WITHOUT being swallowed (`ContextMenu`'s pass-through) and the menu comes back on the lift.
///   They live in `#term-surface`, beside `#xterm` — never inside it, where the touch scroll, the hold and
///   xterm.js's own mouse handling would take their drags. A drag past the screen's top or bottom scrolls.
/// - The selection IS xterm.js's (`term.select`), so both renderers draw it in the selection colour, Copy and
///   ⌘C read it, and the iPad's copy mirror follows it — into a FOCUSED textarea only: `select()` moves focus,
///   and mirroring a finger's selection raised the iPhone's keyboard on every handle drag (terminal-copy.ts).
///   Copy writes the clipboard inside the pick (Safari ties the permission to the gesture). It goes when the
///   menu closes any other way — Escape, a resize — or when the shown terminal changes or xterm.js drops it.
/// - THE FIRST PRESS ANYWHERE ELSE ONLY ENDS IT (asked for, 2026-10-04): no keyboard, no tab switched, nothing to
///   the program. With the menu up, the menu's own swallow does it (a press that closes a menu does nothing else,
///   context-menu.ts); for a selection whose menu is down, this does — the press whole, its release, and the
///   mouse events and click iOS synthesizes after it.

/// A cell of the terminal's BUFFER: `row` counts from the top of the scrollback.
export interface Cell { col: number; row: number }

/// What reading a buffer cell needs: its characters ("" for blank) and width (0 for a wide glyph's second cell).
export type CellAt = (col: number) => { chars: string; width: number } | null;

/// The word at `col` — the run of cells that are neither blank nor a separator, a wide glyph whole — or null on
/// blank space or a separator.
export function wordAt(cell: CellAt, cols: number, col: number, separators: string): { start: number; end: number } | null {
  const isWord = (x: number): boolean => {
    let c = cell(x);
    // A wide glyph's second cell is its first's.
    if (c && c.width === 0 && x > 0) c = cell(x - 1);
    return !!c && c.chars !== "" && c.chars.trim() !== "" && !separators.includes(c.chars);
  };
  if (col < 0 || col >= cols || !isWord(col)) return null;
  let start = col, end = col;
  while (start > 0 && isWord(start - 1)) start--;
  while (end < cols - 1 && isWord(end + 1)) end++;
  return { start, end };
}

/// The buffer cell under a point, given the screen's box, the grid and the first row shown; clamped to the grid.
export function cellAt(x: number, y: number, screen: { left: number; top: number; width: number; height: number },
                       cols: number, rows: number, viewportY: number): Cell {
  const cw = screen.width / cols, ch = screen.height / rows;
  const col = Math.max(0, Math.min(cols - 1, Math.floor((x - screen.left) / cw)));
  const r = Math.max(0, Math.min(rows - 1, Math.floor((y - screen.top) / ch)));
  return { col, row: viewportY + r };
}

/// Two cells in either order as xterm.js's `select(column, row, length)` takes them — `length` counts cells,
/// wrapping at `cols`, both ends included.
export function selectRange(a: Cell, b: Cell, cols: number): { col: number; row: number; length: number } {
  const [s, e] = before(a, b) ? [a, b] : [b, a];
  return { col: s.col, row: s.row, length: (e.row - s.row) * cols + (e.col - s.col) + 1 };
}

export function before(a: Cell, b: Cell): boolean { return a.row < b.row || (a.row === b.row && a.col <= b.col); }

export interface TouchSelectionDeps {
  signal: AbortSignal;
  /// The shown terminal.
  term(): Terminal | null;
  /// The menu, for the selection: open it at `anchor` (Copy first) / out of the way while a finger moves.
  showMenu(anchor: DOMRect): void;
  hideMenu(): void;
}

const EDGE_SCROLL_MS = 70;

export class TouchSelection {
  private term: Terminal | null = null;
  private start: Cell | null = null;
  private end: Cell | null = null;
  /// The word a hold selected — a hold's drag extends from it.
  private word: { start: Cell; end: Cell } | null = null;
  /// A finger is moving an end: the hold's own, or a handle's. The menu closing meanwhile is not the end.
  private moving: "hold" | "start" | "end" | null = null;
  private moved = false;
  private grab = { dx: 0, dy: 0 };
  private edgeTimer: ReturnType<typeof setInterval> | null = null;
  private lastPoint = { x: 0, y: 0 };
  private readonly layer: HTMLElement;
  private readonly handles: { start: HTMLElement; end: HTMLElement };
  private subs: Array<{ dispose(): void }> = [];

  constructor(surface: HTMLElement, private readonly deps: TouchSelectionDeps) {
    const doc = surface.ownerDocument;
    this.layer = doc.createElement("div");
    this.layer.className = "term-sel-handles";
    const handle = (which: "start" | "end") => {
      const h = doc.createElement("div");
      h.className = `term-sel-handle term-sel-${which}`;
      h.hidden = true;
      h.addEventListener("pointerdown", (e) => this.handleDown(which, e), { signal: deps.signal });
      h.addEventListener("pointermove", (e) => { if (this.moving === which) this.drag(e.clientX, e.clientY); }, { signal: deps.signal });
      const up = (e: PointerEvent) => { if (this.moving === which) this.release(e); };
      h.addEventListener("pointerup", up, { signal: deps.signal });
      h.addEventListener("pointercancel", up, { signal: deps.signal });
      // No mouse events, no focus moved (a phone's keyboard would come up), no browser gesture.
      h.addEventListener("touchstart", (e) => e.preventDefault(), { signal: deps.signal, passive: false });
      this.layer.append(h);
      return h;
    };
    this.handles = { start: handle("start"), end: handle("end") };
    surface.append(this.layer);
    // A hold's finger, moving: window CAPTURE, ahead of press-hold's own listener on the terminal, which keeps
    // the rest of a held gesture from everything under it.
    window.addEventListener("pointermove", (e) => {
      if (this.moving !== "hold" || e.pointerType === "mouse") return;
      if (!this.moved) { this.moved = true; this.deps.hideMenu(); }
      this.drag(e.clientX, e.clientY);
    }, { signal: deps.signal, capture: true });
    const holdUp = (e: PointerEvent) => { if (this.moving === "hold" && e.pointerType !== "mouse") this.release(e); };
    window.addEventListener("pointerup", holdUp, { signal: deps.signal, capture: true });
    window.addEventListener("pointercancel", holdUp, { signal: deps.signal, capture: true });
    window.addEventListener("resize", () => this.place(), { signal: deps.signal });
    this.swallowFirstPress(deps.signal);
    deps.signal.addEventListener("abort", () => { this.stopEdge(); this.unsubscribe(); this.layer.remove(); });
  }

  get active(): boolean { return this.start !== null; }
  /// A finger is moving an end (`ContextMenu`'s close is then not the selection's end).
  get busy(): boolean { return this.moving !== null; }
  /// A press on one of the handles: the menu lets it through.
  owns(n: Node | null): boolean { return !!n && this.layer.contains(n); }

  text(): string { return this.term?.getSelection() ?? ""; }

  /// A hold at a point: select the word there. False on blank space (nothing selected).
  holdAt(at: { x: number; y: number }): boolean {
    const term = this.deps.term();
    const screen = screenBox(term);
    if (!term || !screen) return false;
    const buf = term.buffer.active;
    const c = cellAt(at.x, at.y, screen, term.cols, term.rows, buf.viewportY);
    const line = buf.getLine(c.row);
    const nul = buf.getNullCell();
    const word = line ? wordAt((x) => {
      const cell = line.getCell(x, nul);
      return cell ? { chars: cell.getChars(), width: cell.getWidth() } : null;
    }, term.cols, c.col, term.options.wordSeparator ?? " ()[]{}',\"`") : null;
    if (!word) { this.clear(); return false; }
    this.adopt(term);
    this.word = { start: { col: word.start, row: c.row }, end: { col: word.end, row: c.row } };
    this.start = this.word.start;
    this.end = this.word.end;
    this.moving = "hold";
    this.moved = false;
    this.apply();
    return true;
  }

  /// The selection's box on screen (the menu's anchor), or null with none shown.
  anchor(): DOMRect | null {
    const term = this.term, screen = screenBox(term);
    if (!term || !screen || !this.start || !this.end) return null;
    const cw = screen.width / term.cols, ch = screen.height / term.rows, top = term.buffer.active.viewportY;
    const y0 = Math.max(0, this.start.row - top), y1 = Math.min(term.rows - 1, this.end.row - top);
    if (y1 < 0 || y0 > term.rows - 1) return null;
    const multi = this.end.row > this.start.row;
    const x0 = multi ? 0 : this.start.col, x1 = multi ? term.cols - 1 : this.end.col;
    return new DOMRect(screen.left + x0 * cw, screen.top + y0 * ch, (x1 - x0 + 1) * cw, (y1 - y0 + 1) * ch);
  }

  /// The menu closed: the selection goes with it — unless a finger is moving an end, which closed it.
  menuClosed(): void { if (!this.moving) this.clear(); }

  clear(): void {
    const had = this.start !== null;
    this.start = this.end = this.word = null;
    this.moving = null;
    this.stopEdge();
    this.place();
    if (had && this.term?.hasSelection()) this.term.clearSelection();
    this.unsubscribe();
    this.term = null;
  }

  // ---- internals ------------------------------------------------------------------------------------------

  /// A press outside the handles and any menu, while a selection stands and no finger is moving it: the selection
  /// ends and the press does nothing else. Window CAPTURE, after the menu's (registered first): with the menu up,
  /// its swallow stops the press before this sees it.
  private swallowFirstPress(signal: AbortSignal): void {
    let press: { id: number; until: number } | null = null;
    const capture = { signal, capture: true };
    const live = () => !!press && (press.until === 0 || Date.now() < press.until);
    const stop = (e: Event) => { if (e.cancelable) e.preventDefault(); e.stopImmediatePropagation(); };
    window.addEventListener("pointerdown", (e) => {
      if (press && !live()) press = null;
      // Window listeners see the ShadowRoot host as target. Inspect the original node so a Copy
      // pick or handle press is not mistaken for an outside tap and swallowed.
      const t = e.composedPath()[0] as Element | null;
      if (!this.start || this.moving || this.owns(t) || t?.closest?.(".ctx-menu")) return;
      this.clear();
      this.deps.hideMenu();
      press = { id: e.pointerId, until: 0 };
      stop(e);
    }, capture);
    window.addEventListener("pointermove", (e) => { if (press?.until === 0 && e.pointerId === press.id) e.stopImmediatePropagation(); }, capture);
    for (const type of ["pointerup", "pointercancel"] as const) {
      window.addEventListener(type, (e) => {
        if (press?.until !== 0 || e.pointerId !== press.id) return;
        e.stopImmediatePropagation();
        press.until = Date.now() + CLICK_SWALLOW_MS;
      }, capture);
    }
    window.addEventListener("touchend", (e) => { if (live()) stop(e); }, { ...capture, passive: false });
    for (const type of ["mousedown", "mouseup", "dblclick", "contextmenu"] as const) {
      window.addEventListener(type, (e) => { if (live()) stop(e); }, capture);
    }
    window.addEventListener("click", (e) => { if (live()) { stop(e); press = null; } }, capture);
  }

  private adopt(term: Terminal): void {
    if (this.term === term) return;
    this.unsubscribe();
    this.term = term;
    const placeLater = () => this.place();
    this.subs = [
      term.onRender(placeLater),
      term.onScroll(placeLater),
      term.onResize(() => this.clear()),
      // xterm.js dropped it (a click, the buffer it was in going away): so do we, and the menu.
      term.onSelectionChange(() => {
        if (this.start && !this.moving && !term.hasSelection()) { this.clear(); this.deps.hideMenu(); }
      }),
    ];
  }

  private unsubscribe(): void { for (const s of this.subs) s.dispose(); this.subs = []; }

  private apply(): void {
    const term = this.term;
    if (!term || !this.start || !this.end) return;
    const r = selectRange(this.start, this.end, term.cols);
    term.select(r.col, r.row, r.length);
    this.place();
  }

  /// The handles where the ends are on screen; hidden off it.
  private place(): void {
    const term = this.term, screen = screenBox(term);
    for (const [which, h] of Object.entries(this.handles) as Array<["start" | "end", HTMLElement]>) {
      const at = which === "start" ? this.start : this.end;
      if (!term || !screen || !at) { h.hidden = true; continue; }
      const row = at.row - term.buffer.active.viewportY;
      if (row < 0 || row >= term.rows) { h.hidden = true; continue; }
      const cw = screen.width / term.cols, ch = screen.height / term.rows;
      const box = this.layer.getBoundingClientRect();
      // The start's bar runs down its first cell's left edge from the top; the end's up its last cell's right edge.
      const x = screen.left + (which === "start" ? at.col : at.col + 1) * cw - box.left;
      const y = screen.top + (which === "start" ? row : row + 1) * ch - box.top;
      h.hidden = false;
      h.style.left = `${x}px`;
      h.style.top = `${y}px`;
      h.style.setProperty("--cell-h", `${ch}px`);
    }
  }

  private handleDown(which: "start" | "end", e: PointerEvent): void {
    if (!this.term || !this.start || !this.end) return;
    e.preventDefault();
    e.stopPropagation();
    (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
    // Where the finger is against the end it took, so the end does not jump under it.
    const screen = screenBox(this.term)!;
    const cw = screen.width / this.term.cols, ch = screen.height / this.term.rows;
    const at = which === "start" ? this.start : this.end;
    const row = at.row - this.term.buffer.active.viewportY;
    const cx = screen.left + (at.col + 0.5) * cw, cy = screen.top + (row + 0.5) * ch;
    this.grab = { dx: e.clientX - cx, dy: e.clientY - cy };
    this.moving = which;
    this.moved = false;
    this.deps.hideMenu();
  }

  /// The moving end follows the point (the hold's from its word); crossing the other end swaps them.
  private drag(x: number, y: number): void {
    const term = this.term, screen = screenBox(term);
    if (!term || !screen || !this.start || !this.end) return;
    this.moved = true;
    this.lastPoint = { x, y };
    const grab = this.moving === "hold" ? { dx: 0, dy: 0 } : this.grab;
    const c = cellAt(x - grab.dx, y - grab.dy, screen, term.cols, term.rows, term.buffer.active.viewportY);
    if (this.moving === "hold" && this.word) {
      if (before(c, this.word.start)) { this.start = c; this.end = this.word.end; }
      else { this.start = this.word.start; this.end = before(c, this.word.end) ? this.word.end : c; }
    } else if (this.moving === "start") {
      if (before(c, this.end)) this.start = c; else { this.start = this.end; this.end = c; this.moving = "end"; }
    } else if (this.moving === "end") {
      if (before(this.start, c)) this.end = c; else { this.end = this.start; this.start = c; this.moving = "start"; }
    }
    this.apply();
    // Past the screen's top or bottom: the scrollback comes to the finger.
    const above = y - grab.dy < screen.top, below = y - grab.dy > screen.top + screen.height;
    if (above || below) this.startEdge(); else this.stopEdge();
  }

  private startEdge(): void {
    if (this.edgeTimer !== null) return;
    this.edgeTimer = setInterval(() => {
      const term = this.term, screen = screenBox(term);
      if (!term || !this.moving || !screen) { this.stopEdge(); return; }
      const dy = this.moving === "hold" ? 0 : this.grab.dy;
      term.scrollLines(this.lastPoint.y - dy < screen.top ? -1 : 1);
      this.drag(this.lastPoint.x, this.lastPoint.y);
    }, EDGE_SCROLL_MS);
  }

  private stopEdge(): void { if (this.edgeTimer !== null) { clearInterval(this.edgeTimer); this.edgeTimer = null; } }

  /// The finger lifted: the menu comes back, at the selection.
  private release(e: PointerEvent): void {
    this.stopEdge();
    const wasHold = this.moving === "hold";
    const moved = this.moved;
    this.moving = null;
    (e.target as HTMLElement | null)?.releasePointerCapture?.(e.pointerId);
    // A hold that never moved left its menu up; anything else brings it back.
    if (wasHold && !moved) return;
    const a = this.anchor();
    if (a) this.deps.showMenu(a); else this.clear();
  }
}

/// The terminal's screen element's box (`.xterm-screen`: the grid, where the rows are drawn at rest).
function screenBox(term: Terminal | null): DOMRect | null {
  const el = term?.element?.querySelector<HTMLElement>(".xterm-screen");
  const r = el?.getBoundingClientRect();
  return r && r.width > 0 && r.height > 0 ? r : null;
}
