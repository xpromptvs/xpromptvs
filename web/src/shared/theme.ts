/// Light/dark theme. The value lives on `<html data-theme>` — the same convention as `data-layout` and
/// `data-tab` — so every theme difference is pure CSS keyed off one attribute.

export type Theme = "dark" | "light";

export const THEME_KEY = "rdev.theme";

/// Dark-only for now, including installations with a saved light preference.
export function initialTheme(_stored: string | null, _prefersDark: boolean): Theme {
  return "dark";
}

let theme: Theme = "dark";
const listeners: ((t: Theme) => void)[] = [];

export function currentTheme(): Theme { return theme; }

/// Subscribe; the return value unsubscribes. A session subscribes twice and must let go when it ends —
/// the theme outlives every session in the page.
export function onThemeChange(fn: (t: Theme) => void): () => void {
  listeners.push(fn);
  return () => {
    const i = listeners.indexOf(fn);
    if (i >= 0) listeners.splice(i, 1);
  };
}

/// Apply + persist. Persistence is best-effort: Safari private mode throws on localStorage writes, and a
/// failed *save* must never stop the theme from being *applied*.
export function applyTheme(_requested: Theme): void {
  const t: Theme = "dark";
  theme = t;
  document.documentElement.dataset.theme = t;
  try { localStorage.setItem(THEME_KEY, t); } catch { /* private mode / storage disabled */ }
  // A COPY: a listener that unsubscribes itself (or another) splices the LIVE array mid-iteration,
  // which shifts every later entry down one slot and makes a plain for…of skip whatever came right
  // after it — a session ending itself from its own theme callback must not silently deafen the
  // session subscribed after it.
  for (const fn of [...listeners]) fn(t);
}

/// Apply the product theme without consulting the OS or a previous preference.
export function startTheme(): Theme {
  applyTheme("dark");
  return "dark";
}
