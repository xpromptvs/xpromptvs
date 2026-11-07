import {productFeatures} from "../../shared/product-features";
import type { LayoutMode } from "../layout-mode";

/** Presentation attributes live on this instance, never the enclosing document's html element. */
export function createPresentation(root: HTMLElement, layout: LayoutMode = "floating") {
  root.dataset.tab = "sim";
  root.dataset.theme = "dark";
  root.dataset.layout = layout === "glasses" && !productFeatures.glasses ? "floating" : layout;
  return {
    layout: () => root.dataset.layout as LayoutMode,
    setLayout(mode: LayoutMode) { root.dataset.layout = mode === "glasses" && !productFeatures.glasses ? "floating" : mode; },
    theme: () => "dark" as const,
  };
}
