import type { ClientOptions, PreferenceStore } from "./types";

export function createMemoryPreferences(): PreferenceStore {
  const values = new Map<string, string>();
  return { get: key => values.get(key) ?? null, set: (key, value) => { values.set(key, value); }, remove: key => { values.delete(key); } };
}

export function preferenceStorage(store: PreferenceStore): Pick<Storage, "getItem" | "setItem" | "removeItem"> {
  return {getItem: key => store.get(key), setItem: (key,value) => store.set(key,value), removeItem: key => store.remove(key)};
}
export function createSmoothPreference(store: PreferenceStore) {
  const listeners = new Set<(enabled: boolean) => void>();
  return {
    enabled: () => store.get("rdev.smoothScroll") !== "false",
    set(enabled: boolean) { store.set("rdev.smoothScroll", String(enabled)); for (const fn of [...listeners]) fn(enabled); },
    subscribe(fn: (enabled: boolean) => void) { listeners.add(fn); return () => { listeners.delete(fn); }; },
    dispose() { listeners.clear(); },
  };
}

// Ownership only: preferences themselves belong to the mount. A repeated release must never free
// the reservation of a replacement mount, hence the token comparison.
const reservations = new Map<string, object>();
export function reservePreferences(persistence?: ClientOptions["persistence"]): { store: PreferenceStore; release(): void } {
  if (!persistence) return { store: createMemoryPreferences(), release() {} };
  const { namespace, storage } = persistence;
  if (!namespace.trim()) throw Error("A persistent preference namespace is required");
  if (reservations.has(namespace)) throw Error("Preference namespace is already mounted");
  const token = {};
  reservations.set(namespace, token);
  const cache = new Map<string, string | null>();
  const keyFor = (key: string) => `rdev.client.${JSON.stringify([namespace, key])}`;
  return {
    store: {
      get(key) {
        if (cache.has(key)) return cache.get(key)!;
        try { const value = storage.getItem(keyFor(key)); cache.set(key, value); return value; }
        catch { return null; }
      },
      set(key, value) { cache.set(key, value); try { storage.setItem(keyFor(key), value); } catch { /* memory remains usable */ } },
      remove(key) { cache.set(key, null); try { storage.removeItem(keyFor(key)); } catch { /* memory remains usable */ } },
    },
    release() { if (reservations.get(namespace) === token) reservations.delete(namespace); },
  };
}
