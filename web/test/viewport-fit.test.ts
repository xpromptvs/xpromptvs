import { describe, expect, it, test, vi } from "vitest";
import { BOTTOM_OCCLUSION_PX, bottomOccluded, releaseStrandedScroll, safeBottomValue, strandedScroll, viewportFitStyle, ViewportFit, blockPageZoom } from "../src/client/viewport-fit";
import indexHtml from "../index.html?raw";

test("at rest (offsetTop 0) sizes to the visible height with no transform", () => {
  expect(viewportFitStyle({ height: 812, offsetTop: 0 })).toEqual({ height: "812px", transform: "none" });
});

test("keyboard up (visible shrinks, page offset) follows the visual viewport", () => {
  expect(viewportFitStyle({ height: 500, offsetTop: 120 }))
    .toEqual({ height: "500px", transform: "translateY(120px)" });
});

test("rounds subpixel viewport metrics", () => {
  expect(viewportFitStyle({ height: 499.6, offsetTop: 20.4 }))
    .toEqual({ height: "500px", transform: "translateY(20px)" });
});

// ── safeBottomValue ──────────────────────────────────────────────────────────────────────────────
// `env(safe-area-inset-bottom)` is CONSTANT: it describes the home indicator's strip and does not
// change when the soft keyboard opens. An open keyboard already covers that strip, so keeping the
// inset leaves the status bar floating a home-indicator's height above the keyboard.

test("at rest the bottom inset applies", () => {
  expect(safeBottomValue({ height: 1024, offsetTop: 0, layoutHeight: 1024 }))
    .toBe("env(safe-area-inset-bottom)");
});

test("with the keyboard up the inset is dropped — the keyboard covers the indicator", () => {
  expect(safeBottomValue({ height: 700, offsetTop: 0, layoutHeight: 1024 })).toBe("0px");
});

// BOTH ARMS OF THE THRESHOLD. Only asserting the keyboard case also passes for a function that
// always returns 0px, which would reintroduce the original bug at rest.
test("occlusion at the threshold still counts as at rest", () => {
  expect(safeBottomValue({ height: 1024 - BOTTOM_OCCLUSION_PX, offsetTop: 0, layoutHeight: 1024 }))
    .toBe("env(safe-area-inset-bottom)");
});

test("occlusion just past the threshold drops it", () => {
  expect(safeBottomValue({ height: 1024 - BOTTOM_OCCLUSION_PX - 1, offsetTop: 0, layoutHeight: 1024 }))
    .toBe("0px");
});

// The terminal's fit reads the same verdict: a keyboard opening or closing holds the grid for the
// host's snapshot (TermDeck.fit), so the two must never disagree about what a keyboard is.
test("bottomOccluded is the same threshold, both arms", () => {
  expect(bottomOccluded({ height: 1024 - BOTTOM_OCCLUSION_PX, offsetTop: 0, layoutHeight: 1024 })).toBe(false);
  expect(bottomOccluded({ height: 1024 - BOTTOM_OCCLUSION_PX - 1, offsetTop: 0, layoutHeight: 1024 })).toBe(true);
  expect(bottomOccluded({ height: 500, offsetTop: 120, layoutHeight: 1024 })).toBe(true);
});

// A browser that reports the visual viewport a few px short at rest must NOT be read as a keyboard;
// that would drop the inset permanently, which is the original bug back and harder to see.
test("a few pixels of rounding at rest keeps the inset", () => {
  expect(safeBottomValue({ height: 1020.4, offsetTop: 0, layoutHeight: 1024 }))
    .toBe("env(safe-area-inset-bottom)");
});

// iOS sometimes scrolls the page as well as shrinking the visual viewport, so the visible band's
// BOTTOM edge is offsetTop + height — not height alone.
test("accounts for a scrolled page: the band's bottom edge is offsetTop + height", () => {
  // Shrunk by 120 but pushed down 120: the bottom edge is still the screen bottom, so the inset stays.
  expect(safeBottomValue({ height: 904, offsetTop: 120, layoutHeight: 1024 }))
    .toBe("env(safe-area-inset-bottom)");
});

test("the stopper hands <body> back exactly as it found it, and --safe-b to the stylesheet", () => {
  const vv = Object.assign(new EventTarget(), { height: 600, offsetTop: 0 });
  Object.defineProperty(window, "visualViewport", { configurable: true, value: vv });
  try {
    document.body.style.backgroundColor = "red";
    const stop = new ViewportFit(document.body).start();
    expect(document.body.style.position).toBe("fixed");
    expect(document.body.style.height).toBe("600px");
    expect(document.documentElement.style.getPropertyValue("--safe-b")).not.toBe("");
    stop();
    expect(document.body.getAttribute("style")).toBe("background-color: red;");
    expect(document.documentElement.style.getPropertyValue("--safe-b")).toBe("");
    vv.height = 300;
    vv.dispatchEvent(new Event("resize"));
    expect(document.body.style.height).toBe("");          // the listeners went with it
  } finally {
    Reflect.deleteProperty(window, "visualViewport");
    document.body.removeAttribute("style");
  }
});

test("the stopper restores overflow-x/overflow-y LONGHANDS exactly, not just the overflow shorthand", () => {
  // `overflow` is a shorthand: a <body> that arrived with only the longhands set (never the
  // shorthand itself) has an EMPTY `overflow` in its "before" snapshot, and restoring that empty
  // shorthand must not wipe the longhands the start() write clobbered.
  const vv = Object.assign(new EventTarget(), { height: 600, offsetTop: 0 });
  Object.defineProperty(window, "visualViewport", { configurable: true, value: vv });
  try {
    document.body.style.overflowX = "scroll";
    document.body.style.overflowY = "auto";
    const stop = new ViewportFit(document.body).start();
    expect(document.body.style.overflow).toBe("hidden");
    stop();
    expect(document.body.style.overflowX).toBe("scroll");
    expect(document.body.style.overflowY).toBe("auto");
  } finally {
    Reflect.deleteProperty(window, "visualViewport");
    document.body.removeAttribute("style");
  }
});

// ── strandedScroll ───────────────────────────────────────────────────────────────────────────────
// A Home Screen web app turned back to PORTRAIT is left scrolled by the status bar's height, in a
// document that cannot scroll: the page's coordinates and its taps say 68, the screen still shows 0.
// Measured on an iPhone Air (iOS 27.2 simulator), 2026-09-28; every number below is from that run.

test("the rotation's leftover scroll is stranded: the visual viewport is the whole layout viewport", () => {
  expect(strandedScroll({ scrollY: 68, height: 844, layoutHeight: 844 })).toBe(true);
});

test("a scroll ABOVE the top is stranded too — the page cannot scroll either way", () => {
  expect(strandedScroll({ scrollY: -20, height: 844, layoutHeight: 844 })).toBe(true);
});

test("a keyboard's reveal is NOT stranded — the scroll it made is into the band the keyboard shrank", () => {
  // The dashboard's code field focused in landscape: iOS scrolled 228 and the visual viewport was 172
  // of 420. Releasing THAT scroll hid the field behind the keyboard.
  expect(strandedScroll({ scrollY: 228, height: 172, layoutHeight: 420 })).toBe(false);
});

test("at rest nothing is stranded", () => {
  expect(strandedScroll({ scrollY: 0, height: 844, layoutHeight: 844 })).toBe(false);
});

test("a pinch-zoomed page is not stranded — zoom shrinks the visual viewport", () => {
  expect(strandedScroll({ scrollY: 300, height: 422, layoutHeight: 844 })).toBe(false);
});

test("a visual viewport a fraction short of the layout viewport still counts as the whole of it", () => {
  expect(strandedScroll({ scrollY: 68, height: 843.5, layoutHeight: 844 })).toBe(true);
});

/// Stubs one property and returns its undo: jsdom's own `scrollY`/`innerHeight` are OWN properties of
/// `window`, so deleting a stub would take them with it.
function stub(target: object, key: string, value: unknown): () => void {
  const before = Object.getOwnPropertyDescriptor(target, key);
  Object.defineProperty(target, key, { configurable: true, value });
  return () => { if (before) Object.defineProperty(target, key, before); else Reflect.deleteProperty(target, key); };
}

function strandedPage(m: { scrollY: number; offsetTop: number; height: number; clientHeight: number }) {
  const vv = Object.assign(new EventTarget(), { height: m.height, offsetTop: m.offsetTop });
  const undo = [
    stub(window, "visualViewport", vv),
    stub(window, "scrollY", m.scrollY),
    stub(document.documentElement, "clientHeight", m.clientHeight),
  ];
  const scrollTo = vi.spyOn(window, "scrollTo").mockImplementation(() => {});
  return {
    vv, scrollTo,
    set: (key: string, value: unknown) => undo.push(stub(window, key, value)),
    restore() {
      scrollTo.mockRestore();
      for (const u of undo.reverse()) u();
    },
  };
}

test("the page scrolls itself back to 0 on the event that strands it, and on no other", () => {
  const page = strandedPage({ scrollY: 0, offsetTop: 0, height: 844, clientHeight: 844 });
  const stop = releaseStrandedScroll();
  try {
    window.dispatchEvent(new Event("scroll"));
    expect(page.scrollTo).not.toHaveBeenCalled();
    page.set("scrollY", 68);
    page.vv.offsetTop = 68;
    window.dispatchEvent(new Event("scroll"));
    expect(page.scrollTo).toHaveBeenCalledWith(0, 0);
    stop();                                           // idempotent: `finally` calls it again
    page.scrollTo.mockClear();
    window.dispatchEvent(new Event("scroll"));
    window.dispatchEvent(new Event("resize"));
    page.vv.dispatchEvent(new Event("scroll"));
    page.vv.dispatchEvent(new Event("resize"));
    expect(page.scrollTo).not.toHaveBeenCalled();     // the listeners went with it
  } finally {
    stop();
    page.restore();
  }
});

test("the window's resize and the visual viewport's own scroll and resize are watched too", () => {
  // The measured strand arrived with the window's resize, then its scroll: whichever comes first releases.
  const page = strandedPage({ scrollY: 68, offsetTop: 68, height: 844, clientHeight: 844 });
  const stop = releaseStrandedScroll();
  try {
    window.dispatchEvent(new Event("resize"));
    page.vv.dispatchEvent(new Event("scroll"));
    page.vv.dispatchEvent(new Event("resize"));
    expect(page.scrollTo).toHaveBeenCalledTimes(3);
  } finally {
    stop();
    page.restore();
  }
});

test("the layout height is the root's clientHeight, never innerHeight — innerHeight follows the keyboard", () => {
  // iOS reported innerHeight 192 of 420 for a frame while its keyboard opened. A frame where it has
  // caught up with the visual viewport must not make the keyboard's reveal look stranded.
  const page = strandedPage({ scrollY: 228, offsetTop: 227.65625, height: 172, clientHeight: 420 });
  page.set("innerHeight", 172);
  const stop = releaseStrandedScroll();
  try {
    page.vv.dispatchEvent(new Event("resize"));
    expect(page.scrollTo).not.toHaveBeenCalled();
  } finally {
    stop();
    page.restore();
  }
});

test("a keyboard's reveal is left alone", () => {
  const page = strandedPage({ scrollY: 228, offsetTop: 227.65625, height: 172, clientHeight: 420 });
  const stop = releaseStrandedScroll();
  try {
    page.vv.dispatchEvent(new Event("resize"));
    window.dispatchEvent(new Event("scroll"));
    expect(page.scrollTo).not.toHaveBeenCalled();
  } finally {
    stop();
    page.restore();
  }
});

test("the stubs above leave jsdom's window as they found it", () => {
  expect(typeof window.scrollY).toBe("number");
  expect(typeof window.innerHeight).toBe("number");
  expect(window.visualViewport ?? null).toBeNull();
});

describe("no page zoom on a touch device (blockPageZoom)", () => {
  const gesture = (doc: Document, type: string) => {
    const e = new Event(type, { cancelable: true });
    doc.dispatchEvent(e);
    return e.defaultPrevented;
  };

  it("cancels the WebKit gesture events that drive iOS Safari's page zoom, under a coarse pointer", () => {
    const off = blockPageZoom(document, true);
    expect(gesture(document, "gesturestart")).toBe(true);
    expect(gesture(document, "gesturechange")).toBe(true);
    off();
    expect(gesture(document, "gesturestart")).toBe(false);
  });

  it("leaves a desktop's pinch alone", () => {
    const off = blockPageZoom(document, false);
    expect(gesture(document, "gesturestart")).toBe(false);
    off();
  });

  it("the viewport meta forbids scaling and keeps viewport-fit=cover (the safe-area insets need it)", () => {
    const meta = /<meta name="viewport" content="([^"]+)"/.exec(indexHtml)?.[1] ?? "";
    expect(meta.split(/,\s*/)).toEqual(expect.arrayContaining(["maximum-scale=1", "user-scalable=no", "viewport-fit=cover"]));
  });
});
