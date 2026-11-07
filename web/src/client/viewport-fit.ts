export interface FitStyle { height: string; transform: string }

/// How much of the layout viewport's bottom must be covered before the bottom safe-area inset is
/// dropped. A BOUND, not a tuned value: any real soft keyboard occludes 200px+, and an iPad's
/// hardware-keyboard accessory bar about 55px, while the inset being guarded against is at most ~34px.
///
/// Erring HIGH is deliberate. Too low and a browser that reports `visualViewport.height` a few pixels
/// short of the layout viewport at rest would drop the inset permanently — i.e. the original bug,
/// back and harder to see. Too high merely leaves a strip of dead space under a small accessory bar.
export const BOTTOM_OCCLUSION_PX = 48;

/// The value for `--safe-b`: the bottom safe-area inset, or zero while something covers the bottom.
///
/// `env(safe-area-inset-bottom)` is CONSTANT — it describes the home indicator's strip of screen and
/// does not change when the soft keyboard opens. But an open keyboard already covers that strip, so
/// the status bar would sit a home-indicator's height above the keyboard, reserving space for
/// something that is not there. Nothing in CSS can express "unless the keyboard is up"; the visual
/// viewport is the only place that knows, and this is already watching it.
export function safeBottomValue(m: { height: number; offsetTop: number; layoutHeight: number }): string {
  return bottomOccluded(m) ? "0px" : "env(safe-area-inset-bottom)";
}

/// Something — the soft keyboard — covers the layout viewport's bottom. The session's terminal fit reads
/// it too: a keyboard opening or closing HOLDS the grid for the host's snapshot (`TermDeck.fit`).
export function bottomOccluded(m: { height: number; offsetTop: number; layoutHeight: number }): boolean {
  return m.layoutHeight - (m.offsetTop + m.height) > BOTTOM_OCCLUSION_PX;
}

/// Body styles that pin the app to the visual viewport. iOS Safari keeps the LAYOUT viewport
/// (`window.innerHeight`) constant when the soft keyboard opens — it only shrinks `visualViewport` and
/// scrolls the page. Sizing <body> to `visualViewport.height` and following `visualViewport.offsetTop`
/// keeps the app exactly in the visible band, so #stage (and the terminal filling it) always equals the
/// visible area. `transform` is "none" (not `translateY(0)`) at rest so <body> never becomes a
/// containing block for position:fixed descendants (the floating sim) except while the keyboard is up.
export function viewportFitStyle(m: { height: number; offsetTop: number }): FitStyle {
  return {
    height: `${Math.round(m.height)}px`,
    transform: m.offsetTop > 0 ? `translateY(${Math.round(m.offsetTop)}px)` : "none",
  };
}

/// How far short of the layout viewport the visual viewport may be and still be ALL of it — iOS reports
/// fractional heights (843.67 of 844) at rest.
const WHOLE_VIEWPORT_SLACK_PX = 1;

/// Whether the document holds a scroll position the SCREEN does not share. Nothing on this page
/// scrolls the document — `html, body` are `overflow: hidden` at 100% — and the one thing that may
/// (iOS revealing a focused field above the soft keyboard) scrolls INTO the band the keyboard shrank.
/// So a scroll while the visual viewport is the whole layout viewport has nowhere to be, and the one
/// measured way to get there is a Home Screen web app turned back to portrait: iOS leaves it scrolled
/// by the status bar's height (68 on an iPhone Air, measured 2026-09-28; the document's `scrollHeight`
/// was 844 of 844 then — iOS moved the web view past a range of zero) while it still DRAWS the page
/// at 0. The page's coordinates and its taps say 68, the screen says 0 — a pinned session's
/// `ViewportFit` then followed the 68 and drew everything 68 low; the dashboard, drawn right, took
/// every tap 68 high. `layoutHeight` is `document.documentElement.clientHeight`, which held at 420
/// while the keyboard opened, not `innerHeight`, which iOS reported as 192 of 420 for a frame there:
/// it FOLLOWS the keyboard, and a first version of this check, measured against it, undid the
/// keyboard's own reveal and hid the focused field behind the keyboard. ANY non-zero scroll counts, above
/// the top as well as below it: the page is not scrollable either way. `scrollY` alone, because it is the
/// one `scrollTo` puts back (`visualViewport.offsetTop` read the same 68 in every measurement).
export function strandedScroll(m: { scrollY: number; height: number; layoutHeight: number }): boolean {
  return m.scrollY !== 0 && m.height >= m.layoutHeight - WHOLE_VIEWPORT_SLACK_PX;
}

/// Scrolls the document back to 0 on the event that strands it (`strandedScroll`) — the same thing
/// opening and closing the keyboard did by hand. FOR THE LIFE OF THE PAGE, and installed at page setup
/// BEFORE any session's `ViewportFit`: listeners on one target run in registration order, so on that
/// event `ViewportFit` reads the offset this has already put back, and never draws the stranded one.
/// Feature-detects visualViewport. Glue — the rotation itself needs a device (`docs/client-web.md`).
export function releaseStrandedScroll(): () => void {
  const vv = window.visualViewport;
  if (!vv) return () => {};
  const release = () => {
    const stranded = strandedScroll({
      scrollY: window.scrollY, height: vv.height, layoutHeight: document.documentElement.clientHeight,
    });
    if (stranded) window.scrollTo(0, 0);
  };
  // The measured strand arrived with the WINDOW's resize, then its scroll; whichever comes first releases.
  window.addEventListener("resize", release);
  window.addEventListener("scroll", release);
  vv.addEventListener("scroll", release);
  vv.addEventListener("resize", release);
  return () => {
    window.removeEventListener("resize", release);
    window.removeEventListener("scroll", release);
    vv.removeEventListener("scroll", release);
    vv.removeEventListener("resize", release);
  };
}

/// **NO PAGE ZOOM ON A TOUCH DEVICE** (asked for 2026-10-04: "disable page zoom at least on mobile"). A pinch
/// or a double tap scaled the whole client — its layout follows the viewport's width, so `chooseLayoutMode`
/// could flip under the fingers — where every two-finger gesture that means something here is the app's own
/// (the picture's pan and its Zoom mode). Three layers, one per engine's way of zooming: the viewport meta's
/// `maximum-scale=1, user-scalable=no` (index.html — Chromium on Android honours it, and on iOS it also stops
/// the page zooming to a focused input), `touch-action: manipulation` on the root under a coarse pointer
/// (style.css — no double-tap zoom, panning untouched: an ancestor's `touch-action` limits the terminal's own
/// native scroll, so never `none` there), and THIS — iOS Safari ignores the meta for a pinch, so the WebKit
/// gesture events that drive its page zoom are cancelled. Gated on `(any-pointer: coarse)`, the touch gate every
/// touch affordance uses (an iPad with a trackpad is one): a desktop pinch still zooms the page outside the
/// picture, which swallows its own (`input.ts`). Returns the remover.
export function blockPageZoom(doc: Document = document, coarse = window.matchMedia?.("(any-pointer: coarse)").matches ?? false): () => void {
  if (!coarse) return () => {};
  const cancel = (e: Event) => e.preventDefault();
  const opts = { passive: false } as const;
  for (const g of ["gesturestart", "gesturechange"]) doc.addEventListener(g, cancel, opts);
  return () => { for (const g of ["gesturestart", "gesturechange"]) doc.removeEventListener(g, cancel); };
}

/// The inline `<body>` properties `ViewportFit` writes. The stopper hands each back exactly as it
/// found it — the session starts and stops many times in one document now, and a pinned `<body>` left
/// behind would pin the dashboard. BOTH `overflow` (the shorthand `start()` actually writes) AND its
/// `overflow-x`/`overflow-y` LONGHANDS are snapshotted: a `<body>` that arrived with only the
/// longhands set has an EMPTY `overflow` in its "before" snapshot, and restoring only the shorthand
/// from that empty value would leave `start()`'s own `overflow = "hidden"` write behind forever.
const PINNED = [
  "position", "left", "right", "top", "overflow", "overflow-x", "overflow-y", "height", "transform",
] as const;

/// Pins <body> to `window.visualViewport`. At rest the terminal fills the screen; when the soft keyboard
/// opens, <body> shrinks → #stage shrinks → the existing ResizeObserver reflows xterm to fit above the
/// keyboard. No transform-shift, no custom scrollbar, no page-scroll offset. Feature-detects
/// visualViewport (no-op without it). Glue — measured by `e2e/keyboard-viewport-check.mjs`.
///
/// **A SESSION'S DOM PINS <body> FOR ITS LIFETIME** — the controller pins at mount and releases at
/// unmount (`session-lifecycle.ts`), so the pin outlives the engine through the Disconnect slide — and
/// the stopper hands it back exactly, with `--safe-b`, because the dashboard lives in this same document. While a
/// session is pending the dashboard sits in the pinned <body>: a geometric no-op at rest, different
/// only with the keyboard up (the check's dashboard arm measures it).
export class ViewportFit {
  constructor(private body: HTMLElement, private stateRoot: HTMLElement = document.documentElement) {}

  start(): () => void {
    const vv = window.visualViewport;
    if (!vv) return () => {};
    const style = this.body.style;
    const before = PINNED.map((p) => [p, style.getPropertyValue(p), style.getPropertyPriority(p)] as const);
    style.position = "fixed";
    style.left = "0";
    style.right = "0";
    style.top = "0";
    style.overflow = "hidden";
    const root = this.stateRoot;
    const apply = () => {
      const s = viewportFitStyle({ height: vv.height, offsetTop: vv.offsetTop });
      style.height = s.height;
      style.transform = s.transform;
      // Drop the bottom inset while the keyboard covers the home indicator. Set on the ROOT rather
      // than on <body>, because the palette sheet is a fixed-position child that reads it too.
      root.style.setProperty("--safe-b",
        safeBottomValue({ height: vv.height, offsetTop: vv.offsetTop, layoutHeight: window.innerHeight }));
    };
    vv.addEventListener("resize", apply);
    vv.addEventListener("scroll", apply);
    apply();
    return () => {
      vv.removeEventListener("resize", apply);
      vv.removeEventListener("scroll", apply);
      // Hand `--safe-b` back to the stylesheet's default rather than leaving the last measured value
      // pinned inline, which would outlive the reason for it.
      root.style.removeProperty("--safe-b");
      for (const [p, value, priority] of before) {
        if (value === "") style.removeProperty(p); else style.setProperty(p, value, priority);
      }
    };
  }
}
