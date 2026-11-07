import { afterEach, expect, it, vi } from "vitest";
import type { Terminal } from "@xterm/xterm";
import { mountTerminalScrollbar } from "../src/client/terminal-scrollbar";

afterEach(() => { vi.unstubAllGlobals(); document.body.replaceChildren(); });
it("anchors to the surface through scaled/inset content and scrolls to both ends", () => {
  vi.stubGlobal("ResizeObserver", class { observe() {} disconnect() {} });
  document.body.innerHTML = '<div id="xterm"><div class="xterm-inst"></div></div>';
  const surface = document.querySelector<HTMLElement>("#xterm")!;
  const container = surface.firstElementChild as HTMLElement;
  Object.defineProperties(surface, { offsetHeight: { value: 400 }, clientHeight: { value: 400 } });
  surface.getBoundingClientRect = () => ({ top: 100, right: 600, height: 800 }) as DOMRect;
  container.getBoundingClientRect = () => ({ top: 140, left: 48 }) as DOMRect;
  let update = () => {};
  const buffer = { baseY: 180, viewportY: 180, type: "normal" };
  const scrollToLine = vi.fn((line: number) => { buffer.viewportY = line; update(); });
  const term = { rows: 20, buffer: { active: buffer }, scrollToLine,
    onScroll: (cb: () => void) => { update = cb; return { dispose() {} }; },
    onRender: () => ({ dispose() {} }), onResize: () => ({ dispose() {} }),
  } as unknown as Terminal;
  const dispose = mountTerminalScrollbar(term, container, () => {});
  const rail = container.querySelector<HTMLElement>('[role="scrollbar"]')!;
  expect(rail.style.top).toBe("-14px"); // 20px content inset, but only 6px rail inset.
  expect(rail.style.height).toBe("388px");
  rail.dispatchEvent(new KeyboardEvent("keydown", { key: "Home" }));
  expect(scrollToLine).toHaveBeenLastCalledWith(0);
  rail.dispatchEvent(new KeyboardEvent("keydown", { key: "End" }));
  expect(scrollToLine).toHaveBeenLastCalledWith(180);
  buffer.type = "alternate"; update(); expect(rail.hidden).toBe(true);
  dispose(); expect(container.querySelector('[role="scrollbar"]')).toBeNull();
});

it("moves the thumb between row boundaries and releases its pixel-position subscription", () => {
  vi.stubGlobal("ResizeObserver", class { observe() {} disconnect() {} });
  document.body.innerHTML = '<div id="xterm"><div></div></div>';
  const surface = document.querySelector<HTMLElement>("#xterm")!;
  Object.defineProperties(surface, { offsetHeight: { value: 400 }, clientHeight: { value: 400 } });
  const container = surface.firstElementChild as HTMLElement;
  surface.getBoundingClientRect = () => ({ top: 0, right: 600, height: 400 }) as DOMRect;
  container.getBoundingClientRect = () => ({ top: 0, left: 0 }) as DOMRect;
  const term = { rows: 20, buffer: { active: { baseY: 100, viewportY: 10, type: "normal" } },
    onScroll: () => ({ dispose() {} }), onRender: () => ({ dispose() {} }), onResize: () => ({ dispose() {} }),
  } as unknown as Terminal;
  let top = 200, scrolled = () => {};
  const unsubscribe = vi.fn();
  const dispose = mountTerminalScrollbar(term, container, () => {}, {
    cellHeight: () => 20, scrollTop: () => top,
    onScroll: cb => { scrolled = () => cb(top); return { dispose: unsubscribe }; },
  });
  const thumb = container.querySelector<HTMLElement>(".terminal-scrollbar-thumb")!;
  const before = parseFloat(thumb.style.top);
  top = 205; scrolled();
  expect(parseFloat(thumb.style.top)).toBeGreaterThan(before);
  expect(parseFloat(thumb.style.top) / before).toBeCloseTo(205 / 200);
  expect(term.buffer.active.viewportY).toBe(10);
  top = 4000; scrolled();
  expect(parseFloat(thumb.style.top)).toBeCloseTo(388 - parseFloat(thumb.style.height));
  dispose(); expect(unsubscribe).toHaveBeenCalledOnce();
});
