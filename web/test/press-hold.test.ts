// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { attachPressHold, HOLD_MS, TOUCH_SLOP_PX } from "../src/client/press-hold";

/// jsdom has no PointerEvent: a MouseEvent of the pointer type, with the pointer's fields on it.
const ptr = (type: string, x: number, y: number, o: { pointerType?: string; pointerId?: number; isPrimary?: boolean } = {}) => {
  const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y });
  const f = { pointerId: 7, pointerType: "touch", isPrimary: true, ...o };
  for (const [k, v] of Object.entries(f)) Object.defineProperty(e, k, { value: v });
  return e as PointerEvent;
};

describe("attachPressHold — §2.2", () => {
  let ac: AbortController; let el: HTMLElement; let child: HTMLElement; let holds: { x: number; y: number }[];
  beforeEach(() => {
    vi.useFakeTimers();
    ac = new AbortController(); holds = [];
    el = document.createElement("div"); child = document.createElement("span"); el.append(child); document.body.append(el);
    attachPressHold(el, { accepts: () => true, onHold: (at) => holds.push(at) }, ac.signal);
  });
  afterEach(() => { ac.abort(); vi.useRealTimers(); document.body.innerHTML = ""; });

  it("a still finger for 500 ms holds, at where it went down", () => {
    child.dispatchEvent(ptr("pointerdown", 50, 60));
    vi.advanceTimersByTime(HOLD_MS - 1); expect(holds).toEqual([]);
    vi.advanceTimersByTime(1); expect(holds).toEqual([{ x: 50, y: 60 }]);
  });
  it("a move past the slop first is a scroll: no hold", () => {
    child.dispatchEvent(ptr("pointerdown", 50, 60));
    window.dispatchEvent(ptr("pointermove", 50, 60 + TOUCH_SLOP_PX + 1));
    vi.advanceTimersByTime(HOLD_MS * 2);
    expect(holds).toEqual([]);
  });
  it("a wobble inside the slop still holds", () => {
    child.dispatchEvent(ptr("pointerdown", 50, 60));
    window.dispatchEvent(ptr("pointermove", 55, 66));
    vi.advanceTimersByTime(HOLD_MS);
    expect(holds.length).toBe(1);
  });
  it("a mouse never holds, and a second finger cancels", () => {
    child.dispatchEvent(ptr("pointerdown", 1, 1, { pointerType: "mouse" }));
    vi.advanceTimersByTime(HOLD_MS); expect(holds).toEqual([]);
    child.dispatchEvent(ptr("pointerdown", 1, 1));
    child.dispatchEvent(ptr("pointerdown", 9, 9, { pointerId: 8, isPrimary: false }));
    vi.advanceTimersByTime(HOLD_MS); expect(holds).toEqual([]);
  });
  it("once held: moves are swallowed, the release synthesizes nothing, its click is swallowed — and the NEXT tap is real", () => {
    const below = vi.fn(); el.addEventListener("touchmove", below); el.addEventListener("pointermove", below);
    const clicks = vi.fn(); el.addEventListener("click", clicks);
    child.dispatchEvent(ptr("pointerdown", 50, 60));
    vi.advanceTimersByTime(HOLD_MS);
    const tm = new Event("touchmove", { bubbles: true, cancelable: true }); child.dispatchEvent(tm);
    expect(tm.defaultPrevented).toBe(true);
    child.dispatchEvent(ptr("pointermove", 80, 90));
    expect(below).not.toHaveBeenCalled();
    window.dispatchEvent(ptr("pointerup", 50, 60));
    const te = new Event("touchend", { bubbles: true, cancelable: true }); child.dispatchEvent(te);
    expect(te.defaultPrevented).toBe(true);
    child.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    expect(clicks).not.toHaveBeenCalled();
    child.dispatchEvent(ptr("pointerdown", 5, 5)); window.dispatchEvent(ptr("pointerup", 5, 5));
    child.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    expect(clicks).toHaveBeenCalledTimes(1);
  });
  // Measured on iOS 26.5 (task 3, P6): a hold ends pointerdown -> pointerup with no cancel, and iOS still
  // synthesizes mousedown/mouseup/click after it. xterm.js turns that mousedown into a mouse report.
  it("after a held release the trailing mousedown and mouseup reach nothing; after a plain tap they do", () => {
    const seen = vi.fn(); el.addEventListener("mousedown", seen); el.addEventListener("mouseup", seen);
    const mouse = () => { for (const t of ["mousedown", "mouseup"]) child.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true })); };
    child.dispatchEvent(ptr("pointerdown", 50, 60));
    vi.advanceTimersByTime(HOLD_MS);
    window.dispatchEvent(ptr("pointerup", 50, 60));
    mouse();
    expect(seen).not.toHaveBeenCalled();
    child.dispatchEvent(ptr("pointerdown", 5, 5)); window.dispatchEvent(ptr("pointerup", 5, 5));
    mouse();
    expect(seen).toHaveBeenCalledTimes(2);
  });
  it("a press the caller does not accept never holds", () => {
    ac.abort(); ac = new AbortController();
    attachPressHold(el, { accepts: () => false, onHold: (at) => holds.push(at) }, ac.signal);
    child.dispatchEvent(ptr("pointerdown", 1, 1)); vi.advanceTimersByTime(HOLD_MS);
    expect(holds).toEqual([]);
  });
});
