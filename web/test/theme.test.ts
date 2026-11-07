import { expect, test, vi } from "vitest";
import { applyTheme, initialTheme, onThemeChange } from "../src/shared/theme";

test("dark-only ignores saved light preferences", () => {
  expect(initialTheme("light", true)).toBe("dark");
  expect(initialTheme("dark", false)).toBe("dark");
});

test("dark-only ignores the system preference", () => {
  expect(initialTheme(null, true)).toBe("dark");
  expect(initialTheme(null, false)).toBe("dark");
});

test("a junk stored value is ignored, not trusted", () => {
  expect(initialTheme("neon", true)).toBe("dark");
  expect(initialTheme("", false)).toBe("dark");
});

test("onThemeChange returns an unsubscribe — a disposed session's listener hears nothing more", () => {
  const heard: string[] = [];
  const off = onThemeChange((t) => heard.push(t));
  applyTheme("light");
  off();
  applyTheme("dark");
  expect(heard).toEqual(["dark"]);
  off();                                   // idempotent
});

test("an unsubscribe called from INSIDE a listener does not skip the next listener", () => {
  // A live array walked with a plain for…of and spliced mid-iteration drops whatever came right
  // after the removed entry — a session ending itself from within its own theme callback must not
  // silently deafen the session subscribed after it.
  const heard: string[] = [];
  const offA = onThemeChange((t) => { heard.push(`a:${t}`); offA(); });
  const offB = onThemeChange((t) => heard.push(`b:${t}`));
  applyTheme("light");
  expect(heard).toEqual(["a:dark", "b:dark"]);
  offB();
});

test("requesting light still applies and persists dark", () => {
  const setItem = vi.fn();
  vi.stubGlobal("localStorage", { setItem });
  try {
    applyTheme("light");
    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(setItem).toHaveBeenCalledWith("rdev.theme", "dark");
  } finally { vi.unstubAllGlobals(); }
});
