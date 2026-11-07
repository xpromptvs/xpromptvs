import { afterEach, describe, expect, it, vi } from "vitest";
import { CLICK_SWALLOW_MS } from "../src/client/press-hold";
import { attachTouchScroll, touchScrollWheel, XTERM_PX_PER_NOTCH, type TouchScrollView } from "../src/client/touch-scroll";

describe("touchScrollWheel", () => {
  /// xterm.js 6 normalises wheel events with VS Code's StandardWheelEvent, which prefers the LEGACY
  /// `wheelDeltaY` (one notch = 120) and scrolls 50 px per notch. Left unset, WebKit derives it from
  /// `deltaY` (-1) and a one-line event scrolled 1/120 of a notch: 20 rows of finger drag scrolled ONE
  /// row on an iPhone (measured), and Chromium's +1 scrolled nothing. It must be set explicitly, to one
  /// ROW's worth, so a drag scrolls 1:1.
  it("carries one row of wheelDeltaY per event, signed opposite to deltaY", () => {
    const back = touchScrollWheel(1, 16, 10, 20);   // finger moved DOWN a row: scroll back
    expect(back.deltaY).toBe(-1);
    expect(back.deltaMode).toBe(1);
    expect(back.wheelDeltaY).toBe(Math.round(120 * 16 / XTERM_PX_PER_NOTCH));
    const fwd = touchScrollWheel(-1, 16, 10, 20);
    expect(fwd.deltaY).toBe(1);
    expect(fwd.wheelDeltaY).toBe(-Math.round(120 * 16 / XTERM_PX_PER_NOTCH));
  });

  it("keeps the finger's coordinates (mouse-tracking apps get the wheel at that cell)", () => {
    expect(touchScrollWheel(1, 18, 33, 44)).toMatchObject({ clientX: 33, clientY: 44, bubbles: true, cancelable: true });
  });

  it("never sends a zero wheelDeltaY, however small the row", () => {
    expect(Math.abs(touchScrollWheel(1, 0.1, 0, 0).wheelDeltaY)).toBeGreaterThanOrEqual(1);
  });
});

/// A touch event as the handler reads it: `touches` (every finger still down, ANYWHERE on the screen),
/// `changedTouches` (the fingers this event is about) and each finger's `identifier` and page point.
/// A finger's id defaults to its index; `changed` defaults to all of `fingers` (a lift passes it).
type Finger = { x: number; y: number; id?: number };
function touch(el: EventTarget, type: string, fingers: Finger[], changed?: Finger[]): Event {
  const ev = new Event(type, { bubbles: true, cancelable: true });
  const list = (fs: Finger[]) => fs.map((f, i) => ({ clientX: f.x, clientY: f.y, identifier: f.id ?? i }));
  Object.defineProperty(ev, "touches", { value: list(fingers) });
  Object.defineProperty(ev, "changedTouches", { value: list(changed ?? fingers) });
  el.dispatchEvent(ev);
  return ev;
}

/// The visible instance: its buffer and mouse mode, and a recording stand-in for its SmoothScroll.
function view(o: { smooth?: boolean; alt?: boolean; mouse?: string; gliding?: boolean } = {}) {
  const calls: string[] = [];
  const v = {
    term: { modes: { mouseTrackingMode: o.mouse ?? "none" }, buffer: { active: { type: o.alt ? "alternate" : "normal" } } },
    smooth: {
      enabled: o.smooth ?? true,
      gliding: o.gliding ?? false,
      hold: () => calls.push("hold"),
      drag: (dy: number) => calls.push(`drag ${dy}`),
      release: (v: number | null) => calls.push(v === null ? "release null" : `release ${v.toFixed(2)}`),
    },
  };
  return { v: v as unknown as TouchScrollView, calls };
}

function rig(v: TouchScrollView | null, rowPx = 20, pan?: (dy: number) => number) {
  const el = document.createElement("div");
  document.body.append(el);
  let t = 1000;
  let current = v;
  const wheels: WheelEvent[] = [];
  el.addEventListener("wheel", (e) => wheels.push(e as WheelEvent));
  const detach = attachTouchScroll(el, { view: () => current, rowHeight: () => rowPx, now: () => t, pan });
  return { el, wheels, detach, at: (ms: number) => { t = ms; }, show: (next: TouchScrollView | null) => { current = next; } };
}

describe("attachTouchScroll", () => {
  it("smooth: the scrollback follows the finger pixel for pixel, and the page does not scroll", () => {
    const { v, calls } = view();
    const { el, wheels } = rig(v);
    touch(el, "touchstart", [{ x: 5, y: 100 }]);
    const move = touch(el, "touchmove", [{ x: 5, y: 107 }]);   // finger DOWN 7 px: scroll BACK 7 px
    touch(el, "touchmove", [{ x: 5, y: 104 }]);
    expect(calls).toEqual(["hold", "drag -7", "drag 3"]);
    expect(move.defaultPrevented).toBe(true);
    expect(wheels).toHaveLength(0);
  });

  it("smooth: a flick glides on at the finger's speed; a finger that stopped first does not", () => {
    const { v, calls } = view();
    const { el, at } = rig(v);
    at(1000); touch(el, "touchstart", [{ x: 0, y: 100 }]);
    for (let i = 1; i <= 5; i++) { at(1000 + i * 10); touch(el, "touchmove", [{ x: 0, y: 100 + i * 20 }]); }
    at(1055); touch(el, "touchend", []);
    expect(calls.at(-1)).toBe("release -2.00");   // 20 px per 10 ms, finger down: back at 2 px/ms

    calls.length = 0;
    at(2000); touch(el, "touchstart", [{ x: 0, y: 100 }]);
    at(2010); touch(el, "touchmove", [{ x: 0, y: 140 }]);
    at(2500); touch(el, "touchend", []);          // held still for half a second, then lifted
    expect(calls.at(-1)).toBe("release null");
  });

  it("smooth: a touch stops a glide in progress (hold), and a cancel never flings", () => {
    const { v, calls } = view();
    const { el, at } = rig(v);
    at(1000); touch(el, "touchstart", [{ x: 0, y: 100 }]);
    at(1010); touch(el, "touchmove", [{ x: 0, y: 140 }]);
    at(1015); touch(el, "touchcancel", []);
    expect(calls).toEqual(["hold", "drag -40", "release null"]);
  });

  it("off: one wheel event per row of drag, as before, and the smooth controller is never driven", () => {
    const { v, calls } = view({ smooth: false });
    const { el, wheels } = rig(v, 20);
    touch(el, "touchstart", [{ x: 0, y: 100 }]);
    touch(el, "touchmove", [{ x: 0, y: 145 }]);   // 2.25 rows
    expect(wheels).toHaveLength(2);
    expect(wheels.every((w) => w.deltaMode === 1 && w.deltaY === -1)).toBe(true);
    touch(el, "touchend", []);
    expect(calls).toEqual([]);
  });

  it("smooth, but an app owns the wheel (alt screen, mouse tracking): rows as before", () => {
    for (const o of [{ alt: true }, { mouse: "vt200" }, { mouse: "any" }]) {
      const { v, calls } = view(o);
      const { el, wheels } = rig(v, 20);
      touch(el, "touchstart", [{ x: 0, y: 100 }]);
      touch(el, "touchmove", [{ x: 0, y: 60 }]);
      expect(wheels).toHaveLength(2);
      expect(calls.filter((c) => c.startsWith("drag"))).toEqual([]);
    }
  });

  // THE KEYBOARD'S SHIFTED VIEW PANS FIRST over a full-screen app (keyboard-shift.ts's panBy, wired as `pan`): the
  // drag's px go to it until it cannot pan further, and only the rest becomes rows for the app.
  it("rows: a pan that can take the drag takes it first; the app gets only the rest", () => {
    const { v } = view({ alt: true });
    let room = 30;
    const seen: number[] = [];
    const pan = (dy: number) => { seen.push(dy); const used = Math.sign(dy) * Math.min(Math.abs(dy), room); room -= Math.abs(used); return dy - used; };
    const { el, wheels } = rig(v, 20, pan);
    touch(el, "touchstart", [{ x: 0, y: 200 }]);
    touch(el, "touchmove", [{ x: 0, y: 160 }]);    // 40 px up: 30 pan the view, 10 left — not yet a row
    expect(wheels, "the view took the drag first").toHaveLength(0);
    touch(el, "touchmove", [{ x: 0, y: 120 }]);    // 40 more, nothing left to pan: 50 px for the app, 2 rows
    expect(wheels).toHaveLength(2);
    expect(wheels.every((w) => w.deltaY > 0), "forward, as a drag up is").toBe(true);
    expect(seen).toEqual([-40, -40]);
  });

  it("smooth: the scrolling finger's lift ends the gesture even while another finger rests elsewhere", () => {
    // A finger on the key strip (or a palm on an iPad) is in `touches` for the whole page; the terminal
    // finger's own lift must still release, or nothing settles again until the next touch (review M1).
    const { v, calls } = view();
    const { el, at } = rig(v);
    at(1000); touch(el, "touchstart", [{ x: 0, y: 100, id: 7 }]);
    at(1010); touch(el, "touchmove", [{ x: 0, y: 130, id: 7 }, { x: 0, y: 900, id: 9 }]);
    at(1015); touch(el, "touchend", [{ x: 0, y: 900, id: 9 }], [{ x: 0, y: 130, id: 7 }]);
    expect(calls.at(-1)?.startsWith("release")).toBe(true);
  });

  it("smooth: a view that changes mid-gesture hands the finger over — the old one released, the new one held", () => {
    const a = view(), b = view();
    const { el, at, show } = rig(a.v);
    at(1000); touch(el, "touchstart", [{ x: 0, y: 100 }]);
    at(1010); touch(el, "touchmove", [{ x: 0, y: 110 }]);
    show(b.v);                                   // a snapshot swapped a fresh instance in, or the tab changed
    at(1020); touch(el, "touchmove", [{ x: 0, y: 140 }]);
    at(1500); touch(el, "touchend", []);
    expect(a.calls).toEqual(["hold", "drag -10", "release null"]);
    expect(b.calls).toEqual(["hold", "drag -30", "release null"]);
  });

  it("rows: a view that changes mid-gesture keeps the rows coming (an app owns the wheel)", () => {
    // Second review, M-d: with the option on over a TUI the finger drives rows, not the controller, and
    // a change of instance must not end that.
    const a = view({ alt: true }), b = view({ alt: true });
    const { el, wheels, show } = rig(a.v, 20);
    touch(el, "touchstart", [{ x: 0, y: 100 }]);
    touch(el, "touchmove", [{ x: 0, y: 120 }]);
    show(b.v);
    touch(el, "touchmove", [{ x: 0, y: 160 }]);
    expect(wheels).toHaveLength(3);
  });

  it("two fingers scroll nothing", () => {
    const { v, calls } = view();
    const { el, wheels } = rig(v);
    touch(el, "touchstart", [{ x: 0, y: 100 }, { x: 50, y: 100 }]);
    touch(el, "touchmove", [{ x: 0, y: 160 }, { x: 50, y: 160 }]);
    expect(wheels).toHaveLength(0);
    expect(calls.filter((c) => c.startsWith("drag"))).toEqual([]);
  });

  it("with no terminal visible, a drag does nothing and throws nothing", () => {
    const { el, wheels } = rig(null);
    touch(el, "touchstart", [{ x: 0, y: 100 }]);
    touch(el, "touchmove", [{ x: 0, y: 160 }]);
    touch(el, "touchend", []);
    expect(wheels).toHaveLength(3);   // 60 px at 20 px rows, dispatched on the surface as before
  });

  describe("the tap that stops a glide only stops it", () => {
    afterEach(() => { vi.useRealTimers(); });
    /// xterm.js's own listener: on its screen, INSIDE the surface — it focuses the textarea on `mousedown`.
    function terminalScreen(el: HTMLElement) {
      const screen = document.createElement("div");
      el.append(screen);
      const heard: string[] = [];
      for (const type of ["mousedown", "mouseup", "click"]) screen.addEventListener(type, () => heard.push(type));
      const mouse = (type: string) => screen.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true }));
      return { heard, mouse };
    }

    it("its touchend is prevented and the mouse events iOS synthesizes for it never reach xterm.js — no focus, no keyboard", () => {
      const { v, calls } = view({ gliding: true });
      const { el } = rig(v);
      const { heard, mouse } = terminalScreen(el);
      touch(el, "touchstart", [{ x: 5, y: 100 }]);
      const lift = touch(el, "touchend", [], [{ x: 5, y: 100 }]);
      mouse("mousedown"); mouse("mouseup"); mouse("click");
      expect(calls[0]).toBe("hold");              // the glide stopped
      expect(lift.defaultPrevented).toBe(true);
      expect(heard).toEqual([]);
      mouse("mousedown");                         // after its click, the next is a real one
      expect(heard).toEqual(["mousedown"]);
    });

    it("a tap with no glide is a tap: nothing prevented, xterm.js hears it (the keyboard comes up as ever)", () => {
      const { v } = view({ gliding: false });
      const { el } = rig(v);
      const { heard, mouse } = terminalScreen(el);
      touch(el, "touchstart", [{ x: 5, y: 100 }]);
      const lift = touch(el, "touchend", [], [{ x: 5, y: 100 }]);
      mouse("mousedown"); mouse("mouseup"); mouse("click");
      expect(lift.defaultPrevented).toBe(false);
      expect(heard).toEqual(["mousedown", "mouseup", "click"]);
    });

    it("the swallow lasts CLICK_SWALLOW_MS, and the next press ends it at once", () => {
      vi.useFakeTimers();
      const { v } = view({ gliding: true });
      const { el } = rig(v);
      const { heard, mouse } = terminalScreen(el);
      touch(el, "touchstart", [{ x: 5, y: 100 }]);
      touch(el, "touchend", [], [{ x: 5, y: 100 }]);
      vi.advanceTimersByTime(CLICK_SWALLOW_MS - 50);
      mouse("mousedown");
      expect(heard).toEqual([]);
      vi.advanceTimersByTime(100);
      mouse("mouseup");
      expect(heard).toEqual(["mouseup"]);

      heard.length = 0;
      touch(el, "touchstart", [{ x: 5, y: 100 }]);
      touch(el, "touchend", [], [{ x: 5, y: 100 }]);
      (v.smooth as { gliding: boolean }).gliding = false;
      touch(el, "touchstart", [{ x: 5, y: 100 }]);   // a new press, on a still scrollback
      mouse("mousedown");
      expect(heard).toEqual(["mousedown"]);
    });

    it("a finger that lands on a glide and drags on still scrolls", () => {
      const { v, calls } = view({ gliding: true });
      const { el } = rig(v);
      touch(el, "touchstart", [{ x: 5, y: 100 }]);
      touch(el, "touchmove", [{ x: 5, y: 110 }]);
      expect(calls).toEqual(["hold", "drag -10"]);
    });
  });

  it("detached, listens to nothing", () => {
    const { v, calls } = view();
    const { el, detach } = rig(v);
    detach();
    touch(el, "touchstart", [{ x: 0, y: 100 }]);
    touch(el, "touchmove", [{ x: 0, y: 160 }]);
    expect(calls).toEqual([]);
  });
});

