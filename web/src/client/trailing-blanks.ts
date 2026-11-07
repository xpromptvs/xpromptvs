import type { IDisposable, Terminal } from "@xterm/xterm";

/// **TRAILING BLANK LINES DO NOT EXIST IN AN AGENT'S TAB** (asked 2026-10-14: "On the client, we should treat trailing
/// empty lines as non-existing"; docs/terminal.md, "An agent's tab ends at its last line").
///
/// An agent redraws from the top of the screen — Claude Code after a clear or a resize — and its UI is then followed
/// by empty rows to the bottom: on a phone, 16 of 40 rows under the input box, the conversation pushed up out of view.
/// The host's screen really holds them (tmux's own pane did, measured), so the CLIENT hides them: the view's last line
/// is the screen's last row with anything drawn — never above the cursor's — and the scrollback above makes up the
/// rows. The view is scrolled there and is never scrolled below it; output that fills those rows, or erases above
/// them, moves the end and a view at the end follows it. The screen itself is untouched, so the cursor, every
/// absolute position the program writes and the host's grid stay what they are.
///
/// Only where an agent runs (session.ts, from `term-list.agent`): a shell after `clear` keeps its blank screen. Never
/// on the alternate screen, and never under a mouse-tracking app — xterm.js reports the VIEW's rows, which a view
/// scrolled by the hidden rows would put off by that many.
///
/// The view is scrolled with xterm.js's own `scrollToLine`, so the rows that come into view are real rows — selection,
/// image paths, links and the scrollbar work on them. That puts xterm.js in its "scrolled back" state, where it holds
/// the view still under output; so FOLLOWING is this class's to decide: the view follows while it is at or below the
/// line it was last put on (`pinnedAt`) — xterm.js never moves it down by itself there, so a view above it was moved
/// by the person. At the scrollback's cap xterm.js trims as it scrolls and moves the view UP to keep it on the same
/// text; that is not the person either, so `pinnedAt` is moved with it (`onTrim`, the buffer's PRIVATE line list).

/// How many rows at the bottom of the screen are taken as not there: those below both the last row with anything
/// drawn (`lastDrawnRow`, -1 for none) and the cursor's row. Never more than the scrollback can make up (`baseY`).
export function hiddenRows(m: { rows: number; cursorY: number; lastDrawnRow: number; baseY: number }): number {
  const bottom = Math.max(m.cursorY, m.lastDrawnRow);
  return Math.max(0, Math.min(m.baseY, m.rows - 1 - bottom));
}

/// The cursor's row in the VIEW: its screen row plus the rows the view rests into the scrollback — or null when the
/// view is scrolled back past the content's end, where the cursor is not on screen to keep (session.ts, `cursorTop`,
/// which the soft keyboard's shift keeps below the top). With nothing hidden that is the bottom, as it always was.
export function cursorViewRow(m: { cursorY: number; baseY: number; viewportY: number; hidden: number }): number | null {
  const up = m.baseY - m.viewportY;
  return up > m.hidden ? null : m.cursorY + up;
}

/// The last row of the screen with anything to see — a glyph, or a cell with a background of its own (an inverse
/// cell's is its foreground) — or -1.
export function lastDrawnRow(term: Pick<Terminal, "rows" | "buffer">): number {
  const b = term.buffer.active;
  const cell = b.getNullCell();
  for (let y = term.rows - 1; y >= 0; y--) {
    const line = b.getLine(b.baseY + y);
    if (!line) continue;
    if (line.translateToString(true) !== "") return y;
    for (let x = 0; x < line.length; x++) {
      const c = line.getCell(x, cell);
      if (c && (!c.isBgDefault() || c.isInverse())) return y;
    }
  }
  return -1;
}

/// The normal buffer's line list — PRIVATE (xterm.js 6's `_core._bufferService.buffers.normal.lines`), for its
/// `onTrim`. Null when an upgrade moved it: following then stops at the scrollback's cap until the person scrolls
/// to the end or types (`trailing-blanks.test.ts` asserts it is there).
type TrimList = { onTrim(cb: (n: number) => void): IDisposable };
function normalLines(term: Terminal): TrimList | null {
  const lines = (term as unknown as { _core?: { _bufferService?: { buffers?: { normal?: { lines?: Partial<TrimList> } } } } })
    ._core?._bufferService?.buffers?.normal?.lines;
  return lines && typeof lines.onTrim === "function" ? (lines as TrimList) : null;
}

export class TrailingBlanks {
  private on = false;
  /// The line the view was last put on at the content's end; -1 before any (a view at the bottom follows).
  private pinnedAt = -1;
  /// This class's own scroll is under way: the `onScroll` it fires is not a reason to look again.
  private moving = false;
  /// A look is queued (`update`): whether any reason for it was NOT a scroll, which lets the view follow.
  private queued: { follow: boolean } | null = null;
  private lines: TrimList | null = null;
  private trimSub: IDisposable | null = null;
  private readonly subs: IDisposable[];

  constructor(private readonly term: Terminal) {
    this.subs = [
      term.onWriteParsed(() => this.update(false)),
      term.onResize(() => this.update(false)),
      term.buffer.onBufferChange(() => this.update(false)),
      // Typing: xterm.js has already scrolled to the BOTTOM (`scrollOnUserInput`), in this task — the clamp that
      // follows brings it to the end before anything is drawn.
      term.onData(() => this.update(false)),
      term.onScroll(() => this.update(true)),
      // A wheel, a finger and smooth scrolling move the view through xterm.js's Viewport, which fires no `onScroll`
      // (measured: the wheel ran past the end, trailing-blanks-check T4) — every redraw looks too. At worst one frame
      // shows past the end before the next is put back, as a list's end stops a fling; smooth scrolling takes this
      // class's scroll as somebody else's and ends its animation there.
      term.onRender(() => this.update(true)),
    ];
    this.watchTrims();
  }

  /// An agent runs in the tab (on) or not (off). Off, a view at the end goes back to the bottom.
  set(on: boolean): void {
    if (on === this.on) return;
    this.on = on;
    if (on) { this.look(false); return; }
    const b = this.term.buffer.active;
    if (this.following()) this.scrollTo(b.baseY);
    this.pinnedAt = -1;
  }

  /// The rows taken as not there now: 0 when off, on the alternate screen or under a mouse-tracking app.
  hidden(): number {
    if (!this.on) return 0;
    const t = this.term, b = t.buffer.active;
    if (b.type === "alternate" || t.modes.mouseTrackingMode !== "none") return 0;
    return hiddenRows({ rows: t.rows, cursorY: b.cursorY, lastDrawnRow: lastDrawnRow(t), baseY: b.baseY });
  }

  /// The last line the view may start at — the content's end.
  end(): number { return this.term.buffer.active.baseY - this.hidden(); }

  dispose(): void {
    for (const s of this.subs) s.dispose();
    this.trimSub?.dispose();
    this.trimSub = null;
  }

  private following(): boolean {
    const b = this.term.buffer.active;
    return this.pinnedAt < 0 ? b.viewportY >= b.baseY : b.viewportY >= this.pinnedAt;
  }

  /// **NEVER FROM INSIDE xterm.js's OWN EVENT** — a microtask after it, before anything is drawn. Scrolled from
  /// inside xterm.js's `onScroll` while it scrolled to the bottom for a keystroke, its row and its scrollable's
  /// position disagreed, both of this class's scrolls applied their delta, and the view landed `hidden` rows too FAR
  /// UP (measured: line 6 where the end was 29, trailing-blanks-check T5).
  private update(scrolled: boolean): void {
    if (!this.on || this.moving) return;
    if (this.queued) { this.queued.follow ||= !scrolled; return; }
    this.queued = { follow: !scrolled };
    queueMicrotask(() => {
      const q = this.queued;
      this.queued = null;
      if (q) this.look(!q.follow);
    });
  }

  private look(scrolled: boolean): void {
    if (!this.on) return;
    this.watchTrims();
    const b = this.term.buffer.active;
    const end = this.end();
    // Never on a line that is not there; and a view at the end follows it — but a scroll is the person's (or
    // xterm.js's own, which the clamp answers): it moves nothing that is above the end.
    if (b.viewportY > end || (!scrolled && b.viewportY !== end && this.following())) this.scrollTo(end);
    if (b.viewportY === end) this.pinnedAt = end;
  }

  private scrollTo(line: number): void {
    this.moving = true;
    try { this.term.scrollToLine(line); } finally { this.moving = false; }
  }

  /// `onTrim` on the normal buffer's CURRENT line list (a reset replaces it).
  private watchTrims(): void {
    const lines = normalLines(this.term);
    if (lines === this.lines) return;
    this.trimSub?.dispose();
    this.lines = lines;
    this.trimSub = lines?.onTrim((n) => { if (this.pinnedAt >= 0) this.pinnedAt = Math.max(0, this.pinnedAt - n); }) ?? null;
  }
}
