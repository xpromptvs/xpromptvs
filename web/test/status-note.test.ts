// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { StatusNote, TOAST_MS, attachToast } from "../src/client/status-note";

/// A toast's notes (2026-10-02, asked): a MESSAGE goes after `TOAST_MS` — a failure too — and not while a
/// mouse is on it; a STATE (a paste's progress, a boot phase) stays until it is cleared or replaced; every
/// exit is ANIMATED, the text going only when the exit has ended.
describe("StatusNote", () => {
  let el: HTMLElement;
  let note: StatusNote;
  /// The exit `toast-out` would play: jsdom runs no CSS, so the test plays it — `end()` finishes it.
  let exits: Array<{ animationName: string; finished: Promise<unknown>; end: () => void }>;
  beforeEach(() => {
    vi.useFakeTimers();
    el = document.createElement("div");
    exits = [];
    (el as unknown as { getAnimations: () => unknown[] }).getAnimations = () => {
      if (!("leaving" in el.dataset)) return [];
      let end!: () => void;
      const finished = new Promise((res) => { end = () => res(undefined); });
      const a = { animationName: "toast-out", finished, end };
      exits.push(a);
      return [a];
    };
    note = new StatusNote(() => el, {
      setTimer: (fn, ms) => setTimeout(fn, ms),
      clearTimer: (t) => clearTimeout(t as ReturnType<typeof setTimeout>),
      now: () => Date.now(),
    });
  });
  afterEach(() => vi.useRealTimers());
  const leaving = () => "leaving" in el.dataset;
  const settle = async () => { for (let i = 0; i < 4; i++) await Promise.resolve(); };
  const endExit = async () => { exits.at(-1)?.end(); await settle(); };

  it("a message stays TOAST_MS, 6 s, then animates out: the text goes only when the exit has ended", async () => {
    expect(TOAST_MS).toBe(6000);
    note.flash("Dropped as a paste");
    vi.advanceTimersByTime(TOAST_MS - 1);
    expect(el.textContent).toBe("Dropped as a paste");
    expect(leaving()).toBe(false);
    vi.advanceTimersByTime(1);
    expect(leaving()).toBe(true);
    expect(el.textContent).toBe("Dropped as a paste");
    await endExit();
    expect(el.textContent).toBe("");
    expect(leaving()).toBe(false);
  });

  it("a failure is a message like any other: it goes after 6 s too", async () => {
    note.flash("Not pasted: the Mac could not save it");
    vi.advanceTimersByTime(TOAST_MS);
    await endExit();
    expect(el.textContent).toBe("");
  });

  it("a STATE stays until it is cleared, then animates out", async () => {
    const m = note.show("Sending IMG_0042.jpg — 40%");
    vi.advanceTimersByTime(TOAST_MS * 10);
    expect(el.textContent).toBe("Sending IMG_0042.jpg — 40%");
    expect(leaving()).toBe(false);
    note.clear(m);
    expect(leaving()).toBe(true);
    await endExit();
    expect(el.textContent).toBe("");
  });

  it("a mouse on the toast holds a message with no limit; the time it was held does not count", async () => {
    note.flash("tmux session ended");
    vi.advanceTimersByTime(4000);
    note.hold(true);
    vi.advanceTimersByTime(TOAST_MS * 10);
    expect(el.textContent).toBe("tmux session ended");
    expect(leaving()).toBe(false);
    note.hold(false);
    vi.advanceTimersByTime(1999);
    expect(leaving()).toBe(false);
    vi.advanceTimersByTime(1);
    expect(leaving()).toBe(true);
    await endExit();
    expect(el.textContent).toBe("");
  });

  it("a message that arrives under the mouse waits for it to leave, then has its whole 6 s", () => {
    note.hold(true);
    note.flash("Nothing to paste");
    vi.advanceTimersByTime(TOAST_MS * 3);
    expect(leaving()).toBe(false);
    note.hold(false);
    vi.advanceTimersByTime(TOAST_MS - 1);
    expect(leaving()).toBe(false);
    vi.advanceTimersByTime(1);
    expect(leaving()).toBe(true);
  });

  it("a note written while the last one leaves takes its place: the old exit's end clears nothing", async () => {
    note.flash("Dropped as a paste");
    vi.advanceTimersByTime(TOAST_MS);
    expect(leaving()).toBe(true);
    const old = exits.at(-1)!;
    note.show("Sending a.png — 10%");
    expect(leaving()).toBe(false);
    expect(el.textContent).toBe("Sending a.png — 10%");
    old.end();
    await settle();
    expect(el.textContent).toBe("Sending a.png — 10%");
  });

  it("the next note replaces a message, and the message's timer then clears nothing — in the same words too", () => {
    note.flash("Not pasted — try again");
    vi.advanceTimersByTime(TOAST_MS - 1000);
    note.show("Not pasted — try again");              // the same words, now a state
    vi.advanceTimersByTime(TOAST_MS);
    expect(el.textContent).toBe("Not pasted — try again");
    expect(leaving()).toBe(false);
  });

  it("a tap animates out whatever is shown — a message or a state — and its pending timer does nothing after", async () => {
    note.flash("Nothing to paste");
    note.dismiss();
    expect(leaving()).toBe(true);
    await endExit();
    expect(el.textContent).toBe("");
    note.show("booting…");
    note.dismiss();
    await endExit();
    expect(el.textContent).toBe("");
    note.show("attaching…");
    vi.advanceTimersByTime(TOAST_MS);                 // the first flash's timer, had it survived
    expect(el.textContent).toBe("attaching…");
    expect(leaving()).toBe(false);
  });

  it("clear(mark) takes away only the note that mark showed", () => {
    const stale = note.show("Sending a.png — 90%");
    note.flash("Not pasted: the Mac did not answer");
    note.clear(stale);
    expect(leaving()).toBe(false);
    expect(el.textContent).toBe("Not pasted: the Mac did not answer");
  });

  it("with no exit to play (reduced motion: no animation runs) the text goes at once", () => {
    (el as unknown as { getAnimations: () => unknown[] }).getAnimations = () => [];
    note.flash("Dropped as a paste");
    vi.advanceTimersByTime(TOAST_MS);
    expect(el.textContent).toBe("");
    expect(leaving()).toBe(false);
  });
});

describe("attachToast", () => {
  it("a mouse or a pen holds the toast while on it, a finger never does; a tap dismisses; a press moves no focus", () => {
    const el = document.createElement("div");
    const calls: string[] = [];
    const ac = new AbortController();
    attachToast(el, { hold: (on: boolean) => calls.push(`hold:${on}`), dismiss: () => calls.push("dismiss") }, ac.signal);
    const pe = (type: string, pointerType: string) => {
      const e = new Event(type) as Event & { pointerType: string };
      e.pointerType = pointerType;
      el.dispatchEvent(e);
    };
    pe("pointerenter", "mouse"); pe("pointerleave", "mouse");
    pe("pointerenter", "pen"); pe("pointerleave", "pen");
    pe("pointerenter", "touch"); pe("pointerleave", "touch");
    el.dispatchEvent(new MouseEvent("click"));
    expect(calls).toEqual(["hold:true", "hold:false", "hold:true", "hold:false", "dismiss"]);
    const down = new MouseEvent("mousedown", { cancelable: true });
    el.dispatchEvent(down);
    expect(down.defaultPrevented).toBe(true);
    ac.abort();
    el.dispatchEvent(new MouseEvent("click"));
    expect(calls.length).toBe(5);
  });
});
