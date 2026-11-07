import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { isCopyChord, execCommandCopy, writeClipboard, installTerminalCopy, setNativeSelectionMirror, installSelectionMirror, type CopyResult } from "../src/client/terminal-copy";

const chord = (over: Partial<KeyboardEventInit> & { key: string }) => ({
  key: over.key, metaKey: !!over.metaKey, ctrlKey: !!over.ctrlKey,
  altKey: !!over.altKey, shiftKey: !!over.shiftKey,
});

describe("isCopyChord", () => {
  it("accepts Cmd+C (what iPadOS and macOS send)", () => {
    expect(isCopyChord(chord({ key: "c", metaKey: true }))).toBe(true);
    expect(isCopyChord(chord({ key: "C", metaKey: true, shiftKey: true }))).toBe(true);
  });

  it("accepts Ctrl+Shift+C", () => {
    expect(isCopyChord(chord({ key: "C", ctrlKey: true, shiftKey: true }))).toBe(true);
  });

  it("leaves plain Ctrl+C alone — that is SIGINT and must reach the shell", () => {
    expect(isCopyChord(chord({ key: "c", ctrlKey: true }))).toBe(false);
  });

  it("ignores other keys and Alt variants", () => {
    expect(isCopyChord(chord({ key: "v", metaKey: true }))).toBe(false);
    expect(isCopyChord(chord({ key: "k", metaKey: true }))).toBe(false);
    expect(isCopyChord(chord({ key: "c" }))).toBe(false);
    expect(isCopyChord(chord({ key: "c", metaKey: true, altKey: true }))).toBe(false);
  });
});

describe("writeClipboard", () => {
  const original = navigator.clipboard;
  afterEach(() => {
    Object.defineProperty(navigator, "clipboard", { value: original, configurable: true });
    vi.restoreAllMocks();
  });
  const setClipboard = (value: unknown) =>
    Object.defineProperty(navigator, "clipboard", { value, configurable: true });

  it("uses the async clipboard API when it exists", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    setClipboard({ writeText });
    const results: CopyResult[] = [];
    writeClipboard("hello", (r) => results.push(r));
    await vi.waitFor(() => expect(results.length).toBe(1));
    expect(writeText).toHaveBeenCalledWith("hello");
    expect(results[0]).toMatchObject({ method: "async", ok: true, chars: 5 });
  });

  it("falls back to execCommand on an insecure origin (no navigator.clipboard)", () => {
    setClipboard(undefined);
    const exec = vi.fn().mockReturnValue(true);
    Object.defineProperty(document, "execCommand", { value: exec, configurable: true });
    const results: CopyResult[] = [];
    writeClipboard("hello", (r) => results.push(r));
    expect(exec).toHaveBeenCalledWith("copy");
    expect(results[0]).toMatchObject({ method: "exec", ok: true });
  });

  it("falls back to execCommand when the async write is refused", async () => {
    setClipboard({ writeText: vi.fn().mockRejectedValue(new Error("denied")) });
    const exec = vi.fn().mockReturnValue(true);
    Object.defineProperty(document, "execCommand", { value: exec, configurable: true });
    const results: CopyResult[] = [];
    writeClipboard("hello", (r) => results.push(r));
    await vi.waitFor(() => expect(results.length).toBe(1));
    expect(results[0]).toMatchObject({ method: "exec", ok: true, error: expect.stringContaining("denied") });
  });
});

describe("execCommandCopy", () => {
  beforeEach(() => {
    Object.defineProperty(document, "execCommand", { value: vi.fn().mockReturnValue(true), configurable: true });
  });

  it("leaves no scratch node behind and restores focus to the terminal's textarea", () => {
    const ta = document.createElement("textarea");
    document.body.appendChild(ta);
    ta.focus();
    const before = document.querySelectorAll("textarea").length;
    expect(execCommandCopy("some selection")).toBe(true);
    expect(document.querySelectorAll("textarea").length).toBe(before);
    expect(document.activeElement).toBe(ta);
    ta.remove();
  });
});

describe("installTerminalCopy", () => {
  let el: HTMLElement;
  beforeEach(() => {
    el = document.createElement("div");
    document.body.appendChild(el);
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: vi.fn().mockResolvedValue(undefined) }, configurable: true,
    });
  });
  afterEach(() => { el.remove(); vi.restoreAllMocks(); });

  const press = (init: KeyboardEventInit, target: EventTarget = el) =>
    target.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));

  it("copies the selection on Cmd+C", async () => {
    const results: CopyResult[] = [];
    installTerminalCopy(el, { hasSelection: () => true, getSelection: () => "selected text", onResult: (r) => results.push(r) });
    press({ key: "c", metaKey: true });
    await vi.waitFor(() => expect(results.length).toBe(1));
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("selected text");
  });

  it("sees the chord even when it targets the helper textarea INSIDE the terminal", async () => {
    const inner = document.createElement("textarea");
    el.appendChild(inner);
    const results: CopyResult[] = [];
    installTerminalCopy(el, { hasSelection: () => true, getSelection: () => "abc", onResult: (r) => results.push(r) });
    press({ key: "c", metaKey: true }, inner);
    await vi.waitFor(() => expect(results.length).toBe(1));
  });

  it("does not preventDefault — a browser whose native copy works must keep working", () => {
    installTerminalCopy(el, { hasSelection: () => true, getSelection: () => "abc" });
    const e = new KeyboardEvent("keydown", { key: "c", metaKey: true, bubbles: true, cancelable: true });
    el.dispatchEvent(e);
    expect(e.defaultPrevented).toBe(false);
  });

  it("is a no-op with no selection, or an empty one", () => {
    installTerminalCopy(el, { hasSelection: () => false, getSelection: () => "abc" });
    press({ key: "c", metaKey: true });
    expect(navigator.clipboard.writeText).not.toHaveBeenCalled();
    installTerminalCopy(el, { hasSelection: () => true, getSelection: () => "" });
    press({ key: "c", metaKey: true });
    expect(navigator.clipboard.writeText).not.toHaveBeenCalled();
  });

  it("stops listening once disposed", () => {
    const dispose = installTerminalCopy(el, { hasSelection: () => true, getSelection: () => "abc" });
    dispose();
    press({ key: "c", metaKey: true });
    expect(navigator.clipboard.writeText).not.toHaveBeenCalled();
  });
});

describe("setNativeSelectionMirror / installSelectionMirror", () => {
  it("puts the selection in the FOCUSED helper textarea and selects it", () => {
    const ta = document.createElement("textarea");
    document.body.appendChild(ta);
    ta.focus();
    expect(setNativeSelectionMirror(ta, "hello world")).toBe(true);
    expect(ta.value).toBe("hello world");
    expect(ta.selectionStart).toBe(0);
    expect(ta.selectionEnd).toBe("hello world".length);
    expect(setNativeSelectionMirror(ta, "")).toBe(true);
    expect(ta.value).toBe("");
    ta.remove();
  });

  it("is a no-op when xterm has no textarea yet", () => {
    expect(setNativeSelectionMirror(undefined, "x")).toBe(false);
  });

  it("an UNFOCUSED textarea gets no mirror and NO FOCUS — select() focuses, and on a phone that raises the keyboard", () => {
    const button = document.createElement("button");
    const ta = document.createElement("textarea");
    document.body.append(button, ta);
    button.focus();
    ta.value = "a stale mirror";
    expect(setNativeSelectionMirror(ta, "a finger's selection")).toBe(false);
    expect(document.activeElement, "focus stays where it was").toBe(button);
    expect(ta.value, "the stale mirror cleared — xterm.js's IME path reads it").toBe("");
    button.remove(); ta.remove();
  });

  it("follows the selection, and syncs once up front", () => {
    const ta = document.createElement("textarea");
    document.body.appendChild(ta);
    let selection = "first";
    let fire = () => {};
    ta.focus();
    const dispose = installSelectionMirror({
      textarea: () => ta,
      getSelection: () => selection,
      subscribe: (cb) => { fire = cb; return { dispose: () => { fire = () => {}; } }; },
    });
    expect(ta.value).toBe("first");          // synced immediately, not only on the next change
    selection = "second";
    fire();
    expect(ta.value).toBe("second");
    selection = "";
    fire();
    expect(ta.value).toBe("");               // selection cleared -> mirror cleared
    dispose();
    ta.remove();
  });

  it("clears the mirror when the user types, so xterm's IME path can never send it", () => {
    const el = document.createElement("div");
    const ta = document.createElement("textarea");
    el.appendChild(ta);
    document.body.appendChild(el);
    ta.focus();
    setNativeSelectionMirror(ta, "mirrored selection");
    expect(ta.value).toBe("mirrored selection");
    installTerminalCopy(el, { hasSelection: () => true, getSelection: () => "mirrored selection", textarea: () => ta });
    el.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true }));
    expect(ta.value).toBe("");
    el.remove();
  });

  it("does NOT clear mid-composition — that value belongs to xterm then", () => {
    const el = document.createElement("div");
    const ta = document.createElement("textarea");
    el.appendChild(ta);
    document.body.appendChild(el);
    installTerminalCopy(el, { hasSelection: () => true, getSelection: () => "x", textarea: () => ta });
    el.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    ta.value = "\u3053\u3093";
    el.dispatchEvent(new KeyboardEvent("keydown", { key: "n", bubbles: true }));
    expect(ta.value).toBe("\u3053\u3093");
    el.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }));
    el.remove();
  });

  it("keeps the mirror intact for the copy chord itself", () => {
    const el = document.createElement("div");
    const ta = document.createElement("textarea");
    el.appendChild(ta);
    document.body.appendChild(el);
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: vi.fn().mockResolvedValue(undefined) }, configurable: true,
    });
    installTerminalCopy(el, { hasSelection: () => true, getSelection: () => "the selection", textarea: () => ta });
    ta.focus();                                    // ⌘C reaches the focused textarea
    ta.dispatchEvent(new KeyboardEvent("keydown", { key: "c", metaKey: true, bubbles: true }));
    expect(ta.value).toBe("the selection");
    el.remove();
  });
});
