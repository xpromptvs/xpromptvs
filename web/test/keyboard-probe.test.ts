import { afterEach, expect, it } from "vitest";
import { installKeyboardProbe } from "../src/client/keyboard-probe";

let stop: (() => void) | null = null;
afterEach(() => { stop?.(); stop = null; });

// The instrument's log is the measurement (a screenshot off a real phone): every focus change, and every
// visualViewport resize with its height and offset, timed from that focus change.
it("logs a focus change and the visual viewport's resize after it, with the viewport's height", () => {
  const vv = Object.assign(new EventTarget(), { width: 390, height: 844, offsetTop: 0 });
  Object.defineProperty(window, "visualViewport", { configurable: true, get: () => vv });
  stop = installKeyboardProbe(window);
  const input = document.createElement("input");
  document.body.append(input);
  input.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
  vv.height = 508;
  vv.dispatchEvent(new Event("resize"));
  const text = document.getElementById("kbprobe")!.textContent!;
  expect(text).toMatch(/focusin input/);
  expect(text).toMatch(/vv\.resize\s+vv 390×508 top 0/);
});
