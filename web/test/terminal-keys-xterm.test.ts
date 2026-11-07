import { beforeAll, describe, expect, it } from "vitest";
import { Terminal } from "@xterm/xterm";
import { stripKeyBytes, TERMINAL_KEYS, TERMINAL_KEYS_MORE, type TermKeyDef } from "../src/client/terminal-keys";

/// The strip's modifiers applied to the strip's own keys are MEASURED against xterm.js 6 — what a real
/// Terminal sends for that chord on a hardware keyboard — never written from memory. Each strip key is
/// pressed on a real xterm.js (its textarea's keydown, with `keyCode` as xterm reads it), under every
/// combination of ⇧/Ctrl/Opt, in normal and in application cursor mode.
///
/// TWO deliberate differences. ⇧ with PgUp/PgDn: xterm.js sends NOTHING (it scrolls its own viewport);
/// the strip sends the key as if ⇧ were up, so the key never goes dead — compared against xterm.js's
/// bytes for the same chord WITHOUT shift. And Opt or Ctrl ALONE with ← or →: `ESC b` / `ESC f`, word
/// motions, which the product's own terminal sends for those keys too (`textEditingBytes`; asserted against
/// `mountXterm` in term-editing-keys.test.ts).

const PHYSICAL: Record<string, [key: string, keyCode: number]> = {
  esc: ["Escape", 27], tab: ["Tab", 9],
  left: ["ArrowLeft", 37], up: ["ArrowUp", 38], right: ["ArrowRight", 39], down: ["ArrowDown", 40],
  home: ["Home", 36], end: ["End", 35], pgup: ["PageUp", 33], pgdn: ["PageDown", 34],
  ...Object.fromEntries(Array.from({ length: 12 }, (_, i) => [`f${i + 1}`, [`F${i + 1}`, 112 + i]])),
};

beforeAll(() => {
  // jsdom lacks these; the renderer only needs them to exist (as term-client-queries.test.ts).
  (window as unknown as { matchMedia: unknown }).matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  (globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
});

function xtermSends(term: Terminal, ta: HTMLTextAreaElement, id: string, mask: number): string {
  const [key, code] = PHYSICAL[id]!;
  let got = "";
  const sub = term.onData((d) => { got += d; });
  const ev = new KeyboardEvent("keydown", {
    key, bubbles: true, cancelable: true,
    shiftKey: (mask & 1) !== 0, ctrlKey: (mask & 2) !== 0, altKey: (mask & 4) !== 0,
  });
  Object.defineProperty(ev, "keyCode", { get: () => code });
  Object.defineProperty(ev, "which", { get: () => code });
  ta.dispatchEvent(ev);
  sub.dispose();
  return got;
}

describe("the strip's modified keys send what xterm.js sends for the same chord", () => {
  const keys = [...TERMINAL_KEYS, ...TERMINAL_KEYS_MORE].filter((d): d is TermKeyDef => d.kind === "key" && d.id in PHYSICAL);

  it("covers every strip key a hardware keyboard has (the non-zero guard)", () => {
    expect(keys.map((k) => k.id).sort()).toEqual(Object.keys(PHYSICAL).sort());
  });

  for (const appCursor of [false, true]) {
    it(`every key × every ⇧/Ctrl/Opt combination, ${appCursor ? "application" : "normal"} cursor mode`, async () => {
      const el = document.createElement("div");
      document.body.append(el);
      const term = new Terminal();
      term.open(el);
      await new Promise<void>((r) => term.write(appCursor ? "\x1b[?1h" : "", r));
      const ta = el.querySelector("textarea")!;
      const wrong: string[] = [];
      let compared = 0;
      for (const k of keys) {
        for (let mask = 0; mask < 8; mask++) {
          const page = k.id === "pgup" || k.id === "pgdn";
          const word = (mask === 4 || mask === 2) && (k.id === "left" || k.id === "right");
          const want = word ? (k.id === "left" ? "\x1bb" : "\x1bf") : xtermSends(term, ta, k.id, page ? mask & ~1 : mask);
          const got = stripKeyBytes(k, appCursor, mask);
          compared++;
          if (got !== want) wrong.push(`${k.id} mask=${mask}: strip ${JSON.stringify(got)} xterm ${JSON.stringify(want)}`);
        }
      }
      term.dispose(); el.remove();
      expect(wrong).toEqual([]);
      expect(compared).toBe(keys.length * 8);
    });
  }
});
