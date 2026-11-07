// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { dragSlot, dropSlot, menuPosition, revealScroll, shiftSteps, TabBar, type TabBarCallbacks } from "../src/client/tab-bar";
import type { RenameField } from "../src/client/tab-name";

describe("dropSlot — where a dragged tab lands among the others", () => {
  const centers = [50, 150, 250];   // the OTHER tabs' centres, in bar order
  it("counts the others whose centre the dragged tab's centre has passed", () => {
    expect(dropSlot(centers, 10)).toBe(0);
    expect(dropSlot(centers, 149)).toBe(1);
    expect(dropSlot(centers, 151)).toBe(2);
    expect(dropSlot(centers, 999)).toBe(3);
  });
});

describe("dragSlot — the slot under a tab dragged by dx, read at its LEADING edge", () => {
  // A 60-wide first tab, then a 100-wide one being dragged, then a 60-wide last tab (6 px gaps).
  const first = { left: 0, width: 60 }, me = { left: 66, width: 100 }, last = { left: 172, width: 60 };
  it("is its own slot when it has not moved", () => {
    expect(dragSlot([first, last], me, 0)).toBe(1);
  });
  // REGRESSION (tab-menu-check T2c): read at the CENTRE, a tab wider than the first one could never be
  // dropped first — the drag is clamped at the bar's start, where its centre is still past the first
  // tab's — nor, wider than the last, last.
  it("a tab wider than the first can be dropped FIRST, at the clamp", () => {
    expect(dragSlot([first, last], me, first.left - me.left)).toBe(0);
  });
  it("a tab wider than the last can be dropped LAST, at the clamp", () => {
    expect(dragSlot([first, last], me, last.left + last.width - (me.left + me.width))).toBe(2);
  });
  it("passes a neighbour once its leading edge crosses the neighbour's middle", () => {
    expect(dragSlot([first, last], me, -35)).toBe(1);      // left edge at 31: first's middle is 30
    expect(dragSlot([first, last], me, -37)).toBe(0);
    expect(dragSlot([first, last], me, 35)).toBe(1);       // right edge at 201: last's middle is 202
    expect(dragSlot([first, last], me, 37)).toBe(2);
  });
});

describe("shiftSteps — how far each other tab moves to make room", () => {
  // Five tabs, the one at index 1 dragged: the others are bar indices 0, 2, 3, 4 → others-index 0..3.
  it("nothing moves while the tab is over its own slot", () => {
    expect([0, 1, 2, 3].map((j) => shiftSteps(j, 1, 1))).toEqual([0, 0, 0, 0]);
  });
  it("dragged right past two tabs: those two step LEFT", () => {
    expect([0, 1, 2, 3].map((j) => shiftSteps(j, 1, 3))).toEqual([0, -1, -1, 0]);
  });
  it("dragged left to the front: the tab it passed steps RIGHT", () => {
    expect([0, 1, 2, 3].map((j) => shiftSteps(j, 1, 0))).toEqual([1, 0, 0, 0]);
  });
});

describe("revealScroll — the scroll position that shows the selected tab whole, moving the bar least", () => {
  const view = { left: 12, right: 312 };   // the scroller's box inside its padding, as it scrolls now
  it("moves nothing when the tab already shows whole, edge to edge included", () => {
    expect(revealScroll(40, view, { left: 100, right: 200 })).toBe(40);
    expect(revealScroll(40, view, { left: 12, right: 312 })).toBe(40);
  });
  it("off to the RIGHT (the bar opened at its start): its end at the view's end", () => {
    expect(revealScroll(0, view, { left: 900, right: 1010 })).toBe(698);
    expect(revealScroll(0, view, { left: 280, right: 330 })).toBe(18);     // partly hidden counts
  });
  it("off to the LEFT: its start at the view's start", () => {
    expect(revealScroll(500, view, { left: -200, right: -100 })).toBe(288);
    expect(revealScroll(500, view, { left: 0, right: 80 })).toBe(488);
  });
  it("wider than the view: its start, whichever side it is off", () => {
    expect(revealScroll(0, view, { left: 100, right: 500 })).toBe(88);
    expect(revealScroll(300, view, { left: -50, right: 400 })).toBe(238);
  });
});

describe("menuPosition", () => {
  const view = { left: 0, top: 0, width: 400, height: 300 };
  const menu = { width: 120, height: 80 };
  const tab = { left: 100, top: 10, right: 180, bottom: 54 };
  it("opens under the tab, aligned to its left edge", () => {
    expect(menuPosition(tab, menu, view)).toEqual({ left: 100, top: 58 });
  });
  it("opens at the pointer for a right-click", () => {
    expect(menuPosition(tab, menu, view, { x: 130, y: 30 })).toEqual({ left: 130, top: 30 });
  });
  it("stays inside the visible area", () => {
    expect(menuPosition({ left: 350, top: 10, right: 398, bottom: 54 }, menu, view)).toEqual({ left: 272, top: 58 });
    expect(menuPosition(tab, menu, view, { x: 390, y: 290 })).toEqual({ left: 272, top: 212 });
  });
  it("opens ABOVE a tab with no room below it", () => {
    expect(menuPosition({ left: 100, top: 250, right: 180, bottom: 294 }, menu, view)).toEqual({ left: 100, top: 166 });
  });
  it("measures against the VISUAL viewport, which a soft keyboard moves", () => {
    expect(menuPosition(tab, menu, { left: 0, top: 200, width: 400, height: 300 })).toEqual({ left: 100, top: 208 });
  });
});

// jsdom 25 implements neither `showModal` nor `close` on <dialog>: the stub opens it, and closes it firing the
// `close` a browser fires.
function stubDialogs(): void {
  HTMLDialogElement.prototype.showModal = function (this: HTMLDialogElement) { this.setAttribute("open", ""); };
  HTMLDialogElement.prototype.close = function (this: HTMLDialogElement) {
    if (!this.hasAttribute("open")) return;
    this.removeAttribute("open");
    this.dispatchEvent(new Event("close"));
  };
}

describe("TabBar — rename in an OVERLAY ALERT (jsdom: no layout, no top layer; the browser check covers those)", () => {
  beforeEach(stubDialogs);
  afterEach(() => { document.body.replaceChildren(); vi.restoreAllMocks(); });

  function setup(field: RenameField | null = { value: "zsh", placeholder: "zsh", named: false, clearable: true }) {
    const scroller = document.createElement("div");
    const tab = document.createElement("button");
    tab.className = "rl-tab";
    tab.dataset.tabKey = "pty:1";
    const label = document.createElement("span");
    label.className = "rl-tab-label";
    label.textContent = "zsh";
    tab.append(label);
    scroller.append(tab);
    document.body.append(scroller);
    const cb: TabBarCallbacks = {
      enabled: () => true, renameField: () => field,
      rename: vi.fn(), close: vi.fn(), move: vi.fn(), settled: vi.fn(),
    };
    const ctl = new AbortController();
    const bar = new TabBar(scroller, cb, ctl.signal);
    return { bar, cb, tab, label, scroller, ctl };
  }
  const dialog = () => document.querySelector<HTMLDialogElement>("dialog.tab-rename-dialog");
  const input = () => dialog()!.querySelector<HTMLInputElement>("input")!;
  const button = (text: string) => [...dialog()!.querySelectorAll("button")].find((b) => b.textContent === text)!;
  const key = (el: HTMLElement, k: string) => el.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true }));

  it("opens a MODAL alert holding the name, all selected and focused — the tab itself untouched, the bar not busy", () => {
    const { bar, tab, label } = setup();
    bar.beginRename("pty:1");
    expect(dialog()!.open).toBe(true);
    expect(dialog()!.querySelector("h2")!.textContent).toBe("Rename Tab");
    expect(input().value).toBe("zsh");
    expect(input().placeholder, "what an empty one leaves").toBe("zsh");
    expect(document.activeElement).toBe(input());
    expect([input().selectionStart, input().selectionEnd]).toEqual([0, 3]);
    expect(tab.querySelector("input"), "nothing in the tab").toBeNull();
    expect(label.hidden).toBe(false);
    expect(bar.busy, "a rebuild cannot touch the alert").toBe(false);
    expect(bar.editingKey).toBe("pty:1");
  });

  it("Enter commits the tidied name, closes the alert and settles", () => {
    const { bar, cb } = setup();
    bar.beginRename("pty:1");
    input().value = "  api  ";
    key(input(), "Enter");
    expect(cb.rename).toHaveBeenCalledWith("pty:1", "api");
    expect(cb.settled).toHaveBeenCalledTimes(1);
    expect(dialog()!.open).toBe(false);
    expect(bar.editingKey).toBeNull();
  });

  it("the Rename button commits; Cancel and Escape (the dialog's cancel) send nothing", () => {
    const { bar, cb } = setup();
    bar.beginRename("pty:1");
    input().value = "api";
    button("Rename").click();
    expect(cb.rename).toHaveBeenCalledWith("pty:1", "api");
    bar.beginRename("pty:1");
    input().value = "nope";
    button("Cancel").click();
    bar.beginRename("pty:1");
    input().value = "nope";
    dialog()!.dispatchEvent(new Event("cancel", { cancelable: true }));
    expect(cb.rename).toHaveBeenCalledTimes(1);
    expect(dialog()!.open).toBe(false);
    expect(cb.settled).toHaveBeenCalledTimes(3);
  });

  it("an unchanged name sends nothing; an emptied given name CLEARS it; a tmux tab's alert renames its session", () => {
    const named = setup({ value: "api", placeholder: "zsh", named: true, clearable: true });
    named.bar.beginRename("pty:1");
    key(input(), "Enter");
    expect(named.cb.rename).not.toHaveBeenCalled();
    named.bar.beginRename("pty:1");
    input().value = "";
    key(input(), "Enter");
    expect(named.cb.rename).toHaveBeenCalledWith("pty:1", "");
    named.ctl.abort();
    document.body.replaceChildren();
    const tmux = setup({ value: "work", placeholder: "work", named: false, clearable: false });
    tmux.bar.beginRename("pty:1");
    expect(dialog()!.querySelector("h2")!.textContent).toBe("Rename Tmux Session");
  });

  it("keeps its keys to itself — a session shortcut must not see them", () => {
    const { bar } = setup();
    const seen = vi.fn();
    document.addEventListener("keydown", seen);
    bar.beginRename("pty:1");
    key(input(), "k");
    expect(seen).not.toHaveBeenCalled();
    document.removeEventListener("keydown", seen);
  });

  it("a tab with no field cannot be renamed", () => {
    const { bar } = setup(null);
    bar.beginRename("pty:1");
    expect(dialog()?.open ?? false).toBe(false);
    expect(bar.editingKey).toBeNull();
  });

  it("cancelRename drops the alert without sending — the tab went away underneath it", () => {
    const { bar, cb } = setup();
    bar.beginRename("pty:1");
    input().value = "api";
    bar.cancelRename();
    expect(cb.rename).not.toHaveBeenCalled();
    expect(dialog()!.open).toBe(false);
  });

  it("the window losing focus commits nothing — the alert stays (an app switch is not a decision)", () => {
    const { bar, cb } = setup();
    bar.beginRename("pty:1");
    input().value = "";
    input().dispatchEvent(new FocusEvent("blur"));
    expect(cb.rename).not.toHaveBeenCalled();
    expect(bar.editingKey).toBe("pty:1");
  });

  it("the session ending takes the alert with it", () => {
    const { bar, ctl } = setup();
    bar.beginRename("pty:1");
    ctl.abort();
    expect(dialog()).toBeNull();
  });

  it("gives focus back to what held it when the menu opened", () => {
    const { bar } = setup();
    const term = document.createElement("textarea");
    document.body.append(term);                               // OUTSIDE the bar, as the terminal is
    term.focus();
    bar.rememberFocus();
    bar.beginRename("pty:1");
    key(input(), "Enter");
    expect(document.activeElement).toBe(term);
  });
});

describe("TabBar — a press holds the bar (the strip must not rebuild under a finger)", () => {
  afterEach(() => { document.body.replaceChildren(); });
  /// jsdom has no PointerEvent: a MouseEvent of the pointer type, with the pointer's fields on it.
  const pointer = (type: string, pointerType: string, pointerId = 1) => {
    const e = new MouseEvent(type, { bubbles: true, cancelable: true, button: 0 });
    Object.defineProperty(e, "pointerId", { value: pointerId });
    Object.defineProperty(e, "pointerType", { value: pointerType });
    return e;
  };
  function setup() {
    const scroller = document.createElement("div");
    const tab = document.createElement("button");
    tab.className = "rl-tab";
    tab.dataset.tabKey = "pty:1";
    scroller.append(tab);
    document.body.append(scroller);
    const cb: TabBarCallbacks = { enabled: () => true, renameField: () => null, rename: vi.fn(), close: vi.fn(),
                                  move: vi.fn(), settled: vi.fn() };
    const bar = new TabBar(scroller, cb, new AbortController().signal);
    return { bar, cb, tab };
  }
  const tick = () => new Promise((r) => setTimeout(r, 0));

  // A term-list landing during a finger's hold rebuilt the strip and DETACHED the element the finger was
  // on; its touch and pointer events then reach no listener in the document, and the tab could not be
  // carried (tab-menu-check T2c).
  it("is busy from press to release, and settles AFTER the release's click", async () => {
    const { bar, cb, tab } = setup();
    tab.dispatchEvent(pointer("pointerdown", "mouse"));
    expect(bar.busy).toBe(true);
    window.dispatchEvent(pointer("pointerup", "mouse"));
    expect(bar.busy).toBe(false);
    expect(cb.settled).not.toHaveBeenCalled();          // the click is dispatched first, on the tab it hit
    await tick();
    expect(cb.settled).toHaveBeenCalledTimes(1);
  });

  it("a press whose end never came does not block the next one", async () => {
    const { bar, tab } = setup();
    tab.dispatchEvent(pointer("pointerdown", "touch", 1));    // its pointerup is lost
    tab.dispatchEvent(pointer("pointerdown", "mouse", 2));
    window.dispatchEvent(pointer("pointerup", "mouse", 2));
    expect(bar.busy).toBe(false);
  });

  it("a passive client's press holds nothing", () => {
    const { bar, cb, tab } = setup();
    (cb as { enabled: () => boolean }).enabled = () => false;
    tab.dispatchEvent(pointer("pointerdown", "mouse"));
    expect(bar.busy).toBe(false);
  });
});


describe("TabBar — the review's gesture findings (2026-10-01)", () => {
  afterEach(() => { document.body.replaceChildren(); vi.useRealTimers(); vi.restoreAllMocks(); });
  /// jsdom has no PointerEvent: a MouseEvent of the pointer type, with the pointer's fields on it.
  const pointer = (type: string, pointerType: string, o: { id?: number; x?: number; buttons?: number; button?: number; primary?: boolean } = {}) => {
    const e = new MouseEvent(type, { bubbles: true, cancelable: true, button: o.button ?? 0, buttons: o.buttons ?? 1, clientX: o.x ?? 0, clientY: 10 });
    Object.defineProperty(e, "pointerId", { value: o.id ?? 1 });
    Object.defineProperty(e, "pointerType", { value: pointerType });
    Object.defineProperty(e, "isPrimary", { value: o.primary ?? true });
    return e;
  };
  const rect = (left: number, width: number) => ({ left, right: left + width, top: 0, bottom: 40, width, height: 40, x: left, y: 0, toJSON() {} }) as DOMRect;
  /// Three 100-wide tabs at 0, 106, 212 in a 400-wide scroller — enough layout for a drag.
  function setup(enabled = true) {
    const scroller = document.createElement("div");
    scroller.getBoundingClientRect = () => rect(0, 400);
    const tabs = ["pty:1", "pty:2", "pty:3"].map((k, i) => {
      const t = document.createElement("button");
      t.className = "rl-tab";
      t.dataset.tabKey = k;
      const l = document.createElement("span"); l.className = "rl-tab-label"; l.textContent = k; t.append(l);
      t.getBoundingClientRect = () => rect(i * 106, 100);
      (t as unknown as { setPointerCapture(): void }).setPointerCapture = () => {};
      scroller.append(t);
      return t;
    });
    document.body.append(scroller);
    const state = { enabled };
    const cb: TabBarCallbacks = { enabled: () => state.enabled, renameField: () => ({ value: "zsh", placeholder: "zsh", named: false, clearable: true }),
                                  rename: vi.fn(), close: vi.fn(), move: vi.fn(), settled: vi.fn() };
    const ctl = new AbortController();
    const bar = new TabBar(scroller, cb, ctl.signal);
    return { bar, cb, tabs, scroller, ctl, state };
  }
  const click = (el: Element) => { const e = new MouseEvent("click", { bubbles: true, cancelable: true }); el.dispatchEvent(e); return e.defaultPrevented; };

  it("M2: Escape cancels a drag for good — moving on and releasing sends no move and switches nothing", () => {
    const { bar, cb, tabs } = setup();
    tabs[0]!.dispatchEvent(pointer("pointerdown", "mouse", { x: 50 }));
    window.dispatchEvent(pointer("pointermove", "mouse", { x: 300 }));
    expect(bar.busy).toBe(true);                                     // dragging
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    expect(bar.busy).toBe(false);
    window.dispatchEvent(pointer("pointermove", "mouse", { x: 310 }));
    expect(bar.busy).toBe(false);                                    // not restarted
    window.dispatchEvent(pointer("pointerup", "mouse", { x: 310, buttons: 0 }));
    expect(cb.move).not.toHaveBeenCalled();
    expect(click(tabs[0]!)).toBe(true);                              // the release's click is swallowed
  });

  it("M3: after a hold, the lift's click is swallowed even when it comes late (iOS), and a later one is not", () => {
    vi.useFakeTimers();
    const { tabs } = setup();
    tabs[1]!.dispatchEvent(pointer("pointerdown", "touch", { x: 150 }));
    vi.advanceTimersByTime(600);                                     // held
    window.dispatchEvent(pointer("pointerup", "touch", { x: 150, buttons: 0 }));
    vi.advanceTimersByTime(80);                                      // iOS clicks after the touch sequence
    expect(click(tabs[1]!)).toBe(true);
    vi.advanceTimersByTime(2000);
    expect(click(tabs[1]!)).toBe(false);                             // a later, real click switches
  });

  it("M4: a rename gives focus back to what held it BEFORE the press took it", () => {
    stubDialogs();
    const { bar, tabs } = setup();
    const input = document.createElement("input");
    document.body.append(input);
    input.focus();
    tabs[1]!.dispatchEvent(pointer("pointerdown", "mouse", { button: 2, buttons: 2 }));
    tabs[1]!.focus();                                                // Chromium focuses the button on mousedown
    tabs[1]!.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 150, clientY: 10 }));
    bar.beginRename("pty:2");
    const field = document.querySelector("dialog.tab-rename-dialog input")!;
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    expect(document.activeElement).toBe(input);
  });

  it("M6: a touch whose end was lost does not hold the bar for good — the next first finger starts afresh", () => {
    const { bar, tabs } = setup();
    tabs[0]!.dispatchEvent(pointer("pointerdown", "touch", { id: 5 }));        // its pointerup never comes
    tabs[1]!.dispatchEvent(pointer("pointerdown", "touch", { id: 6, primary: true }));
    window.dispatchEvent(pointer("pointerup", "touch", { id: 6, buttons: 0 }));
    expect(bar.busy).toBe(false);
  });

  it("M6: a real second finger is still ignored", () => {
    const { bar, tabs } = setup();
    tabs[0]!.dispatchEvent(pointer("pointerdown", "touch", { id: 5 }));
    tabs[1]!.dispatchEvent(pointer("pointerdown", "touch", { id: 6, primary: false }));
    window.dispatchEvent(pointer("pointerup", "touch", { id: 6, buttons: 0 }));
    expect(bar.busy).toBe(true);                                     // the first finger is still down
    window.dispatchEvent(pointer("pointerup", "touch", { id: 5, buttons: 0 }));
    expect(bar.busy).toBe(false);
  });

  it("M6: a mouse whose release was lost (released outside) ends the drag on the next buttonless move", () => {
    const { bar, cb, tabs } = setup();
    tabs[0]!.dispatchEvent(pointer("pointerdown", "mouse", { x: 50 }));
    window.dispatchEvent(pointer("pointermove", "mouse", { x: 300 }));
    expect(bar.busy).toBe(true);
    window.dispatchEvent(pointer("pointermove", "mouse", { x: 320, buttons: 0 }));
    expect(bar.busy).toBe(false);
    expect(cb.move).not.toHaveBeenCalled();
  });

  it("M6: the window losing focus cancels a press and a drag", () => {
    const { bar, cb, tabs } = setup();
    tabs[0]!.dispatchEvent(pointer("pointerdown", "mouse", { x: 50 }));
    window.dispatchEvent(pointer("pointermove", "mouse", { x: 300 }));
    window.dispatchEvent(new Event("blur"));
    expect(bar.busy).toBe(false);
    window.dispatchEvent(pointer("pointerup", "mouse", { x: 300, buttons: 0 }));
    expect(cb.move).not.toHaveBeenCalled();
  });

  it("M7: cancelGesture ends a drag without a drop — the client went passive", () => {
    const { bar, cb, tabs } = setup();
    tabs[0]!.dispatchEvent(pointer("pointerdown", "mouse", { x: 50 }));
    window.dispatchEvent(pointer("pointermove", "mouse", { x: 300 }));
    bar.cancelGesture();
    expect(bar.busy).toBe(false);
    window.dispatchEvent(pointer("pointerup", "mouse", { x: 300, buttons: 0 }));
    expect(cb.move).not.toHaveBeenCalled();
  });

  it("M7: a hold that completes after the client went passive opens nothing and holds nothing", () => {
    vi.useFakeTimers();
    const { bar, tabs, state } = setup();
    tabs[1]!.dispatchEvent(pointer("pointerdown", "touch", { x: 150 }));
    state.enabled = false;
    vi.advanceTimersByTime(600);
    window.dispatchEvent(pointer("pointermove", "touch", { x: 300 }));       // would carry a held tab
    expect(bar.busy).toBe(false);
  });

  it("M8: a session torn down during a hold leaves no timer behind", () => {
    vi.useFakeTimers();
    const { bar, tabs, ctl } = setup();
    tabs[1]!.dispatchEvent(pointer("pointerdown", "touch", { x: 150 }));
    ctl.abort();
    expect(bar.busy).toBe(false);
    expect(vi.getTimerCount()).toBe(0);
  });
});

// THE SESSION'S ITEMS (paste, 2026-10-02): on a phone a window's titlebar is all controls, so the tab's menu
// is where a finger can ask to paste into it. The bar shows what the session adds for a key AFTER its own
// two and hands a pick back BY KEY; it knows nothing of what they do.
describe("TabBar — the session's extra items", () => {
  // jsdom has no Popover API: a flag `:popover-open` reads (as context-menu.test.ts does).
  const proto = HTMLElement.prototype as unknown as Record<string, unknown>;
  const realMatches = Element.prototype.matches;
  beforeEach(() => {
    proto.showPopover = function (this: HTMLElement) { this.dataset.open = "1"; };
    proto.hidePopover = function (this: HTMLElement) { delete this.dataset.open; };
    Element.prototype.matches = function (this: Element, sel: string) {
      return sel === ":popover-open" ? (this as HTMLElement).dataset.open === "1" : realMatches.call(this, sel);
    };
  });
  afterEach(() => {
    delete proto.showPopover;
    delete proto.hidePopover;
    Element.prototype.matches = realMatches;
    document.body.replaceChildren();
  });

  const PASTE = [{ action: "paste", label: "Paste" }, { action: "file", label: "Paste Image/File…" }];
  function setup(extras: boolean) {
    const scroller = document.createElement("div");
    const tabs = ["pty:1", "win:7"].map((k) => {
      const t = document.createElement("button");
      t.className = "rl-tab";
      t.dataset.tabKey = k;
      const l = document.createElement("span"); l.className = "rl-tab-label"; l.textContent = k; t.append(l);
      scroller.append(t);
      return t;
    });
    document.body.append(scroller);
    const cb: TabBarCallbacks = {
      enabled: () => true, renameField: () => ({ value: "zsh", placeholder: "zsh", named: false, clearable: true }),
      rename: vi.fn(), close: vi.fn(), move: vi.fn(), settled: vi.fn(),
      ...(extras ? { extraItems: vi.fn(() => PASTE), onExtra: vi.fn() } : {}),
    };
    const ctl = new AbortController();
    const bar = new TabBar(scroller, cb, ctl.signal);
    return { bar, cb, tabs, ctl };
  }
  const items = () => [...document.querySelectorAll(".ctx-menu .ctx-menu-item")].map((b) => b.textContent);
  const pick = (action: string) => document.querySelector<HTMLButtonElement>(`.ctx-menu-item[data-action="${action}"]`)!.click();
  const rightClick = (el: Element) => el.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 150, clientY: 10 }));

  it("shows them AFTER Rename and Close, in the order given, asked for THAT tab's key", () => {
    const { cb, tabs } = setup(true);
    rightClick(tabs[1]!);
    expect(items()).toEqual(["Rename", "Close", "Paste", "Paste Image/File…"]);
    expect(cb.extraItems).toHaveBeenCalledWith("win:7");
    rightClick(tabs[0]!);
    expect(items()).toEqual(["Rename", "Close", "Paste", "Paste Image/File…"]);
    expect(cb.extraItems).toHaveBeenLastCalledWith("pty:1");
  });

  it("a pick of one goes to onExtra with the tab's key — and neither closes nor renames", () => {
    const { bar, cb, tabs } = setup(true);
    rightClick(tabs[1]!);
    pick("file");
    expect(cb.onExtra).toHaveBeenCalledTimes(1);
    expect(cb.onExtra).toHaveBeenCalledWith("win:7", "file");
    expect(cb.close).not.toHaveBeenCalled();
    expect(bar.editingKey).toBeNull();
    rightClick(tabs[0]!);
    pick("paste");
    expect(cb.onExtra).toHaveBeenLastCalledWith("pty:1", "paste");
  });

  it("Rename and Close are unchanged beside them", () => {
    const { bar, cb, tabs } = setup(true);
    rightClick(tabs[0]!);
    pick("close");
    expect(cb.close).toHaveBeenCalledWith("pty:1");
    rightClick(tabs[1]!);
    pick("rename");
    expect(bar.editingKey).toBe("win:7");
    expect(cb.onExtra).not.toHaveBeenCalled();
  });

  it("with none given the menu is Rename and Close, as before", () => {
    const { tabs } = setup(false);
    rightClick(tabs[1]!);
    expect(items()).toEqual(["Rename", "Close"]);
  });
});
