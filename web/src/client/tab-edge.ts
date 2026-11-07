import { presentationRoot, contextFor } from "./instance/context";
/** Keep the mobile back-arrow join in step with whichever active tab reaches the scroll edge.
 * The tab's own concave foot is clipped by overflow-x:auto, so the fixed rail paints that foot. */
export function installTabEdge(scroller: HTMLElement): () => void {
  const bar = scroller.closest<HTMLElement>("#tabbar");
  if (!bar) return () => {};
  let frame = 0;
  const update = () => {
    frame = 0;
    const active = scroller.querySelector<HTMLElement>(".rl-tab.on");
    const edge = scroller.getBoundingClientRect().left;
    const tab = active?.getBoundingClientRect();
    bar.toggleAttribute("data-active-left-edge", presentationRoot(scroller).dataset.layout === "tabbed"
      && !!tab && tab.left < edge && tab.right > edge);
  };
  const schedule = () => { if (!frame) frame = requestAnimationFrame(update); };
  const observer = new MutationObserver(schedule);
  observer.observe(scroller, { subtree: true, childList: true, attributes: true, attributeFilter: ["class", "style"] });
  observer.observe(presentationRoot(scroller), { attributes: true, attributeFilter: ["data-layout"] });
  scroller.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", schedule);
  const offResize=contextFor(scroller)?.onResize(schedule);
  schedule();
  return () => {
    offResize?.();observer.disconnect();
    scroller.removeEventListener("scroll", schedule);
    window.removeEventListener("resize", schedule);
    if (frame) cancelAnimationFrame(frame);
    bar.removeAttribute("data-active-left-edge");
  };
}
