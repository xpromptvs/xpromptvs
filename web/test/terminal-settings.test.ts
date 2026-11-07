import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mountTerminalSettings, rendererStatus, savedBackgroundGradient, savedTerminalRenderer, saveBackgroundGradient, saveTerminalRenderer,
         type RendererSetting, type SwitchSetting } from "../src/client/terminal-settings";

// Terminal Settings' Renderer row: what the shown terminal is drawn with, and the switch back to the DOM
// renderer (docs/client-web.md, "The WebGPU renderer").

describe("the Renderer row's words", () => {
  it("says what the shown terminal is DRAWN with, and why it is the DOM renderer when WebGPU was asked for", () => {
    expect(rendererStatus(true, "webgpu", "ready")).toBe("WebGPU");
    expect(rendererStatus(false, "dom", "ready"), "turned off").toBe("DOM");
    expect(rendererStatus(true, "dom", "unavailable")).toBe("DOM (WebGPU unavailable)");
    expect(rendererStatus(true, "dom", "pending")).toBe("DOM (starting WebGPU…)");
    expect(rendererStatus(true, "dom", "untried")).toBe("DOM (starting WebGPU…)");
    expect(rendererStatus(true, "dom", "ready"), "the tabs have not moved over yet").toBe("DOM (switching to WebGPU…)");
    expect(rendererStatus(true, null, "ready"), "no terminal open").toBe("WebGPU");
  });
});

/// A fresh in-memory Storage per test (the environment's own global lacks parts of the API — the repo's other
/// storage tests stub it the same way).
function memStore(): Storage {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => { m.set(k, String(v)); },
           removeItem: (k: string) => { m.delete(k); }, clear: () => m.clear(), key: () => null,
           get length() { return m.size; } } as Storage;
}

describe("the saved choice", () => {
  beforeEach(() => { vi.stubGlobal("localStorage", memStore()); });
  afterEach(() => { vi.unstubAllGlobals(); });
  it("is WebGPU until a saved \"dom\" turns it off", () => {
    expect(savedTerminalRenderer()).toBe("webgpu");
    saveTerminalRenderer("dom");
    expect(savedTerminalRenderer()).toBe("dom");
    saveTerminalRenderer("webgpu");
    expect(savedTerminalRenderer()).toBe("webgpu");
  });
  it("storage that throws reads as WebGPU", () => {
    vi.stubGlobal("localStorage", { getItem: () => { throw new Error("blocked"); } });
    expect(savedTerminalRenderer()).toBe("webgpu");
  });
  it("the experimental gradient defaults on and respects a saved choice", () => {
    expect(savedBackgroundGradient()).toBe(true);
    saveBackgroundGradient(true);
    expect(savedBackgroundGradient()).toBe(true);
    saveBackgroundGradient(false);
    expect(savedBackgroundGradient()).toBe(false);
    vi.stubGlobal("localStorage", { getItem: () => { throw new Error("blocked"); } });
    expect(savedBackgroundGradient(), "storage that throws retains the default").toBe(true);
  });
});

describe("the modal", () => {
  // jsdom 25 implements neither `showModal` nor `close` on <dialog>.
  beforeEach(() => {
    vi.stubGlobal("localStorage", memStore());
    HTMLDialogElement.prototype.showModal = function () { this.setAttribute("open", ""); this.dataset.modal = "true"; };
    HTMLDialogElement.prototype.show = function () { this.setAttribute("open", ""); this.dataset.modal = "false"; };
    HTMLDialogElement.prototype.close = function () { this.removeAttribute("open"); this.dispatchEvent(new Event("close")); };
  });
  afterEach(() => { document.body.replaceChildren(); delete document.documentElement.dataset.layout; vi.unstubAllGlobals(); });

  function mount(sameMac = false) {
    const bar = document.createElement("div");
    const footer = document.createElement("div");
    const surface = document.createElement("div");
    bar.append(footer);
    document.body.append(bar, surface);
    let on = true, drawing = "WebGPU";
    const set = vi.fn((v: boolean) => { on = v; drawing = v ? "WebGPU" : "DOM"; });
    const renderer: RendererSetting = { enabled: () => on, status: () => drawing, set };
    let shaded = false;
    const setGradient = vi.fn((v: boolean) => { shaded = v; });
    const gradient: SwitchSetting = { enabled: () => shaded, set: setGradient };
    const dispose = mountTerminalSettings(footer, { get: () => 14, set: () => {} }, renderer, gradient, surface, sameMac);
    const dialog = surface.querySelector("dialog")!;
    const button = bar.querySelector<HTMLButtonElement>("#terminal-settings-open")!;
    return { bar, dialog, button, set, setGradient, dispose, open: () => button.click() };
  }
  it("keeps remote native clients' footer for connection status", () => {
    vi.stubGlobal('__rdevShell', { openMacs: vi.fn() });
    const t = mount(false);
    expect(t.bar.querySelector('#macs-open')).toBeNull();
    expect(t.bar.firstElementChild?.getAttribute('data-local-client')).toBe('false');
    t.dispose();
  });
  it("keeps Other Devices in This Mac's footer only", () => {
    const openMacs = vi.fn(); vi.stubGlobal('__rdevShell', { openMacs });
    const t = mount(true);
    const button = t.bar.querySelector<HTMLButtonElement>('#macs-open')!;
    expect(button.textContent).toBe('Other Devices');
    expect(t.bar.firstElementChild?.getAttribute('data-local-client')).toBe('true');
    button.click(); expect(openMacs).toHaveBeenCalledOnce();
    t.dispose(); expect(t.bar.firstElementChild?.hasAttribute('data-local-client')).toBe(false);
  });

  // On a phone it is a sheet over the terminal, as a window's settings cover their window (its geometry is
  // e2e/terminal-settings-sheet-check.mjs's): opened NON-modal, toggled by its button, closed by a layout flip.
  it("on the tabbed layout: a non-modal sheet the button toggles; elsewhere the modal", () => {
    document.documentElement.dataset.layout = "tabbed";
    const m = mount();
    m.open();
    expect([m.dialog.open, m.dialog.dataset.modal, m.button.getAttribute("aria-expanded")]).toEqual([true, "false", "true"]);
    m.open();
    expect([m.dialog.open, m.button.getAttribute("aria-expanded")], "the button again closes it").toEqual([false, "false"]);
    document.documentElement.dataset.layout = "floating";
    m.open();
    expect([m.dialog.open, m.dialog.dataset.modal]).toEqual([true, "true"]);
    m.dispose();
  });

  it("a sheet closes on Esc and when the layout flips under it", async () => {
    document.documentElement.dataset.layout = "tabbed";
    const m = mount();
    m.open();
    m.dialog.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    expect(m.dialog.open, "Esc").toBe(false);
    m.open();
    document.documentElement.dataset.layout = "floating";              // an iPad turned on its side
    await Promise.resolve();
    expect(m.dialog.open, "the flip").toBe(false);
    m.dispose();
  });

  it("the experimental gradient's switch: off at first, its own setting, and only while WebGPU draws", () => {
    const m = mount();
    m.open();
    const sw = m.dialog.querySelector<HTMLButtonElement>("[aria-label=\"Gradient backgrounds\"]")!;
    const gpu = m.dialog.querySelector<HTMLButtonElement>("[aria-label=\"WebGPU rendering\"]")!;
    expect(sw.closest("section")!.querySelector("h3")!.textContent).toBe("Experimental");
    expect(sw.getAttribute("aria-checked")).toBe("false");
    expect(sw.disabled).toBe(false);
    sw.click();
    expect(m.setGradient).toHaveBeenLastCalledWith(true);
    expect(m.set, "the renderer is untouched").not.toHaveBeenCalled();
    expect(sw.getAttribute("aria-checked")).toBe("true");
    gpu.click();
    expect(sw.disabled, "the DOM renderer draws no gradient").toBe(true);
    gpu.click();
    expect(sw.disabled).toBe(false);
    m.dispose();
  });

  it("shows what draws, and the switch turns WebGPU off and on", () => {
    const m = mount();
    m.open();
    const out = m.dialog.querySelector<HTMLOutputElement>(".terminal-renderer")!;
    const sw = m.dialog.querySelector<HTMLButtonElement>("[aria-label=\"WebGPU rendering\"]")!;
    expect(out.value).toBe("WebGPU");
    expect(sw.getAttribute("aria-checked")).toBe("true");
    sw.click();
    expect(m.set).toHaveBeenLastCalledWith(false);
    expect(out.value).toBe("DOM");
    expect(sw.getAttribute("aria-checked")).toBe("false");
    sw.click();
    expect(m.set).toHaveBeenLastCalledWith(true);
    m.dispose();
  });

  it("the smooth-scrolling switch is still its own (two switches now)", () => {
    const m = mount();
    m.open();
    const smooth = m.dialog.querySelector<HTMLButtonElement>("[aria-label=\"Smooth scrolling\"]")!;
    const before = smooth.getAttribute("aria-checked");
    smooth.click();
    expect(m.set, "the renderer is untouched").not.toHaveBeenCalled();
    expect(smooth.getAttribute("aria-checked")).not.toBe(before);
    smooth.click();               // back as it was, for the next test's storage
    m.dispose();
  });

  it("re-reads the status while open, and stops when it closes", () => {
    vi.useFakeTimers();
    try {
      const m = mount();
      const out = () => m.dialog.querySelector<HTMLOutputElement>(".terminal-renderer")!.value;
      m.open();
      expect(out()).toBe("WebGPU");
      m.set(false);                                   // the drawing changes with no click in the dialog
      vi.advanceTimersByTime(450);
      expect(out(), "picked up by the poll").toBe("DOM");
      m.dialog.close();
      expect(vi.getTimerCount(), "no poll after close").toBe(0);
      m.dispose();
    } finally { vi.useRealTimers(); }
  });
});
