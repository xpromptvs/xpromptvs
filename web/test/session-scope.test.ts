import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionScope } from "../src/client/session-scope";

const FAKE = ["setTimeout", "clearTimeout", "setInterval", "clearInterval",
              "requestAnimationFrame", "cancelAnimationFrame"] as const;

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  delete (globalThis as { __rdevSkipDisposer?: string }).__rdevSkipDisposer;
});

describe("SessionScope", () => {
  it("dispose is idempotent — nothing runs twice", () => {
    const scope = new SessionScope();
    const fn = vi.fn();
    scope.defer(fn);
    scope.dispose();
    scope.dispose();
    expect(fn).toHaveBeenCalledTimes(1);
    expect(scope.disposed).toBe(true);
    expect(scope.signal.aborted).toBe(true);
  });

  it("a listener added through the scope hears nothing after dispose", () => {
    const scope = new SessionScope();
    const heard = vi.fn();
    scope.listen(window, "resize", heard);
    window.dispatchEvent(new Event("resize"));
    scope.dispose();
    window.dispatchEvent(new Event("resize"));
    expect(heard).toHaveBeenCalledTimes(1);
  });

  it("a CAPTURE listener is released too — the signal travels with the options", () => {
    const scope = new SessionScope();
    const heard = vi.fn();
    scope.listen(document, "keydown", heard, true);
    scope.listen(document, "pointerdown", heard, { capture: true, passive: true });
    scope.dispose();
    document.dispatchEvent(new KeyboardEvent("keydown"));
    document.dispatchEvent(new Event("pointerdown"));
    expect(heard).not.toHaveBeenCalled();
  });

  it("listen after dispose adds nothing", () => {
    const scope = new SessionScope();
    scope.dispose();
    const heard = vi.fn();
    scope.listen(window, "resize", heard);
    window.dispatchEvent(new Event("resize"));
    expect(heard).not.toHaveBeenCalled();
  });

  it("intervals, timeouts and animation frames stop at dispose, and none is left behind", () => {
    vi.useFakeTimers({ toFake: [...FAKE] });
    const scope = new SessionScope();
    const tick = vi.fn(), once = vi.fn(), frame = vi.fn();
    scope.interval(tick, 100);
    scope.timeout(once, 1000);
    scope.raf(frame);
    vi.advanceTimersByTime(250);
    expect(tick).toHaveBeenCalledTimes(2);
    expect(frame).toHaveBeenCalledTimes(1);
    scope.raf(frame);
    scope.dispose();
    vi.advanceTimersByTime(5000);
    expect(tick).toHaveBeenCalledTimes(2);
    expect(once).not.toHaveBeenCalled();
    expect(frame).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("clearTimeout / clearInterval through the scope cancel and forget the id", () => {
    vi.useFakeTimers({ toFake: [...FAKE] });
    const scope = new SessionScope();
    const fn = vi.fn();
    scope.clearTimeout(scope.timeout(fn, 1000));
    scope.clearInterval(scope.interval(fn, 10));
    scope.clearTimeout(undefined);
    vi.advanceTimersByTime(2000);
    expect(fn).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("timers asked for after dispose are never started", () => {
    vi.useFakeTimers({ toFake: [...FAKE] });
    const scope = new SessionScope();
    scope.dispose();
    expect(scope.timeout(() => {}, 10)).toBeUndefined();
    expect(scope.interval(() => {}, 10)).toBeUndefined();
    expect(scope.raf(() => {})).toBeUndefined();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("observe hands the observer back and disconnects it at dispose", () => {
    const scope = new SessionScope();
    const observer = { disconnect: vi.fn() };
    expect(scope.observe(observer)).toBe(observer);
    scope.dispose();
    expect(observer.disconnect).toHaveBeenCalledTimes(1);
  });

  it("guard turns a late callback into a no-op", () => {
    const scope = new SessionScope();
    const fn = vi.fn();
    const guarded = scope.guard(fn);
    guarded(1);
    scope.dispose();
    guarded(2);
    expect(fn.mock.calls).toEqual([[1]]);
  });

  it("disposers run LIFO", () => {
    const scope = new SessionScope();
    const order: string[] = [];
    scope.defer(() => order.push("first"));
    scope.defer(() => order.push("second"));
    scope.defer(() => order.push("third"));
    scope.dispose();
    expect(order).toEqual(["third", "second", "first"]);
  });

  it("a throwing disposer does not stop the rest", () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const scope = new SessionScope();
    const after = vi.fn();
    scope.defer(after);
    scope.defer(() => { throw new Error("boom"); }, "broken");
    scope.dispose();
    expect(after).toHaveBeenCalledTimes(1);
    expect(console.error).toHaveBeenCalled();
  });

  it("defer after dispose runs at once — a teardown registered late is never lost", () => {
    const scope = new SessionScope();
    scope.dispose();
    const fn = vi.fn();
    scope.defer(fn);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("TEST-ONLY __rdevSkipDisposer skips exactly the named disposer", () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    (globalThis as { __rdevSkipDisposer?: string }).__rdevSkipDisposer = "viewport-fit";
    const scope = new SessionScope();
    const skipped = vi.fn(), kept = vi.fn(), unnamed = vi.fn();
    scope.defer(skipped, "viewport-fit");
    scope.defer(kept, "term-strip");
    scope.defer(unnamed);
    scope.dispose();
    expect(skipped).not.toHaveBeenCalled();
    expect(kept).toHaveBeenCalledTimes(1);
    expect(unnamed).toHaveBeenCalledTimes(1);
  });
});
