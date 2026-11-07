import type { SessionScope } from "../session-scope";
export function observeClientViewport(root: HTMLElement, scope: SessionScope, changed: () => void) {
  if (typeof ResizeObserver !== "undefined") scope.observe(new ResizeObserver(scope.guard(changed))).observe(root);
  return {
    rect: () => root.getBoundingClientRect(),
    size() { const r = root.getBoundingClientRect(); return {width: r.width, height: r.height}; },
    toLocal(x: number, y: number) { const r = root.getBoundingClientRect(); return {x: x-r.left, y: y-r.top}; },
  };
}
