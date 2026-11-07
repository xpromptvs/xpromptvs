// A SOFT KEYBOARD SHIFTS THE TERMINAL; IT NEVER RESIZES IT (2026-10-13, asked: "detect when the inset changes because
// of the system keyboard, and not change the terminal size — only shift it. Otherwise there is too much movement and
// everything is getting messed up").
//
// Before this, the keyboard shrank `<body>` (`ViewportFit` pins it to the visual viewport), `#stage`'s observer fitted
// the terminal to the smaller band, and the host resized EVERY tab: tmux reflowed, every tab was re-sent, the deck held
// for the snapshots — and all of it again when the keyboard went. Now, while the keyboard alone covers the bottom,
// `#xterm` keeps the height it had without it (so nothing re-measures: not FitAddon, not the WebGPU surface, not the
// overscan rows) and moves UP by the band the keyboard took — bottom-aligned above the key strip, as a native terminal
// moves — unless that would put the cursor's row above the top. `#stage` clips what goes above it. Nothing is sent to the host.
//
// What counts as "the keyboard alone": the visual viewport is covered at the bottom (`bottomOccluded`, the test the
// status bar's inset already uses) while `#stage` keeps the WIDTH it had without the keyboard. iOS — and Android
// Chrome since 108 — keep the layout viewport and shrink only the visual one. A rotation, a split-view resize or a
// window changing size is not the keyboard and fits as before (with its hold, `TermDeck.follow`).

import { bottomOccluded } from "./viewport-fit";

/// The shift, in px: the WHOLE band the keyboard took (`overflow`) — the terminal bottom-aligned above the key strip,
/// its blank rows and bottom padding with it, as a native terminal moves — except that the cursor's row never goes
/// above the visible area's top (`cursorTop`, in the UNSHIFTED terminal's coordinates, against `visibleTop`): a fresh
/// shell's prompt on its first line stays in sight. Never less than this keyboard session already shifted
/// (`previous`), so output arriving under a prompt does not walk the picture. `cursorTop` null (scrolled back into the
/// scrollback, or no terminal shown) caps nothing. (2026-10-13, the same day the shift came: first to the cursor's row
/// — "the last line is the one with the cursor, instead of the full view" — then to the last row drawn below it —
/// "the bottom inset is not fully translated when the keyboard is on".)
export function keyboardShift(m: { cursorTop: number | null; visibleTop: number; overflow: number; previous: number }): number {
  const band = Math.max(0, Math.floor(m.overflow));
  const cap = m.cursorTop === null ? band : Math.max(0, Math.floor(m.cursorTop - m.visibleTop));
  return Math.min(band, Math.max(m.previous, cap));
}

/// The keyboard's change alone: the bottom is covered while the stage keeps the width it had without it.
export function keyboardOnly(m: { occluded: boolean; stageWidth: number; restWidth: number | null }): boolean {
  return m.occluded && m.restWidth !== null && Math.abs(m.stageWidth - m.restWidth) < 1;
}

export interface KeyboardShiftOpts {
  win: Window;
  stage: HTMLElement;
  /// The element that moves: `#xterm` (the tab slots, the preview and the WebGPU canvas are its children).
  xterm: HTMLElement;
  /// Whether this page shifts at all: a coarse pointer that is not the glasses (the layouts `ViewportFit` pins).
  enabled(): boolean;
  /// Where the visible terminal area ends on screen: the key strip's top, or `#stage`'s bottom.
  visibleBottom(): number;
  /// Where the visible terminal area starts on screen: `#stage`'s top (what goes above it is clipped).
  visibleTop(): number;
  /// The cursor's row's TOP on screen, AS DRAWN NOW (the current shift included), or null.
  cursorTop(): number | null;
}

export class KeyboardShift {
  /// `#stage`'s box with no keyboard up, measured at every resize without one. Its HEIGHT, not `#xterm`'s: the key
  /// strip can fold or unfold without `#stage` resizing, so `#xterm`'s own height may be stale by the time the keyboard
  /// comes — the stage's is not, and what the keyboard took is exactly what the stage lost.
  private rest: { width: number; stageHeight: number } | null = null;
  /// `#xterm`'s content height while frozen: what it was just before the keyboard came.
  private frozenHeight = 0;
  private frozen = false;
  private shift = 0;
  private raf = 0;
  /// The band this keyboard session can shift through (`#xterm`'s bottom down to the visible bottom), read each frame.
  private band = 0;
  /// The person panned the view (`panBy`): the cursor no longer moves it, until the keyboard goes.
  private manual = false;

  constructor(private readonly o: KeyboardShiftOpts) {}

  /// From `#stage`'s ResizeObserver, BEFORE anything is fitted. True when the change was the keyboard's alone — or its
  /// going, back to the box the terminal already has — and the caller must fit, follow and send NOTHING.
  onStageResize(): boolean {
    const { win, stage } = this.o;
    const vv = win.visualViewport;
    if (!vv || !this.o.enabled()) { this.release(); this.rest = null; return false; }
    const occluded = bottomOccluded({ height: vv.height, offsetTop: vv.offsetTop, layoutHeight: win.innerHeight });
    const width = stage.clientWidth;
    if (!occluded) {
      const rest = { width, stageHeight: stage.clientHeight };
      if (!this.frozen) { this.rest = rest; return false; }
      const held = this.frozenHeight, heldWidth = this.rest!.width;
      this.release();
      this.rest = rest;
      // The keyboard went and the terminal's box is the one it kept: nothing to fit. (The key strip changed while it
      // was up, or the width: fit as any resize.)
      return Math.abs(width - heldWidth) < 1 && Math.abs(this.contentHeight() - held) < 1;
    }
    if (keyboardOnly({ occluded, stageWidth: width, restWidth: this.rest?.width ?? null })) {
      if (!this.frozen) this.freeze(this.contentHeight() + Math.max(0, this.rest!.stageHeight - stage.clientHeight));
      this.schedule();
      return true;
    }
    // Covered, but not the keyboard alone (turned with it up), or no rest seen yet: fit to what is visible, as before.
    this.release();
    return false;
  }

  /// The keyboard is up and the terminal is frozen and shifted (tests, and a `fit` that wants to know).
  get active(): boolean { return this.frozen; }

  /// A finger's drag over a FULL-SCREEN app while the keyboard is up (2026-10-13: "scrolling with expanded keyboard
  /// first scrolls the screen, then the underlying app once there is no space to scroll on client screen"): the shifted
  /// view pans FIRST, following the finger — a drag down brings the rows the shift put above the top back into sight,
  /// a drag up takes the view back toward bottom-aligned — and only what is left once it cannot pan further goes on to
  /// the app. `dy` and the return value are px in the finger's sense (down positive). Once panned, the cursor no longer
  /// moves the view until the keyboard goes: the person chose where it sits.
  panBy(dy: number): number {
    if (!this.frozen || dy === 0) return dy;
    const next = Math.min(this.band, Math.max(0, this.shift - dy));
    const used = this.shift - next;
    if (used === 0) return dy;
    this.manual = true;
    this.setShift(next);
    return dy - used;
  }

  dispose(): void { this.release(); this.rest = null; }

  private contentHeight(): number {
    const el = this.o.xterm, cs = this.o.win.getComputedStyle(el);
    return el.clientHeight - (parseFloat(cs.paddingTop) || 0) - (parseFloat(cs.paddingBottom) || 0);
  }

  private freeze(height: number): void {
    this.frozen = true;
    this.frozenHeight = height;
    this.shift = 0;
    const s = this.o.xterm.style;
    s.bottom = "auto";
    s.height = `${height}px`;
  }

  private release(): void {
    if (this.raf) { this.o.win.cancelAnimationFrame(this.raf); this.raf = 0; }
    if (!this.frozen) return;
    this.frozen = false;
    this.shift = 0;
    this.band = 0;
    this.manual = false;
    const s = this.o.xterm.style;
    s.bottom = "";
    s.height = "";
    s.transform = "";
  }

  /// Re-reads the cursor every frame while the keyboard is up: typing, output, a tab switch, the key strip folding —
  /// whatever moved the row, the shift follows in the next frame (and only ever grows while the keyboard stays).
  private schedule(): void {
    if (this.raf) return;
    const step = (): void => {
      this.raf = 0;
      if (!this.frozen) return;
      this.apply();
      this.raf = this.o.win.requestAnimationFrame(step);
    };
    this.apply();
    this.raf = this.o.win.requestAnimationFrame(step);
  }

  private apply(): void {
    const box = this.o.xterm.getBoundingClientRect();
    this.band = Math.max(0, Math.floor(box.bottom + this.shift - this.o.visibleBottom()));
    if (this.manual) {
      if (this.shift > this.band) this.setShift(this.band);   // the band shrank (the key strip unfolded)
      return;
    }
    const drawn = this.o.cursorTop();
    // The cursor's row keeps the breathing room it has at rest below the top: `#xterm`'s top padding.
    const pad = parseFloat(this.o.win.getComputedStyle(this.o.xterm).paddingTop) || 0;
    const next = keyboardShift({
      cursorTop: drawn === null ? null : drawn + this.shift,
      visibleTop: this.o.visibleTop() + pad,
      overflow: this.band,
      previous: this.shift,
    });
    if (next === this.shift && (next !== 0 || this.o.xterm.style.transform === "")) return;
    this.setShift(next);
  }

  private setShift(px: number): void {
    this.shift = px;
    this.o.xterm.style.transform = px > 0 ? `translateY(${-px}px)` : "";
  }


}
