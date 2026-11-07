import { describe, expect, it } from "vitest";
import { KeyboardShift, keyboardOnly, keyboardShift } from "../src/client/keyboard-shift";

describe("keyboardShift — how far the frozen terminal moves up", () => {
  it("the whole band the keyboard took: bottom-aligned, the blank rows and the padding with it", () => {
    expect(keyboardShift({ cursorTop: 500, visibleTop: 64, overflow: 336, previous: 0 })).toBe(336);
  });
  it("never the cursor's row above the top: a fresh shell's prompt on its first line stays in sight", () => {
    expect(keyboardShift({ cursorTop: 90, visibleTop: 72, overflow: 336, previous: 0 })).toBe(18);
    expect(keyboardShift({ cursorTop: 72, visibleTop: 72, overflow: 336, previous: 0 })).toBe(0);
  });
  it("grows as the cursor comes down, never back while the keyboard stays", () => {
    expect(keyboardShift({ cursorTop: 300, visibleTop: 72, overflow: 336, previous: 18 })).toBe(228);
    expect(keyboardShift({ cursorTop: 90, visibleTop: 72, overflow: 336, previous: 228 })).toBe(228);
  });
  it("scrolled back (no cursor on screen): the whole band", () => {
    expect(keyboardShift({ cursorTop: null, visibleTop: 72, overflow: 336, previous: 0 })).toBe(336);
  });
  it("a band that shrank (the key strip unfolded) caps what was already shifted", () => {
    expect(keyboardShift({ cursorTop: 500, visibleTop: 72, overflow: 120, previous: 200 })).toBe(120);
  });
});

describe("keyboardOnly — the keyboard's change alone", () => {
  it("covered at the bottom with the width it had without the keyboard", () => {
    expect(keyboardOnly({ occluded: true, stageWidth: 390, restWidth: 390 })).toBe(true);
  });
  it("a turn with the keyboard up is not the keyboard alone", () => {
    expect(keyboardOnly({ occluded: true, stageWidth: 844, restWidth: 390 })).toBe(false);
  });
  it("nothing covered, or no rest seen yet, is not the keyboard", () => {
    expect(keyboardOnly({ occluded: false, stageWidth: 390, restWidth: 390 })).toBe(false);
    expect(keyboardOnly({ occluded: true, stageWidth: 390, restWidth: null })).toBe(false);
  });
});

/// A phone 390 × 844 whose stage is the body minus 64 (tab bar) and 38 (status bar), with an xterm whose content box is
/// the stage minus the key strip (52) and its padding (8 + 8). The keyboard shrinks the visual viewport and, with it,
/// the pinned body — as ViewportFit does.
function rig() {
  const W = 390, H = 844, BARS = 64 + 38, STRIP = 52, PAD = 16;
  let covered = 0, width = W, cursorRow = 30;
  const cellH = 17;
  const frames: FrameRequestCallback[] = [];
  const vv = { get height() { return H - covered; }, offsetTop: 0 };
  const xtermStyle: Record<string, string> = {};
  const stageH = () => H - covered - BARS;
  const naturalContent = () => stageH() - STRIP - PAD;
  const contentH = () => (xtermStyle.height ? parseFloat(xtermStyle.height) : naturalContent());
  const shiftPx = () => { const m = /translateY\((-?[\d.]+)px\)/.exec(xtermStyle.transform ?? ""); return m ? -parseFloat(m[1]!) : 0; };
  const xterm = {
    style: new Proxy(xtermStyle, { set(t, k: string, v) { t[k] = v; return true; } }) as unknown as CSSStyleDeclaration,
    get clientHeight() { return contentH() + PAD; },
    getBoundingClientRect: () => ({ top: 64 - shiftPx(), bottom: 64 + contentH() + PAD - shiftPx() }) as DOMRect,
  } as unknown as HTMLElement;
  const stage = {
    get clientWidth() { return width; },
    get clientHeight() { return stageH(); },
    getBoundingClientRect: () => ({ top: 64, bottom: 64 + stageH() }) as DOMRect,
  } as unknown as HTMLElement;
  const win = {
    visualViewport: vv,
    get innerHeight() { return H; },
    getComputedStyle: () => ({ paddingTop: "8px", paddingBottom: "8px" }),
    requestAnimationFrame: (f: FrameRequestCallback) => { frames.push(f); return frames.length; },
    cancelAnimationFrame: () => {},
  } as unknown as Window;
  const ks = new KeyboardShift({
    win, stage, xterm, enabled: () => true,
    visibleBottom: () => 64 + stageH() - STRIP,
    visibleTop: () => 64,
    // As drawn: the xterm's top plus its top padding plus the cursor's row.
    cursorTop: () => 64 + 8 - shiftPx() + cursorRow * cellH,
  });
  return {
    ks, xtermStyle, shiftPx, contentH, naturalContent,
    keyboard(px: number) { covered = px; },
    turn(w: number) { width = w; },
    cursorAt(row: number) { cursorRow = row; },
    frame() { const f = frames.splice(0); for (const cb of f) cb(0); },
    pan(dy: number) { return ks.panBy(dy); },
  };
}

describe("KeyboardShift — the terminal keeps its box while the keyboard alone covers it", () => {
  it("keyboard up: nothing to fit, the box kept, the whole terminal moved up by the keyboard's band", () => {
    const r = rig();
    expect(r.ks.onStageResize()).toBe(false);            // at rest: an ordinary resize, and the rest is learned
    const restContent = r.contentH();
    r.keyboard(336);
    expect(r.ks.onStageResize()).toBe(true);             // the keyboard alone: the caller fits nothing
    expect(r.contentH()).toBe(restContent);              // the terminal's box is the one it had
    expect(r.ks.active).toBe(true);
    // The whole band: #xterm's bottom (64 + 674 + 16 = 754) up to the key strip's top (64 + 406 − 52 = 418) → 336 px;
    // the cursor (row 30, its top at 64 + 8 + 30·17 = 582) stays far below the top.
    expect(r.shiftPx()).toBe(336);
  });

  it("keyboard down to the same box: nothing to fit, and nothing left on the element", () => {
    const r = rig();
    r.ks.onStageResize();
    r.keyboard(336); r.ks.onStageResize();
    r.keyboard(0);
    expect(r.ks.onStageResize()).toBe(true);
    expect(r.ks.active).toBe(false);
    expect(r.xtermStyle.height).toBe("");
    expect(r.xtermStyle.transform).toBe("");
  });

  it("a prompt near the top stays in sight; the whole band once the cursor comes down, and never back", () => {
    const r = rig();
    r.ks.onStageResize();
    r.cursorAt(5);
    r.keyboard(336); r.ks.onStageResize();
    expect(r.shiftPx()).toBe(85);                        // a prompt near the top moves only until it reaches it (5·17)
    r.cursorAt(25); r.frame();
    expect(r.shiftPx()).toBe(336);                       // the cursor came down: the whole band
    r.cursorAt(10); r.frame();
    expect(r.shiftPx()).toBe(336);                      // the cursor went up (a clear): the picture stays
  });

  // A DRAG OVER A FULL-SCREEN APP PANS THE SHIFTED VIEW FIRST (panBy): down brings the rows above back, up returns
  // toward bottom-aligned, and what is left past either end goes on to the app; once panned the cursor no longer moves it.
  it("panBy: the view pans first, the app gets the rest, and the cursor no longer moves it", () => {
    const r = rig();
    r.ks.onStageResize();
    r.keyboard(336); r.ks.onStageResize();
    expect(r.shiftPx()).toBe(336);
    expect(r.pan(100), "a drag down of 100: all of it pans the view").toBe(0);
    expect(r.shiftPx()).toBe(236);
    expect(r.pan(300), "300 more: 236 pan it to the top, 64 go to the app").toBe(64);
    expect(r.shiftPx()).toBe(0);
    expect(r.pan(40), "at the top: everything goes to the app").toBe(40);
    expect(r.pan(-50), "a drag up: the view first").toBe(0);
    expect(r.shiftPx()).toBe(50);
    r.cursorAt(37); r.frame();
    expect(r.shiftPx(), "panned: the cursor coming down does not move it").toBe(50);
    expect(r.pan(-400), "up past bottom-aligned: the band, the rest to the app").toBe(-114);
    expect(r.shiftPx()).toBe(336);
    r.keyboard(0); r.ks.onStageResize();
    expect(r.pan(10), "no keyboard: nothing to pan").toBe(10);
  });

  it("a turn with the keyboard up is a real resize: released, fitted as before", () => {
    const r = rig();
    r.ks.onStageResize();
    r.keyboard(336); r.ks.onStageResize();
    r.turn(844);
    expect(r.ks.onStageResize()).toBe(false);
    expect(r.ks.active).toBe(false);
    expect(r.xtermStyle.height).toBe("");
  });

  it("a keyboard with no rest seen first (connected with it up) fits to what is visible, as before", () => {
    const r = rig();
    r.keyboard(336);
    expect(r.ks.onStageResize()).toBe(false);
    expect(r.ks.active).toBe(false);
  });
});
