/// One of the session's TOASTS (`#sim-status-note`, `#term-stream-note`; centred under the tab bar, over the
/// windows and the terminal — style.css, "Toasts"). Two kinds of note:
///
/// - a MESSAGE (`flash`) goes after `TOAST_MS` — a tmux error, "Dropped as a paste", "Nothing to paste", and
///   since 2026-10-02 a paste's FAILURE too (asked: "Failures go after 6 s too"; until then a failure stayed
///   until the next note, docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §2.6). While a MOUSE is
///   on the toast it does not go at all, and the time it was held does not count (`hold`);
/// - a STATE (`show`) stays until it is cleared or replaced — a paste's progress, a source's boot phase, the
///   terminal's "not updating": each is true until it is not.
///
/// EVERY EXIT IS ANIMATED: a note that goes is marked `data-leaving`, which plays `toast-out`, and its text
/// is taken away only once that has ENDED — the toast's `:empty` is what hides it. No animation playing
/// (reduced motion, an engine without `getAnimations`) ends it at once. A note written meanwhile takes its
/// place, and that exit's end then clears nothing.
///
/// "This note" is decided by a MARK, not by the words: a message and a later state can read the same ("Not
/// pasted — try again"), and the message's timer must not take the state with it.

export const TOAST_MS = 6000;

export interface NoteClock {
  setTimer(fn: () => void, ms: number): unknown;
  clearTimer(handle: unknown): void;
  now(): number;
}

export class StatusNote {
  private mark = 0;
  private shown = "";
  /// A message's time still to run, null for a state or nothing shown; it runs only while not held.
  private left: number | null = null;
  private timer: unknown = null;
  private startedAt = 0;
  private held = false;
  /// The exit in progress, by generation; 0 when none. A write voids it.
  private leaving = 0;
  private exits = 0;

  constructor(private readonly el: () => HTMLElement, private readonly clock: NoteClock) {}

  /// A STATE: shown until cleared or replaced. The mark lets `clear` take away THIS note and no other.
  show(text: string): number {
    this.stop();
    this.left = null;
    const el = this.el();
    this.leaving = 0;
    delete el.dataset.leaving;
    el.textContent = text;
    this.shown = text;
    return ++this.mark;
  }

  /// A MESSAGE: it goes after `TOAST_MS`, not counting the time a mouse holds it.
  flash(text: string): void {
    this.show(text);
    this.left = TOAST_MS;
    if (!this.held) this.run();
  }

  /// A mouse is on the toast (true) or has left it (false).
  hold(on: boolean): void {
    if (on === this.held) return;
    this.held = on;
    if (on) {
      if (this.timer !== null && this.left !== null) {
        this.left = Math.max(0, this.left - (this.clock.now() - this.startedAt));
        this.stop();
      }
    } else if (this.left !== null && this.shown) {
      this.run();
    }
  }

  /// The person tapped the toast: whatever it shows goes.
  dismiss(): void { this.hide(); }

  /// Take away the note `mark` showed, only while it is still the one shown.
  clear(mark: number): void {
    if (mark === this.mark) this.hide();
  }

  private run(): void {
    const m = this.mark;
    this.startedAt = this.clock.now();
    this.timer = this.clock.setTimer(() => {
      this.timer = null;
      if (m === this.mark) this.hide();
    }, this.left ?? TOAST_MS);
  }

  private stop(): void {
    if (this.timer !== null) this.clock.clearTimer(this.timer);
    this.timer = null;
  }

  private hide(): void {
    this.stop();
    this.left = null;
    if (!this.shown) return;
    this.shown = "";
    ++this.mark;
    const el = this.el();
    const gen = this.leaving = ++this.exits;
    el.dataset.leaving = "";
    const end = (): void => {
      if (this.leaving !== gen) return;
      this.leaving = 0;
      this.held = false;                 // nothing is left under the mouse
      delete el.dataset.leaving;
      el.textContent = "";
    };
    // `getAnimations` brings style up to date first, so the exit `data-leaving` starts is already there.
    const playing = (el.getAnimations?.() ?? []).filter((a) => (a as CSSAnimation).animationName === "toast-out");
    if (!playing.length) { end(); return; }
    // A write during the exit removes `data-leaving`, which CANCELS it: `finished` rejects, and `gen` is stale anyway.
    Promise.all(playing.map((a) => a.finished)).then(end, () => {});
  }
}

/// A toast's own gestures: a MOUSE (or a pen) on it holds a message, a finger never does — a tap on a touch
/// screen is a dismissal, and iOS reports a pointer that "entered" with every tap; a tap or a click takes it
/// away; and a press on it moves no focus, or the terminal or a window would lose its keys and a phone its
/// keyboard (the key strip's reason).
export function attachToast(el: HTMLElement, note: Pick<StatusNote, "hold" | "dismiss">, signal: AbortSignal): void {
  const mouse = (e: Event) => (e as PointerEvent).pointerType !== "touch";
  el.addEventListener("pointerenter", (e) => { if (mouse(e)) note.hold(true); }, { signal });
  el.addEventListener("pointerleave", (e) => { if (mouse(e)) note.hold(false); }, { signal });
  el.addEventListener("click", () => note.dismiss(), { signal });
  el.addEventListener("mousedown", (e) => e.preventDefault(), { signal });
}
