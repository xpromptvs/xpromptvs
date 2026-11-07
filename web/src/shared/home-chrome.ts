import { onSmoothScrollChange, setSmoothScroll, smoothScrollEnabled } from "./smooth-scroll-pref";

/**
 * **The home page's chrome behaviours, shared by both dashboards.**
 *
 * Devices/Settings navigation, the Smooth scrolling checkbox are identical
 * on `#welcome` in the browser and on `app://ui/` in the app — same ids (`#home-devices`,
 * `#home-settings`), same attributes (`[data-home]`, `[data-settings]`,
 * `[data-smooth-scroll]`), same behaviour. They were two copies
 * until 2026-09-14, and the app's copy had quietly grown its own theme persistence: it read and
 * wrote `rdev.theme` by hand, so `theme.ts`'s system-preference fallback and its change listeners
 * existed on one surface only. `docs/ui-design.md`.
 *
 * Animation accessibility follows the system preference; there is no app-level override.
 */

export type HomePage = "devices" | "settings";

export function mountHomeChrome (opts: {
  /** Where the nav buttons live. The browser scopes this to `#welcome`; the app uses the document. */
  root?: ParentNode;
  /** The browser re-mounts its overlay after every session, and each mount drops the last one's listeners. */
  signal?: AbortSignal;
  /**
   * Run before a page is shown. The app is really THREE views — devices, settings and Share this
   * Mac — and picking either nav item has to leave the share panel first. The browser passes nothing.
   */
  beforeShow?: () => void;
} = {}): (page: HomePage) => void {
  const root = opts.root ?? document;
  const listener = opts.signal ? { signal: opts.signal } : undefined;

  const devices = root.querySelector<HTMLElement>("#home-devices");
  const settings = root.querySelector<HTMLElement>("#home-settings");

  const showPage = (page: HomePage): void => {
    opts.beforeShow?.();
    if (devices) devices.hidden = page !== "devices";
    if (settings) settings.hidden = page !== "settings";
    // `aria-current` is the only thing that says which nav item is the page you are on — the
    // integrated tab fill is drawn from that attribute, not from a class.
    root.querySelectorAll("[data-home], [data-settings]").forEach((el) => {
      if (el.matches(page === "devices" ? "[data-home]" : "[data-settings]")) el.setAttribute("aria-current", "page");
      else el.removeAttribute("aria-current");
    });
  };

  root.querySelectorAll("[data-home]").forEach((el) =>
    el.addEventListener("click", (e) => { e.preventDefault(); showPage("devices"); }, listener));
  root.querySelector("[data-settings]")
    ?.addEventListener("click", () => showPage("settings"), listener);

  // Smooth scrolling (`smooth-scroll-pref.ts`): what this device saved, and the checkbox follows a
  // change made elsewhere — the palette of a session in this document, or another page of the origin.
  const smooth = root.querySelector<HTMLInputElement>("[data-smooth-scroll]");
  if (smooth) {
    smooth.checked = smoothScrollEnabled();
    smooth.addEventListener("change", () => setSmoothScroll(smooth.checked), listener);
    const off = onSmoothScrollChange((on) => { smooth.checked = on; });
    opts.signal?.addEventListener("abort", off, { once: true });
  }

  return showPage;
}
