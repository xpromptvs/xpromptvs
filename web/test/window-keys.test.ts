import { describe, expect, it } from "vitest";
import {
  charMessages, charToCode, modifierMessage, winKeyMessages,
  WINDOW_KEYS, WINDOW_KEYS_MORE,
} from "../src/client/window-keys";

const byId = (id: string) => {
  const d = [...WINDOW_KEYS, ...WINDOW_KEYS_MORE].find((k) => k.id === id);
  if (!d || d.kind !== "key") throw new Error(`no key ${id}`);
  return d;
};

describe("charToCode", () => {
  it("maps letters to their physical code so ⌘C is a real Command-C", () => {
    expect(charToCode("c")).toBe("KeyC");
    expect(charToCode("z")).toBe("KeyZ");
  });
  // THE RULE. planKeyInjection drops the unicode override when ⌘ or ⌃ is present and goes
  // keycode-only, so "C" + meta must resolve to KeyC with NO shift bit or ⌘C silently becomes ⌘⇧C.
  it("maps an UPPERCASE letter to the same code and infers no Shift", () => {
    expect(charToCode("C")).toBe("KeyC");
  });
  it("maps digits and the common punctuation", () => {
    expect(charToCode("5")).toBe("Digit5");
    expect(charToCode(" ")).toBe("Space");
    expect(charToCode("-")).toBe("Minus");
    expect(charToCode(".")).toBe("Period");
  });
  it("returns an empty code for a character it does not know, leaving the host's unicode override to type it", () => {
    expect(charToCode("é")).toBe("");
    expect(charToCode("字")).toBe("");
  });
  it("leaves a SHIFTED symbol unmapped — Digit1 would lie about which key was pressed", () => {
    expect(charToCode("!")).toBe("");
  });
});

describe("winKeyMessages", () => {
  it("emits a down then an up, both carrying the mask", () => {
    const msgs = winKeyMessages(byId("esc"), 0);
    expect(msgs).toEqual([
      { t: "win-key", down: true, code: "Escape", key: "Escape", repeat: false, mods: 0 },
      { t: "win-key", down: false, code: "Escape", key: "Escape", repeat: false, mods: 0 },
    ]);
  });
  it("carries a latched modifier on both halves", () => {
    const msgs = winKeyMessages(byId("tab"), 8);
    expect(msgs.map((m) => m.mods)).toEqual([8, 8]);
    expect(msgs[0]?.code).toBe("Tab");
  });
});

describe("charMessages", () => {
  it("sends the character as its own `key` with the resolved code", () => {
    expect(charMessages("c", 0)).toEqual([
      { t: "win-key", down: true, code: "KeyC", key: "c", repeat: false, mods: 0 },
      { t: "win-key", down: false, code: "KeyC", key: "c", repeat: false, mods: 0 },
    ]);
  });
  it("⌘ + c stays KeyC with mods 8 — the host goes keycode-only from there", () => {
    const msgs = charMessages("c", 8);
    expect(msgs[0]).toMatchObject({ code: "KeyC", key: "c", mods: 8 });
  });
  it("an unknown character rides with an empty code and its own key", () => {
    expect(charMessages("é", 0)[0]).toMatchObject({ code: "", key: "é" });
  });
});

describe("modifierMessage", () => {
  // This is what writes the host's currentFlags, which touch/hover stamp onto mouse events —
  // i.e. this single message is what makes ⌘-click work from a touchscreen.
  it("arming meta sends a MetaLeft down with meta in the mask", () => {
    expect(modifierMessage("meta", true, 8)).toEqual({
      t: "win-key", down: true, code: "MetaLeft", key: "Meta", repeat: false, mods: 8,
    });
  });
  it("clearing sends the matching up with the modifier gone from the mask", () => {
    expect(modifierMessage("meta", false, 0)).toEqual({
      t: "win-key", down: false, code: "MetaLeft", key: "Meta", repeat: false, mods: 0,
    });
  });
  it("uses the LEFT code for every modifier — planKeyInjection maps all four", () => {
    expect(modifierMessage("ctrl", true, 2).code).toBe("ControlLeft");
    expect(modifierMessage("alt", true, 4).code).toBe("AltLeft");
    expect(modifierMessage("shift", true, 1).code).toBe("ShiftLeft");
  });
});

describe("the tables", () => {
  it("row 1 carries Esc, Tab, the four modifiers and the arrows", () => {
    expect(WINDOW_KEYS.map((k) => k.id))
      .toEqual(["esc", "tab", "ctrl", "alt", "meta", "shift", "left", "down", "up", "right"]);
  });
  it("every non-modifier entry has a code planKeyInjection can map", () => {
    // Mirrors macVirtualKeys in host/RdevCore/.../KeyInjection.swift. A key whose code is absent
    // there is dropped by the host as "unmapped code" and does nothing at all.
    const known = new Set([
      "Escape", "Tab", "Delete", "Home", "End", "PageUp", "PageDown",
      "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
      ...Array.from({ length: 12 }, (_, i) => `F${i + 1}`),
    ]);
    for (const d of [...WINDOW_KEYS, ...WINDOW_KEYS_MORE]) {
      if (d.kind !== "key") continue;
      expect(known.has(d.code), `${d.id} has code ${d.code}, which the host cannot map`).toBe(true);
    }
  });
  it("every entry has a unique id", () => {
    const ids = [...WINDOW_KEYS, ...WINDOW_KEYS_MORE].map((k) => k.id);
    expect(new Set(ids).size).toBe(ids.length);
  });
});
