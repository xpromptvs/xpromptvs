import type { ScrollSurface } from "./smooth-scroll";
import type { Terminal } from "@xterm/xterm";

/** A surface-aligned rail, independent of the text grid and its tmux/content insets. `end`: the last line the view
 *  may start at — the bottom (`baseY`) unless an agent's trailing blank lines are taken as not there
 *  (trailing-blanks.ts), and the rail's range ends there too. */
export function mountTerminalScrollbar(term: Terminal, container: HTMLElement, stop: () => void,
  position?: Pick<ScrollSurface, "scrollTop" | "cellHeight" | "onScroll">,
  end: () => number = () => term.buffer.active.baseY): () => void {
  const surface = container.closest<HTMLElement>("#xterm");
  if (!surface) return () => {};
  const rail = document.createElement("div");
  rail.className = "terminal-scrollbar";
  rail.setAttribute("role", "scrollbar");
  rail.setAttribute("aria-label", "Terminal scrollback");
  rail.setAttribute("aria-orientation", "vertical");
  rail.setAttribute("aria-valuemin", "0");
  rail.tabIndex = 0;
  const thumb = document.createElement("div");
  thumb.className = "terminal-scrollbar-thumb";
  rail.append(thumb); container.append(rail);
  // The terminal's touch-pan handler must not also interpret a thumb drag.
  for (const type of ["touchstart", "touchmove", "touchend", "touchcancel"]) {
    rail.addEventListener(type, event => event.stopPropagation(), { passive: true });
  }
  container.classList.add("has-terminal-scrollbar");
  let height = 0, thumbHeight = 0, drag: { id: number; grab: number } | null = null;
  const update = () => {
    const buffer = term.buffer.active;
    const max = end();
    rail.hidden = height <= 0 || max <= 0 || buffer.type === "alternate";
    thumbHeight = Math.min(height, Math.max(28, height * term.rows / (max + term.rows)));
    thumb.style.height = `${thumbHeight}px`;
    const cellHeight = position?.cellHeight() ?? 0;
    const row = position && cellHeight > 0 ? position.scrollTop() / cellHeight : buffer.viewportY;
    const fraction = max > 0 ? Math.max(0, Math.min(1, row / max)) : 0;
    thumb.style.top = `${(height - thumbHeight) * fraction}px`;
    rail.setAttribute("aria-valuemax", String(max));
    rail.setAttribute("aria-valuenow", String(buffer.viewportY));
  };
  const measure = () => {
    const outer = surface.getBoundingClientRect(), inner = container.getBoundingClientRect();
    const scale = surface.offsetHeight ? outer.height / surface.offsetHeight : 1;
    if (!scale) return;
    height = Math.max(0, surface.clientHeight - 12);
    rail.style.top = `${(outer.top - inner.top) / scale + 6}px`;
    rail.style.left = `${(outer.right - inner.left) / scale - 14}px`;
    rail.style.height = `${height}px`;
    update();
  };
  const scroll = (clientY: number, grab: number) => {
    const rect = rail.getBoundingClientRect();
    const y = (clientY - rect.top) * height / rect.height - grab;
    const fraction = Math.max(0, Math.min(1, y / Math.max(1, height - thumbHeight)));
    term.scrollToLine(Math.round(fraction * end()));
  };
  rail.addEventListener("pointerdown", e => {
    if (e.button !== 0) return;
    e.preventDefault(); e.stopPropagation(); stop();
    const rect = thumb.getBoundingClientRect();
    const grab = e.target === thumb ? (e.clientY - rect.top) * thumbHeight / rect.height : thumbHeight / 2;
    drag = { id: e.pointerId, grab };
    rail.setPointerCapture(e.pointerId); rail.classList.add("dragging");
    scroll(e.clientY, grab);
  });
  rail.addEventListener("pointermove", e => {
    if (drag?.id !== e.pointerId) return;
    e.preventDefault(); e.stopPropagation(); scroll(e.clientY, drag.grab);
  });
  const release = () => { drag = null; rail.classList.remove("dragging"); };
  rail.addEventListener("lostpointercapture", release);
  rail.addEventListener("pointerup", release);
  rail.addEventListener("pointercancel", release);
  rail.addEventListener("keydown", e => {
    const delta = e.key === "ArrowUp" ? -1 : e.key === "ArrowDown" ? 1
      : e.key === "PageUp" ? -term.rows : e.key === "PageDown" ? term.rows : null;
    if (delta === null && e.key !== "Home" && e.key !== "End") return;
    e.preventDefault(); e.stopPropagation(); stop();
    term.scrollToLine(e.key === "Home" ? 0 : e.key === "End" ? end() : term.buffer.active.viewportY + delta!);
  });
  const subscriptions = [term.onScroll(update), term.onRender(update), term.onResize(measure)];
  if (position) subscriptions.push(position.onScroll(update));
  const observer = new ResizeObserver(measure);
  observer.observe(surface); observer.observe(container);
  measure();
  return () => {
    observer.disconnect(); subscriptions.forEach(s => s.dispose());
    rail.remove(); container.classList.remove("has-terminal-scrollbar");
  };
}
