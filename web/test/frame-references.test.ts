import { expect, test } from "vitest";
import { FrameReferenceTracker } from "../src/client/frame-references";

test("a keyframe is always accepted and resets the chain", () => {
  const t = new FrameReferenceTracker();
  expect(t.accept({ type: "key", frameId: 10, dependencies: [] })).toBe(true);
  expect(t.accept({ type: "delta", frameId: 11, dependencies: [10] })).toBe(true);
});

test("a delta whose reference was never decoded is REFUSED", () => {
  // THE WHOLE POINT. Feeding this to the decoder produces `EncodingError: Decoding error`, WebCodecs
  // closes the codec, and the renderer must rebuild it and ask for an IDR. Measured under 10% loss:
  // 83 decoder recreations in 80s, one roughly every second, before the stream stalled for good.
  const t = new FrameReferenceTracker();
  t.accept({ type: "key", frameId: 10, dependencies: [] });
  expect(t.accept({ type: "delta", frameId: 12, dependencies: [11] })).toBe(false);
});

test("once the chain is broken every later delta is refused until a keyframe", () => {
  const t = new FrameReferenceTracker();
  t.accept({ type: "key", frameId: 1, dependencies: [] });
  expect(t.accept({ type: "delta", frameId: 3, dependencies: [2] })).toBe(false);   // 2 was lost
  // 4 depends on 3, which we refused — so it is undecodable too, even though 3 "arrived".
  expect(t.accept({ type: "delta", frameId: 4, dependencies: [3] })).toBe(false);
  expect(t.accept({ type: "key", frameId: 5, dependencies: [] })).toBe(true);       // recovery
  expect(t.accept({ type: "delta", frameId: 6, dependencies: [5] })).toBe(true);
});

test("a delta with MULTIPLE dependencies needs all of them", () => {
  const t = new FrameReferenceTracker();
  t.accept({ type: "key", frameId: 1, dependencies: [] });
  t.accept({ type: "delta", frameId: 2, dependencies: [1] });
  expect(t.accept({ type: "delta", frameId: 4, dependencies: [2, 3] })).toBe(false);
  expect(t.accept({ type: "delta", frameId: 5, dependencies: [1, 2] })).toBe(true);
});

test("NO METADATA MEANS ACCEPT — never refuse a frame on an engine that cannot tell us", () => {
  // `frameId`/`dependencies` are optional in the spec. An engine that omits them must behave exactly
  // as before this tracker existed, not lose its video to a check it cannot answer.
  const t = new FrameReferenceTracker();
  expect(t.accept({ type: "delta" })).toBe(true);
  expect(t.accept({ type: "delta", frameId: 7 })).toBe(true);      // id but no dependency list
  expect(t.accept({ type: "key" })).toBe(true);
});

test("a repeated or out-of-order frameId does not wedge the chain", () => {
  const t = new FrameReferenceTracker();
  t.accept({ type: "key", frameId: 1, dependencies: [] });
  expect(t.accept({ type: "delta", frameId: 2, dependencies: [1] })).toBe(true);
  expect(t.accept({ type: "delta", frameId: 2, dependencies: [1] })).toBe(true);   // duplicate
});

test("memory is bounded — a long session does not grow the decoded set without limit", () => {
  const t = new FrameReferenceTracker();
  t.accept({ type: "key", frameId: 0, dependencies: [] });
  for (let i = 1; i < 5000; i++) t.accept({ type: "delta", frameId: i, dependencies: [i - 1] });
  expect(t.size).toBeLessThanOrEqual(256);
  // and it still works at the head of the chain
  expect(t.accept({ type: "delta", frameId: 5000, dependencies: [4999] })).toBe(true);
});
