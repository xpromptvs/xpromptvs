import { expect, test } from "vitest";
import { windowAspectRatio } from "../src/client/window-aspect";

test("prefers the SOURCE's point size over the decoded frame size", () => {
  // The decoded size moves whenever auto-resolution picks a new scale; the host window's point size
  // does not. Deriving the window's aspect from the decoded size closes a feedback loop:
  //   scale -> encode WxH -> video 'resize' -> setRatio -> window height -> .win-body box ->
  //   ResizeObserver -> autoScale -> a different scale -> ...
  // Each lap recreates the libaom encoder and emits an IDR. Measured on a clean host with ONE client:
  //   [encode] 1044x1472 -> 998x1408 -> 1044x1472
  expect(windowAspectRatio({ w: 522, h: 736 }, { w: 1044, h: 1472 })).toBeCloseTo(522 / 736, 10);
  expect(windowAspectRatio({ w: 522, h: 736 }, { w: 998, h: 1408 })).toBeCloseTo(522 / 736, 10);
});

test("THE RATIO IS STABLE ACROSS AN AUTO-RESOLUTION CHANGE — the whole point", () => {
  const pt = { w: 522, h: 736 };
  const a = windowAspectRatio(pt, { w: 1044, h: 1472 });
  const b = windowAspectRatio(pt, { w: 998, h: 1408 });
  const c = windowAspectRatio(pt, { w: 416, h: 958 });   // a wildly different decode, same window
  expect(a).toBe(b);
  expect(b).toBe(c);
});

test("falls back to the decoded size when the point size is unknown", () => {
  // A source that has not reported its size yet still needs an aspect, and the decoded frame is the
  // only thing available. The loop is acceptable there because it resolves as soon as source-status
  // arrives.
  expect(windowAspectRatio(undefined, { w: 1044, h: 1472 })).toBeCloseTo(1044 / 1472, 10);
});

test("returns null when neither size is known, rather than a bogus ratio", () => {
  // The caller keeps whatever ratio it already had. Returning 0 or 1 would resize the window to
  // something arbitrary on the first frame.
  expect(windowAspectRatio(undefined, undefined)).toBeNull();
  expect(windowAspectRatio({ w: 0, h: 0 }, { w: 0, h: 0 })).toBeNull();
  expect(windowAspectRatio({ w: 522, h: 0 }, undefined)).toBeNull();
});
