// The soft keyboard's text is SENT at `beforeinput`, never inserted into xterm.js's helper textarea
// (docs/client-web.md, "Shake to Undo"). Every insertion there was an undoable edit, so iOS's Shake to
// Undo offered "Undo Typing" over the terminal. Exactly the text xterm.js's own `_inputEvent` would have
// sent is taken, and nothing else: its rule (a plain `insertText`, no key held, not composing, no screen
// reader) is the one mirrored here. A browser measures the undo history itself: e2e/term-undo-check.mjs.
import { beforeAll, describe, expect, it } from "vitest";
import { mountXterm, type XtermView } from "../src/client/xterm-view";

beforeAll(() => {
  (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
});

function rig(): { v: XtermView; ta: HTMLTextAreaElement; data: string[] } {
  const el = document.createElement("div");
  document.body.append(el);
  const data: string[] = [];
  const v = mountXterm(el, { onData: (d) => data.push(d), onFit: () => {}, theme: "dark" });
  return { v, ta: v.term.textarea!, data };
}

/// What a soft keyboard's commit dispatches first; `true` when a listener cancelled it.
function beforeInput(ta: HTMLTextAreaElement, init: InputEventInit): boolean {
  const e = new InputEvent("beforeinput", { bubbles: true, cancelable: true, ...init });
  ta.dispatchEvent(e);
  return e.defaultPrevented;
}

describe("the soft keyboard's text", () => {
  it("is sent once and never inserted: the textarea keeps no undo history", () => {
    const { v, ta, data } = rig();
    expect(beforeInput(ta, { inputType: "insertText", data: "abc" })).toBe(true);
    expect(beforeInput(ta, { inputType: "insertText", data: "dictated words" })).toBe(true);
    expect(data).toEqual(["abc", "dictated words"]);
    v.dispose();
  });

  it("is left to the key events while a key is held, as xterm.js leaves it (its keypress sends it)", () => {
    const { v, ta, data } = rig();
    ta.dispatchEvent(new KeyboardEvent("keydown", { key: "Unidentified", bubbles: true }));
    expect(beforeInput(ta, { inputType: "insertText", data: "x" })).toBe(false);
    ta.dispatchEvent(new KeyboardEvent("keyup", { key: "Unidentified", bubbles: true }));
    expect(beforeInput(ta, { inputType: "insertText", data: "y" })).toBe(true);
    expect(data).toEqual(["y"]);
    v.dispose();
  });

  it("leaves a composition, every other input type and a screen reader's textarea to xterm.js", () => {
    const { v, ta, data } = rig();
    expect(beforeInput(ta, { inputType: "insertText", data: "か", isComposing: true })).toBe(false);
    expect(beforeInput(ta, { inputType: "insertCompositionText", data: "か" })).toBe(false);
    expect(beforeInput(ta, { inputType: "insertReplacementText", data: "word" })).toBe(false);
    expect(beforeInput(ta, { inputType: "deleteContentBackward" })).toBe(false);
    expect(beforeInput(ta, { inputType: "insertText" })).toBe(false);                 // no data
    v.term.options.screenReaderMode = true;
    expect(beforeInput(ta, { inputType: "insertText", data: "z" })).toBe(false);
    expect(data).toEqual([]);
    v.dispose();
  });

  it("stops with the instance", () => {
    const { v, ta, data } = rig();
    v.dispose();
    expect(beforeInput(ta, { inputType: "insertText", data: "late" })).toBe(false);
    expect(data).toEqual([]);
  });
});
