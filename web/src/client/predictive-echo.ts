/// Pure prediction logic for local terminal echo. Predictions render as an opaque overlay on top of xterm
/// (see prediction-overlay.ts); this module owns the reconciliation, the model state, and the gate. No DOM.

export interface Cursor { row: number; col: number }

/// Reconcile predictions against the terminal's ACTUAL buffer after the server bytes were applied.
/// `anchor` = the authoritative cursor before the server bytes (where predictions start); `cursor` = the
/// cursor after them. We compare the cells the cursor advanced over to the predicted chars, using the real
/// buffer — so any redraw (backspace, CR, cursor move, re-emitted confirmed chars) reconciles correctly,
/// because the buffer already reflects the true line. Returns the surviving (still-un-echoed) predictions
/// and whether the echo matched (false = a real mismatch or a backward/ambiguous move → withdraw + resync).
export function validatePredictions(
  anchor: Cursor,
  cursor: Cursor,
  predicted: string,
  cols: number,
  cellAt: (row: number, col: number) => string,
): { survivors: string; matched: boolean } {
  const lin = (c: Cursor) => c.row * cols + c.col;
  const delta = lin(cursor) - lin(anchor);
  if (delta <= 0) return { survivors: "", matched: false };   // no forward progress → resync (drop all)
  const a = lin(anchor);
  const max = Math.min(delta, predicted.length);
  let m = 0;
  for (; m < max; m++) {
    const p = a + m;
    if (cellAt(Math.floor(p / cols), p % cols) !== predicted[m]) break;   // buffer disagrees with our guess
  }
  if (m < max) return { survivors: "", matched: false };          // mismatch → withdraw all remaining
  if (predicted.length <= delta) return { survivors: "", matched: true };   // all predictions confirmed
  return { survivors: predicted.slice(delta), matched: true };     // delta confirmed; ghosts past cursor survive
}

const STALE_FLOOR_MS = 2500;   // clear ghosts unconfirmed this long — must exceed realistic echo latency, or
const STALE_RTT_FACTOR = 4;    // it wrongly wipes ghosts still in flight on a slow link (exposing the replay)

/// True when the oldest still-shown ghost has gone unconfirmed too long — e.g. a no-echo password prompt
/// (`sudo`, `read -s`) where the shell never echoes, so ghosts would otherwise linger until the next output.
/// The threshold MUST exceed the real round-trip echo latency, otherwise it clears a ghost whose echo is
/// simply still in flight (which then reveals the authoritative replay under the overlay). The RTT estimate
/// can under-read on bursty/pipelined typing, so the FLOOR is deliberately generous; Enter clears sooner.
export function isGhostStale(ghostSinceMs: number | null, nowMs: number, rttMs: number): boolean {
  if (ghostSinceMs == null) return false;
  return nowMs - ghostSinceMs > Math.max(STALE_FLOOR_MS, rttMs * STALE_RTT_FACTOR);
}

/// Ordered edit states, not just the final string. An echo of "abc" cannot confirm "ab"
/// while its Backspace is still in flight. Matching is conservative: repeated states confirm
/// the EARLIEST possible edit, never a later coincidentally-identical one.
export class OverlayModel {
  private predicted = "";
  private confirmed = "";
  private anchor: Cursor | null = null;
  private offset = 0;
  private width = 0;
  private capacity = Infinity;
  private field = false;
  private edited = false;
  private pending: { text: string; cursor: number }[] = [];

  text(): string { return this.predicted; }
  paintText(): string { return this.predicted.padEnd(this.width, " "); }
  pendingCells(): boolean[] {
    return Array.from(this.paintText(), (ch, i) => ch !== (this.confirmed[i] ?? " "));
  }
  hasPendingEmpty(): boolean { return this.pending.some(s => s.text.length === 0); }
  cursorOffset(): number { return this.offset; }
  anchorAt(): Cursor | null { return this.anchor; }
  active(): boolean { return this.pending.length > 0; }
  inField(): boolean { return this.field; }
  fieldCapacity(): number { return this.capacity; }

  /// A positively recognized single visual row. Unknown wrapping/multiline semantics are refused
  /// by the recognizer; the capacity stops new edits before they can move its borders or footer.
  beginField(anchor: Cursor, text: string, cursor: number, capacity: number, coverWidth = text.length): void {
    this.reset(); this.anchor = { ...anchor }; this.predicted = text;
    this.confirmed = text;
    this.offset = cursor; this.width = Math.max(text.length, coverWidth); this.capacity = capacity; this.field = true;
  }

  predictChar(ch: string, cursor: Cursor): boolean {
    if (!this.anchor) this.anchor = { ...cursor };
    if (this.predicted.length >= this.capacity || this.pending.length >= 512) { this.reset(); return false; }
    this.predicted = this.predicted.slice(0, this.offset) + ch + this.predicted.slice(this.offset);
    this.offset += ch.length; this.record(); return true;
  }

  backspace(): boolean {
    if (!this.anchor || this.offset === 0) return false;
    this.predicted = this.predicted.slice(0, this.offset - 1) + this.predicted.slice(this.offset);
    this.offset--; this.edited = true; this.record(); return true;
  }

  private record(): void {
    this.width = Math.max(this.width, this.predicted.length);
    this.pending.push({ text: this.predicted, cursor: this.offset });
  }

  reset(): void {
    this.predicted = ""; this.anchor = null; this.offset = 0; this.width = 0;
    this.confirmed = "";
    this.pending = []; this.capacity = Infinity; this.field = false; this.edited = false;
  }

  reconcile(cursor: Cursor, cols: number, cellAt: (r: number, c: number) => string): { matched: boolean; cleared: boolean; definitive: boolean } {
    if (!this.anchor || !this.active()) return { matched: true, cleared: true, definitive: false };
    const start = this.anchor.row * cols + this.anchor.col;
    const delta = cursor.row * cols + cursor.col - start;
    const matches = (s: { text: string; cursor: number }) => {
      if (delta !== s.cursor) return false;
      // Deletions also acknowledge the erased tail. An old visible character cannot be hidden
      // by a cleared overlay simply because the cursor happened to move left over it.
      const n = this.edited || this.field ? this.width : s.text.length;
      for (let i = 0; i < n; i++) {
        const pos = start + i;
        if (cellAt(Math.floor(pos / cols), pos % cols) !== (s.text[i] ?? " ")) return false;
      }
      return true;
    };
    const index = this.pending.findIndex(matches);
    if (index < 0) return { matched: false, cleared: false, definitive: delta > this.width };
    const confirmed = this.pending[index]!;
    this.confirmed = confirmed.text;
    this.pending.splice(0, index + 1);
    if (!this.pending.length) { this.reset(); return { matched: true, cleared: true, definitive: false }; }
    // Straight typing can shrink its overlay to the pending suffix. Once editing starts, retain
    // the entire range: a future deletion can touch an already-echoed character in that range.
    if (!this.field && !this.edited) {
      this.predicted = this.predicted.slice(confirmed.text.length);
      this.offset -= confirmed.text.length; this.width -= confirmed.text.length;
      this.anchor = { ...cursor };
      this.confirmed = "";
      this.pending = this.pending.map(s => ({ text: s.text.slice(confirmed.text.length), cursor: s.cursor - confirmed.text.length }));
    }
    return { matched: true, cleared: false, definitive: false };
  }
}

export interface ControllerConfig {
  thresholdMs: number;
  force: "on" | "off" | null;
  /// The NETWORK's round trip in ms — the selected ICE candidate pair's `currentRoundTripTime` — or null
  /// where there is none (a socket transport: the app's own bridge) or none measured yet.
  networkRttMs: () => number | null;
  /// Latency the page itself adds to every echo (`?predictlag`, a simulated slow link).
  addedLagMs?: number;
}

/// Pure gate deciding WHEN ghosts may show: active client, primary screen, a SLOW LINK, echo-healthy (no
/// recent run of mismatches), or a `?predict` force override.
///
/// **THE LINK IS THE NETWORK'S ROUND TRIP, NEVER THE ECHO'S** — Mosh's SRTT trigger. MEASURED 2026-10-01
/// over loopback: the gate read an average of echo times sampled at the reconcile settle (40 ms quiet),
/// so once predicting no sample fell under the 30 ms threshold, and one keystroke a shell never echoes
/// (`read -s`) made a 1 s sample that opened it for good. An echo sample cannot be repaired into a link
/// measurement: a person typing faster than the round trip has the echo of an EARLIER key close each
/// sample (false-low), unrelated output does the same, a silent key or a slow application is a false
/// high — and on loopback nothing about the link needs hiding however slow the app is. The echo's own
/// time is still measured (`onKeystroke`/`onBytes`, at ARRIVAL), only for the stale-ghost clock.
export class PredictionController {
  private isActive = false;
  private altScreen = false;
  private rtt = 0;                 // EWMA of echo latency (ms) — the stale-ghost clock's scale, never the gate
  private lastKeyMs: number | null = null;
  private misses = 0;
  private static readonly MISS_LIMIT = 2;
  constructor(private cfg: ControllerConfig) {}

  setActive(on: boolean): void { this.isActive = on; }
  setAltScreen(alt: boolean): void { this.altScreen = alt; }
  onKeystroke(nowMs: number): void { if (this.lastKeyMs == null) this.lastKeyMs = nowMs; }

  /// Server bytes were applied. Closes the sample the oldest unanswered keystroke opened; output with no
  /// keystroke pending (a program printing on its own) is no sample.
  onBytes(nowMs: number): void {
    if (this.lastKeyMs == null) return;
    const sample = Math.max(0, nowMs - this.lastKeyMs);
    this.lastKeyMs = null;
    this.rtt = this.rtt === 0 ? sample : this.rtt + (sample - this.rtt) / 8;   // EWMA
  }

  /// A prediction was reconciled against the authoritative buffer: `matched` is the echo's health.
  onReconcile(matched: boolean): void { this.misses = matched ? 0 : this.misses + 1; }

  /// The echo latency estimate (EWMA, ms) — the stale-ghost clock's scale.
  rttMs(): number { return this.rtt; }

  /// The link's latency as the gate reads it: the network's round trip plus what the page adds, or null
  /// when there is no network to measure and nothing added.
  linkMs(): number | null {
    const net = this.cfg.networkRttMs();
    const added = this.cfg.addedLagMs ?? 0;
    return net == null && added === 0 ? null : (net ?? 0) + added;
  }

  active(): boolean {
    if (this.cfg.force === "on") return true;
    if (this.cfg.force === "off") return false;
    const link = this.linkMs();
    return this.isActive && !this.altScreen && link != null && link > this.cfg.thresholdMs
      && this.misses < PredictionController.MISS_LIMIT;
  }
}
