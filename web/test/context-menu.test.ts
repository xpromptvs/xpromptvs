// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ContextMenu, menuPosition } from "../src/client/context-menu";
import { CLICK_SWALLOW_MS } from "../src/client/press-hold";

// jsdom has no Popover API and no top layer: the stub is a flag, `:popover-open` reads it, and a hide
// fires the `toggle` the real one fires (synchronously here, a task later in a browser).
const proto = HTMLElement.prototype as unknown as Record<string, unknown>;
const realMatches = Element.prototype.matches;
beforeEach(() => {
  proto.showPopover = function (this: HTMLElement) { this.dataset.open = "1"; };
  proto.hidePopover = function (this: HTMLElement) {
    delete this.dataset.open;
    const ev = new Event("toggle");
    (ev as unknown as { newState: string }).newState = "closed";
    this.dispatchEvent(ev);
  };
  Element.prototype.matches = function (this: Element, sel: string) {
    return sel === ":popover-open" ? (this as HTMLElement).dataset.open === "1" : realMatches.call(this, sel);
  };
});
afterEach(() => {
  delete proto.showPopover;
  delete proto.hidePopover;
  Element.prototype.matches = realMatches;
});

describe("ContextMenu", () => {
  let ac: AbortController; let picks: string[]; let closed = 0; let menu: ContextMenu;
  beforeEach(() => { ac = new AbortController(); picks = []; closed = 0; menu = new ContextMenu(ac.signal, (a) => picks.push(a), () => closed++); });
  afterEach(() => { ac.abort(); document.body.innerHTML = ""; });

  const item = (a: string) => document.querySelector<HTMLButtonElement>(`.ctx-menu-item[data-action="${a}"]`)!;

  it("renders the items asked for, in order, and a pick closes it", () => {
    expect(menu.open([{ action: "paste", label: "Paste" }, { action: "file", label: "Paste Image/File…" }], null, { x: 10, y: 10 })).toBe(true);
    expect([...document.querySelectorAll(".ctx-menu-item")].map((b) => b.textContent)).toEqual(["Paste", "Paste Image/File…"]);
    item("file").click();
    expect(picks).toEqual(["file"]);
    expect(menu.isOpen).toBe(false);
    expect(closed).toBe(1);
  });
  it("a disabled item picks nothing", () => {
    menu.open([{ action: "rename", label: "Rename", disabled: true }], null, { x: 0, y: 0 });
    item("rename").click();
    expect(picks).toEqual([]);
  });
  it("reopening replaces the items", () => {
    menu.open([{ action: "a", label: "A" }], null, { x: 0, y: 0 });
    menu.open([{ action: "b", label: "B" }], null, { x: 0, y: 0 });
    expect([...document.querySelectorAll(".ctx-menu-item")].map((b) => (b as HTMLElement).dataset.action)).toEqual(["b"]);
  });
  it("says no where there is no Popover API", () => {
    delete proto.showPopover;
    expect(menu.open([{ action: "a", label: "A" }], null, { x: 0, y: 0 })).toBe(false);
  });
  it("a press outside, Escape, a resize and a blur close it", () => {
    for (const fire of [
      () => document.body.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true })),
      () => window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" })),
      () => window.dispatchEvent(new Event("resize")),
      () => window.dispatchEvent(new Event("blur")),
    ]) {
      menu.open([{ action: "a", label: "A" }], null, { x: 0, y: 0 });
      fire();
      expect(menu.isOpen).toBe(false);
    }
  });
  it("a press on the menu itself does not close it, and takes no focus", () => {
    menu.open([{ action: "a", label: "A" }], null, { x: 0, y: 0 });
    item("a").dispatchEvent(new MouseEvent("pointerdown", { bubbles: true }));
    expect(menu.isOpen).toBe(true);
    const md = new MouseEvent("mousedown", { bubbles: true, cancelable: true });
    item("a").dispatchEvent(md);
    expect(md.defaultPrevented).toBe(true);
  });
  // The tab bar's pick reads the tab its `onClosed` forgets: a pick must run while the menu is still
  // its own. Safe in a browser only because `toggle` fires a task later; the stub fires it at once.
  it("a pick is told BEFORE the menu closes", () => {
    const order: string[] = [];
    const m = new ContextMenu(ac.signal, (a) => order.push(`pick ${a}`), () => order.push("closed"));
    m.open([{ action: "a", label: "A" }], null, { x: 0, y: 0 });
    document.querySelector<HTMLButtonElement>('.ctx-menu-item[data-action="a"]')!.click();
    expect(order).toEqual(["pick a", "closed"]);
  });
  it("ONE MENU AT A TIME: opening one closes any other", () => {
    const other = new ContextMenu(ac.signal, () => {});
    menu.open([{ action: "a", label: "A" }], null, { x: 0, y: 0 });
    other.open([{ action: "b", label: "B" }], null, { x: 0, y: 0 });
    expect([menu.isOpen, other.isOpen]).toEqual([false, true]);
    expect(closed).toBe(1);
    menu.open([{ action: "a", label: "A" }], null, { x: 0, y: 0 });
    expect([menu.isOpen, other.isOpen]).toEqual([true, false]);
    // A menu whose session ended is no longer one to close.
    const gone = new AbortController();
    const third = new ContextMenu(gone.signal, () => {});
    third.open([{ action: "c", label: "C" }], null, { x: 0, y: 0 });
    expect(menu.isOpen).toBe(false);
    gone.abort();
    expect(() => menu.open([{ action: "a", label: "A" }], null, { x: 0, y: 0 })).not.toThrow();
    expect(menu.isOpen).toBe(true);
  });
  // THE PRESS THAT CLOSES A MENU IS SWALLOWED WHOLE (asked for 2026-10-01): it must not also switch a tab, put
  // the caret in the terminal, press a strip key or click through a window's picture onto the Mac.
  describe("the press that closes it", () => {
    let below: HTMLElement; let seen: string[];
    const KINDS = ["pointerdown", "pointermove", "pointerup", "pointercancel", "touchstart", "touchmove", "touchend",
                   "mousedown", "mouseup", "click", "dblclick", "auxclick", "contextmenu"];
    beforeEach(() => {
      seen = [];
      below = document.createElement("div");
      document.body.append(below);
      // Every place a listener can sit below the window's capture phase: the document's capture, the element
      // itself, the document's bubble.
      for (const t of KINDS) {
        document.addEventListener(t, () => seen.push(`doc-capture ${t}`), { capture: true, signal: ac.signal });
        below.addEventListener(t, () => seen.push(t), { signal: ac.signal });
        document.addEventListener(t, () => seen.push(`doc ${t}`), { signal: ac.signal });
      }
    });
    afterEach(() => vi.useRealTimers());

    const fire = (type: string, o: { id?: number; kind?: string; button?: number } = {}) => {
      const e = type.startsWith("touch") ? new Event(type, { bubbles: true, cancelable: true })
        : new MouseEvent(type, { bubbles: true, cancelable: true, detail: 1, button: o.button ?? 0 });
      if (type.startsWith("pointer")) {
        Object.defineProperty(e, "pointerId", { value: o.id ?? 1 });
        Object.defineProperty(e, "pointerType", { value: o.kind ?? "mouse" });
      }
      below.dispatchEvent(e);
      return e;
    };
    const open = () => menu.open([{ action: "a", label: "A" }], null, { x: 0, y: 0 });

    it("a mouse press: closed, and nothing below the window's capture sees any of it", () => {
      open();
      const down = fire("pointerdown");
      expect(menu.isOpen).toBe(false);
      const md = fire("mousedown");
      fire("pointermove");
      fire("pointerup");
      fire("mouseup");
      const click = fire("click");
      expect(seen).toEqual([]);
      // Prevented: no compatibility mouse events, no focus moved by the mousedown, no button activated.
      expect([down.defaultPrevented, md.defaultPrevented, click.defaultPrevented]).toEqual([true, true, true]);
    });
    it("a right-click: no browser menu and no other menu", () => {
      open();
      fire("pointerdown", { button: 2 });
      const cm = fire("contextmenu", { button: 2 });
      fire("pointerup", { button: 2 });
      fire("auxclick", { button: 2 });
      expect(seen).toEqual([]);
      expect(cm.defaultPrevented).toBe(true);
    });
    it("a finger: its touches too, the release PREVENTED, and the mouse events iOS synthesizes late", () => {
      vi.useFakeTimers();
      open();
      fire("pointerdown", { id: 7, kind: "touch" });
      fire("touchstart");
      fire("pointermove", { id: 7, kind: "touch" });
      fire("touchmove");
      fire("pointerup", { id: 7, kind: "touch" });
      const te = fire("touchend");
      expect(te.defaultPrevented).toBe(true);
      vi.advanceTimersByTime(CLICK_SWALLOW_MS - 50);
      fire("mousedown");
      fire("mouseup");
      fire("click");
      expect(seen).toEqual([]);
    });
    it("a cancelled finger (the browser took the swipe) is swallowed the same way", () => {
      open();
      fire("pointerdown", { id: 7, kind: "touch" });
      fire("pointercancel", { id: 7, kind: "touch" });
      fire("touchend");
      expect(seen).toEqual([]);
    });
    it("the window ends: a late click after CLICK_SWALLOW_MS is its own", () => {
      vi.useFakeTimers();
      open();
      fire("pointerdown", { id: 7, kind: "touch" });
      fire("pointerup", { id: 7, kind: "touch" });
      vi.advanceTimersByTime(CLICK_SWALLOW_MS + 1);
      fire("click");
      expect(seen).toEqual(["doc-capture click", "click", "doc click"]);
    });
    it("only ONE click is the press's", () => {
      open();
      fire("pointerdown");
      fire("pointerup");
      fire("click");
      fire("click");          // a keyboard's or a script's, in the same instant
      expect(seen).toEqual(["doc-capture click", "click", "doc click"]);
    });
    it("THE NEXT REAL PRESS ENDS IT AT ONCE, and is not swallowed", () => {
      open();
      fire("pointerdown", { id: 7, kind: "touch" });
      fire("pointerup", { id: 7, kind: "touch" });
      fire("touchend");
      fire("pointerdown", { id: 8, kind: "touch" });
      fire("pointerup", { id: 8, kind: "touch" });
      fire("click");
      expect(seen.filter((s) => !s.startsWith("doc"))).toEqual(["pointerdown", "pointerup", "click"]);
    });
    // Review finding (2026-10-02): a key or another finger DURING the held press ended the swallow, and the
    // press's own release and click then acted — a tab switched, the terminal focused.
    it("a key while the press is still DOWN does not end it: its release and click are still swallowed", () => {
      open();
      fire("pointerdown");
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "Shift" }));
      fire("pointerup");
      fire("mouseup");
      const click = fire("click");
      expect(seen).toEqual([]);
      expect(click.defaultPrevented).toBe(true);
    });
    it("ANOTHER finger landing while it is down is the press's too: neither finger's events act", () => {
      open();
      fire("pointerdown", { id: 7, kind: "touch" });
      const second = fire("pointerdown", { id: 8, kind: "touch" });
      fire("touchstart");
      fire("pointermove", { id: 8, kind: "touch" });
      fire("pointerup", { id: 8, kind: "touch" });
      fire("pointermove", { id: 7, kind: "touch" });
      fire("pointerup", { id: 7, kind: "touch" });
      fire("touchend");
      fire("click");
      expect(seen).toEqual([]);
      expect(second.defaultPrevented).toBe(true);
    });
    it("a finger still down when the first lifts keeps its release swallowed", () => {
      open();
      fire("pointerdown", { id: 7, kind: "touch" });
      fire("pointerdown", { id: 8, kind: "touch" });
      fire("pointerup", { id: 7, kind: "touch" });
      fire("pointermove", { id: 8, kind: "touch" });
      fire("pointerup", { id: 8, kind: "touch" });
      expect(seen).toEqual([]);
    });
    it("AFTER the release a key ends it, and so does a blur at any time (a release that never came)", () => {
      open();
      fire("pointerdown");
      fire("pointerup");
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
      fire("click");                            // the key's own activation, inside the window
      expect(seen.filter((s) => !s.startsWith("doc"))).toEqual(["click"]);
      seen.length = 0;
      open();
      fire("pointerdown");                      // its pointerup never comes
      window.dispatchEvent(new Event("blur"));
      fire("click");
      expect(seen.filter((s) => !s.startsWith("doc"))).toEqual(["click"]);
    });
    it("a press with no menu open, and a press ON the menu, reach everything", () => {
      fire("pointerdown");
      fire("click");
      expect(seen.filter((s) => !s.startsWith("doc"))).toEqual(["pointerdown", "click"]);
      open();
      const item = document.querySelector<HTMLButtonElement>(".ctx-menu-item")!;
      const seenOnItem: string[] = [];
      item.addEventListener("pointerdown", () => seenOnItem.push("pointerdown"));
      const pd = new MouseEvent("pointerdown", { bubbles: true, cancelable: true });
      item.dispatchEvent(pd);
      expect(seenOnItem).toEqual(["pointerdown"]);
      expect(menu.isOpen).toBe(true);
    });
  });
  it("menuPosition still keeps the menu inside the visible area", () => {
    expect(menuPosition({ left: 0, top: 0, right: 10, bottom: 10 }, { width: 100, height: 50 }, { left: 0, top: 0, width: 300, height: 300 }, { x: 290, y: 290 }))
      .toEqual({ left: 192, top: 242 });
  });
  it("a selection's menu goes ABOVE its anchor, clear by the gap — below only without room", () => {
    const view = { left: 0, top: 0, width: 400, height: 400 };
    expect(menuPosition({ left: 50, top: 200, right: 90, bottom: 216 }, { width: 100, height: 60 }, view, undefined, { above: true, gap: 22 }))
      .toEqual({ left: 50, top: 118 });
    expect(menuPosition({ left: 50, top: 40, right: 90, bottom: 56 }, { width: 100, height: 60 }, view, undefined, { above: true, gap: 22 }),
           "no room above: below, the same gap").toEqual({ left: 50, top: 78 });
  });
  it("a PASS-THROUGH press closes the menu and is not swallowed — the selection's handles (touch-selection.ts)", () => {
    const ac = new AbortController();
    const menu = new ContextMenu(ac.signal, () => {});
    const handle = document.createElement("div"), other = document.createElement("div");
    document.body.append(handle, other);
    const press = (el: Element) => {
      const e = new MouseEvent("pointerdown", { bubbles: true, cancelable: true });
      Object.defineProperty(e, "pointerId", { value: 9 });
      el.dispatchEvent(e);
      return e;
    };
    let seen = 0;
    handle.addEventListener("pointerdown", () => seen++);
    menu.open([{ action: "copy", label: "Copy" }], null, { x: 5, y: 5 }, { passThrough: (n) => n === handle });
    const through = press(handle);
    expect(menu.isOpen).toBe(false);
    expect(seen).toBe(1);
    expect(through.defaultPrevented).toBe(false);
    menu.open([{ action: "copy", label: "Copy" }], null, { x: 5, y: 5 }, { passThrough: (n) => n === handle });
    const swallowed = press(other);
    expect(menu.isOpen).toBe(false);
    expect(swallowed.defaultPrevented, "anywhere else: swallowed whole, as before").toBe(true);
    ac.abort();
  });
});
