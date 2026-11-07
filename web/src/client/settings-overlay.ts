import { contextFor } from "./instance/context";
/** Centre a top-layer settings card on its owner, constrained only by the visible viewport. */
export function positionSettingsCard(card: HTMLElement, owner: HTMLElement): void {
  const box = owner.getBoundingClientRect(), size = card.getBoundingClientRect();
  const context = contextFor(owner);
  const bounds = context?.viewport.rect();
  const vv = context ? null : window.visualViewport;
  const left = bounds?.left ?? vv?.offsetLeft ?? 0, top = bounds?.top ?? vv?.offsetTop ?? 0;
  const width = bounds?.width ?? vv?.width ?? innerWidth, height = bounds?.height ?? vv?.height ?? innerHeight;
  card.style.margin = "0"; card.style.right = "auto"; card.style.bottom = "auto";
  card.style.left = `${Math.max(left + 20, Math.min(box.left + (box.width - size.width) / 2, left + width - size.width - 20)) - (bounds?.left ?? 0)}px`;
  card.style.top = `${Math.max(top + 20, Math.min(box.top + (box.height - size.height) / 2, top + height - size.height - 20)) - (bounds?.top ?? 0)}px`;
}
