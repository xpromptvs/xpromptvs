// TEXT-EDITING KEYS, AS A MAC'S TERMINALS SEND THEM (terminal-keys.ts, `textEditingBytes`; docs/terminal.md, "Text-editing
// keys"): ⌥/Ctrl + ← → are word motions (`ESC b` / `ESC f`), ⌘ + ← → the line's ends (`^A` / `^E`), ⌘⌫ deletes to the
// line's start (`^U`) — Ghostty's macOS defaults, Ctrl by decision — from the product's own terminal (`mountXterm`) and
// the touch strip alike. Reported 2026-10-06: xterm.js's `ESC [1;3D` / `ESC [1;5D` reached zsh, which binds only `^[b`,
// `^[f`, `^A`, `^E` and the plain arrows (measured on the dev Mac), and printed `;5D`.
import { beforeAll, describe, expect, it } from "vitest";
import { mountXterm } from "../src/client/xterm-view";
import { stripKeyBytes, TERMINAL_KEYS, textEditingBytes, type TermKeyDef } from "../src/client/terminal-keys";

beforeAll(() => {
  (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
});

type Mods = { alt?: boolean; shift?: boolean; ctrl?: boolean; meta?: boolean };
/// What the product's terminal sends for a keydown of `key` (`keyCode` as xterm.js reads it) under `mods`.
function press(key: string, keyCode: number, mods: Mods): { sent: string[]; prevented: boolean } {
  const el = document.createElement("div");
  document.body.append(el);
  const sent: string[] = [];
  const v = mountXterm(el, { onData: (d) => sent.push(d), onFit: () => {}, theme: "dark" });
  const ev = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, altKey: !!mods.alt, shiftKey: !!mods.shift, ctrlKey: !!mods.ctrl, metaKey: !!mods.meta });
  Object.defineProperty(ev, "keyCode", { get: () => keyCode });
  Object.defineProperty(ev, "which", { get: () => keyCode });
  v.term.textarea!.dispatchEvent(ev);
  const prevented = ev.defaultPrevented;
  v.dispose(); el.remove();
  return { sent, prevented };
}
const L = ["ArrowLeft", 37] as const, R = ["ArrowRight", 39] as const, BS = ["Backspace", 8] as const;

describe("text-editing keys", () => {
  it("⌥ or Ctrl with ← / → is a word back / forward: ESC b / ESC f, once, the key kept from the browser", () => {
    for (const mods of [{ alt: true }, { ctrl: true }]) {
      expect(press(...L, mods), JSON.stringify(mods)).toEqual({ sent: ["\x1bb"], prevented: true });
      expect(press(...R, mods), JSON.stringify(mods)).toEqual({ sent: ["\x1bf"], prevented: true });
    }
  });

  it("⌘ with ← / → is the line's start / end (^A / ^E), and ⌘⌫ deletes to its start (^U) — Ghostty's macOS defaults", () => {
    expect(press(...L, { meta: true })).toEqual({ sent: ["\x01"], prevented: true });
    expect(press(...R, { meta: true })).toEqual({ sent: ["\x05"], prevented: true });
    expect(press(...BS, { meta: true })).toEqual({ sent: ["\x15"], prevented: true });
  });

  it("anything else keeps xterm.js's own encoding — Shift+arrows among them", () => {
    expect(press(...L, {}).sent).toEqual(["\x1b[D"]);
    expect(press(...L, { shift: true }).sent, "Shift passes, as Ghostty passes it").toEqual(["\x1b[1;2D"]);
    expect(press(...L, { alt: true, shift: true }).sent).toEqual(["\x1b[1;4D"]);
    expect(press(...R, { ctrl: true, shift: true }).sent).toEqual(["\x1b[1;6C"]);
    expect(press("ArrowUp", 38, { alt: true }).sent, "only Left and Right").toEqual(["\x1b[1;3A"]);
    expect(press(...BS, {}).sent).toEqual(["\x7f"]);
    expect(press(...BS, { alt: true }).sent, "⌥⌫ stays ESC DEL, a word back deleted").toEqual(["\x1b\x7f"]);
  });

  it("the touch strip's Opt or Ctrl + ← / → send the same, in either cursor mode", () => {
    const key = (id: string) => TERMINAL_KEYS.find((d): d is TermKeyDef => d.kind === "key" && d.id === id)!;
    for (const appCursor of [false, true]) for (const mask of [4, 2]) {
      expect([stripKeyBytes(key("left"), appCursor, mask), stripKeyBytes(key("right"), appCursor, mask)], `mask ${mask}`).toEqual(["\x1bb", "\x1bf"]);
    }
    expect(stripKeyBytes(key("left"), false, 4 | 1), "Opt+⇧ keeps xterm.js's").toBe("\x1b[1;4D");
    expect(textEditingBytes("ArrowLeft", { alt: true, ctrl: true, shift: false, meta: false }), "two modifiers: none of these").toBeNull();
  });
});
