import { expect, test } from "vitest";
import { KeyframeGate, makeKeyframeRequester } from "../src/client/keyframe-gate";

test("gate drops deltas until the first key, then admits everything", () => {
  const g = new KeyframeGate();
  expect(g.accept("delta")).toBe(false);
  expect(g.armed).toBe(false);
  expect(g.accept("key")).toBe(true);
  expect(g.armed).toBe(true);
  expect(g.accept("delta")).toBe(true);
});

test("gate re-gates after reset — a decoder reset must start on a key again", () => {
  const g = new KeyframeGate();
  g.accept("key"); g.accept("delta");
  g.reset();
  expect(g.armed).toBe(false);
  expect(g.accept("delta")).toBe(false);
  expect(g.accept("key")).toBe(true);
});

test("requester forwards at most once per interval", () => {
  let now = 1000, sent = 0;
  const req = makeKeyframeRequester(() => { sent++; }, () => now, 250);
  req(); req();
  now = 1100; req();
  now = 1300; req();
  expect(sent).toBe(2);
});
