import {productFeatures} from "../shared/product-features";
export type LayoutMode = "floating" | "tabbed" | "glasses";

/// A touch window this narrow gets the tabbed layout — a portrait tablet, and a phone either way up by
/// this or by `TABLET_MIN_SHORT_SIDE`; wider (desktop, landscape iPad) keeps floating.
export const TABBED_MAX_WIDTH = 820;

/// A touch SCREEN whose shorter side is under this is a PHONE's, and a phone keeps the tabbed layout
/// in landscape too — an iPhone Air on its side is 912pt wide, and it got the desktop's floating
/// windows. 600 is the line Android draws between phone and tablet (`sw600dp`); the largest iPhone is
/// 440pt across and the smallest iPad 744, so neither is near it. The SCREEN, never the window: iOS
/// reported `innerHeight` 192 of 420 for a frame while its keyboard opened (measured 2026-09-28), and
/// a window's short side would flip a landscape iPad to tabbed every time its keyboard came up.
export const TABLET_MIN_SHORT_SIDE = 600;

/// Terminal font size (px) for the desktop/floating layout.
export const TERMINAL_FONT_SIZE = 15;

/// Terminal font size (px) for the tabbed/mobile layout. 12px since 2026-09-24 — it was HALF the
/// desktop size (7.5px, "2x smaller", so more grid fit on a phone) and that proved too small to read.
export const TABBED_TERMINAL_FONT_SIZE = 12;

/// Meta Ray-Ban Display is exactly 600x600dp. BOTH axes are checked: a 600-wide phone window is
/// common, a 600x600 one is not.
export const GLASSES_SIZE = 600;

/// 16px, not the tabbed layout's 12px — below 14dp, the display guidelines' floor for interactive
/// text, and illegible on the waveguide. Yields roughly 60x30 at 600px.
export const GLASSES_TERMINAL_FONT_SIZE = 16;

/// Terminal font size (px) for a layout. The tabbed/mobile layout is smaller than desktop so more of
/// the terminal grid fits on a phone screen. Pure — feeds both xterm and the prediction overlay so their
/// sizes stay in lockstep (a mismatch misaligns the ghost text).
/// Whether the terminal may take DOM focus for itself.
///
/// FALSE on glasses. The D-pad drives `document.activeElement`, so xterm grabbing focus parks the
/// wearer on an element the nav order does not own — no focus ring, nothing the D-pad recognises,
/// and no pointer to take it back. The terminal still receives typed text: the compose bar sends it
/// over the same `{t:"key"}` path, and that field is reachable by the D-pad like any other control.
export function terminalMayAutofocus(mode: LayoutMode): boolean {
  return mode !== "glasses";
}

export function terminalFontSize(mode: LayoutMode): number {
  if (mode === "glasses") return GLASSES_TERMINAL_FONT_SIZE;
  return mode === "tabbed" ? TABBED_TERMINAL_FONT_SIZE : TERMINAL_FONT_SIZE;
}

/// Pure decision. `override` is the raw `?layout=` value; only "tabbed"/"floating" are honored.
/// `width`/`height` are the WINDOW's; `screen` is the device's (`window.screen`, which iOS reports in
/// portrait points whatever the orientation and Android turns with the device — only its short side
/// is read, so either is right).
export function chooseLayoutMode(
  env: { width: number; height: number; coarsePointer: boolean; screen: { width: number; height: number } },
  override: string | null,
): LayoutMode {
  if (override === "tabbed" || override === "floating") return override;
  if (productFeatures.glasses && override === "glasses") return override;
  if (productFeatures.glasses && env.width === GLASSES_SIZE && env.height === GLASSES_SIZE) return "glasses";
  const phone = Math.min(env.screen.width, env.screen.height) < TABLET_MIN_SHORT_SIDE;
  return env.coarsePointer && (env.width <= TABBED_MAX_WIDTH || phone) ? "tabbed" : "floating";
}

/// Watch width + pointer and call onChange whenever the resolved mode flips (fires once immediately).
/// Returns an unsubscribe fn. Glue — not unit-tested (needs matchMedia/resize).
export function watchLayoutMode(
  override: string | null,
  onChange: (mode: LayoutMode) => void,
): () => void {
  const coarse = window.matchMedia("(pointer: coarse)");
  let last: LayoutMode | null = null;
  const evaluate = () => {
    const mode = chooseLayoutMode(
      {
        width: window.innerWidth, height: window.innerHeight, coarsePointer: coarse.matches,
        screen: { width: window.screen.width, height: window.screen.height },
      },
      override,
    );
    if (mode !== last) { last = mode; onChange(mode); }
  };
  window.addEventListener("resize", evaluate);
  window.addEventListener("orientationchange", evaluate);
  coarse.addEventListener("change", evaluate);
  evaluate();
  return () => {
    window.removeEventListener("resize", evaluate);
    window.removeEventListener("orientationchange", evaluate);
    coarse.removeEventListener("change", evaluate);
  };
}
