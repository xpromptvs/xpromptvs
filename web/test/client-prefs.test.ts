import { describe, it, expect } from "vitest";
import {
  CLIENT_PREFS_KEY, LEGACY_POINTER_MODE_KEY, DEFAULT_CLIENT_PREFS,
  loadClientPrefs, saveClientPrefs, parseClientPrefs, clientPrefsWire, type PrefsStore,
} from "../src/shared/client-prefs";

const memory = (initial: Record<string, string> = {}): PrefsStore & { data: Record<string, string> } => ({
  data: initial,
  getItem: (k) => initial[k] ?? null,
  setItem: (k, v) => { initial[k] = v; },
  removeItem: (k) => { delete initial[k]; },
});

describe("client preferences", () => {
  it("default to Auto resolution and Auto codec, with the host's fps and bitrate", () => {
    // ABSENT fps/bitrate is the HOST's default, never a number invented here: a device that never
    // picked one must stream at whatever the host is configured for.
    expect(loadClientPrefs(memory())).toEqual({ scale: "auto", codec: "auto" });
    expect(DEFAULT_CLIENT_PREFS).toEqual({ scale: "auto", codec: "auto" });
  });

  it("round-trip through storage", () => {
    const store = memory();
    saveClientPrefs({ fps: 30, scale: 0.5, bitrateBps: 8_000_000, codec: "h265", pointerMode: "trackpad" }, store);
    expect(loadClientPrefs(store)).toEqual({ fps: 30, scale: 0.5, bitrateBps: 8_000_000, codec: "h265", pointerMode: "trackpad" });
  });

  it("parse LENIENTLY, field by field — one bad field costs that field, never the rest", () => {
    expect(parseClientPrefs({ fps: "60", scale: 2, bitrateBps: -1, codec: "vp9", pointerMode: "mouse" }))
      .toEqual({ scale: "auto", codec: "auto" });
    expect(parseClientPrefs({ fps: 24, scale: "auto", codec: "av1" })).toEqual({ fps: 24, scale: "auto", codec: "av1" });
    expect(parseClientPrefs(null)).toEqual({ scale: "auto", codec: "auto" });
  });

  it("MIGRATE the touch mode once from its old key, and forget the old key", () => {
    const store = memory({ [LEGACY_POINTER_MODE_KEY]: "trackpad" });
    expect(loadClientPrefs(store).pointerMode).toBe("trackpad");
    expect(store.data[LEGACY_POINTER_MODE_KEY]).toBeUndefined();
    expect(JSON.parse(store.data[CLIENT_PREFS_KEY]!).pointerMode).toBe("trackpad");
  });

  it("never let the old key override a preference set that already exists", () => {
    const store = memory({ [CLIENT_PREFS_KEY]: JSON.stringify({ scale: "auto", codec: "auto", pointerMode: "direct" }),
                           [LEGACY_POINTER_MODE_KEY]: "trackpad" });
    expect(loadClientPrefs(store).pointerMode).toBe("direct");
  });

  it("read garbage as the defaults", () => {
    expect(loadClientPrefs(memory({ [CLIENT_PREFS_KEY]: "{not json" }))).toEqual({ scale: "auto", codec: "auto" });
  });

  it("survive storage that throws — a browser blocking site data does not merely return null", () => {
    const hostile: PrefsStore = { getItem: () => { throw new Error("denied"); }, setItem: () => { throw new Error("denied"); } };
    expect(loadClientPrefs(hostile)).toEqual({ scale: "auto", codec: "auto" });
    expect(() => saveClientPrefs({ scale: 0.5, codec: "auto" }, hostile)).not.toThrow();
    expect(loadClientPrefs(null)).toEqual({ scale: "auto", codec: "auto" });
  });

  it("put only what the device chose on the wire — absent means the host's default", () => {
    expect(clientPrefsWire({ scale: "auto", codec: "auto" })).toEqual({ scale: "auto", codec: "auto" });
    expect(clientPrefsWire({ fps: 30, scale: 0.5, bitrateBps: 4_000_000, codec: "av1", pointerMode: "direct" }))
      .toEqual({ fps: 30, scale: 0.5, bitrateBps: 4_000_000, codec: "av1", pointerMode: "direct" });
  });
});

describe("optional AV1 reference recovery", () => {
  it("preserves an explicit on or off choice through storage and the wire", () => {
    for (const enabled of [true, false]) {
      const store = memory({ [CLIENT_PREFS_KEY]: JSON.stringify({ av1ReferenceRecovery: enabled }) });
      const loaded = loadClientPrefs(store);
      expect(clientPrefsWire(loaded).av1ReferenceRecovery).toBe(enabled);
      saveClientPrefs(loaded, store);
      expect(JSON.parse(store.data[CLIENT_PREFS_KEY]!).av1ReferenceRecovery).toBe(enabled);
    }
  });
  it("never opts in from missing or malformed values", () => {
    for (const value of [undefined, null, 1, "true", {}]) {
      expect(clientPrefsWire(parseClientPrefs({ av1ReferenceRecovery: value })).av1ReferenceRecovery).toBeUndefined();
    }
  });
});
