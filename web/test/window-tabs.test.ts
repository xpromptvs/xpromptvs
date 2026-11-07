import { describe, expect, it, test } from "vitest";
import { WindowTabs, landedOnTerminal, personAtWindow, windowTabViews, winRenameField } from "../src/client/window-tabs";
import type { Source, SessionWindowMsg } from "../src/client/source-picker";

const sources: Source[] = [
  { id: "sim:aaa", kind: "sim", name: "iPhone 17e", inputCapable: true, running: true },
  { id: "win:123", kind: "window", name: "Terminal.app", inputCapable: false, running: true },
];
const open = (source: string): SessionWindowMsg => ({ source, minimized: false });
const parked = (source: string): SessionWindowMsg => ({ source, minimized: true });

test("no windows → no tabs (TerminalTabs owns the terminal side)", () => {
  expect(windowTabViews({ windows: [], focused: null }, sources, "terminal")).toEqual([]);
});

test("one tab per window of the SESSION, in its order, named from sources, id fallback when unknown", () => {
  expect(windowTabViews({ windows: [open("sim:aaa"), open("win:999")], focused: "sim:aaa" }, sources, "sim")).toEqual([
    { id: "sim:aaa", label: "iPhone 17e", active: true, minimized: false },
    { id: "win:999", label: "win:999", active: false, minimized: false },
  ]);
});

test("a tab is active only when tab===sim AND it is the focused window", () => {
  const vs = { windows: [open("sim:aaa")], focused: "sim:aaa" };
  expect(windowTabViews(vs, sources, "terminal")[0]?.active).toBe(false);
  expect(windowTabViews(vs, sources, "sim")[0]?.active).toBe(true);
  expect(windowTabViews({ windows: [open("sim:aaa")], focused: "win:123" }, sources, "sim")[0]?.active).toBe(false);
});

test("floating windows never select a tab; pinned layouts still select the visible window", () => {
  const vs = { windows: [open("win:123")], focused: "win:123" };
  for (const layout of ["floating", "tabbed", "glasses"] as const) {
    const strip = document.createElement("div");
    const tabs = new WindowTabs({ root: document.documentElement, strip }, { onFocusSource: () => {} });
    tabs.update(windowTabViews(vs, sources, "sim", layout));
    expect(strip.firstElementChild?.classList.contains("on")).toBe(layout !== "floating");
    expect(strip.firstElementChild?.getAttribute("aria-selected")).toBe(String(layout !== "floating"));
  }
});

// A MINIMIZED WINDOW IS STILL THE SESSION'S — it keeps its place in the tab order, which is what makes
// "the same session on another device" true of parked windows too.
test("a minimized window keeps its tab, in place, dimmed and never active", () => {
  expect(windowTabViews({ windows: [parked("win:123"), open("sim:aaa")], focused: "sim:aaa" }, sources, "sim")).toEqual([
    { id: "win:123", label: "Terminal.app", active: false, minimized: true },
    { id: "sim:aaa", label: "iPhone 17e", active: true, minimized: false },
  ]);
});

test("a window the driver NAMED is labelled by its name; the source's own name otherwise", () => {
  const named: SessionWindowMsg = { source: "win:123", minimized: false, name: "logs" };
  expect(windowTabViews({ windows: [named, open("sim:aaa")], focused: null }, sources, "sim").map((v) => v.label))
    .toEqual(["logs", "iPhone 17e"]);
});

test("winRenameField opens on the label and empties to the source's own name", () => {
  expect(winRenameField({ source: "win:123", minimized: false }, sources))
    .toEqual({ value: "Terminal.app", placeholder: "Terminal.app", named: false, clearable: true });
  expect(winRenameField({ source: "win:123", minimized: false, name: "logs" }, sources))
    .toEqual({ value: "logs", placeholder: "Terminal.app", named: true, clearable: true });
});

test("WindowTabs keys its tabs, defers while held, and takes a label override", () => {
  let held = true;
  const strip = document.createElement("div");
  const tabs = new WindowTabs({ root: document.documentElement, strip }, {
    onFocusSource: () => {}, hold: () => held, label: (key, label) => (key === "win:123" ? "logs" : label),
  });
  const views = windowTabViews({ windows: [open("win:123"), open("sim:aaa")], focused: null }, sources, "sim");
  tabs.update(views);
  expect(strip.children.length).toBe(0);
  held = false;
  tabs.refresh();
  expect([...strip.querySelectorAll<HTMLElement>(".rl-tab")].map((b) => b.dataset.tabKey)).toEqual(["win:123", "sim:aaa"]);
  expect([...strip.querySelectorAll(".rl-tab-label")].map((l) => l.textContent)).toEqual(["logs", "iPhone 17e"]);
});

test("WindowTabs redraws IN PLACE: a tab keeps its element through a relabel, a focus change and a park", () => {
  const strip = document.createElement("div");
  const tabs = new WindowTabs({ root: document.documentElement, strip }, { onFocusSource: () => {} });
  tabs.update(windowTabViews({ windows: [open("win:123"), open("sim:aaa")], focused: "win:123" }, sources, "sim"));
  const before = [...strip.querySelectorAll<HTMLElement>(".rl-tab")];
  before[0]!.classList.add("dragging");
  tabs.update(windowTabViews({ windows: [{ source: "win:123", minimized: true, name: "logs" }, open("sim:aaa")], focused: "sim:aaa" }, sources, "sim"));
  const after = [...strip.querySelectorAll<HTMLElement>(".rl-tab")];
  expect(after[0]).toBe(before[0]);
  expect(after[1]).toBe(before[1]);
  expect(after[0]!.classList.contains("minimized")).toBe(true);
  expect(after[0]!.classList.contains("dragging")).toBe(true);
  expect(after[0]!.querySelector(".rl-tab-label")!.textContent).toBe("logs");
  expect(after.map((b) => b.classList.contains("on"))).toEqual([false, true]);
});

test("a window tab's click acts on its CURRENT state: parked, it restores", () => {
  const strip = document.createElement("div");
  const calls: [string, boolean][] = [];
  const tabs = new WindowTabs({ root: document.documentElement, strip }, { onFocusSource: (id, m) => calls.push([id, m]) });
  tabs.update(windowTabViews({ windows: [open("win:123")], focused: null }, sources, "sim"));
  tabs.update(windowTabViews({ windows: [parked("win:123")], focused: null }, sources, "sim"));
  strip.querySelector<HTMLElement>(".rl-tab")!.click();
  expect(calls).toEqual([["win:123", true]]);
});

// A WINDOW'S BELL (term-bell.ts): a window tab whose application raised its Dock badge carries `data-bell`,
// as a terminal tab does — drawn on a render and by `markBells`, on a HELD strip too, never by a rebuild.
test("WindowTabs marks a window that rang, in place, held or not", () => {
  let held = false;
  const rang = new Set<string>(["sim:aaa"]);
  const strip = document.createElement("div");
  const tabs = new WindowTabs({ root: document.documentElement, strip }, {
    onFocusSource: () => {}, hold: () => held, bell: (k) => rang.has(k),
  });
  const marked = () => [...strip.querySelectorAll<HTMLElement>(".rl-tab")].map((b) => b.hasAttribute("data-bell"));
  tabs.update(windowTabViews({ windows: [open("win:123"), parked("sim:aaa")], focused: "win:123" }, sources, "sim"));
  expect(marked()).toEqual([false, true]);                                  // a parked tab carries it too
  const before = [...strip.querySelectorAll(".rl-tab")];
  held = true;
  rang.clear(); rang.add("win:123");
  tabs.markBells();
  expect(marked()).toEqual([true, false]);
  expect([...strip.querySelectorAll(".rl-tab")]).toEqual(before);
});

// THE HOST LANDED THE PERSON ON A TERMINAL TAB (`SessionState.landing`, 2026-10-02): the window they were at
// — focused, on the windows surface — left, and the SAME view-set shows the terminal surface. That is what
// tells the page to hand the window's keys to the terminal rather than to the next window.
describe("landedOnTerminal", () => {
  const vs = (windows: SessionWindowMsg[], focused: string | null, surface: "terminal" | "windows") =>
    ({ windows, focused, view: { surface, fullscreen: null } });
  const before = vs([open("win:1"), open("win:2")], "win:2", "windows");

  it("the focused window gone and the surface the terminal's: landed", () => {
    expect(landedOnTerminal(before, vs([open("win:1")], "win:1", "terminal"))).toBe(true);
  });
  it("parked (still listed, minimized) counts as gone", () => {
    expect(landedOnTerminal(before, vs([open("win:1"), parked("win:2")], "win:1", "terminal"))).toBe(true);
  });
  it("the last window gone: landed (nothing focused after)", () => {
    expect(landedOnTerminal(vs([open("win:2")], "win:2", "windows"), vs([], null, "terminal"))).toBe(true);
  });
  it("the focused window gone but the surface stays the windows': landed on a WINDOW, not the terminal", () => {
    expect(landedOnTerminal(before, vs([open("win:1")], "win:1", "windows"))).toBe(false);
  });
  it("a switch to the terminal with the window still there (a terminal tab tapped): no landing", () => {
    expect(landedOnTerminal(before, vs([open("win:1"), open("win:2")], "win:2", "terminal"))).toBe(false);
  });
  it("the person was at the terminal already: no landing", () => {
    expect(landedOnTerminal(vs([open("win:1"), open("win:2")], "win:2", "terminal"), vs([open("win:1")], "win:1", "terminal"))).toBe(false);
  });
  it("an UNFOCUSED window gone: no landing", () => {
    expect(landedOnTerminal(before, vs([open("win:2")], "win:2", "terminal"))).toBe(false);
  });
});

// WHETHER THE PERSON WAS AT THE WINDOW they close or park — what the intent says as `land` (review,
// 2026-10-02). Only the page can tell: on a pinned layout the window on screen; on the floating layout,
// where the surface means nothing (it stays "windows" after a palette pick while the person types in the
// terminal), the window holding the KEYS.
describe("personAtWindow", () => {
  const at = (o: Partial<Parameters<typeof personAtWindow>[0]>) =>
    personAtWindow({ pinned: false, windowsSurface: true, focused: true, holdsKeys: false, ...o });
  it("floating: the window holding the keys, whatever the surface says", () => {
    expect(at({ holdsKeys: true })).toBe(true);
    expect(at({ holdsKeys: true, windowsSurface: false })).toBe(true);
  });
  it("floating: the focused window WITHOUT the keys (the person types in the terminal) is not where they are", () => {
    expect(at({ holdsKeys: false })).toBe(false);
  });
  it("pinned: the focused window on the windows surface, keys or not", () => {
    expect(at({ pinned: true })).toBe(true);
    expect(at({ pinned: true, holdsKeys: true })).toBe(true);
  });
  it("pinned: not while the terminal surface shows, nor an unfocused window", () => {
    expect(at({ pinned: true, windowsSurface: false, holdsKeys: true })).toBe(false);
    expect(at({ pinned: true, focused: false })).toBe(false);
  });
});
