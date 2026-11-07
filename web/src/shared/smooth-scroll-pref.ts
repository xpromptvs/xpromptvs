/// **Smooth scrolling of a terminal's scrollback — this DEVICE's preference, on unless saved off**
/// (`web/src/client/smooth-scroll.ts` is what it switches). The dashboard Settings, Terminal Settings
/// and the command palette change it, which applies it live to every open tab.
///
/// In a browser the dashboard and the session are one document, so one stored value serves both.
///
/// **In the native app the value is the APP's** (`AppSettings.smoothScroll`, `app-settings.json`): the
/// dashboard (`app://ui`) and the session windows (`app://client`) are two origins with two storages,
/// so neither page can hold the truth. A change anywhere is saved through the window's bridge
/// (`rdevApp` / `__rdevShell` `setSmoothScroll`), and the app pushes every change to EVERY window
/// (`onSmoothScroll`) — the dashboard's checkbox and each session's open tabs follow at once, whichever
/// window made it. A page's own storage is then only the value it starts from before the app answers
/// (`followNativeSmoothScroll`).

export const SMOOTH_SCROLL_KEY = "rdev.smoothScroll";

const listeners = new Set<(on: boolean) => void>();
/// A value this page APPLIED that storage refused to save. Storage is the truth otherwise — it is what
/// another page of the origin changes — but a refused write must not leave the palette reading the old
/// value back: its row would offer the wrong direction and never turn the option off (review M3).
let unsaved: boolean | null = null;
/// Changes made on THIS page — so the app's answer to the question asked at boot cannot undo one made
/// while that question was on its way.
let changes = 0;

/// The native app's bridge, when this page runs inside the app: the dashboard's `rdevApp` or a session
/// window's `__rdevShell` (`app/Sources/BridgeScripts.swift`).
interface NativeSmoothScroll {
  smoothScroll(): Promise<unknown>;
  setSmoothScroll(on: boolean): Promise<unknown>;
  onSmoothScroll(cb: (on: boolean) => void): () => void;
}

function nativeApp(): NativeSmoothScroll | null {
  const g = globalThis as { rdevApp?: Partial<NativeSmoothScroll>; __rdevShell?: Partial<NativeSmoothScroll> };
  for (const api of [g.rdevApp, g.__rdevShell]) {
    if (api && typeof api.smoothScroll === "function" && typeof api.setSmoothScroll === "function"
      && typeof api.onSmoothScroll === "function") return api as NativeSmoothScroll;
  }
  return null;
}

export function smoothScrollEnabled(): boolean {
  if (unsaved !== null) return unsaved;
  try { return localStorage.getItem(SMOOTH_SCROLL_KEY) !== "false"; } catch { return true; }
}

/// Apply on this page: its storage and every listener. Saving is best-effort (Safari private mode
/// throws on a write), and a failed SAVE must never stop the change being APPLIED.
function apply(on: boolean): void {
  try { localStorage.setItem(SMOOTH_SCROLL_KEY, String(on)); unsaved = null; } catch { unsaved = on; }
  for (const fn of [...listeners]) fn(on);
}

/// Change it: apply here, and — inside the app — save it in the app, which pushes it to every window.
/// A save the app refuses leaves this window on the app's value, never diverged from every other.
export function setSmoothScroll(on: boolean): void {
  changes++;
  apply(on);
  const app = nativeApp();
  if (!app) return;
  const mine = changes;
  app.setSmoothScroll(on).catch((e) => {
    console.warn("[smooth-scroll] the app did not save it; taking the app's value back", e);
    adoptAppValue(app, mine);
  });
}

/// How long before asking the app again after a refused question — once, as `rdevApp.subscribe` does.
const ASK_AGAIN_MS = 250;

/// Apply the app's value here, unless this page has changed it since `asked` (a later answer to an
/// earlier question must not undo it).
function adoptAppValue(app: NativeSmoothScroll, asked: number, again = true): void {
  app.smoothScroll().then((v) => {
    const on = v === true;
    if (changes === asked && on !== smoothScrollEnabled()) apply(on);
  }, (e) => {
    if (again) setTimeout(() => adoptAppValue(app, asked, false), ASK_AGAIN_MS);
    else console.warn("[smooth-scroll] could not read the app's value", e);
  });
}

/// Inside the app, follow the APP's value: ask for it now, and take every change it pushes after — from
/// this window or any other. A push is applied here and never saved back. In a browser there is no app,
/// and this does nothing. Returns the unsubscribe.
export function followNativeSmoothScroll(): () => void {
  const app = nativeApp();
  if (!app) return () => {};
  const off = app.onSmoothScroll((on) => { if (on !== smoothScrollEnabled()) apply(on); });
  adoptAppValue(app, changes);
  return off;
}

/// Subscribe to every change — this page's, one another page of this origin saved (a `storage` event),
/// and one the app pushed. The return value unsubscribes: a session subscribes and must let go when it
/// ends.
export function onSmoothScrollChange(fn: (on: boolean) => void): () => void {
  const fromStorage = (e: StorageEvent) => { if (e.key === SMOOTH_SCROLL_KEY) fn(e.newValue !== "false"); };
  listeners.add(fn);
  window.addEventListener("storage", fromStorage);
  return () => {
    listeners.delete(fn);
    window.removeEventListener("storage", fromStorage);
  };
}
