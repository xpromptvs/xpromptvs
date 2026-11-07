const KEY = "rdev.resumeId";

/// A v4-UUID that also works in a NON-SECURE context. `crypto.randomUUID` (and `crypto.subtle`) exist
/// only in a secure context (HTTPS or localhost) — over plain http on a LAN IP (device testing) Safari
/// leaves `randomUUID` undefined, which used to crash the client at module load and hang it at
/// "connecting". `crypto.getRandomValues` is NOT secure-context-gated, so derive the UUID from it; fall
/// back to Math.random only if there's no crypto at all (fine for a per-tab resume id).
export function randomUUID(): string {
  const c = (globalThis as { crypto?: Crypto }).crypto;
  if (c && typeof c.randomUUID === "function") return c.randomUUID();
  if (c && typeof c.getRandomValues === "function") {
    const b = c.getRandomValues(new Uint8Array(16));
    b[6] = (b[6]! & 0x0f) | 0x40;   // version 4
    b[8] = (b[8]! & 0x3f) | 0x80;   // variant 10xx
    const h = Array.from(b, (x) => x.toString(16).padStart(2, "0"));
    return `${h[0]}${h[1]}${h[2]}${h[3]}-${h[4]}${h[5]}-${h[6]}${h[7]}-${h[8]}${h[9]}-${h[10]}${h[11]}${h[12]}${h[13]}${h[14]}${h[15]}`;
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (ch) => {
    const r = (Math.random() * 16) | 0;
    return (ch === "x" ? r : (r & 0x3) | 0x8).toString(16);
  });
}

/// Stable per-browser-session client id. Persisted in sessionStorage so it survives a WS/PC drop AND a
/// page reload within the same tab, but is per-tab (a new tab = a new logical client, by design). The
/// host maps a reconnecting socket back to the same peer via this id (see connection-resilience spec).
export function resumeId(store: Storage = sessionStorage, gen: () => string = randomUUID): string {
  const existing = store.getItem(KEY);
  if (existing) return existing;
  const id = gen();
  store.setItem(KEY, id);
  return id;
}
