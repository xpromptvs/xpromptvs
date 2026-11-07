/// Hands xterm.js a SYNCHRONIZED frame (`?2026h` … `?2026l`) only WHOLE.
///
/// xterm.js 6 paints on an animation frame, and at that moment skips the paint (buffering the rows)
/// whenever `?2026` is ON — it checks the mode AT THE ANIMATION FRAME, not whether a frame has ended
/// since (`RenderService._renderRows`). An app that redraws inside ?2026 (Claude Code does) sends
/// frames back to back; when each frame reaches the page in pieces, the next frame's `?2026h` has
/// usually been parsed by the time the animation frame runs, so the paint is skipped again, and again:
/// nothing paints until the stream pauses. MEASURED (2026-09-28, tmux 3.7c): during a wheel flick tmux
/// reads a busy pane a few dozen bytes at a time (docs/terminal.md, "WHY tmux SOMETIMES READS A PANE
/// 1-5 BYTES AT A TIME"), the host forwards each read unheld within 500 ms of input, and 40 frames of
/// ~9 KB streamed over one second painted 0 times on WebKit and 19 on Chromium when they arrived as
/// 48-byte messages — 40 of 40 on both when each arrived whole.
///
/// So text from an opening `?2026h` is HELD until the frame ends, and every release ends OUTSIDE a
/// frame: the animation frame after any write sees the mode off, and paints. A frame that has not
/// ended after `SYNC_FRAME_HOLD_MS` is released as it stands (xterm.js then buffers it itself, under
/// its own 1 s timeout), so an app that never ends one costs one cap, not a frozen terminal. A frame
/// that carries something xterm.js ANSWERS (`QUERY`) is not held either: an app may wait for the
/// answer before it ends the frame.
///
/// What ends a frame is what turns the mode off in xterm.js: `?2026l` (alone or among other modes),
/// DECSTR (`CSI ! p`, a soft reset — every snapshot opens with one) and RIS (`ESC c`). The 8-bit CSI
/// (U+009B) is read as xterm.js reads it. A partial sequence at the end of a push is held until the
/// next one, so a marker split between two messages is still seen.
export const SYNC_FRAME_HOLD_MS = 500;

export interface SyncFrameTimers<T = unknown> {
  set(f: () => void, ms: number): T;
  clear(t: T): void;
}

/// DECSET/DECRST with their parameter list, DECSTR, RIS. Group 1: the DEC private mode list; group 2:
/// `h` or `l`. No group: a reset.
const MARKER = /(?:\x1b\[|\u009b)(?:\?([0-9;]*)([hl])|!p)|\x1bc/g;
/// Something xterm.js ANSWERS (protocol/fixtures/term-reply-handlers.json: CSI `c`, `n`, `t`, `$p`
/// with any prefix; DCS `$q` — any DCS here, as the host's send buffer does; OSC 4/10/11/12 asking
/// with `?`). Inside an open frame one ends the hold: an app that waits for the answer before it ends
/// its frame must not wait for the cap.
const QUERY = /(?:\x1b\[|\u009b)[<=>?]?[0-9;:]*(?:\$p|[cnt])|\x1bP|\u0090|(?:\x1b\]|\u009d)(?:4|10|11|12);[^\x07\x1b\u009c]*\?/g;
/// A push that ENDS partway into something `MARKER` could match.
const PARTIAL_TAIL = /(?:\x1b(?:\[[?!]?[0-9;]*)?|\u009b[?!]?[0-9;]*)$/;
/// How far back into held text a marker or query split by the previous push can begin (a longer
/// sequence than this is not something a real app sends).
const LOOKBACK = 128;

export class SyncFrameGate<T = unknown> {
  /// Unreleased text, in pieces (joined only when released, so holding a long frame is linear): an
  /// open frame from its opening marker, or a partial sequence.
  private parts: string[] = [];
  private heldLen = 0;
  /// The last `LOOKBACK` characters of the held text.
  private tail = "";
  /// The held text starts with an opening marker whose frame has not ended.
  private open = false;
  private timer: T | undefined;
  private disposed = false;

  constructor(
    private readonly release: (text: string) => void,
    private readonly timers: SyncFrameTimers<T>,
    private readonly capMs = SYNC_FRAME_HOLD_MS,
  ) {}

  push(text: string): void {
    if (this.disposed || text === "") return;
    // Scan `w`, which sits at `base` in the held text + `text`: everything when nothing is open (the
    // held text is then a short partial), else the lookback and the new text — what came before was
    // scanned already and held neither an end nor a query.
    const w = (this.open ? this.tail : this.parts.join("")) + text;
    const base = this.heldLen + text.length - w.length;
    let open = this.open;
    let frameStart = open ? 0 : -1;
    MARKER.lastIndex = 0;
    for (let m = MARKER.exec(w); m; m = MARKER.exec(w)) {
      if (m[2] === undefined) {                                  // DECSTR / RIS: the mode goes off
        open = false; frameStart = -1;
      } else if ((m[1] ?? "").split(";").includes("2026")) {
        if (m[2] === "h" && !open) { open = true; frameStart = base + m.index; }
        else if (m[2] === "l") { open = false; frameStart = -1; }
      }
    }
    if (open) {
      QUERY.lastIndex = Math.max(0, frameStart - base);
      if (QUERY.test(w)) { open = false; frameStart = -1; }     // an answer is owed: stop holding
      QUERY.lastIndex = 0;
    }
    const total = this.heldLen + text.length;
    const cut = open ? frameStart : total - (PARTIAL_TAIL.exec(w)?.[0].length ?? 0);
    const wasHolding = this.heldLen > 0;
    this.open = open;
    if (cut === 0) {                                             // the hold continues from its start
      this.parts.push(text);
      this.heldLen = total;
      this.tail = (this.tail + text).slice(-LOOKBACK);
    } else {
      const s = this.parts.join("") + text;
      const rest = s.slice(cut);
      this.parts = rest === "" ? [] : [rest];
      this.heldLen = rest.length;
      this.tail = rest.slice(-LOOKBACK);
      this.release(s.slice(0, cut));
    }
    // The cap runs from when a hold STARTS: a new hold (nothing held before, or the old one released
    // by this push) gets a fresh timer, a continuing one keeps its own.
    if (this.heldLen === 0) this.stopTimer();
    else if (!wasHolding || cut > 0) { this.stopTimer(); this.timer = this.timers.set(() => this.expire(), this.capMs); }
  }

  /// Drop what is held; nothing is released after this.
  dispose(): void {
    this.disposed = true;
    this.stopTimer();
    this.clear();
  }

  private expire(): void {
    this.timer = undefined;
    const t = this.parts.join("");
    this.clear();
    if (t !== "") this.release(t);
  }

  private clear(): void {
    this.parts = [];
    this.heldLen = 0;
    this.tail = "";
    this.open = false;
  }

  private stopTimer(): void {
    if (this.timer !== undefined) { this.timers.clear(this.timer); this.timer = undefined; }
  }
}
