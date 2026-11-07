// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Terminal } from "@xterm/xterm";
import { before, cellAt, selectRange, TouchSelection, wordAt } from "../src/client/touch-selection";

// A finger's text selection in the terminal (touch-selection.ts): the pure arithmetic — which word a hold
// lands on, which cell a point is, and the range xterm.js's `select` takes. The gestures are
// e2e/term-touch-select-check.mjs's (real CDP touch).

const SEP = " ()[]{}',\"`";
/** A line as cells: each character one cell; "W" stands for a wide glyph (its second cell width 0). */
const line = (s: string) => {
  const cells: Array<{ chars: string; width: number }> = [];
  for (const ch of s) {
    if (ch === "W") { cells.push({ chars: "界", width: 2 }, { chars: "", width: 0 }); continue; }
    cells.push({ chars: ch === " " ? "" : ch, width: 1 });
  }
  return { at: (x: number) => cells[x] ?? null, cols: cells.length };
};

describe("wordAt", () => {
  it("is the run around the cell that is neither blank nor a separator", () => {
    const l = line("const DESKTOP = {w: 1};");
    expect(wordAt(l.at, l.cols, 8, SEP)).toEqual({ start: 6, end: 12 });     // DESKTOP
    expect(wordAt(l.at, l.cols, 0, SEP)).toEqual({ start: 0, end: 4 });      // const, at the line's start
    expect(wordAt(l.at, l.cols, 18, SEP), "punctuation that is not a separator joins").toEqual({ start: 17, end: 18 });   // w:
    expect(wordAt(l.at, l.cols, 20, SEP), "a separator ends a word").toEqual({ start: 20, end: 20 });   // the 1 of 1};
    expect(wordAt(l.at, l.cols, 14, SEP)).toEqual({ start: 14, end: 14 });   // =
  });
  it("is null on blank space, on a separator and off the line", () => {
    const l = line("ab  (cd)");
    expect(wordAt(l.at, l.cols, 2, SEP)).toBeNull();
    expect(wordAt(l.at, l.cols, 4, SEP)).toBeNull();
    expect(wordAt(l.at, l.cols, -1, SEP)).toBeNull();
    expect(wordAt(l.at, l.cols, 99, SEP)).toBeNull();
  });
  it("takes a wide glyph whole, from either of its cells", () => {
    const l = line("aWb c");
    expect(wordAt(l.at, l.cols, 2, SEP), "its second cell").toEqual({ start: 0, end: 3 });
    expect(wordAt(l.at, l.cols, 0, SEP)).toEqual({ start: 0, end: 3 });
  });
});

describe("cellAt", () => {
  const screen = { left: 10, top: 20, width: 100, height: 50 };     // 10 cols × 5 rows of 10 × 10
  it("maps a point to its buffer cell, counting the rows scrolled above", () => {
    expect(cellAt(10, 20, screen, 10, 5, 0)).toEqual({ col: 0, row: 0 });
    expect(cellAt(35, 44, screen, 10, 5, 100)).toEqual({ col: 2, row: 102 });
  });
  it("clamps a point outside the grid to its edge", () => {
    expect(cellAt(-50, -50, screen, 10, 5, 7)).toEqual({ col: 0, row: 7 });
    expect(cellAt(500, 500, screen, 10, 5, 7)).toEqual({ col: 9, row: 11 });
  });
});

describe("selectRange", () => {
  it("is xterm.js's (column, row, length) — both ends included, wrapping at the width", () => {
    expect(selectRange({ col: 6, row: 3 }, { col: 12, row: 3 }, 80)).toEqual({ col: 6, row: 3, length: 7 });
    expect(selectRange({ col: 70, row: 3 }, { col: 4, row: 4 }, 80)).toEqual({ col: 70, row: 3, length: 15 });
  });
  it("takes its ends in either order", () => {
    expect(selectRange({ col: 4, row: 4 }, { col: 70, row: 3 }, 80)).toEqual({ col: 70, row: 3, length: 15 });
    expect(before({ col: 9, row: 1 }, { col: 0, row: 2 })).toBe(true);
    expect(before({ col: 0, row: 2 }, { col: 9, row: 1 })).toBe(false);
  });
});

/// A terminal as TouchSelection reads it: one line, a 10 × 5 grid on a 100 × 50 px screen at the origin.
function fakeTerm(text: string) {
  const screen = document.createElement("div");
  screen.className = "xterm-screen";
  screen.getBoundingClientRect = () => new DOMRect(0, 0, 100, 50);
  const element = document.createElement("div");
  element.append(screen);
  document.body.append(element);
  let selected = false;
  const sub = () => ({ dispose() {} });
  const term = {
    cols: 10, rows: 5, element, options: {},
    buffer: { active: { viewportY: 0, getNullCell: () => ({}),
      getLine: (r: number) => (r !== 0 ? undefined : { getCell: (x: number) => ({ getChars: () => (text[x] ?? " ").trim(), getWidth: () => 1 }) }) } },
    select: vi.fn(() => { selected = true; }),
    clearSelection: vi.fn(() => { selected = false; }),
    hasSelection: () => selected,
    getSelection: () => (selected ? "hello" : ""),
    onRender: sub, onScroll: sub, onResize: sub, onSelectionChange: sub, scrollLines: vi.fn(),
  };
  return term;
}
const pointer = (type: string, target: EventTarget, id = 1) => {
  const e = new MouseEvent(type, { bubbles: true, composed: true, cancelable: true, clientX: 80, clientY: 40 });
  Object.defineProperty(e, "pointerId", { value: id });
  Object.defineProperty(e, "pointerType", { value: "touch" });
  target.dispatchEvent(e);
  return e;
};

describe("TouchSelection — the first press elsewhere only ends it", () => {
  let ac: AbortController;
  afterEach(() => { ac.abort(); document.body.innerHTML = ""; });
  const rig = (shadow = false) => {
    ac = new AbortController();
    const surface = document.createElement("div");
    const host = document.createElement("div");
    document.body.append(host);
    const root = shadow ? host.attachShadow({ mode: "open" }) : host;
    root.append(surface);
    const term = fakeTerm("hello world");
    surface.append(term.element);
    const hidden: number[] = [];
    const sel = new TouchSelection(surface, {
      signal: ac.signal, term: () => term as unknown as Terminal,
      showMenu: () => {}, hideMenu: () => { hidden.push(1); },
    });
    return { sel, term, surface, hidden, root };
  };

  it("a hold selects the word; with its menu down, the next press elsewhere ends it and does nothing else", () => {
    const { sel, term, hidden } = rig();
    expect(sel.holdAt({ x: 15, y: 5 })).toBe(true);           // "hello", cells 0–4 of row 0
    expect(term.select).toHaveBeenCalledWith(0, 0, 5);
    pointer("pointerup", window);                              // the hold's finger lifts
    const elsewhere = document.createElement("button");
    document.body.append(elsewhere);
    const reached: string[] = [];
    for (const t of ["pointerdown", "pointerup", "mousedown", "click"]) elsewhere.addEventListener(t, () => reached.push(t));
    const down = pointer("pointerdown", elsewhere);
    expect(down.defaultPrevented).toBe(true);
    expect(sel.active).toBe(false);
    expect(term.clearSelection).toHaveBeenCalled();
    expect(hidden.length).toBeGreaterThan(0);
    pointer("pointerup", elsewhere);
    elsewhere.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    elsewhere.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    expect(reached, "nothing of the press reached what it landed on").toEqual([]);
    pointer("pointerdown", elsewhere, 2);
    expect(reached, "the press after it is its own").toEqual(["pointerdown"]);
  });

  it("a Copy tap inside the session ShadowRoot reaches the menu with its selection intact", () => {
    const { sel, root } = rig(true);
    sel.holdAt({ x: 15, y: 5 });
    pointer("pointerup", window);
    const menu = document.createElement("div");
    menu.className = "ctx-menu";
    const copy = document.createElement("button");
    menu.append(copy); root.append(menu);
    const copied: string[] = [];
    copy.addEventListener("click", () => copied.push(sel.text()));
    expect(pointer("pointerdown", copy).defaultPrevented).toBe(false);
    pointer("pointerup", copy);
    copy.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true, cancelable: true }));
    expect(copied).toEqual(["hello"]);
    expect(sel.active).toBe(true);
  });

  it("a selection handle inside the session ShadowRoot still starts a drag", () => {
    const { sel, surface } = rig(true);
    sel.holdAt({ x: 15, y: 5 });
    pointer("pointerup", window);
    pointer("pointerdown", surface.querySelector(".term-sel-end")!);
    expect(sel.active).toBe(true);
    expect(sel.busy).toBe(true);
  });

  it("a press on a handle is the handle's, not swallowed", () => {
    const { sel, surface } = rig();
    sel.holdAt({ x: 15, y: 5 });
    pointer("pointerup", window);
    const handle = surface.querySelector(".term-sel-end")!;
    const down = pointer("pointerdown", handle);
    expect(sel.active, "still selected").toBe(true);
    expect(down.defaultPrevented, "the handle's own listener prevents it — it is not dropped").toBe(true);
    expect(sel.busy, "the handle took it").toBe(true);
  });
});
