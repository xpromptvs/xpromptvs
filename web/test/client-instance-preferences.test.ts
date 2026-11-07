import { expect, it } from "vitest";
import { createMemoryPreferences, createSmoothPreference, reservePreferences } from "../src/client/instance/preferences";

it("memory preferences are independent", () => {
  const a = createMemoryPreferences(), b = createMemoryPreferences();
  a.set("font", "18"); b.set("font", "12"); a.remove("font");
  expect(a.get("font")).toBeNull(); expect(b.get("font")).toBe("12");
});
it("persistent namespaces are exclusive while live and survive release", () => {
  // Node 25's experimental global localStorage shadows jsdom's Storage; inject the same
  // synchronous Storage boundary as resume-id.test, leaving persistence logic real.
  const data = new Map<string, string>();
  const storage: Storage = {
    getItem: key => data.get(key) ?? null,
    setItem: (key, value) => { data.set(key, value); },
    removeItem: key => { data.delete(key); }, clear: () => data.clear(),
    key: index => [...data.keys()][index] ?? null, get length() { return data.size; },
  };
  const a = reservePreferences({ namespace: "left", storage });
  const b = reservePreferences({ namespace: "right", storage });
  try {
    expect(() => reservePreferences({ namespace: "left", storage })).toThrow(/namespace/);
    a.store.set("font", "18"); b.store.set("font", "12");
    expect(a.store.get("font")).toBe("18"); expect(b.store.get("font")).toBe("12");
    a.release();
    const again = reservePreferences({namespace: "left", storage});
    try { expect(again.store.get("font")).toBe("18"); } finally { again.release(); }
  } finally { a.release(); b.release(); }
});
it("storage failure stays local and retains in-memory writes", () => {
  const denied = { getItem() { throw Error("denied"); }, setItem() { throw Error("denied"); }, removeItem() { throw Error("denied"); } } as unknown as Storage;
  const a = reservePreferences({ namespace: "denied", storage: denied });
  try { a.store.set("size", "16"); expect(a.store.get("size")).toBe("16"); a.store.remove("size"); expect(a.store.get("size")).toBeNull(); }
  finally { a.release(); }
});
it("smooth scrolling keeps the product default and notifies only its own client", () => {
  const a = createSmoothPreference(createMemoryPreferences()), b = createSmoothPreference(createMemoryPreferences());
  const changes: boolean[] = []; b.subscribe(value => changes.push(value));
  expect(a.enabled()).toBe(true); expect(b.enabled()).toBe(true);
  a.set(false); expect(a.enabled()).toBe(false); expect(b.enabled()).toBe(true);
  expect(changes).toEqual([]);
});
