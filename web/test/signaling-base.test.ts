import { describe, it, expect, afterEach } from "vitest";
import { signalingBase } from "../src/lib/signaling-base";

const g = globalThis as unknown as { __rdevShell?: { signalingBase?: string } };
afterEach(() => { delete g.__rdevShell; });

describe("signalingBase", () => {
  it("falls back to the page origin in a browser — byte-identical to the old expression", () => {
    // Don't hardcode jsdom's origin; assert both that the rule is the old one AND that the result
    // is really a ws URL, so this cannot pass by both sides being equally wrong.
    expect(signalingBase()).toBe(location.origin.replace(/^http/, "ws"));
    expect(signalingBase()).toMatch(/^wss?:\/\//);
  });

  it("prefers an injected https origin and converts it to wss", () => {
    g.__rdevShell = { signalingBase: "https://rdev-control-plane.example.workers.dev" };
    expect(signalingBase()).toBe("wss://rdev-control-plane.example.workers.dev");
  });

  it("converts an injected http origin to ws", () => {
    g.__rdevShell = { signalingBase: "http://127.0.0.1:8787" };
    expect(signalingBase()).toBe("ws://127.0.0.1:8787");
  });

  it("accepts an injected ws base unchanged", () => {
    g.__rdevShell = { signalingBase: "wss://already.example" };
    expect(signalingBase()).toBe("wss://already.example");
  });

  it("strips a trailing slash — the caller appends /session/<code>", () => {
    g.__rdevShell = { signalingBase: "https://example.test/" };
    expect(signalingBase()).toBe("wss://example.test");
  });

  it("ignores an empty injected value rather than producing 'ws'", () => {
    g.__rdevShell = { signalingBase: "" };
    expect(signalingBase()).toBe(location.origin.replace(/^http/, "ws"));
  });
});
