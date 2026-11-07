import { beforeAll, describe, expect, it } from "vitest";
import { Terminal } from "@xterm/xterm";
import { SmoothScroll, xtermScrollSurface } from "../src/client/smooth-scroll";

/// Smooth scrolling reads xterm.js's PRIVATE Viewport (`_core._viewport._scrollableElement`, VS Code's
/// scrollable element). This asserts it against the REAL xterm.js the product ships, so an upgrade that
/// moves it fails here rather than silently turning the option into nothing.

beforeAll(() => {
  (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
});

function opened(): { term: Terminal; el: HTMLElement } {
  const el = document.createElement("div");
  document.body.append(el);
  const term = new Terminal({ cols: 40, rows: 10 });
  term.open(el);
  return { term, el };
}

/// jsdom measures no glyph, so xterm.js's own scroll handler would divide by a zero cell height (and
/// write NaN back into the position). Give its renderer the cell height a browser would measure.
/// A measured, visible terminal also has a layout box: without it the product's hidden-DOM guard
/// correctly skips every row pass, including the synchronous draw these tests exercise.
function measure(term: Terminal, cellPx: number): void {
  term.element!.getClientRects = () => [new DOMRect(0, 0, term.cols * 8, term.rows * cellPx)] as unknown as DOMRectList;
  (term as unknown as { _core: { _renderService: { dimensions: { css: { cell: { height: number } } } } } })
    ._core._renderService.dimensions.css.cell.height = cellPx;
}

/// The scrollable element itself, to give it dimensions jsdom's unmeasured renderer never sets.
function scrollable(term: Terminal): { setScrollDimensions(d: { height: number; scrollHeight: number }): void } {
  return (term as unknown as { _core: { _viewport: { _scrollableElement: never } } })._core._viewport._scrollableElement;
}

describe("xtermScrollSurface over a real xterm.js", () => {
  it("finds the Viewport's scrollable element and the screen once the terminal is open", () => {
    const { term } = opened();
    expect(xtermScrollSurface(term, () => 17)).not.toBeNull();
    term.dispose();
  });

  it("is null before the terminal is open, and for an xterm.js without those internals", () => {
    expect(xtermScrollSurface(new Terminal(), () => 17)).toBeNull();
    const el = document.createElement("div");
    el.append(Object.assign(document.createElement("div"), { className: "xterm-screen" }));
    const fake = { _core: { _viewport: {} }, element: el, buffer: { active: { viewportY: 0 } } };
    expect(xtermScrollSurface(fake as unknown as Terminal, () => 17)).toBeNull();
  });

  it("moves the position by the fraction of a pixel, clamps it, and reports every change", () => {
    const { term } = opened();
    measure(term, 17);
    scrollable(term).setScrollDimensions({ height: 170, scrollHeight: 1700 });
    const s = xtermScrollSurface(term, () => 17)!;
    const seen: number[] = [];
    const sub = s.onScroll((t) => seen.push(t));
    s.setScrollTop(55.5);
    expect(s.scrollTop()).toBe(55.5);
    expect(s.maxScrollTop()).toBe(1530);
    s.setScrollTop(99_999);
    expect(s.scrollTop()).toBe(1530);
    sub.dispose();
    s.setScrollTop(10);
    expect(seen).toEqual([55.5, 1530]);
    term.dispose();
  });

  it("translates the screen element, and removes the transform at zero", () => {
    const { term, el } = opened();
    const s = xtermScrollSurface(term, () => 17)!;
    const screen = el.querySelector<HTMLElement>(".xterm-screen")!;
    s.setScreenOffset(-5.5);
    expect(screen.style.transform).toBe("translateY(-5.5px)");
    s.setScreenOffset(0);
    expect(screen.style.transform).toBe("");
    term.dispose();
  });
});

describe("mountXterm's smooth scrolling", () => {
  /// A mounted instance holding 100 lines, measured, its scrollable given the height of them.
  async function mounted(smoothScroll?: boolean) {
    const { mountXterm } = await import("../src/client/xterm-view");
    const el = document.createElement("div");
    document.body.append(el);
    const v = mountXterm(el, { onData: () => {}, onFit: () => {}, theme: "dark", smoothScroll });
    await v.writeAsync(Array.from({ length: 100 }, (_, i) => `line ${i}`).join("\r\n"));   // scrollback
    measure(v.term, 17);
    scrollable(v.term).setScrollDimensions({ height: 170, scrollHeight: 1700 });
    const screen = el.querySelector<HTMLElement>(".xterm-screen")!;
    // The offset is against the row xterm.js has DRAWN, and it draws on its next animation frame.
    const scrollTo = async (top: number) => {
      (scrollable(v.term) as unknown as { setScrollPosition(p: { scrollTop: number }): void }).setScrollPosition({ scrollTop: top });
      await new Promise((r) => setTimeout(r, 60));
    };
    return { v, screen, scrollTo };
  }

  it("is OFF unless asked for: a fractional scroll leaves the screen where it is", async () => {
    const { v, screen, scrollTo } = await mounted();
    expect(v.smooth).toBeInstanceOf(SmoothScroll);
    await scrollTo(3 * 17 + 5);
    expect(screen.style.transform).toBe("");
    v.dispose();
  });

  it("asked for, shifts the screen by the fraction", async () => {
    const { v, screen, scrollTo } = await mounted(true);
    await scrollTo(3 * 17 + 5);
    expect(screen.style.transform).toBe("translateY(-5px)");
    v.dispose();
  });

  it("draws the rows a scroll moves to IN the scroll, with the shift — no frame in between", async () => {
    // WebKit paints an input's changes at the next display refresh, animation frame or not (Safari holds
    // animation frames to 60 Hz on a 120 Hz display), so the rows must not wait for xterm.js's frame.
    const { v, screen } = await mounted(true);
    await new Promise((r) => setTimeout(r, 60));   // the first screen drawn
    const first = () => screen.querySelector(".xterm-rows > div")?.textContent?.trim();
    (scrollable(v.term) as unknown as { setScrollPosition(p: { scrollTop: number }): void }).setScrollPosition({ scrollTop: 40 * 17 + 5 });
    expect(v.term.buffer.active.viewportY).toBe(40);
    expect(first()).toBe("line 40");
    expect(screen.style.transform).toBe("translateY(-5px)");
    v.dispose();
  });

  it("…unless turned off (`?scrollsync=0`): the rows then wait for xterm.js's frame, as before", async () => {
    const { mountXterm } = await import("../src/client/xterm-view");
    const el = document.createElement("div");
    document.body.append(el);
    const v = mountXterm(el, { onData: () => {}, onFit: () => {}, theme: "dark", smoothScroll: true, scrollSync: false });
    await v.writeAsync(Array.from({ length: 100 }, (_, i) => `line ${i}`).join("\r\n"));
    measure(v.term, 17);
    scrollable(v.term).setScrollDimensions({ height: 170, scrollHeight: 1700 });
    await new Promise((r) => setTimeout(r, 60));
    const screen = el.querySelector<HTMLElement>(".xterm-screen")!;
    const before = screen.querySelector(".xterm-rows > div")?.textContent?.trim();
    (scrollable(v.term) as unknown as { setScrollPosition(p: { scrollTop: number }): void }).setScrollPosition({ scrollTop: 40 * 17 + 5 });
    expect(screen.querySelector(".xterm-rows > div")?.textContent?.trim()).toBe(before);
    await new Promise((r) => setTimeout(r, 60));
    expect(screen.querySelector(".xterm-rows > div")?.textContent?.trim()).toBe("line 40");
    v.dispose();
  });

  /// A trackpad's wheel event, as WebKit and Chromium make one (the legacy `wheelDeltaY` is −3 × `deltaY`).
  const wheelOn = (target: Element, deltaY: number, init: Partial<WheelEventInit> = {}) => {
    const e = new WheelEvent("wheel", { deltaY, deltaMode: 0, bubbles: true, cancelable: true, ...init });
    Object.defineProperty(e, "wheelDeltaY", { value: -3 * deltaY });
    target.dispatchEvent(e);
    return e;
  };
  const top = (v: { term: Terminal }) =>
    (scrollable(v.term) as unknown as { getScrollPosition(): { scrollTop: number } }).getScrollPosition().scrollTop;

  it("takes a wheel over the smooth scrollback from xterm.js and follows it at frames, as far as xterm.js would have", async () => {
    const { v, screen, scrollTo } = await mounted(true);
    await scrollTo(20 * 17);
    const e = wheelOn(screen, 40);            // 40 ÷ 40 × 50 = 50 px
    expect(e.defaultPrevented).toBe(true);
    expect(top(v)).toBe(20 * 17);             // not in the event
    await new Promise((r) => setTimeout(r, 150));
    expect(top(v)).toBeCloseTo(20 * 17 + 50, 6);
    v.dispose();
  });

  it("leaves the wheel to xterm.js while off, with `wheelResample: false` (`?wheelresample=0`), and for ⌃ (a pinch)", async () => {
    const { mountXterm } = await import("../src/client/xterm-view");
    for (const [smoothScroll, wheelResample, ctrlKey] of [[false, true, false], [true, false, false], [true, true, true]] as const) {
      const el = document.createElement("div");
      document.body.append(el);
      const v = mountXterm(el, { onData: () => {}, onFit: () => {}, theme: "dark", smoothScroll, wheelResample });
      await v.writeAsync(Array.from({ length: 100 }, (_, i) => `line ${i}`).join("\r\n"));
      measure(v.term, 17);
      scrollable(v.term).setScrollDimensions({ height: 170, scrollHeight: 1700 });
      (scrollable(v.term) as unknown as { setScrollPosition(p: { scrollTop: number }): void }).setScrollPosition({ scrollTop: 20 * 17 });
      wheelOn(el.querySelector(".xterm-screen")!, 7, { ctrlKey });
      // xterm.js's own scrollable, at once: 7 px of trackpad is 21/120 × 50 = 8.75, rounded away from 0.
      expect(top(v), `smooth ${smoothScroll}, resample ${wheelResample}, ctrl ${ctrlKey}`).toBe(20 * 17 + 9);
      v.dispose();
    }
  });

  it("setSmoothScroll switches it live, both ways", async () => {
    const { v, screen, scrollTo } = await mounted(false);
    await scrollTo(3 * 17 + 5);
    v.setSmoothScroll(true);
    expect(screen.style.transform).toBe("translateY(-5px)");
    v.setSmoothScroll(false);
    expect(screen.style.transform).toBe("");
    v.dispose();
  });
});
