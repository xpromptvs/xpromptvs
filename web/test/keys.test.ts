import { expect, test } from "vitest";
import { keyEventToWire } from "../src/client/keys";
import { decodeJson } from "../src/lib/codec";

const ev = (o: Partial<KeyboardEvent>) => ({
  code: "KeyA", key: "a", repeat: false, isComposing: false,
  shiftKey: false, ctrlKey: false, altKey: false, metaKey: false,
  getModifierState: () => false, ...o,
}) as unknown as KeyboardEvent;

test("a keydown carries the physical code and the produced character", () => {
  expect(keyEventToWire(ev({ code: "KeyA", key: "a" }), true))
    .toEqual({ t: "win-key", down: true, code: "KeyA", key: "a", repeat: false, mods: 0 });
});

test("a keyup is a keyup", () => {
  expect(keyEventToWire(ev({}), false)?.down).toBe(false);
});

test("modifiers ride along as a bitmask", () => {
  expect(keyEventToWire(ev({ code: "KeyC", key: "c", metaKey: true }), true)?.mods).toBe(8);
});

test("auto-repeat is reported, not swallowed", () => {
  // macOS apps do their own repeat off received keyDowns, so repeats MUST be forwarded.
  expect(keyEventToWire(ev({ repeat: true }), true)?.repeat).toBe(true);
});

test("a key produced mid-composition is not forwarded", () => {
  // The composed character arrives on its own event; forwarding the intermediate types twice.
  expect(keyEventToWire(ev({ isComposing: true }), true)).toBeNull();
});

test("an event with no physical identity at all is not forwarded", () => {
  expect(keyEventToWire(ev({ code: "", key: "" }), true)).toBeNull();
});

test("a named key keeps its name, for the host to map", () => {
  // The host decides that "ArrowUp" is a name and not a character; the client stays dumb.
  expect(keyEventToWire(ev({ code: "ArrowUp", key: "ArrowUp" }), true))
    .toEqual({ t: "win-key", down: true, code: "ArrowUp", key: "ArrowUp", repeat: false, mods: 0 });
});

// ── The glasses guard ────────────────────────────────────────────────────────────────────────────
// On glasses the D-pad IS the keyboard: arrows and Enter arrive as key events at the focused
// element. `attachWindowKeys` preventDefaults and forwards every key a focused .win-body sees, and
// the desktop escape from that is the mouse — which glasses do not have. One pinch into a projected
// window would hand the wearer's only input device to the remote Mac permanently.
import { attachWindowKeys, releaseKeyboardOwner } from "../src/client/keys";

const attach = (layout: string) => {
  document.documentElement.dataset.layout = layout;
  const body = document.createElement("div");
  document.body.append(body);
  const sent: unknown[] = [];
  const channel = { send: (b: unknown) => sent.push(b) } as unknown as RTCDataChannel;
  attachWindowKeys(body, channel, () => true);
  return { body, sent };
};

const key = (k: string, code: string) =>
  new KeyboardEvent("keydown", { key: k, code, bubbles: true, cancelable: true });

test("glasses: forwards nothing at all — the D-pad must stay ours", () => {
  const { body, sent } = attach("glasses");
  body.dispatchEvent(key("ArrowDown", "ArrowDown"));
  body.dispatchEvent(key("Enter", "Enter"));
  body.dispatchEvent(key("a", "KeyA"));
  expect(sent).toHaveLength(0);
});

test("floating: still forwards, so the guard is narrow", () => {
  const { body, sent } = attach("floating");
  body.dispatchEvent(key("a", "KeyA"));
  expect(sent.length).toBeGreaterThan(0);
});

test("unset data-layout still forwards — it means floating, not glasses", () => {
  delete document.documentElement.dataset.layout;
  const body = document.createElement("div");
  document.body.append(body);
  const sent: unknown[] = [];
  attachWindowKeys(body, { send: (b: unknown) => sent.push(b) } as unknown as RTCDataChannel, () => true);
  body.dispatchEvent(key("a", "KeyA"));
  expect(sent.length).toBeGreaterThan(0);
});

// ── attachWindowKeys extraMods ───────────────────────────────────────────────────────────────────
// The on-screen key strip latches its modifiers outside the DOM keyboard, so an iPad with BOTH a
// hardware keyboard and the strip has to be able to arm Ctrl with a finger and press the letter
// physically. That is the whole job of `extraMods`.

const wireUp = (extraMods?: () => number) => {
  const sent: Record<string, unknown>[] = [];
  const body = document.createElement("div");
  document.body.append(body);
  // decodeJson, not TextDecoder: encodeJson WRAPS the payload with a codec header, so reading it
  // back by hand parses the header as if it were JSON and throws.
  const ch = {
    send: (d: Uint8Array) => sent.push(decodeJson<Record<string, unknown>>(d)),
  } as unknown as RTCDataChannel;
  attachWindowKeys(body, ch, () => true, extraMods);
  return { body, sent };
};

test("extraMods is OR'd into a hardware keystroke", () => {
  const { body, sent } = wireUp(() => 8);
  body.dispatchEvent(new KeyboardEvent("keydown", { code: "KeyC", key: "c" }));
  expect(sent[0]).toMatchObject({ t: "win-key", code: "KeyC", mods: 8 });
  body.remove();
});

test("extraMods COMBINES with the event's own modifiers rather than replacing them", () => {
  const { body, sent } = wireUp(() => 2);                     // strip holds Ctrl
  body.dispatchEvent(new KeyboardEvent("keydown", { code: "KeyC", key: "c", shiftKey: true }));
  expect(sent[0]).toMatchObject({ mods: 3 });                 // shift 1 | ctrl 2
  body.remove();
});

test("mods are untouched when no extraMods is supplied", () => {
  const { body, sent } = wireUp();
  body.dispatchEvent(new KeyboardEvent("keydown", { code: "KeyC", key: "c" }));
  expect(sent[0]).toMatchObject({ mods: 0 });
  body.remove();
});

test("releaseKeyboardOwner: a disposed session's window no longer gets the page-level release", () => {
  delete document.documentElement.dataset.layout;
  const sent: Record<string, unknown>[] = [];
  const body = document.createElement("div");
  body.tabIndex = 0;
  document.body.append(body);
  attachWindowKeys(body, { send: (d: Uint8Array) => sent.push(decodeJson<Record<string, unknown>>(d)) } as unknown as RTCDataChannel, () => true);
  body.focus();
  window.dispatchEvent(new Event("blur"));
  expect(sent).toEqual([{ t: "win-keys-release" }]);   // CONTROL: the owner is live
  sent.length = 0;
  releaseKeyboardOwner();
  window.dispatchEvent(new Event("blur"));
  expect(sent).toEqual([]);
  body.remove();
});
