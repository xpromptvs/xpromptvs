import { describe, it, expect } from "vitest";
import { DEFAULT_POINTER_MODE } from "../src/client/pointer-mode";
import { loadClientPrefs, type PrefsStore } from "../src/shared/client-prefs";

const memory = (initial: Record<string, string> = {}): PrefsStore => ({
  getItem: (k) => initial[k] ?? null,
  setItem: (k, v) => { initial[k] = v; },
  removeItem: (k) => { delete initial[k]; },
});

// The storage behaviour — saved inside the device set, migrated from the old key, hostile storage —
// is `client-prefs.test.ts`'s: the manager holds the device set now.
describe("pointer mode", () => {
  it("defaults to direct", () => {
    // DIRECT STAYS THE DEFAULT so nothing changes for an existing session, and so the coordinate
    // fix is independently observable before the new mode is in play.
    expect(DEFAULT_POINTER_MODE).toBe("direct");
    expect(loadClientPrefs(memory()).pointerMode ?? DEFAULT_POINTER_MODE).toBe("direct");
  });
});
