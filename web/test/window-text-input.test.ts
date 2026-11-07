import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HOLD_MS } from "../src/client/press-hold";
import { mountWindowKeyboard } from "../src/client/window-text-input";
import type { WinKeyWire } from "../src/client/keys";

let winEl: HTMLElement;
const setup = (isActive: () => boolean = () => true) => {
  const sent: WinKeyWire[] = [];
  const h = mountWindowKeyboard(winEl, { send: (m) => sent.push(m), isActive });
  return { h, sent };
};

/// A modifier is HELD: pointerdown then pointerup, not a click. jsdom has no PointerEvent, so the
/// events carry the one field the implementation reads.
const pointer = (el: HTMLElement, type: string, pointerId = 1) => {
  const e = new Event(type, { bubbles: true });
  Object.defineProperty(e, "pointerId", { value: pointerId });
  el.dispatchEvent(e);
};
/// One finger per modifier, so two held modifiers do not share a pointer.
const FINGER: Record<string, number> = { meta: 1, ctrl: 2, alt: 3, shift: 4 };
/// A modifier under a finger is only PENDING — the finger may be scrolling the strip — until
/// something USES it. `holdMod` is the chord: the finger lands on the modifier, then a second one
/// lands elsewhere (the picture, a strip key), which is what puts it down.
const pressMod = (h: { el: HTMLElement }, id: string) =>
  pointer(h.el.querySelector<HTMLElement>(`[data-key-id="${id}"]`)!, "pointerdown", FINGER[id]);
const holdMod = (h: { el: HTMLElement }, id: string) => {
  pressMod(h, id);
  pointer(document.body, "pointerdown", 99);
};
const releaseMod = (h: { el: HTMLElement }, id: string) =>
  pointer(h.el.querySelector<HTMLElement>(`[data-key-id="${id}"]`)!, "pointerup", FINGER[id]);

beforeEach(() => {
  document.body.innerHTML = "";
  delete document.documentElement.dataset.keystrip;
  winEl = document.createElement("div");
  winEl.className = "source-window";
  document.body.append(winEl);
});

describe("mountWindowKeyboard structure", () => {
  // LOAD-BEARING. keydown BUBBLES, so a hidden input inside .win-body would fire
  // attachWindowKeys' listener AND this module's — every keystroke sent twice.
  it("mounts the hidden input as a child of .source-window, NOT of .win-body", () => {
    const body = document.createElement("div"); body.className = "win-body";
    winEl.append(body);
    const { h } = setup();
    expect(h.input.parentElement).toBe(winEl);
    expect(body.contains(h.input)).toBe(false);
  });

  it("renders the strip with a ⌨ control in the fixed group", () => {
    const { h } = setup();
    expect(h.el.querySelector('.key-strip-fixed [data-key-id="kbd"]')).not.toBeNull();
  });
});

describe("strip keys", () => {
  it("sends a down/up pair for Escape", () => {
    const { h, sent } = setup();
    h.el.querySelector<HTMLElement>('[data-key-id="esc"]')!.click();
    expect(sent).toEqual([
      { t: "win-key", down: true, code: "Escape", key: "Escape", repeat: false, mods: 0 },
      { t: "win-key", down: false, code: "Escape", key: "Escape", repeat: false, mods: 0 },
    ]);
  });

  // THE SCROLL FIX. A finger that lands on ⌘ and then scrolls the strip must not reach the Mac at
  // all — a bare ⌘ down/up there is a real keystroke, and ⌘ alone opens things.
  it("a finger on ⌘ that turns into a strip scroll sends NOTHING to the host", () => {
    const { h, sent } = setup();
    pressMod(h, "meta");
    pointer(h.el.querySelector<HTMLElement>('[data-key-id="meta"]')!, "pointercancel", FINGER.meta);
    expect(sent).toEqual([]);
  });

  it("an UNUSED ⌘ is a tap on release: a bare down then up, nothing on touch down", () => {
    const { h, sent } = setup();
    pressMod(h, "meta");
    expect(sent).toEqual([]);
    releaseMod(h, "meta");
    expect(sent.map((m) => [m.code, m.down])).toEqual([["MetaLeft", true], ["MetaLeft", false]]);
  });

  it("a key typed on the soft keyboard under a pending ⌘ carries it — the chord engages it", () => {
    const { h, sent } = setup();
    pressMod(h, "meta");
    h.input.dispatchEvent(new InputEvent("beforeinput", { bubbles: true, data: "c", inputType: "insertText" }));
    expect(sent.map((m) => [m.code, m.down, m.mods])).toEqual([
      ["MetaLeft", true, 8], ["KeyC", true, 8], ["KeyC", false, 8],
    ]);
  });

  it("holding ⌘ sends a bare MetaLeft down — this is what writes the host's currentFlags", () => {
    const { h, sent } = setup();
    holdMod(h, "meta");
    expect(sent).toEqual([
      { t: "win-key", down: true, code: "MetaLeft", key: "Meta", repeat: false, mods: 8 },
    ]);
  });

  it("releasing it sends the matching up with the modifier gone from the mask", () => {
    const { h, sent } = setup();
    holdMod(h, "meta");
    sent.length = 0;
    releaseMod(h, "meta");
    expect(sent).toEqual([
      { t: "win-key", down: false, code: "MetaLeft", key: "Meta", repeat: false, mods: 0 },
    ]);
  });

  // THE POINT OF HOLD. Under sticky, the modifier was consumed by the first key; here one finger
  // holds ⌘ while the other taps C and then V, and nothing releases it but the finger.
  it("a HELD ⌘ survives any number of keys and is NOT auto-released", () => {
    const { h, sent } = setup();
    holdMod(h, "meta");
    sent.length = 0;
    h.el.querySelector<HTMLElement>('[data-key-id="tab"]')!.click();
    h.el.querySelector<HTMLElement>('[data-key-id="esc"]')!.click();
    expect(sent.every((m) => m.mods === 8)).toBe(true);
    expect(sent.some((m) => m.code === "MetaLeft")).toBe(false);
    expect(sent.map((m) => m.code)).toEqual(["Tab", "Tab", "Escape", "Escape"]);
  });

  it("a duplicated pointerdown sends only ONE bare-modifier message", () => {
    const { h, sent } = setup();
    holdMod(h, "meta");
    holdMod(h, "meta");
    expect(sent).toHaveLength(1);
  });

  it("shows the held state on the key cap", () => {
    const { h } = setup();
    const meta = h.el.querySelector<HTMLElement>('[data-key-id="meta"]')!;
    expect(meta.dataset.state).toBe("off");
    holdMod(h, "meta");
    expect(meta.dataset.state).toBe("held");
    releaseMod(h, "meta");
    expect(meta.dataset.state).toBe("off");
  });

  it("two modifiers can be held at once", () => {
    const { h, sent } = setup();
    holdMod(h, "meta");
    holdMod(h, "shift");
    sent.length = 0;
    h.el.querySelector<HTMLElement>('[data-key-id="tab"]')!.click();
    expect(sent[0]).toMatchObject({ code: "Tab", mods: 9 });   // meta 8 | shift 1
  });
});

describe("typed characters", () => {
  it("beforeinput insertText becomes a win-key pair with the resolved code", () => {
    const { h, sent } = setup();
    h.input.dispatchEvent(new InputEvent("beforeinput", { data: "c", inputType: "insertText" }));
    expect(sent).toEqual([
      { t: "win-key", down: true, code: "KeyC", key: "c", repeat: false, mods: 0 },
      { t: "win-key", down: false, code: "KeyC", key: "c", repeat: false, mods: 0 },
    ]);
  });

  it("sends one message pair PER CHARACTER for multi-character input", () => {
    const { h, sent } = setup();
    h.input.dispatchEvent(new InputEvent("beforeinput", { data: "hi", inputType: "insertText" }));
    expect(sent.map((m) => m.key)).toEqual(["h", "h", "i", "i"]);
  });

  it("a typed character under a HELD ⌘ carries it, and does not release it", () => {
    const { h, sent } = setup();
    holdMod(h, "meta");
    sent.length = 0;
    h.input.dispatchEvent(new InputEvent("beforeinput", { data: "c", inputType: "insertText" }));
    expect(sent[0]).toMatchObject({ code: "KeyC", mods: 8 });
    expect(sent.some((m) => m.code === "MetaLeft")).toBe(false);
  });

  it("deleteContentBackward becomes Backspace", () => {
    const { h, sent } = setup();
    h.input.dispatchEvent(new InputEvent("beforeinput", { inputType: "deleteContentBackward" }));
    expect(sent[0]).toMatchObject({ code: "Backspace", key: "Backspace", down: true });
  });

  it("insertLineBreak becomes Enter", () => {
    const { h, sent } = setup();
    h.input.dispatchEvent(new InputEvent("beforeinput", { inputType: "insertLineBreak" }));
    expect(sent[0]).toMatchObject({ code: "Enter", key: "Enter" });
  });

  it("a hardware keydown with a real code goes through", () => {
    const { h, sent } = setup();
    h.input.dispatchEvent(new KeyboardEvent("keydown", { code: "ArrowUp", key: "ArrowUp" }));
    expect(sent[0]).toMatchObject({ code: "ArrowUp" });
  });

  // The iOS soft keyboard reports code "" (often key "Unidentified"). That MUST fall through to
  // beforeinput rather than being forwarded as a codeless key — the host would drop it.
  it("a codeless keydown sends NOTHING, leaving it to beforeinput", () => {
    const { h, sent } = setup();
    h.input.dispatchEvent(new KeyboardEvent("keydown", { code: "", key: "Unidentified" }));
    expect(sent).toEqual([]);
  });

  it("never accumulates text — the field is a keystroke tap, not a composer", () => {
    const { h } = setup();
    h.input.value = "leftover";
    h.input.dispatchEvent(new Event("input"));
    expect(h.input.value).toBe("");
  });

  it("sends nothing while the window is not active", () => {
    const { h, sent } = setup(() => false);
    h.el.querySelector<HTMLElement>('[data-key-id="esc"]')!.click();
    h.input.dispatchEvent(new InputEvent("beforeinput", { data: "c", inputType: "insertText" }));
    expect(sent).toEqual([]);
  });
});

describe("mask", () => {
  it("exposes the held modifiers for attachWindowKeys' extraMods", () => {
    const { h } = setup();
    expect(h.mask()).toBe(0);
    holdMod(h, "ctrl");
    expect(h.mask()).toBe(2);
  });
});

describe("clearMods", () => {
  it("releases every held modifier and reports them to the host", () => {
    const { h, sent } = setup();
    holdMod(h, "meta");
    holdMod(h, "ctrl");
    sent.length = 0;
    h.clearMods();
    const ups = sent.filter((m) => !m.down).map((m) => m.code).sort();
    expect(ups).toEqual(["ControlLeft", "MetaLeft"]);
    expect(sent.every((m) => m.mods === 0)).toBe(true);
    expect(h.mask()).toBe(0);
  });

  // A finger lifted outside the page (app switch, call banner) never delivers its pointerup, so
  // clearMods is still the backstop that keeps the host's currentFlags honest.
  it("releases a modifier whose pointerup never arrived", () => {
    const { h, sent } = setup();
    holdMod(h, "meta");
    sent.length = 0;
    h.clearMods();
    expect(sent).toEqual([
      { t: "win-key", down: false, code: "MetaLeft", key: "Meta", repeat: false, mods: 0 },
    ]);
  });

  it("sends nothing when no modifier was held", () => {
    const { h, sent } = setup();
    h.clearMods();
    expect(sent).toEqual([]);
  });

  it("tolerates a send that throws — a channel already closing under it must not make clearMods throw", () => {
    // Measured: `RTCDataChannel.send` on a closed/closing channel throws `InvalidStateError`.
    // `disposeKeyboard` runs `clearMods` unconditionally during teardown, so a caller with no
    // try/catch of its own (`sync`'s removal loop, `releaseTouchMods`) must never see this throw.
    const h = mountWindowKeyboard(winEl, {
      send: () => { throw new DOMException("channel is closed", "InvalidStateError"); },
      isActive: () => true,
    });
    holdMod(h, "meta");
    expect(() => h.clearMods()).not.toThrow();
    expect(h.mask()).toBe(0);
  });
});

describe("destroy", () => {
  it("removes both the strip and the hidden input", () => {
    const { h } = setup();
    h.destroy();
    expect(winEl.querySelector(".key-strip")).toBeNull();
    expect(winEl.querySelector(".win-key-input")).toBeNull();
  });
});

/// FULL SCREEN HAS NO TITLEBAR, so a held finger on ⌨ opens the window's paste menu there (paste-and-drop
/// design §2.2) — and the hold's click must not ALSO toggle the keyboard. Anywhere else ⌨ is only the toggle.
describe("⌨ held in full screen — the window's paste menu", () => {
  /// jsdom has no PointerEvent: a MouseEvent of the pointer type (press-hold.test.ts).
  const touch = (type: string, x: number, y: number) => {
    const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y });
    for (const [k, v] of Object.entries({ pointerId: 5, pointerType: "touch", isPrimary: true })) Object.defineProperty(e, k, { value: v });
    return e as PointerEvent;
  };
  const mount = (o: { fullscreen: boolean; canPaste?: boolean }) => {
    const holds: Array<{ x: number; y: number }> = [];
    const h = mountWindowKeyboard(winEl, {
      send: () => {}, isActive: () => true,
      isFullscreen: () => o.fullscreen,
      ...(o.canPaste === undefined ? {} : { canPaste: () => o.canPaste! }),
      onKeyboardHold: (at) => holds.push(at),
    });
    return { h, holds, kbd: h.el.querySelector<HTMLElement>('[data-key-id="kbd"]')! };
  };
  /// A held finger, released: the down, 500 ms still, the up — then the click iOS synthesizes after it.
  const holdThenClick = (kbd: HTMLElement) => {
    kbd.dispatchEvent(touch("pointerdown", 30, 700));
    vi.advanceTimersByTime(HOLD_MS);
    window.dispatchEvent(touch("pointerup", 30, 700));
    kbd.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
  };
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); (document.activeElement as HTMLElement | null)?.blur?.(); });

  it("in full screen a 500 ms hold opens the menu at the finger, and its click does NOT toggle the keyboard", () => {
    const { h, holds, kbd } = mount({ fullscreen: true });
    holdThenClick(kbd);
    expect(holds).toEqual([{ x: 30, y: 700 }]);
    expect(document.activeElement).not.toBe(h.input);
    // The NEXT tap is the toggle again: the swallow is for the hold's own click only.
    kbd.dispatchEvent(touch("pointerdown", 30, 700));
    window.dispatchEvent(touch("pointerup", 30, 700));
    kbd.click();
    expect(document.activeElement).toBe(h.input);
    h.destroy();
  });

  it("out of full screen the hold does nothing, and the tap toggles as before", () => {
    const { h, holds, kbd } = mount({ fullscreen: false });
    holdThenClick(kbd);
    expect(holds).toEqual([]);
    expect(document.activeElement).toBe(h.input);
    h.destroy();
  });

  it("a client that may not paste gets no hold even in full screen — the click is the toggle", () => {
    const { h, holds, kbd } = mount({ fullscreen: true, canPaste: false });
    holdThenClick(kbd);
    expect(holds).toEqual([]);
    expect(document.activeElement).toBe(h.input);
    h.destroy();
  });

  it("destroy() takes the hold with it: a press already held fires nothing", () => {
    const { h, holds, kbd } = mount({ fullscreen: true });
    kbd.dispatchEvent(touch("pointerdown", 30, 700));
    h.destroy();
    vi.advanceTimersByTime(HOLD_MS);
    expect(holds).toEqual([]);
  });
});


describe("custom keyboard input", () => {
  it("routes characters and editing keys as window down/up pairs", () => {
    const { h, sent } = setup();
    for (const id of ["char:a", "char:enter", "char:backspace"])
      h.el.querySelector<HTMLElement>(`[data-key-id="${id}"]`)!.click();
    expect(sent.map(m => [m.code, m.key, m.down])).toEqual([
      ["KeyA", "a", true], ["KeyA", "a", false],
      ["Enter", "Enter", true], ["Enter", "Enter", false],
      ["Backspace", "Backspace", true], ["Backspace", "Backspace", false],
    ]);
    h.destroy();
  });
});

describe("a simulator window", () => {
  it("sends a SIMULATOR's inserted text whole, as sim-text", () => {
    const sent: unknown[] = [], texts: string[] = [];
    const kb = mountWindowKeyboard(document.body.appendChild(document.createElement("div")), {
      send: (m) => sent.push(m), isActive: () => true, sendText: (t) => texts.push(t),
    });
    kb.input.dispatchEvent(new InputEvent("beforeinput", { data: "héllo 😀", inputType: "insertText", cancelable: true }));
    expect(texts).toEqual(["héllo 😀"]);
    expect(sent).toEqual([]);
    kb.destroy();
  });
});
