/// **This DEVICE's streaming preferences** — frame rate, resolution, bitrate, codec and the touch mode
/// (asked for 2026-09-29: "fps, scale, bitrate, codec, should be client-specific, client-wide (not
/// window-specific) preferences … Pointer interaction (direct/pointer) too").
///
/// NOT SESSION STATE. The session — which windows are open, where, what shows — is the HOST's
/// (`view-set`, `term-list`), the same whichever device connects. These travel with the DEVICE: the
/// client states them in `client-hello` on every control open and in `set-prefs` on a change, and the
/// host applies fps/scale/bitrate/codec to every window it streams to that client while it drives.
/// A phone and a laptop ask for different things of the same windows, which is exactly why they are
/// not per window any more.
///
/// ABSENT fps/bitrate means the HOST's default, never a number invented here: a device that never
/// picked one streams at what the host is configured for. Resolution and codec always have a value —
/// `auto` is a real choice.
///
/// ONE STORE, the page's own `localStorage`. In the native app the session windows (`app://client`)
/// share their origin's storage, so one set serves every session window; the dashboard (`app://ui`)
/// never shows these rows, so no second origin changes them and no bridge is needed (unlike
/// `smooth-scroll-pref.ts`).

export type ScalePref = "auto" | number;
export type PointerModePref = "direct" | "trackpad";
export type CodecName = "auto" | "av1" | "h265" | "h264";

export interface ClientPrefs {
  fps?: number;
  scale: ScalePref;
  bitrateBps?: number;
  codec: CodecName;
  pointerMode?: PointerModePref;
  av1ReferenceRecovery?: boolean;
}

export const CLIENT_PREFS_KEY = "rdev.clientPrefs";
/// Where the touch mode lived on its own until it joined the rest (pointer-mode.ts, before 2026-09-29).
export const LEGACY_POINTER_MODE_KEY = "rdev.pointerMode";

export const DEFAULT_CLIENT_PREFS: Readonly<ClientPrefs> = Object.freeze({ scale: "auto", codec: "auto" });

/// The `Storage` methods this needs — structural, so a test can pass a plain object and a page with no
/// storage can pass null.
export interface PrefsStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem?(key: string): void;
}

/// `localStorage` where it exists and is reachable. THE ACCESSOR ITSELF CAN THROW — a browser set to
/// block site data does not merely return null.
export function defaultPrefsStore(): PrefsStore | null {
  try { return globalThis.localStorage ?? null; } catch { return null; }
}

const CODECS: ReadonlySet<string> = new Set(["auto", "av1", "h265", "h264"]);

function positiveInt(v: unknown): number | undefined {
  return typeof v === "number" && Number.isInteger(v) && v > 0 ? v : undefined;
}

/// A fixed fraction of native resolution is (0, 1]; anything else is Auto.
function scaleOf(v: unknown): ScalePref {
  return typeof v === "number" && Number.isFinite(v) && v > 0 && v <= 1 ? v : "auto";
}

/// LENIENT, FIELD BY FIELD: one bad field costs that field and never the rest — the same rule the host
/// applies to `client-hello` (contract). A stored value from a future build keeps whatever still parses.
export function parseClientPrefs(v: unknown): ClientPrefs {
  const o = (typeof v === "object" && v !== null ? v : {}) as Record<string, unknown>;
  const p: ClientPrefs = {
    scale: scaleOf(o.scale),
    codec: typeof o.codec === "string" && CODECS.has(o.codec) ? (o.codec as CodecName) : "auto",
  };
  const fps = positiveInt(o.fps);
  if (fps !== undefined) p.fps = fps;
  const bitrate = positiveInt(o.bitrateBps);
  if (bitrate !== undefined) p.bitrateBps = bitrate;
  if (o.pointerMode === "direct" || o.pointerMode === "trackpad") p.pointerMode = o.pointerMode;
  if (typeof o.av1ReferenceRecovery === "boolean") p.av1ReferenceRecovery = o.av1ReferenceRecovery;
  return p;
}

/// The saved set, or the defaults. NEVER THROWS. MIGRATES the touch mode ONCE: a device that chose
/// Trackpad before this store existed keeps it, and the old key goes so it can never override a later
/// choice. A stored set that already exists wins over the old key.
export function loadClientPrefs(store: PrefsStore | null = defaultPrefsStore()): ClientPrefs {
  let raw: string | null = null;
  let legacy: string | null = null;
  try {
    raw = store?.getItem(CLIENT_PREFS_KEY) ?? null;
    legacy = store?.getItem(LEGACY_POINTER_MODE_KEY) ?? null;
  } catch {
    return { ...DEFAULT_CLIENT_PREFS };
  }
  let parsed: unknown = null;
  if (raw !== null) { try { parsed = JSON.parse(raw); } catch { parsed = null; } }
  const p = parseClientPrefs(parsed);
  if (raw === null && (legacy === "direct" || legacy === "trackpad")) {
    p.pointerMode = legacy;
    saveClientPrefs(p, store);
    try { store?.removeItem?.(LEGACY_POINTER_MODE_KEY); } catch { /* the next load migrates again, harmlessly */ }
  }
  return p;
}

/// Best-effort, NEVER THROWS (Safari's private mode refuses writes): the caller has already APPLIED the
/// change, and a failed save must not undo that.
export function saveClientPrefs(p: ClientPrefs, store: PrefsStore | null = defaultPrefsStore()): void {
  try { store?.setItem(CLIENT_PREFS_KEY, JSON.stringify(clientPrefsWire(p))); } catch { /* not saved; still applied */ }
}

/// `ClientPrefsWire` (contract): what the device CHOSE. An absent field means the host's default, so it
/// is omitted rather than sent as null.
export function clientPrefsWire(p: ClientPrefs): Record<string, unknown> {
  const w: Record<string, unknown> = { scale: p.scale, codec: p.codec };
  if (p.fps !== undefined) w.fps = p.fps;
  if (p.bitrateBps !== undefined) w.bitrateBps = p.bitrateBps;
  if (p.pointerMode !== undefined) w.pointerMode = p.pointerMode;
  if (p.av1ReferenceRecovery !== undefined) w.av1ReferenceRecovery = p.av1ReferenceRecovery;
  return w;
}
