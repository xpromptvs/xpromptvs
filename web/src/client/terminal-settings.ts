import { openClientDialog, closeClientDialog } from "./instance/overlays";
import { contextFor, presentationRoot } from "./instance/context";
import { positionSettingsCard } from "./settings-overlay";
import { onSmoothScrollChange, setSmoothScroll, smoothScrollEnabled } from "../shared/smooth-scroll-pref";
import { windowControlIcon } from "./window-control-icons";
import type { GpuState } from "./webgpu/device";

export function savedTerminalFontSize(fallback: number, store: Pick<Storage, "getItem"> = localStorage): number {
  try { const value = Number(store.getItem("rdev.terminalFontSize")); return value >= 8 && value <= 32 ? value : fallback; }
  catch { return fallback; }
}

/// The terminals' renderer as this device chose it (docs/client-web.md, "The WebGPU renderer"): WebGPU unless a
/// SAVED "dom" turned it off — the setting below, per device, like the font size.
export function savedTerminalRenderer(store: Pick<Storage, "getItem"> = localStorage): "webgpu" | "dom" {
  try { return store.getItem("rdev.terminalRenderer") === "dom" ? "dom" : "webgpu"; }
  catch { return "webgpu"; }
}
export function saveTerminalRenderer(kind: "webgpu" | "dom", store: Pick<Storage, "setItem"> = localStorage): void {
  try { store.setItem("rdev.terminalRenderer", kind); } catch { /* still applied for this session */ }
}

/// EXPERIMENTAL: the WebGPU renderer shades coloured backgrounds by where they sit (webgpu/renderer.ts
/// `setBackgroundGradient`) — ON unless this device explicitly saved it off.
export function savedBackgroundGradient(store: Pick<Storage, "getItem"> = localStorage): boolean {
  try { return store.getItem("rdev.terminalBgGradient") !== "off"; }
  catch { return true; }
}
export function saveBackgroundGradient(on: boolean, store: Pick<Storage, "setItem"> = localStorage): void {
  try { store.setItem("rdev.terminalBgGradient", on ? "on" : "off"); } catch { /* still applied for this session */ }
}

/// What the Renderer row says: what the shown terminal is DRAWN with (null: no terminal open), and why
/// it is the DOM renderer when WebGPU was asked for.
export function rendererStatus(enabled: boolean, drawing: "webgpu" | "dom" | null, gpu: GpuState): string {
  if (drawing === "webgpu") return "WebGPU";
  if (!enabled) return "DOM";
  if (gpu === "unavailable") return "DOM (WebGPU unavailable)";
  if (gpu === "ready") return drawing === null ? "WebGPU" : "DOM (switching to WebGPU…)";
  return "DOM (starting WebGPU…)";
}

export interface RendererSetting {
  enabled(): boolean;
  status(): string;
  set(on: boolean): void;
}

/// An on/off setting (the experimental gradient).
export interface SwitchSetting {
  enabled(): boolean;
  set(on: boolean): void;
}

/// **ON A PHONE IT IS A SHEET OVER THE TERMINAL, AS A WINDOW'S SETTINGS COVER THEIR WINDOW** (2026-10-06, asked for:
/// "on mobile make terminal settings full screen just like window settings"): on the tabbed layout the dialog opens
/// NON-modal inside `surface` (`#term-surface`) at `inset: 0` — the tab bar and the status bar stay live, the
/// status-bar button TOGGLES it (lit while open, `aria-expanded`), and it goes away with the terminal surface. Every
/// other layout keeps the centred modal. A layout flip while it is open closes it rather than show one mode's sheet
/// in the other's geometry.
export function mountTerminalSettings(footer: HTMLElement, font: { get(): number; set(size: number): void },
                                      renderer: RendererSetting, gradient: SwitchSetting, surface: HTMLElement,
                                      sameMac = false): () => void {
  const context = contextFor(footer);
  const smoothEnabled = context?.smooth.enabled ?? smoothScrollEnabled;
  const setSmooth = context?.smooth.set ?? setSmoothScroll;
  const onSmooth = context?.smooth.subscribe ?? onSmoothScrollChange;
  const shell = context ? context.platform.native : (window as Window & { __rdevShell?: { openMacs?(): void } }).__rdevShell;
  // A native shell can also be a remote client. Only This Mac replaces connection chrome.
  footer.dataset.localClient = String(sameMac);
  let macs: HTMLButtonElement | undefined;
  if (sameMac && shell?.openMacs) {
    macs = document.createElement("button");
    macs.id = "macs-open";
    macs.type = "button";
    macs.title = "Network and Sharing";
    macs.setAttribute("aria-label", "Open Network and Sharing");
    macs.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="13" rx="2"/><path d="M9 21h6m-3-4v4"/></svg><span>Other Devices</span>`;
    macs.onclick = () => shell.openMacs!();
    footer.prepend(macs);
  }
  const button = document.createElement("button");
  button.id = "terminal-settings-open";
  button.type = "button";
  button.title = "Terminal Settings";
  button.setAttribute("aria-label", "Terminal Settings");
  button.setAttribute("aria-haspopup", "dialog");
  button.setAttribute("aria-expanded", "false");
  button.innerHTML = windowControlIcon("settingsPanel", 22);
  footer.insertBefore(button, footer.querySelector("#keyboard-open"));
  const dialog = document.createElement("dialog");
  dialog.className = "win-settings terminal-settings";
  dialog.setAttribute("aria-label", "Terminal Settings");
  dialog.innerHTML = `<header class="win-settings-head"><span class="win-settings-title">Terminal Settings</span><button class="win-settings-close" aria-label="Close settings">${windowControlIcon("close")}</button></header>
    <section class="win-settings-section"><h3>Appearance</h3>
      <div class="win-settings-row"><span class="win-settings-label">Font size</span><div class="terminal-font-stepper"><button type="button" aria-label="Decrease font size">−</button><output aria-live="polite"></output><button type="button" aria-label="Increase font size">+</button></div></div>
      <div class="win-settings-row"><span class="win-settings-label">Smooth scrolling</span><button type="button" class="win-switch" role="switch" aria-label="Smooth scrolling"></button></div>
    </section>
    <section class="win-settings-section"><h3>Rendering</h3>
      <div class="win-settings-row"><span class="win-settings-label">Renderer</span><output class="terminal-renderer" aria-live="polite"></output></div>
      <div class="win-settings-row"><span class="win-settings-label">WebGPU rendering</span><button type="button" class="win-switch" role="switch" aria-label="WebGPU rendering"></button></div>
    </section>
    <section class="win-settings-section"><h3>Experimental</h3>
      <div class="win-settings-row"><span class="win-settings-label">Gradient backgrounds</span><button type="button" class="win-switch" role="switch" aria-label="Gradient backgrounds"></button></div>
    </section>`;
  surface.append(dialog);
  const output = dialog.querySelector("output")!;
  const minus = dialog.querySelector<HTMLButtonElement>("[aria-label=\"Decrease font size\"]")!;
  const plus = dialog.querySelector<HTMLButtonElement>("[aria-label=\"Increase font size\"]")!;
  const smooth = dialog.querySelector<HTMLButtonElement>("[aria-label=\"Smooth scrolling\"]")!;
  const rendererOut = dialog.querySelector<HTMLOutputElement>(".terminal-renderer")!;
  const gpuSwitch = dialog.querySelector<HTMLButtonElement>("[aria-label=\"WebGPU rendering\"]")!;
  const gradientSwitch = dialog.querySelector<HTMLButtonElement>("[aria-label=\"Gradient backgrounds\"]")!;
  const refresh = () => {
    output.value = `${font.get()} pt`;
    minus.disabled = font.get() <= 8; plus.disabled = font.get() >= 32;
    smooth.setAttribute("aria-checked", String(smoothEnabled()));
    rendererOut.value = renderer.status();
    gpuSwitch.setAttribute("aria-checked", String(renderer.enabled()));
    gradientSwitch.setAttribute("aria-checked", String(gradient.enabled()));
    // Only the WebGPU renderer draws it.
    gradientSwitch.disabled = !renderer.enabled();
  };
  const change = (delta: number) => {
    const size = Math.max(8, Math.min(32, font.get() + delta));
    try { (context?.storage ?? localStorage).setItem("rdev.terminalFontSize", String(size)); } catch { /* Still apply locally. */ }
    font.set(size); refresh();
  };
  minus.onclick = () => change(-1); plus.onclick = () => change(1);
  smooth.onclick = () => setSmooth(!smoothEnabled());
  gpuSwitch.onclick = () => { renderer.set(!renderer.enabled()); refresh(); };
  gradientSwitch.onclick = () => { gradient.set(!gradient.enabled()); refresh(); };
  // The status follows the tabs moving over (a fresh snapshot each), so it is re-read while the dialog is up.
  let poll: ReturnType<typeof setInterval> | null = null;
  const stopPoll = () => { if (poll !== null) { clearInterval(poll); poll = null; } };
  const asSheet = () => presentationRoot(footer).dataset.layout === "tabbed";
  let sheet = false;
  button.onclick = () => {
    if (dialog.open) { closeClientDialog(dialog); return; }        // the sheet's toggle (a modal leaves the button inert)
    button.focus({ preventScroll: true });
    refresh();
    sheet = asSheet();
    dialog.style.removeProperty("left"); dialog.style.removeProperty("top");
    dialog.style.removeProperty("right"); dialog.style.removeProperty("bottom"); dialog.style.removeProperty("margin");
    if (sheet) dialog.show(); else {
      openClientDialog(dialog);
      positionSettingsCard(dialog, surface);
    }
    button.setAttribute("aria-expanded", "true");
    stopPoll(); poll = setInterval(refresh, 400);
  };
  dialog.addEventListener("close", () => { stopPoll(); button.setAttribute("aria-expanded", "false"); });
  // A modal dialog closes on Esc by itself; a sheet does not.
  dialog.addEventListener("keydown", event => { if (sheet && event.key === "Escape") { event.preventDefault(); closeClientDialog(dialog); } });
  const layout = new MutationObserver(() => { if (dialog.open && sheet !== asSheet()) closeClientDialog(dialog); });
  layout.observe(presentationRoot(footer), { attributes: true, attributeFilter: ["data-layout"] });
  dialog.querySelector<HTMLButtonElement>(".win-settings-close")!.onclick = () => closeClientDialog(dialog);
  dialog.addEventListener("click", event => {
    const r = dialog.getBoundingClientRect();
    if (event.target === dialog && (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom)) closeClientDialog(dialog);
  });
  const reposition = () => { if (dialog.open && !sheet) positionSettingsCard(dialog, surface); };
  window.addEventListener("resize", reposition);
  const off = onSmooth(refresh);
  return () => { window.removeEventListener("resize", reposition); off(); stopPoll(); layout.disconnect(); macs?.remove(); delete footer.dataset.localClient; closeClientDialog(dialog); dialog.remove(); button.remove(); };
}
