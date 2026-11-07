import { it, expect, vi } from "vitest";
import { installMobileWindowControls } from "../src/client/mobile-window-controls";

it("follows the focused window, mirrors state, and removes controls on teardown", async () => {
  document.body.innerHTML = `<div id="windows"><div class="source-window focused"><button class="win-zoom" aria-pressed="false"></button><button class="win-gear" aria-expanded="false"></button><button class="win-fullscreen" aria-pressed="false"></button></div><div class="source-window"><button class="win-zoom" aria-pressed="true"></button><button class="win-gear" aria-expanded="true"></button><button class="win-fullscreen" aria-pressed="true"></button></div></div><footer><button id="keyboard-open">Keyboard</button></footer>`;
  const windows = document.querySelector<HTMLElement>("#windows")!;
  const footer = document.querySelector("footer")!;
  const toggle = vi.fn();
  const dispose = installMobileWindowControls(windows, footer, toggle);
  const [first, second] = [...windows.children];
  const a = vi.fn(), b = vi.fn();
  first!.querySelector(".win-zoom")!.addEventListener("click", a);
  second!.querySelector(".win-zoom")!.addEventListener("click", b);
  const [touch, zoom, settings, full] = ["Trackpad mode", "Zoom", "Settings", "Full screen"].map(label =>
    footer.querySelector<HTMLButtonElement>(`.mobile-window-controls [aria-label="${label}"]`));
  touch!.click(); expect(toggle).toHaveBeenCalledOnce();
  (first as HTMLElement).dataset.pointerMode = "trackpad"; await Promise.resolve();
  expect(touch!.getAttribute("aria-pressed")).toBe("true");
  zoom!.click(); expect(a).toHaveBeenCalledOnce(); expect(b).not.toHaveBeenCalled();
  first!.classList.remove("focused"); second!.classList.add("focused");
  await Promise.resolve();
  zoom!.click(); expect(b).toHaveBeenCalledOnce();
  expect(zoom!.getAttribute("aria-pressed")).toBe("true");
  expect(settings!.getAttribute("aria-expanded")).toBe("true");
  expect(full!.getAttribute("aria-label")).toBe("Exit full screen");
  windows.replaceChildren(); await Promise.resolve();
  expect(footer.querySelector<HTMLElement>(".mobile-window-controls")!.hidden).toBe(true);
  dispose(); expect(footer.querySelector(".mobile-window-controls")).toBeNull();
});

it("hides and disables trackpad switching for simulators, restoring it for Mac windows", async () => {
  document.body.innerHTML = '<div id="windows"><div class="source-window focused" data-source="sim:a" data-pointer-mode="trackpad"></div></div><footer></footer>';
  const windows = document.querySelector<HTMLElement>("#windows")!;
  const footer = document.querySelector("footer")!;
  const toggle = vi.fn();
  const dispose = installMobileWindowControls(windows, footer, toggle);
  const button = footer.querySelector<HTMLButtonElement>(".mobile-pointer-toggle")!;
  expect(button.hidden).toBe(true);
  expect(button.disabled).toBe(true);
  expect(button.getAttribute("aria-pressed")).toBe("false");
  button.click(); expect(toggle).not.toHaveBeenCalled();
  (windows.firstElementChild as HTMLElement).dataset.source = "win:1";
  await Promise.resolve();
  expect(button.hidden).toBe(false);
  expect(button.disabled).toBe(false);
  button.click(); expect(toggle).toHaveBeenCalledOnce();
  dispose();
});

it("offers Home only for a simulator and forwards it to that window", async () => {
  document.body.innerHTML = '<div id="windows"><div class="source-window focused" data-source="sim:a"><button class="win-sim-home"></button><button class="win-sim-keyboard"></button></div></div><footer></footer>';
  const windows = document.querySelector<HTMLElement>("#windows")!;
  const footer = document.querySelector("footer")!;
  const home = vi.fn(); windows.querySelector(".win-sim-home")!.addEventListener("click", home);
  const keyboard = vi.fn(); windows.querySelector(".win-sim-keyboard")!.addEventListener("click", keyboard);
  const dispose = installMobileWindowControls(windows, footer);
  const button = footer.querySelector<HTMLButtonElement>('[aria-label="Home"]');
  expect(button).not.toBeNull();
  expect(button!.hidden).toBe(false);
  button!.click(); expect(home).toHaveBeenCalledOnce();
  footer.querySelector<HTMLButtonElement>('[aria-label="Keyboard"]')!.click();
  expect(keyboard).toHaveBeenCalledOnce();
  expect(footer.dataset.simulatorControls).toBe("true");
  (windows.firstElementChild as HTMLElement).dataset.source = "win:1";
  await Promise.resolve();
  expect(button!.hidden).toBe(true);
  dispose();
});
