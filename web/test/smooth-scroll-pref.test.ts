import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  followNativeSmoothScroll, onSmoothScrollChange, setSmoothScroll, SMOOTH_SCROLL_KEY, smoothScrollEnabled,
} from "../src/shared/smooth-scroll-pref";

/// A Storage the test owns (Node's own `localStorage` global shadows jsdom's here, and is not usable).
function memStore(o: { failWrite?: boolean; failRead?: boolean } = {}): Storage {
  const m = new Map<string, string>();
  return {
    getItem: (k) => { if (o.failRead) throw new Error("SecurityError"); return m.get(k) ?? null; },
    setItem: (k, v) => { if (o.failWrite) throw new Error("QuotaExceededError"); m.set(k, v); },
    removeItem: (k) => void m.delete(k),
    clear: () => m.clear(),
    key: () => null,
    get length() { return m.size; },
  } as Storage;
}

beforeEach(() => { vi.stubGlobal("localStorage", memStore()); setSmoothScroll(false); });
afterEach(() => { vi.unstubAllGlobals(); });

describe("the smooth-scrolling preference", () => {
  it("is ON by default and respects a saved off preference", () => {
    expect(smoothScrollEnabled()).toBe(false);
    localStorage.setItem(SMOOTH_SCROLL_KEY, "true");
    expect(smoothScrollEnabled()).toBe(true);
    localStorage.removeItem(SMOOTH_SCROLL_KEY);
    expect(smoothScrollEnabled()).toBe(true);
  });

  it("saves a change and tells every listener, until it unsubscribes", () => {
    const seen: boolean[] = [];
    const off = onSmoothScrollChange((on) => seen.push(on));
    setSmoothScroll(true);
    expect(localStorage.getItem(SMOOTH_SCROLL_KEY)).toBe("true");
    setSmoothScroll(false);
    off();
    setSmoothScroll(true);
    expect(seen).toEqual([true, false]);
  });

  it("follows a change saved by another page of this origin (a storage event)", () => {
    const seen: boolean[] = [];
    const off = onSmoothScrollChange((on) => seen.push(on));
    localStorage.setItem(SMOOTH_SCROLL_KEY, "true");
    window.dispatchEvent(new StorageEvent("storage", { key: SMOOTH_SCROLL_KEY, newValue: "true" }));
    window.dispatchEvent(new StorageEvent("storage", { key: "rdev.theme", newValue: "light" }));
    off();
    window.dispatchEvent(new StorageEvent("storage", { key: SMOOTH_SCROLL_KEY, newValue: null }));
    expect(seen).toEqual([true]);
  });

  it("still APPLIES a change storage refuses to save (Safari private mode throws)", () => {
    vi.stubGlobal("localStorage", memStore({ failWrite: true }));
    const seen: boolean[] = [];
    const off = onSmoothScrollChange((on) => seen.push(on));
    setSmoothScroll(true);
    off();
    expect(seen).toEqual([true]);
  });

  it("keeps a change storage refused, so the palette can turn it off again", () => {
    // The palette reads the value to label its row and to pick what its row does (review M3).
    vi.stubGlobal("localStorage", memStore({ failWrite: true }));
    setSmoothScroll(true);
    expect(smoothScrollEnabled()).toBe(true);
    setSmoothScroll(false);
    expect(smoothScrollEnabled()).toBe(false);
  });

  it("defaults ON when storage cannot be read at all", () => {
    vi.stubGlobal("localStorage", memStore({ failRead: true }));
    expect(smoothScrollEnabled()).toBe(true);
  });

});

/// The native app's bridge as a page sees it — the dashboard's `rdevApp` or a session window's
/// `__rdevShell` (`app/Sources/BridgeScripts.swift`): the app's ONE value, and its pushes.
function nativeApp(initial: boolean) {
  let value = initial;
  let answer: (v: boolean) => void = () => {};
  const pushes = new Set<(on: boolean) => void>();
  const sets: boolean[] = [];
  const api = {
    /// Held until `answer()` when `deferred`, so a test can make the page's first question slow.
    deferred: false,
    smoothScroll: () => api.deferred
      ? new Promise<boolean>((r) => { answer = r; })
      : Promise.resolve(value),
    setSmoothScroll: (on: boolean) => { sets.push(on); value = on; return Promise.resolve(on); },
    onSmoothScroll: (cb: (on: boolean) => void) => { pushes.add(cb); return () => { pushes.delete(cb); }; },
  };
  /// What `SmoothScrollSetting.write` does: evaluate `__rdevSmoothScroll(on)` in every window.
  const push = (on: boolean) => { value = on; for (const cb of [...pushes]) cb(on); };
  return { api, sets, push, answer: (v: boolean) => answer(v), get listening() { return pushes.size; } };
}
const settle = () => new Promise((r) => setTimeout(r, 0));

describe("the smooth-scrolling preference inside the native app", () => {
  for (const global of ["rdevApp", "__rdevShell"] as const) {
    describe(`through ${global}`, () => {
      it("saves a change in the APP, the one value every window shares", () => {
        const app = nativeApp(false);
        vi.stubGlobal(global, app.api);
        setSmoothScroll(true);
        expect(app.sets).toEqual([true]);
        expect(smoothScrollEnabled()).toBe(true);
      });

      it("adopts the app's value at boot, and every value the app pushes after, without saving it back", async () => {
        const app = nativeApp(true);
        vi.stubGlobal(global, app.api);
        const seen: boolean[] = [];
        const off = onSmoothScrollChange((on) => seen.push(on));
        const stop = followNativeSmoothScroll();
        await settle();
        expect(smoothScrollEnabled()).toBe(true);
        app.push(false);                          // another window turned it off
        expect(smoothScrollEnabled()).toBe(false);
        app.push(false);                          // the same value again changes nothing
        expect(seen).toEqual([true, false]);
        expect(app.sets).toEqual([]);             // nothing was echoed back
        stop();
        expect(app.listening).toBe(0);
        off();
      });

      it("a change made before the app's first answer is not undone by it", async () => {
        const app = nativeApp(false);
        app.api.deferred = true;
        vi.stubGlobal(global, app.api);
        const stop = followNativeSmoothScroll();
        setSmoothScroll(true);                    // the person, faster than the bridge
        app.answer(false);
        await settle();
        expect(smoothScrollEnabled()).toBe(true);
        stop();
      });
    });
  }

  it("a change the app refused to save is taken back to the app's value, never left diverged", async () => {
    const app = nativeApp(false);
    app.api.setSmoothScroll = () => Promise.reject(new Error("refused"));
    vi.stubGlobal("__rdevShell", app.api);
    setSmoothScroll(true);
    expect(smoothScrollEnabled()).toBe(true);    // applied at once, as ever
    await settle(); await settle();
    expect(smoothScrollEnabled()).toBe(false);   // the app kept false, and so does this window
  });

  it("asks the app again, once, when its first answer is refused", async () => {
    vi.useFakeTimers();
    try {
      const app = nativeApp(true);
      let asked = 0;
      const answer = app.api.smoothScroll;
      app.api.smoothScroll = () => (++asked === 1 ? Promise.reject(new Error("refused")) : answer());
      vi.stubGlobal("rdevApp", app.api);
      const stop = followNativeSmoothScroll();
      await vi.advanceTimersByTimeAsync(1000);
      expect(asked).toBe(2);
      expect(smoothScrollEnabled()).toBe(true);
      stop();
    } finally { vi.useRealTimers(); }
  });

  it("in a browser there is no app: following it does nothing, and a change stays this page's", () => {
    const stop = followNativeSmoothScroll();
    setSmoothScroll(true);
    expect(smoothScrollEnabled()).toBe(true);
    stop();
  });

  it("a bridge without the smooth-scrolling calls is no app to follow", () => {
    vi.stubGlobal("__rdevShell", { signalingBase: "x", request: () => Promise.resolve() });
    const stop = followNativeSmoothScroll();
    setSmoothScroll(true);
    expect(smoothScrollEnabled()).toBe(true);
    stop();
  });
});
