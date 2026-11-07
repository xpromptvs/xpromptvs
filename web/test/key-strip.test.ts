import { beforeEach, describe, expect, it, vi } from "vitest";
import { mountKeyStrip, shiftedCharacter, REPEAT_DELAY_MS, REPEAT_INTERVAL_MS } from "../src/client/key-strip";
import type { KeyStripOpts, StripDef } from "../src/client/key-strip";
import type { ModState } from "../src/client/held-mods";

const ROW: StripDef[] = [
  { id: "esc", label: "Esc", aria: "Escape", kind: "key" },
  { id: "ctrl", label: "Ctrl", aria: "Control", kind: "mod", mod: "ctrl" },
  { id: "up", label: "↑", aria: "Up", kind: "key", repeat: true },
];
const MORE: StripDef[] = [{ id: "f1", label: "F1", aria: "F1", kind: "key" }];

let parent: HTMLElement;
beforeEach(() => {
  document.body.innerHTML = "";
  delete document.documentElement.dataset.keystrip;
  parent = document.createElement("div");
  document.body.append(parent);
});

const mount = (over: Partial<KeyStripOpts> = {}) => {
  const presses: string[] = [];
  const modEvents: string[] = [];
  const states: Record<string, ModState> = {};
  const h = mountKeyStrip(parent, {
    row: ROW, more: MORE,
    onPress: (d) => presses.push(d.id),
    onModChange: (m, down) => { states[m] = down ? "held" : "off"; modEvents.push(`${m}:${down ? "down" : "up"}`); },
    modState: (m) => states[m] ?? "off",
    ...over,
  });
  return { h, presses, states, modEvents };
};

/// A modifier is HELD: pointerdown then pointerup, not a click. jsdom has no PointerEvent, so the
/// events are constructed by hand with the one field the implementation reads.
const pointer = (el: HTMLElement, type: string, pointerId = 1) => {
  const e = new Event(type, { bubbles: true }) as Event & { pointerId: number; target: HTMLElement };
  Object.defineProperty(e, "pointerId", { value: pointerId });
  el.dispatchEvent(e);
};

describe("mountKeyStrip structure", () => {
  it("renders one button per row entry, from the TABLE", () => {
    mount();
    const ids = [...parent.querySelectorAll(".key-strip-scroll [data-key-id]")]
      .map((b) => (b as HTMLElement).dataset.keyId);
    expect(ids).toEqual(["esc", "ctrl", "up"]);
  });

  it("labels every button for a screen reader", () => {
    mount();
    const esc = parent.querySelector<HTMLElement>('[data-key-id="esc"]')!;
    expect(esc.getAttribute("aria-label")).toBe("Escape");
    expect(esc.textContent).toBe("Esc");
  });

  // THE TAB-BAR INVARIANT. The fixed group must be a SIBLING of the scroller, never inside it —
  // being outside the scrolling box is what makes "⋯ can never scroll out of reach" structural
  // rather than a styling accident.
  it("puts the fixed group OUTSIDE the scroller", () => {
    const { h } = mount();
    const scroll = h.el.querySelector(".key-strip-scroll")!;
    const fixed = h.el.querySelector(".key-strip-fixed")!;
    expect(fixed.parentElement).toBe(h.el);
    expect(scroll.contains(fixed)).toBe(false);
  });

  it("hides the expansion row until ⋯ is pressed, and flags the ROOT so CSS can resize the grid", () => {
    const { h } = mount();
    expect(h.el.querySelector('[data-key-id="f1"]')).toBeNull();
    expect(document.documentElement.dataset.keystrip).toBeUndefined();
    h.el.querySelector<HTMLElement>('[data-key-id="strip:more"]')!.click();
    expect(h.el.querySelector('[data-key-id="f1"]')).not.toBeNull();
    expect(document.documentElement.dataset.keystrip).toBe("expanded");
    h.el.querySelector<HTMLElement>('[data-key-id="strip:more"]')!.click();
    expect(document.documentElement.dataset.keystrip).toBeUndefined();
  });

  it("renders the extra fixed controls a caller supplies", () => {
    const { h } = mount({ extra: [{ id: "kbd", label: "⌨", aria: "Keyboard", kind: "key" }] });
    expect(h.el.querySelector('.key-strip-fixed [data-key-id="kbd"]')).not.toBeNull();
  });
});

describe("mountKeyStrip presses", () => {
  it("reports a press by def, not by id string", () => {
    const { presses } = mount();
    parent.querySelector<HTMLElement>('[data-key-id="esc"]')!.click();
    expect(presses).toEqual(["esc"]);
  });

  it("reports presses from the EXPANSION row too", () => {
    const { h, presses } = mount();
    h.el.querySelector<HTMLElement>('[data-key-id="strip:more"]')!.click();
    h.el.querySelector<HTMLElement>('[data-key-id="f1"]')!.click();
    expect(presses).toEqual(["f1"]);
  });

  it("the ⋯ control is NOT reported as a key press — it is the strip's own control", () => {
    const { h, presses } = mount();
    h.el.querySelector<HTMLElement>('[data-key-id="strip:more"]')!.click();
    expect(presses).toEqual([]);
  });

  it("reflects modifier state as data-state and aria-pressed", () => {
    const { h, states } = mount();
    const btn = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    expect(btn.dataset.state).toBe("off");
    expect(btn.getAttribute("aria-pressed")).toBe("false");
    states.ctrl = "held";
    h.refresh();
    expect(btn.dataset.state).toBe("held");
    expect(btn.getAttribute("aria-pressed")).toBe("true");
  });

  // THE SCROLL FIX. The strip is a horizontal scroller, so a finger landing on a modifier may be
  // starting a scroll — which the browser announces only later, with pointercancel.
  it("a modifier does NOTHING on pointerdown alone — the finger may be scrolling the strip", () => {
    const { modEvents } = mount();
    pointer(parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!, "pointerdown");
    expect(modEvents).toEqual([]);
  });

  it("a pending modifier LIGHTS UP at once, and a scroll puts the light out", () => {
    mount();
    const ctrl = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    pointer(ctrl, "pointerdown");
    expect(ctrl.dataset.state).toBe("held");
    expect(ctrl.getAttribute("aria-pressed")).toBe("true");
    pointer(ctrl, "pointercancel");
    expect(ctrl.dataset.state).toBe("off");
  });

  it("a tapped modifier's light goes out on release", () => {
    mount();
    const ctrl = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    pointer(ctrl, "pointerdown");
    pointer(ctrl, "pointerup");
    expect(ctrl.dataset.state).toBe("off");
  });

  it("a scroll that started on a modifier (pointercancel) sends nothing at all", () => {
    const { modEvents } = mount();
    const ctrl = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    pointer(ctrl, "pointerdown");
    pointer(ctrl, "pointercancel");
    expect(modEvents).toEqual([]);
  });

  it("an unused modifier is a TAP on release — down then up — and its click adds nothing", () => {
    const { modEvents, presses } = mount();
    const ctrl = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    pointer(ctrl, "pointerdown");
    pointer(ctrl, "pointerup");
    ctrl.click();                       // the click that tails the gesture must add nothing
    expect(modEvents).toEqual(["ctrl:down", "ctrl:up"]);
    expect(presses).toEqual([]);        // and must NOT fire a key press
  });

  it("a second finger landing ANYWHERE puts a pending modifier down first — ⌘-click, ⌘+strip key", () => {
    const { modEvents, presses } = mount();
    const ctrl = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    const esc = parent.querySelector<HTMLElement>('[data-key-id="esc"]')!;
    pointer(ctrl, "pointerdown", 1);
    pointer(document.body, "pointerdown", 2);           // e.g. the picture
    expect(modEvents).toEqual(["ctrl:down"]);
    pointer(esc, "pointerdown", 3);
    pointer(esc, "pointerup", 3);
    esc.click();
    expect(presses).toEqual(["esc"]);
    expect(modEvents).toEqual(["ctrl:down"]);           // still held: the chord is not over
    pointer(ctrl, "pointerup", 1);
    expect(modEvents).toEqual(["ctrl:down", "ctrl:up"]); // ONE down, ONE up — no second tap
  });

  it("a key from the soft keyboard puts a pending modifier down BEFORE its own handler runs", () => {
    const { modEvents, states } = mount();
    const input = document.createElement("input");
    document.body.append(input);
    const seen: string[] = [];
    input.addEventListener("beforeinput", () => seen.push(states.ctrl ?? "off"));
    input.addEventListener("keydown", () => seen.push(states.ctrl ?? "off"));
    const ctrl = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    pointer(ctrl, "pointerdown");
    input.dispatchEvent(new Event("beforeinput", { bubbles: true }));
    input.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true }));
    expect(seen).toEqual(["held", "held"]);
    pointer(ctrl, "pointerup");
    expect(modEvents).toEqual(["ctrl:down", "ctrl:up"]);
  });

  it("a USED modifier is released on pointercancel — otherwise it sticks with no way back", () => {
    const { modEvents } = mount();
    const ctrl = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    pointer(ctrl, "pointerdown", 1);
    pointer(document.body, "pointerdown", 2);
    pointer(ctrl, "pointercancel", 1);
    expect(modEvents).toEqual(["ctrl:down", "ctrl:up"]);
  });

  // pointerleave must NOT release: with pointer capture the finger legitimately wanders off the
  // button mid-chord, and releasing there is the drift bug capture exists to prevent.
  it("pointerleave does NOT release a held modifier", () => {
    const { modEvents } = mount();
    const ctrl = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    pointer(ctrl, "pointerdown", 1);
    pointer(document.body, "pointerdown", 2);
    pointer(ctrl, "pointerleave", 1);
    expect(modEvents).toEqual(["ctrl:down"]);
  });

  it("a second finger's release does not drop the first finger's modifier", () => {
    const { modEvents } = mount();
    const ctrl = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    pointer(ctrl, "pointerdown", 1);
    pointer(ctrl, "pointerdown", 2);    // a second finger lands, which engages the first
    pointer(ctrl, "pointerup", 3);      // a pointer that never went down here
    expect(modEvents).toEqual(["ctrl:down"]);
  });

  it("destroy removes the window listeners — a gone strip engages nothing", () => {
    const { h, modEvents } = mount();
    const ctrl = parent.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
    pointer(ctrl, "pointerdown", 1);
    h.destroy();
    pointer(document.body, "pointerdown", 2);
    window.dispatchEvent(new KeyboardEvent("keydown"));
    expect(modEvents).toEqual([]);
  });

  // THE KEYBOARD-DISMISSAL FIX. mousedown's default action is the focus transfer, and on iOS focus
  // leaving the hidden input closes the soft keyboard — so every key tap dismissed it.
  it("preventDefaults mousedown so a key tap never steals DOM focus", () => {
    mount();
    const esc = parent.querySelector<HTMLElement>('[data-key-id="esc"]')!;
    const e = new MouseEvent("mousedown", { bubbles: true, cancelable: true });
    esc.dispatchEvent(e);
    expect(e.defaultPrevented).toBe(true);
  });
});

describe("mountKeyStrip auto-repeat", () => {
  it("a held repeat:true key fires NOTHING until the delay, then repeats at the interval", () => {
    vi.useFakeTimers();
    const { presses } = mount();
    const up = parent.querySelector<HTMLElement>('[data-key-id="up"]')!;
    up.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    expect(presses).toEqual([]);                         // NOT on touch down: it may be a scroll
    vi.advanceTimersByTime(REPEAT_DELAY_MS);
    expect(presses).toEqual(["up"]);
    vi.advanceTimersByTime(REPEAT_INTERVAL_MS * 3);
    expect(presses.length).toBe(4);
    up.dispatchEvent(new Event("pointerup", { bubbles: true }));
    up.click();                                          // the hold's tail adds no extra step
    vi.advanceTimersByTime(REPEAT_INTERVAL_MS * 10);
    expect(presses.length).toBe(4);                      // stopped
    vi.useRealTimers();
  });

  it("a scroll that started on a repeating key fires nothing, and the NEXT tap still works", () => {
    vi.useFakeTimers();
    const { presses } = mount();
    const up = parent.querySelector<HTMLElement>('[data-key-id="up"]')!;
    up.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    up.dispatchEvent(new Event("pointercancel", { bubbles: true }));
    vi.advanceTimersByTime(REPEAT_DELAY_MS + REPEAT_INTERVAL_MS * 10);
    expect(presses).toEqual([]);
    // A hold that repeated and was THEN claimed by a scroll leaves no mark that eats the next tap.
    up.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    vi.advanceTimersByTime(REPEAT_DELAY_MS);
    up.dispatchEvent(new Event("pointercancel", { bubbles: true }));
    up.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    up.dispatchEvent(new Event("pointerup", { bubbles: true }));
    up.click();
    expect(presses).toEqual(["up", "up"]);
    vi.useRealTimers();
  });

  it("does NOT repeat a key without repeat:true — a repeating Esc is a hazard", () => {
    vi.useFakeTimers();
    const { presses } = mount();
    const esc = parent.querySelector<HTMLElement>('[data-key-id="esc"]')!;
    // A REAL tap, not a bare pointerdown: a non-repeat key fires on the CLICK, which is what a
    // synthetic activation and a screen reader produce too.
    esc.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    esc.dispatchEvent(new Event("pointerup", { bubbles: true }));
    esc.click();
    vi.advanceTimersByTime(REPEAT_DELAY_MS + REPEAT_INTERVAL_MS * 10);
    expect(presses).toEqual(["esc"]);
    vi.useRealTimers();
  });

  it("a bare pointerdown on a non-repeat key fires NOTHING — the click is the press", () => {
    vi.useFakeTimers();
    const { presses } = mount();
    parent.querySelector<HTMLElement>('[data-key-id="esc"]')!
      .dispatchEvent(new Event("pointerdown", { bubbles: true }));
    vi.advanceTimersByTime(REPEAT_DELAY_MS + REPEAT_INTERVAL_MS * 10);
    expect(presses).toEqual([]);
    vi.useRealTimers();
  });

  // A pointerdown is followed by a click on a real device. Without suppression the repeating key
  // fires twice for a single tap, which reads as a stuck arrow.
  it("a pointerdown followed by its click fires the key ONCE", () => {
    vi.useFakeTimers();
    const { presses } = mount();
    const up = parent.querySelector<HTMLElement>('[data-key-id="up"]')!;
    up.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    up.dispatchEvent(new Event("pointerup", { bubbles: true }));
    up.click();
    expect(presses).toEqual(["up"]);
    vi.useRealTimers();
  });

  it("a repeating key still works on a SECOND tap", () => {
    vi.useFakeTimers();
    const { presses } = mount();
    const up = parent.querySelector<HTMLElement>('[data-key-id="up"]')!;
    for (let i = 0; i < 2; i++) {
      up.dispatchEvent(new Event("pointerdown", { bubbles: true }));
      up.dispatchEvent(new Event("pointerup", { bubbles: true }));
      up.click();
    }
    expect(presses).toEqual(["up", "up"]);
    vi.useRealTimers();
  });
});

describe("destroy", () => {
  it("removes the element and clears the root flag", () => {
    const { h } = mount();
    h.el.querySelector<HTMLElement>('[data-key-id="strip:more"]')!.click();
    h.destroy();
    expect(parent.querySelector(".key-strip")).toBeNull();
    expect(document.documentElement.dataset.keystrip).toBeUndefined();
  });

  it("stops a running auto-repeat, so a destroyed strip cannot keep sending", () => {
    vi.useFakeTimers();
    const { h, presses } = mount();
    parent.querySelector<HTMLElement>('[data-key-id="up"]')!
      .dispatchEvent(new Event("pointerdown", { bubbles: true }));
    vi.advanceTimersByTime(REPEAT_DELAY_MS);
    h.destroy();
    vi.advanceTimersByTime(REPEAT_INTERVAL_MS * 10);
    expect(presses).toEqual(["up"]);
    vi.useRealTimers();
  });
});

describe("keyboard drawer", () => {
  const setup = () => {
    const trigger = document.createElement("button"); trigger.id = "keyboard-open"; document.body.append(trigger);
    const text = vi.fn(); const systemKeyboard = vi.fn();
    const result = mount({ drawer: { active: () => true, text, systemKeyboard } });
    trigger.click();
    return { ...result, trigger, text, systemKeyboard };
  };
  it("types letters, numbers, return and backspace without expanding the terminal inset", () => {
    const { h, text } = setup();
    for (const id of ["char:a", "char:3", "char:enter", "char:backspace"])
      h.el.querySelector<HTMLButtonElement>(`[data-key-id="${id}"]`)!.click();
    expect(text.mock.calls.flat()).toEqual(["a", "3", "\r", "\x7f"]);
    h.el.querySelector<HTMLButtonElement>('[data-key-id="strip:more"]')!.click();
    expect(document.documentElement.dataset.keystrip).toBeUndefined();
    expect(h.el.querySelector('[data-key-id="f1"]')).not.toBeNull();
    h.destroy();
  });
  it("releases a held modifier on dismissal and removes the trigger listener on teardown", () => {
    const { h, trigger, modEvents } = setup();
    pointer(h.el.querySelector<HTMLElement>('[data-key-id="ctrl"]')!, "pointerdown", 1);
    pointer(h.el.querySelector<HTMLElement>('[data-key-id="char:c"]')!, "pointerdown", 2);
    expect(modEvents).toEqual(["ctrl:down"]);
    trigger.click();
    expect(modEvents).toEqual(["ctrl:down", "ctrl:up"]);
    expect(h.el.classList.contains("is-open")).toBe(false);
    h.destroy(); trigger.click();
    expect(h.el.classList.contains("is-open")).toBe(false);
  });
  it("can switch to symbols and hand off to the system keyboard", () => {
    const { h, systemKeyboard } = setup();
    h.el.querySelector<HTMLButtonElement>('[aria-label="Symbols"]')!.click();
    expect(h.el.classList.contains("keyboard-symbols")).toBe(true);
    const button = [...h.el.querySelectorAll("button")].find(b => b.getAttribute("aria-label") === "System keyboard")!;
    expect(button.parentElement?.className).toBe("keyboard-mode");
    expect(button.textContent).toBe("System");
    button.click(); expect(systemKeyboard).toHaveBeenCalledOnce();
    expect(h.el.classList.contains("is-open")).toBe(false);
    h.destroy();
  });
});

 it("maps shifted punctuation as well as letters", () => {
  expect([..."1234567890-=[]\\;'`,./"].map(shiftedCharacter).join("")).toBe("!@#$%^&*()_+{}|\":~<>?");
  expect(shiftedCharacter("a")).toBe("A");
});


describe("floating keyboard layouts", () => {
  it("defaults to compact, switches both ways, and stays open when content is touched", () => {
    const trigger = document.createElement("button"); trigger.id = "keyboard-open"; document.body.append(trigger);
    const { h } = mount({ drawer: { active: () => true, text: vi.fn(), systemKeyboard: vi.fn() } });
    trigger.click();
    expect(h.el.classList.contains("keyboard-compact")).toBe(true);
    const [compact, full] = [...h.el.querySelectorAll<HTMLButtonElement>(".keyboard-mode button")];
    expect(compact!.getAttribute("aria-pressed")).toBe("true");
    full!.click(); expect(h.el.classList.contains("keyboard-compact")).toBe(false);
    expect(full!.getAttribute("aria-pressed")).toBe("true");
    expect(compact!.getAttribute("aria-pressed")).toBe("false");
    full!.click(); expect(h.el.classList.contains("keyboard-compact")).toBe(false);
    compact!.click(); expect(h.el.classList.contains("keyboard-compact")).toBe(true);
    expect(compact!.getAttribute("aria-pressed")).toBe("true");
    expect(full!.getAttribute("aria-pressed")).toBe("false");
    pointer(parent, "pointerdown", 9);
    expect(h.el.classList.contains("is-open")).toBe(true);
    expect(document.documentElement.dataset.keystrip).toBeUndefined();
    h.destroy();
  });
  it("routes compact arrows through the original key table and editing keys through text", () => {
    const text = vi.fn();
    const { h, presses } = mount({ drawer: { active: () => true, text, systemKeyboard: vi.fn() } });
    h.el.querySelector<HTMLButtonElement>('[data-key-id="compact:up"]')!.click();
    expect(presses).toEqual(["up"]);
    for (const id of ["ctrl-c", "enter", "backspace"])
      h.el.querySelector<HTMLButtonElement>(`[data-key-id="compact:${id}"]`)!.click();
    expect(text.mock.calls.flat()).toEqual(["\x03", "\r", "\x7f"]);
    h.destroy();
  });
});

it("drags against the positioning box even when the session wrapper has no layout box", () => {
  const trigger = document.createElement("button"); trigger.id = "keyboard-open"; document.body.append(trigger);
  const { h } = mount({ drawer: { active: () => true, text: vi.fn(), systemKeyboard: vi.fn() } });
  trigger.click();
  const bounds = vi.spyOn(document.body, "getBoundingClientRect").mockReturnValue({ left: 0, top: 0, width: 400, height: 800 } as DOMRect);
  vi.spyOn(h.el, "getBoundingClientRect").mockReturnValue({ left: 80, top: 500, width: 310, height: 186 } as DOMRect);
  Object.defineProperty(h.el, "offsetWidth", { value: 310 });
  Object.defineProperty(h.el, "offsetHeight", { value: 186 });
  const header = h.el.querySelector<HTMLElement>(".keyboard-drawer-head")!;
  header.setPointerCapture = vi.fn();
  const move = (type: string, x: number, y: number) => {
    const event = new MouseEvent(type, { bubbles: true, button: 0, clientX: x, clientY: y });
    Object.defineProperty(event, "pointerId", { value: 1 }); header.dispatchEvent(event);
  };
  move("pointerdown", 90, 510); move("pointermove", 60, 410);
  expect(h.el.style.left).toBe("50px"); expect(h.el.style.top).toBe("400px");
  move("pointermove", 1000, 2000);
  expect(h.el.style.left).toBe("82px"); expect(h.el.style.top).toBe("568px");
  bounds.mockRestore(); h.destroy();
});


it("supports a secondary touch typing C under held Ctrl without relying on a click", () => {
  const states: Record<string, ModState> = {};
  const values: Array<[string, ModState]> = [];
  const { h } = mount({
    modState: m => states[m] ?? "off",
    onModChange: (m, down) => { states[m] = down ? "held" : "off"; },
    drawer: { active: () => true, systemKeyboard: vi.fn(), text: value => values.push([value, states.ctrl ?? "off"]) },
  });
  const ctrl = h.el.querySelector<HTMLElement>('[data-key-id="ctrl"]')!;
  const c = h.el.querySelector<HTMLElement>('[data-key-id="char:c"]')!;
  const touch = (el: HTMLElement, type: string, id: number) => {
    const e = new Event(type, { bubbles: true });
    Object.defineProperties(e, { pointerId: { value: id }, pointerType: { value: "touch" }, isPrimary: { value: id === 1 } });
    el.dispatchEvent(e);
  };
  touch(ctrl, "pointerdown", 1);
  touch(c, "pointerdown", 2); touch(c, "pointerup", 2);
  expect(values).toEqual([["c", "held"]]);
  c.click(); expect(values).toHaveLength(1);
  touch(c, "pointerdown", 3); touch(c, "pointercancel", 3);
  expect(values).toHaveLength(1);
  touch(ctrl, "pointerup", 1); expect(states.ctrl).toBe("off");
  h.destroy();
});


it("highlights simultaneous presses independently and clears cancelled fingers", () => {
  const { h } = mount({ drawer: { active: () => true, text: vi.fn(), systemKeyboard: vi.fn() } });
  const a = h.el.querySelector<HTMLElement>('[data-key-id="char:a"]')!;
  const b = h.el.querySelector<HTMLElement>('[data-key-id="char:b"]')!;
  pointer(a, "pointerdown", 1); pointer(b, "pointerdown", 2);
  expect(a.classList.contains("is-pressed")).toBe(true);
  expect(b.classList.contains("is-pressed")).toBe(true);
  pointer(a, "pointerup", 1);
  expect(a.classList.contains("is-pressed")).toBe(false);
  expect(b.classList.contains("is-pressed")).toBe(true);
  pointer(b, "pointercancel", 2);
  expect(b.classList.contains("is-pressed")).toBe(false);
  h.destroy();
});
