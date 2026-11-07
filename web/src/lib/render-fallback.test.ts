import { describe, it, expect } from "vitest";
import { RenderFallback } from "./render-fallback";

describe("RenderFallback", () => {
  // THE DEFAULT IS THE FAST PATH. A source nothing has gone wrong with must never be diverted —
  // this class only ever answers a question about failure.
  it("leaves an untouched source on WebCodecs", () => {
    const fallback = new RenderFallback();
    expect(fallback.pathFor("win:1")).toBe("webcodecs");
    expect(fallback.has("win:1")).toBe(false);
  });

  it("puts a failed source on the video element", () => {
    const fallback = new RenderFallback();
    fallback.fallBack("win:1", "decoder cannot decode av01.0.04M.08");
    expect(fallback.pathFor("win:1")).toBe("video");
  });

  // PER SOURCE. One window failing says nothing about another — they can be different codecs, and a
  // 3.6 MP window can saturate a decoder that a small one does not.
  it("does not divert a different source", () => {
    const fallback = new RenderFallback();
    fallback.fallBack("win:1", "stalled");
    expect(fallback.pathFor("win:2")).toBe("webcodecs");
  });

  // ANNOUNCED ONCE. The give-up path is reachable repeatedly — a resubscribe brings a fresh track,
  // which can stall in its turn — and re-announcing would bury the first report, which is the one
  // that names the original cause.
  it("reports a fallback once and only once", () => {
    const fallback = new RenderFallback();
    expect(fallback.fallBack("win:1", "no frame in 10s")).toBe(true);
    expect(fallback.fallBack("win:1", "no frame in 10s")).toBe(false);
    expect(fallback.fallBack("win:1", "some later, less useful reason")).toBe(false);
  });

  // THE FIRST REASON SURVIVES, for the same reason: the first failure is the diagnostic one and a
  // later stall is usually its consequence.
  it("keeps the reason it first fell back for", () => {
    const fallback = new RenderFallback();
    fallback.fallBack("win:1", "the codec was never resolved");
    fallback.fallBack("win:1", "stalled");
    expect(fallback.reasonFor("win:1")).toBe("the codec was never resolved");
  });

  // THE REASON MUST BE READABLE, not merely recorded. A fallback nobody can see is the silent one
  // the pacer's own comment refuses, and the whole point here is that this one is not silent.
  it("lists what fell back and why", () => {
    const fallback = new RenderFallback();
    fallback.fallBack("win:1", "unsupported codec");
    fallback.fallBack("win:9", "stalled three times");
    expect(fallback.entries()).toEqual([
      { source: "win:1", reason: "unsupported codec" },
      { source: "win:9", reason: "stalled three times" },
    ]);
  });

  it("reports no reason for a source that never failed", () => {
    expect(new RenderFallback().reasonFor("win:1")).toBeUndefined();
  });
});
