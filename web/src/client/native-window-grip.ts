import { SessionScope } from "./session-scope";
/** Report only the unoccupied part of the chrome; native hit testing must not cover a tab.
 * Shared by the real bridge and the workbench's mock window. Lifetime: the owning adapter, released by the returned disposer.
 * Each report carries the WIDTH it was measured at, and the app uses it only at that width (`ChromeGap`):
 * in a lockstep zoom the page lays out ahead of the window, so the report arrives before the width does. */
export function installNativeWindowGrip(shell: { setChromeGap?: (left: number, right: number, width: number) => void }, root: Document | ShadowRoot = document, state: HTMLElement = document.documentElement): () => void {
  const scope = new SessionScope();
  let pending = false, previous = "";
  const schedule = () => {
    if (pending || scope.disposed) return;
    pending = true;
    scope.raf(() => {
      if (scope.disposed) return;
      pending = false;
      const bar = root.getElementById("tabbar");
      const add = root.getElementById("tab-add");
      const scroll = root.getElementById("tabbar-scroll");
      const search = root.getElementById("palette-open");
      const palette = root.getElementById("palette");
      if (scroll && scroll.clientWidth > 0 && state.dataset.layout !== "glasses") {
        const items = Array.from(scroll.querySelectorAll<HTMLElement>(".rl-tab, .tab-add"))
          .filter(item => item.getClientRects().length > 0);
        const style = getComputedStyle(scroll);
        const available = scroll.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
        const occupied = items.reduce((sum, item) => sum + item.offsetWidth, 0);
        // Measure item widths without gaps, so this calculation cannot feed back into itself.
        const gap = items.length > 1
          ? Math.max(5, Math.min(13, (available - occupied) / (items.length - 1))) : 13;
        const value = `${Math.floor(gap * 100) / 100}px`;
        if (scroll.style.getPropertyValue("--native-tab-gap") !== value) {
          scroll.style.setProperty("--native-tab-gap", value);
        }
      }
      let left = 0, right = 0;
      if (bar && add && scroll && search && bar.getBoundingClientRect().height > 0
          && !state.hasAttribute("data-fullscreen")
          && (!palette || palette.classList.contains("hidden"))) {
        const origin = bar.getBoundingClientRect().left;
        left = Math.ceil(Math.max(add.getBoundingClientRect().right, scroll.getBoundingClientRect().left) - origin);
        right = Math.floor(search.getBoundingClientRect().left - origin);
        if (right <= left) left = right = 0;
      }
      const width = innerWidth;
      const next = `${left}:${right}:${width}`;
      if (next !== previous) { previous = next; shell.setChromeGap?.(left, right, width); }
    });
  };
  const resize = scope.observe(new ResizeObserver(schedule));
  const mutations = scope.observe(new MutationObserver(schedule));
  const bind = () => {
    resize.disconnect(); mutations.disconnect();
    for (const id of ["tabbar", "tabbar-scroll", "tab-add", "palette-open", "palette"]) {
      const element = root.getElementById(id);
      if (!element) continue;
      resize.observe(element);
      mutations.observe(element, { childList: true, subtree: true, attributes: true, characterData: true });
    }
    schedule();
  };
  const session = root.getElementById("session");
  if (session) scope.observe(new MutationObserver(bind)).observe(session, { childList: true });
  scope.observe(new MutationObserver(schedule)).observe(state, { attributes: true, attributeFilter: ["data-fullscreen"] });
  scope.listen(document,"scroll",schedule,true);
  scope.listen(window,"resize",schedule);
  const coarse=matchMedia("(any-pointer: coarse)");
  coarse.addEventListener("change",schedule);
  scope.defer(()=>coarse.removeEventListener("change",schedule));
  document.fonts?.ready.then(schedule);
  bind();
  return () => scope.dispose();
}
