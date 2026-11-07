// WHEN TO ASK FOR A FRESH TERMINAL WIRE AFTER A STREAM CANNOT BE DECODED (final review I2).
//
// A decode failure drops the whole wire (term-stream.ts `resync`) and re-declaring `term-mode raw`
// makes the host build a fresh one and snapshot every tab (up to 8 x 5000 lines). If the failure is
// DETERMINISTIC — a host or emitter bug that fails the same tab every time — asking at once loops
// forever: the link and the host's CPU saturate while the terminal never settles. So re-declarations
// back off (250 ms doubling to 30 s), one at a time, and after `maxAttempts` consecutive failures this
// stops asking and says so ONCE, until a reconnect or the page becoming visible starts over — or a wire
// that arrives anyway decodes cleanly (`decoded`), which clears the notice at once.
// "Consecutive": a failure more than `forgetAfterMs` after the previous one starts a fresh count.
//
// A WIRE THAT NEVER STARTS IS ASKED FOR AGAIN (docs/terminal.md). The router drops every frame until a wire start, so
// a re-declaration that went unanswered — sent into a channel that read open and delivered nothing, or ignored by a
// host that did not count this page the driver at that moment — froze the terminal for good: nothing failed again,
// nothing asked again, and no notice showed. So a wire start OWED to a driver — after a re-declaration, a control
// open, or becoming the driver ("Move here") — that has not come within `awaitWireMs` counts as one more failure:
// the same back-off, the same cap, the same notice — but only while the page can ASK (it drives, its control channel
// open): a wait that runs out while it cannot is dropped, and the next control open owes a fresh one. A wire queued
// behind more than `awaitWireMs` of the old wire's frames is asked for again needlessly — bounded by the back-off and
// the cap; frames arriving cannot tell a backlog from the frames of a wire whose start was lost.
//
// Pure apart from what it is given, so the unit test drives the clock.

export const TERM_RESYNC_POLICY = { initialMs: 250, maxMs: 30_000, maxAttempts: 8, forgetAfterMs: 120_000, awaitWireMs: 15_000 };

export interface TermResyncDeps<T = unknown> {
  /// Re-declare raw (the host answers with a fresh wire and a snapshot of every tab).
  request(): void;
  /// The cap was reached: show that the terminal is not updating. Called once per give-up.
  gaveUp(): void;
  /// A reset after a give-up: clear what `gaveUp` showed.
  recovered(): void;
  setTimer(f: () => void, ms: number): T;
  clearTimer(t: T): void;
  now(): number;
  /// Whether this page can ASK for a wire: it drives (only a driver is owed one) and its control channel is open (a
  /// connection mid-rebuild says raw itself when its next control opens). Absent: it can.
  asking?(): boolean;
}

export class TermResync<T = unknown> {
  private attempts = 0;
  private lastFailure = -Infinity;
  private timer: T | null = null;
  /// A wire start is owed (`expectWire`) and has not come.
  private awaiting: T | null = null;
  /// A wire started since this page went passive or its connection began (`becameDriver`).
  private started = false;
  private stopped = false;

  constructor(private readonly d: TermResyncDeps<T>, private readonly policy = TERM_RESYNC_POLICY) {}

  /// The stream could not be decoded (the router is already dropping everything until a new wire).
  failed(): void {
    if (this.stopped || this.timer !== null) return;       // one re-declaration in flight at a time
    const now = this.d.now();
    if (now - this.lastFailure > this.policy.forgetAfterMs) this.attempts = 0;
    this.lastFailure = now;
    this.attempts++;
    if (this.attempts > this.policy.maxAttempts) {
      this.stopped = true;
      this.d.gaveUp();
      return;
    }
    const delay = Math.min(this.policy.initialMs * 2 ** (this.attempts - 1), this.policy.maxMs);
    this.timer = this.d.setTimer(() => { this.timer = null; this.expectWire(); this.d.request(); }, delay);
  }

  /// A wire start is OWED: a re-declaration went out, a control channel opened, or this page became the driver. If
  /// none has come within `awaitWireMs` while this page drives, that is one more failure (`failed`).
  expectWire(): void {
    this.clearAwait();
    this.awaiting = this.d.setTimer(() => {
      this.awaiting = null;
      if (this.d.asking?.() ?? true) this.failed();
    }, this.policy.awaitWireMs);
  }

  /// A wire started (`[4, 0]`): nothing is owed.
  wireStarted(): void { this.started = true; this.clearAwait(); }

  /// This page became the driver: its wire is owed — unless it already started. The host sends a claim's (or a
  /// promotion's) wire BEFORE the `control-state` that says so, on another channel, so usually it has: and a
  /// passive page is sent no wire, so one that started meanwhile is this driver's.
  becameDriver(): void { if (!this.started) this.expectWire(); }

  /// This page went passive: it is owed nothing, and the next wire to start is the next driver's.
  passive(): void { this.started = false; this.clearAwait(); }

  private clearAwait(): void {
    if (this.awaiting !== null) { this.d.clearTimer(this.awaiting); this.awaiting = null; }
  }

  /// A wire decoded cleanly — its start and a WHOLE snapshot (the router's `snapshotEnd`, which fires
  /// only for one). After a give-up that wire came anyway (a claim, a host-side rebind), and it proves
  /// the stream works again: the stop and its notice clear at once, and the next failure is asked about
  /// from the first delay — not only at the next reconnect or return to the page. While still RETRYING
  /// it changes nothing: one tab decoding while another fails every time would otherwise reset the
  /// count on every wire and retry forever.
  decoded(): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.attempts = 0;
    this.lastFailure = -Infinity;
    this.d.recovered();
  }

  /// The page becoming visible (or a control open, through `connectionOpened`): start over. `request`: re-declare
  /// now if one was owed — a pending retry, a give-up, or a wire start still awaited (a phone that left and came back
  /// inside `awaitWireMs` of a lost one; cancelled without a request, every tab stayed frozen) — false when the caller
  /// declares raw itself. `started` survives: the wire that started is still the one on this connection.
  reset(request: boolean): void {
    const owed = this.stopped || this.timer !== null || this.awaiting !== null;
    if (this.timer !== null) { this.d.clearTimer(this.timer); this.timer = null; }
    this.clearAwait();
    const wasStopped = this.stopped;
    this.stopped = false;
    this.attempts = 0;
    this.lastFailure = -Infinity;
    if (wasStopped) this.d.recovered();
    if (owed && request) { this.expectWire(); this.d.request(); }
  }

  /// A control channel opened and the caller declared raw on it: a new connection starts over, its router waits for
  /// a wire start, and that start is owed.
  connectionOpened(): void {
    this.reset(false);
    this.started = false;
    this.expectWire();
  }
}
