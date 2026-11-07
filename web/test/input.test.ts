import { expect, test } from "vitest";
import { attachPointer, toNormalized } from "../src/client/input";
import { decodeJson } from "../src/lib/codec";
import { Trackpad } from "../src/client/trackpad";

test("maps client coordinates to 0..1 within the element rect", () => {
  const rect = { left: 100, top: 50, width: 200, height: 100 } as DOMRect;
  expect(toNormalized(rect, 200, 100)).toEqual({ x: 0.5, y: 0.5 });
  expect(toNormalized(rect, 100, 50)).toEqual({ x: 0, y: 0 });
  expect(toNormalized(rect, 300, 150)).toEqual({ x: 1, y: 1 });
});

test("clamps out-of-bounds coordinates to 0..1", () => {
  const rect = { left: 0, top: 0, width: 100, height: 100 } as DOMRect;
  expect(toNormalized(rect, -10, 200)).toEqual({ x: 0, y: 1 });
});

// ── smooth scroll ────────────────────────────────────────────────────────────────────────────
import { modsBitmask, scrollToWire } from "../src/client/input";

const scrollRect = { left: 0, top: 0, width: 200, height: 100 } as DOMRect;
const wheel = (o: Partial<WheelEvent>) => ({
  deltaMode: 0, deltaX: 0, deltaY: 0, clientX: 100, clientY: 50,
  shiftKey: false, ctrlKey: false, altKey: false, metaKey: false,
  getModifierState: () => false, ...o,
}) as unknown as WheelEvent;

test("modsBitmask packs each modifier into its own bit", () => {
  expect(modsBitmask(wheel({}))).toBe(0);
  expect(modsBitmask(wheel({ shiftKey: true }))).toBe(1);
  expect(modsBitmask(wheel({ ctrlKey: true }))).toBe(2);
  expect(modsBitmask(wheel({ altKey: true }))).toBe(4);
  expect(modsBitmask(wheel({ metaKey: true }))).toBe(8);
  expect(modsBitmask(wheel({ metaKey: true, altKey: true }))).toBe(12);
  expect(modsBitmask(wheel({ getModifierState: (k: string) => k === "CapsLock" }))).toBe(16);
});

test("a pixel-mode wheel forwards pixels undivided", () => {
  const m = scrollToWire(wheel({ deltaMode: 0, deltaY: 14.5 }), scrollRect, 1);
  expect(m.unit).toBe("px");
  expect(m.dy).toBeCloseTo(14.5);   // NOT /40 — that dead zone is the bug
});

test("a line-mode wheel forwards lines and is never divided by the draw scale", () => {
  // A line delta is a NOTCH COUNT, not a length: scaling it would be meaningless.
  const m = scrollToWire(wheel({ deltaMode: 1, deltaY: 3 }), scrollRect, 0.5);
  expect(m.unit).toBe("line");
  expect(m.dy).toBeCloseTo(3);
});

test("pixel deltas are converted to host points by the draw scale", () => {
  // A window drawn at 50% must scroll its content by what the flick LOOKS like it moves,
  // the same rule the resize grip already follows.
  const m = scrollToWire(wheel({ deltaMode: 0, deltaY: 20, deltaX: -10 }), scrollRect, 0.5);
  expect(m.dy).toBeCloseTo(40);
  expect(m.dx).toBeCloseTo(-20);
});

test("the wire message carries the normalized position and the modifier snapshot", () => {
  const m = scrollToWire(wheel({ deltaMode: 0, deltaY: 1, clientX: 50, clientY: 25, altKey: true }), scrollRect, 1);
  expect(m.t).toBe("scroll");
  expect(m.x).toBeCloseTo(0.25);
  expect(m.y).toBeCloseTo(0.25);
  expect(m.mods).toBe(4);
});

test("a tap on a LETTERBOXED surface normalizes against the picture, not the body", () => {
  // THE DEFECT. A 400x400 body showing a 16:9 picture has 87.5px bars top and bottom. A tap at the
  // vertical centre of the PICTURE is the vertical centre of the body too, so the centre alone
  // cannot catch this — the top edge of the picture can.
  const sent: unknown[] = [];
  const channel = { send: (b: Uint8Array) => sent.push(decodeJson(b)) } as unknown as RTCDataChannel;
  const surface = document.createElement("div");
  // jsdom's HTMLElement has neither method, and attachPointer calls both.
  surface.setPointerCapture = () => {}; surface.releasePointerCapture = () => {};
  surface.getBoundingClientRect = () => ({ left: 0, top: 0, width: 400, height: 400 }) as DOMRect;
  attachPointer(surface, channel, () => 0, {
    contentRect: () => ({ left: 0, top: 87.5, width: 400, height: 225 }),
  });

  // y = 87.5 is the picture's TOP edge. Against the body it would read 0.219; against the picture, 0.
  surface.dispatchEvent(Object.assign(
    new Event("pointerdown", { bubbles: true }),
    { clientX: 200, clientY: 87.5, pointerId: 1 },
  ));
  expect(sent).toHaveLength(1);
  expect(sent[0]).toMatchObject({ t: "touch", phase: "down", x: 0.5, y: 0 });
});

test("with no content rect it still measures the surface, so a caller with no video is unchanged", () => {
  const sent: unknown[] = [];
  const channel = { send: (b: Uint8Array) => sent.push(decodeJson(b)) } as unknown as RTCDataChannel;
  const surface = document.createElement("div");
  surface.setPointerCapture = () => {}; surface.releasePointerCapture = () => {};
  surface.getBoundingClientRect = () => ({ left: 0, top: 0, width: 400, height: 400 }) as DOMRect;
  attachPointer(surface, channel, () => 0);
  surface.dispatchEvent(Object.assign(
    new Event("pointerdown", { bubbles: true }),
    { clientX: 200, clientY: 200, pointerId: 1 },
  ));
  expect(sent[0]).toMatchObject({ x: 0.5, y: 0.5 });
});

test("in trackpad mode a tap clicks at the cursor, not under the finger", () => {
  const sent: any[] = [];
  const channel = { send: (b: Uint8Array) => sent.push(decodeJson(b)) } as unknown as RTCDataChannel;
  const surface = document.createElement("div");
  surface.setPointerCapture = () => {}; surface.releasePointerCapture = () => {};
  surface.getBoundingClientRect = () => ({ left: 0, top: 0, width: 400, height: 225 }) as DOMRect;
  attachPointer(surface, channel, () => 0, {
    contentRect: () => ({ left: 0, top: 0, width: 400, height: 225 }),
    mode: () => "trackpad",
    trackpad: new Trackpad(),
    drawScale: () => 1,
  });

  // Tap in the top-left corner. Direct mode would send (0,0); trackpad clicks at the centred cursor.
  surface.dispatchEvent(Object.assign(new Event("pointerdown", { bubbles: true }),
    { clientX: 0, clientY: 0, pointerId: 1 }));
  surface.dispatchEvent(Object.assign(new Event("pointerup", { bubbles: true }),
    { clientX: 0, clientY: 0, pointerId: 1 }));
  // `button` is ABSENT, not "left": one builder now serves the mouse path and both gesture
  // machines, and the rule it enforces is that left is never spelled out on the wire.
  expect(sent).toEqual([
    { t: "touch", phase: "down", id: 1, x: 0.5, y: 0.5, ts: 0 },
    { t: "touch", phase: "up", id: 1, x: 0.5, y: 0.5, ts: 0 },
  ]);
});

test("trackpad scroll deltas are divided by the draw scale, like a wheel's", () => {
  const sent: any[] = [];
  const channel = { send: (b: Uint8Array) => sent.push(decodeJson(b)) } as unknown as RTCDataChannel;
  const surface = document.createElement("div");
  surface.setPointerCapture = () => {}; surface.releasePointerCapture = () => {};
  surface.getBoundingClientRect = () => ({ left: 0, top: 0, width: 400, height: 225 }) as DOMRect;
  attachPointer(surface, channel, () => 0, {
    contentRect: () => ({ left: 0, top: 0, width: 400, height: 225 }),
    mode: () => "trackpad", trackpad: new Trackpad(), drawScale: () => 0.5,
  });
  const at = (type: string, x: number, y: number, id: number) =>
    surface.dispatchEvent(Object.assign(new Event(type, { bubbles: true }),
      { clientX: x, clientY: y, pointerId: id }));
  at("pointerdown", 10, 10, 1);
  at("pointerdown", 30, 10, 2);
  at("pointermove", 30, 90, 2);
  const scroll = sent.find((m) => m.t === "scroll");
  // Centroid moved +40px; natural scrolling negates it; drawScale 0.5 doubles it into host points.
  expect(scroll).toMatchObject({ t: "scroll", unit: "px" });
  expect(scroll.dy).toBeCloseTo(-80);
});

// ── right click ──────────────────────────────────────────────────────────────────────────────
import { isApplePlatform, pointerButton } from "../src/client/input";
import { TWO_FINGER_WINDOW_MS } from "../src/client/direct-touch";

test("the secondary mouse button is right on every platform", () => {
  expect(pointerButton({ button: 2, ctrlKey: false }, false)).toBe("right");
  expect(pointerButton({ button: 2, ctrlKey: false }, true)).toBe("right");
});

test("ctrl+click is right ONLY on an Apple client", () => {
  // THE PLATFORM GATE IS THE POINT. On macOS a control-click IS the secondary click; on
  // Windows/Linux it is a genuine ctrl+click (multi-select) and must stay left, or rdev would
  // make ctrl+click unreachable on every non-Mac client.
  expect(pointerButton({ button: 0, ctrlKey: true }, true)).toBe("right");
  expect(pointerButton({ button: 0, ctrlKey: true }, false)).toBe("left");
});

test("an ordinary press and a middle click are left", () => {
  expect(pointerButton({ button: 0, ctrlKey: false }, true)).toBe("left");
  expect(pointerButton({ button: 1, ctrlKey: true }, true)).toBe("left");
  // A client predating pointer `button` (and jsdom's bare Event) reports undefined: still left.
  expect(pointerButton({ button: undefined as unknown as number, ctrlKey: false }, true)).toBe("left");
});

test("isApplePlatform reads userAgentData first, then platform, then the UA string", () => {
  expect(isApplePlatform({ userAgentData: { platform: "macOS" }, platform: "Win32" })).toBe(true);
  expect(isApplePlatform({ platform: "MacIntel" })).toBe(true);       // also iPadOS Safari
  expect(isApplePlatform({ platform: "iPhone" })).toBe(true);
  expect(isApplePlatform({ platform: "Win32" })).toBe(false);
  expect(isApplePlatform({ platform: "Linux x86_64" })).toBe(false);
  expect(isApplePlatform({ userAgent: "… like Mac OS X … Safari" })).toBe(true);
  expect(isApplePlatform({})).toBe(false);
});

/// A surface wired for direct-mode pointer input, plus the messages it sent.
function directSurface(platform = "Win32") {
  const sent: any[] = [];
  const channel = { send: (b: Uint8Array) => sent.push(decodeJson(b)) } as unknown as RTCDataChannel;
  const surface = document.createElement("div");
  surface.setPointerCapture = () => {}; surface.releasePointerCapture = () => {};
  surface.getBoundingClientRect = () => ({ left: 0, top: 0, width: 400, height: 200 }) as DOMRect;
  Object.defineProperty(globalThis.navigator, "platform", { value: platform, configurable: true });
  attachPointer(surface, channel, () => 0);
  const at = (type: string, o: Record<string, unknown>) =>
    surface.dispatchEvent(Object.assign(new Event(type, { bubbles: true, cancelable: true }),
      { clientX: 200, clientY: 100, pointerId: 1, button: 0, ctrlKey: false, ...o }));
  return { sent, surface, at };
}

test("a right press carries button:right through the WHOLE gesture", () => {
  // The press's button is resolved ONCE at pointerdown: per the Pointer Events spec a chorded
  // second button fires pointermove, not another pointerdown, so the down event is the only
  // honest place to read it — and the host maps a drag to rightMouseDragged off this field.
  const { sent, at } = directSurface();
  at("pointerdown", { button: 2 });
  at("pointermove", { button: 2, clientX: 300 });
  at("pointerup", { button: 2, clientX: 300 });
  expect(sent.map((m) => [m.phase, m.button])).toEqual([
    ["down", "right"], ["move", "right"], ["up", "right"],
  ]);
});

test("a right press released with button 0 reported still releases RIGHT", () => {
  // A stuck rightMouseDown on the host is unrecoverable from the client. The release must use the
  // button the PRESS resolved, never whatever the up event happens to report.
  const { sent, at } = directSurface();
  at("pointerdown", { button: 2 });
  at("pointerup", { button: 0 });
  expect(sent[1]).toMatchObject({ phase: "up", button: "right" });
});

test("a LEFT press omits the button field entirely", () => {
  // ABSENT MEANS LEFT on the host. Omitting keeps every message the direct path ships today
  // byte-identical, and keeps that host rule exercised in production rather than dead.
  const { sent, at } = directSurface();
  at("pointerdown", {});
  at("pointerup", {});
  expect(sent).toEqual([
    { t: "touch", phase: "down", id: 1, x: 0.5, y: 0.5, ts: 0 },
    { t: "touch", phase: "up", id: 1, x: 0.5, y: 0.5, ts: 0 },
  ]);
});

test("ctrl+click reaches the wire as right on a Mac client and as left elsewhere", () => {
  // Drives the REAL navigator read, not just the pure mapping: without this a mutation pinning
  // attachPointer's platform flag to a constant would falsify nothing.
  const mac = directSurface("MacIntel");
  mac.at("pointerdown", { button: 0, ctrlKey: true });
  expect(mac.sent[0]).toMatchObject({ phase: "down", button: "right" });

  const pc = directSurface("Win32");
  pc.at("pointerdown", { button: 0, ctrlKey: true });
  expect(pc.sent[0].button).toBeUndefined();
});

test("the browser's context menu is suppressed over the picture, focused or not", () => {
  // NOT gated on isActive, unlike the wheel: an unfocused window's wheel usefully falls through to
  // page scroll, but there is no useful fallthrough for Chrome's video menu over the video — and
  // the FIRST right click into an unfocused window is exactly the one that would pop it.
  const sent: unknown[] = [];
  const channel = { send: (b: Uint8Array) => sent.push(decodeJson(b)) } as unknown as RTCDataChannel;
  const surface = document.createElement("div");
  surface.setPointerCapture = () => {}; surface.releasePointerCapture = () => {};
  surface.getBoundingClientRect = () => ({ left: 0, top: 0, width: 400, height: 200 }) as DOMRect;
  attachPointer(surface, channel, () => 0, { isActive: () => false });
  const menu = new Event("contextmenu", { bubbles: true, cancelable: true });
  surface.dispatchEvent(menu);
  expect(menu.defaultPrevented).toBe(true);
  expect(sent).toHaveLength(0);   // suppressing is not injecting
});

// ── direct mode, multi-finger ────────────────────────────────────────────────────────────────

/// A surface in DIRECT mode driven by `pointerType: "touch"` events, with a controllable clock.
function fingerSurface() {
  const sent: any[] = [];
  let now = 0;
  const channel = { send: (b: Uint8Array) => sent.push(decodeJson(b)) } as unknown as RTCDataChannel;
  const surface = document.createElement("div");
  surface.setPointerCapture = () => {}; surface.releasePointerCapture = () => {};
  surface.getBoundingClientRect = () => ({ left: 0, top: 0, width: 400, height: 200 }) as DOMRect;
  attachPointer(surface, channel, () => now, {
    contentRect: () => ({ left: 0, top: 0, width: 400, height: 200 }),
  });
  const at = (type: string, id: number, x: number, y: number, t: number) => {
    now = t;
    surface.dispatchEvent(Object.assign(new Event(type, { bubbles: true, cancelable: true }),
      { clientX: x, clientY: y, pointerId: id, pointerType: "touch", button: 0, ctrlKey: false }));
  };
  return { sent, at, tick: (t: number) => { now = t; } };
}

test("REGRESSION: two fingers never leave the host holding a button", () => {
  // The shipped direct path sent `down id=1`, `down id=2`, moves and ONE `up`: two leftMouseDowns
  // against one leftMouseUp. This is that exact gesture, through the real attachment.
  const { sent, at } = fingerSurface();
  at("pointerdown", 1, 100, 100, 0);
  at("pointerdown", 2, 140, 100, 20);
  at("pointermove", 1, 100, 60, 40);
  at("pointermove", 2, 140, 60, 40);
  at("pointerup", 1, 100, 60, 60);
  at("pointerup", 2, 140, 60, 70);
  const touches = sent.filter((m) => m.t === "touch");
  const downs = touches.filter((m) => m.phase === "down").length;
  const ups = touches.filter((m) => m.phase === "up").length;
  expect(downs).toBe(ups);
  expect(sent.some((m) => m.t === "scroll")).toBe(true);   // and it scrolled rather than doing nothing
});

test("a two-finger pan reaches the wire as scroll, and the flick as ONE fling", () => {
  const { sent, at } = fingerSurface();
  at("pointerdown", 1, 100, 180, 0);
  at("pointerdown", 2, 140, 180, 5);
  for (let i = 1; i <= 6; i++) {
    at("pointermove", 1, 100, 180 - i * 20, i * 10);
    at("pointermove", 2, 140, 180 - i * 20, i * 10);
  }
  at("pointerup", 1, 100, 60, 65);
  at("pointerup", 2, 140, 60, 75);
  expect(sent.filter((m) => m.t === "scroll").length).toBeGreaterThan(0);
  expect(sent.filter((m) => m.t === "scroll-fling")).toHaveLength(1);
  expect(sent.find((m) => m.t === "scroll")).toMatchObject({ unit: "px" });
});

test("a two-finger tap reaches the wire as a RIGHT click", () => {
  const { sent, at } = fingerSurface();
  at("pointerdown", 1, 100, 100, 0);
  at("pointerdown", 2, 140, 100, 10);
  at("pointerup", 1, 100, 100, 60);
  at("pointerup", 2, 140, 100, 70);
  expect(sent.map((m) => [m.phase, m.button])).toEqual([["down", "right"], ["up", "right"]]);
});

test("a single finger's press is deferred, then flushed by the timer", async () => {
  const { sent, at, tick } = fingerSurface();
  at("pointerdown", 1, 100, 100, 0);
  expect(sent).toHaveLength(0);                       // nothing crosses the wire yet
  tick(TWO_FINGER_WINDOW_MS + 5);
  await new Promise((r) => setTimeout(r, TWO_FINGER_WINDOW_MS + 20));
  expect(sent).toEqual([{ t: "touch", phase: "down", id: 1, x: 0.25, y: 0.5, ts: TWO_FINGER_WINDOW_MS + 5 }]);
});

test("A MOUSE IS UNTOUCHED BY THE DEFERRAL — its press is immediate", () => {
  // The whole reason the routing keys off pointerType. A 50ms tax on every desktop click would be
  // self-defeating on a product whose thesis is latency.
  const { sent, at } = directSurface();
  at("pointerdown", { pointerType: "mouse" });
  expect(sent).toHaveLength(1);
  expect(sent[0]).toMatchObject({ t: "touch", phase: "down" });
});

test("direct mode does NOT paint the indirect mode's virtual cursor", () => {
  // `paintCursor` is a parameter, and a parameter whose mutation falsifies nothing is not a guard.
  // The dot belongs to trackpad mode; drawing it under a finger that is not driving it would show
  // a second cursor beside the host's own.
  const moves: number[] = [];
  const channel = { send: () => {} } as unknown as RTCDataChannel;
  const surface = document.createElement("div");
  surface.setPointerCapture = () => {}; surface.releasePointerCapture = () => {};
  surface.getBoundingClientRect = () => ({ left: 0, top: 0, width: 400, height: 200 }) as DOMRect;
  attachPointer(surface, channel, () => 0, { onCursorMove: (x) => moves.push(x) });
  const at = (type: string, id: number, x: number, y: number) =>
    surface.dispatchEvent(Object.assign(new Event(type, { bubbles: true, cancelable: true }),
      { clientX: x, clientY: y, pointerId: id, pointerType: "touch", button: 0, ctrlKey: false }));
  at("pointerdown", 1, 100, 100);
  at("pointerdown", 2, 140, 100);
  at("pointerup", 1, 100, 100);
  at("pointerup", 2, 140, 100);   // a two-finger tap: emits a right click through `emit`
  expect(moves).toEqual([]);
});

// ── zoom gestures ────────────────────────────────────────────────────────────────────────────
import { attachScroll } from "../src/client/input";

function scrollSurface(active = true) {
  const sent: any[] = [];
  const channel = { send: (b: Uint8Array) => sent.push(decodeJson(b)) } as unknown as RTCDataChannel;
  const surface = document.createElement("div");
  surface.getBoundingClientRect = () => ({ left: 0, top: 0, width: 400, height: 200 }) as DOMRect;
  attachScroll(surface, channel, { isActive: () => active });
  const fire = (type: string, props: Record<string, unknown> = {}) => {
    const e = Object.assign(new Event(type, { bubbles: true, cancelable: true }), {
      clientX: 200, clientY: 100, deltaMode: 0, deltaX: 0, deltaY: 0,
      shiftKey: false, ctrlKey: false, altKey: false, metaKey: false,
      getModifierState: () => false, ...props,
    });
    surface.dispatchEvent(e);
    return e;
  };
  return { sent, fire };
}

test("a PINCH is dropped, not forwarded as a ctrl+scroll", () => {
  // MEASURED 2026-09-03 in real Safari: one pinch produces wheel events carrying ctrlKey. Forwarded
  // as-is the host receives a ctrl+scroll — a modifier the user never pressed, which on macOS is the
  // screen-zoom idiom. It must still be preventDefault'd, or the BROWSER zooms instead.
  const { sent, fire } = scrollSurface();
  const e = fire("wheel", { ctrlKey: true, deltaY: -4.25 });
  expect(sent).toEqual([]);
  expect(e.defaultPrevented).toBe(true);
});

test("a pinch is suppressed even when the window is UNFOCUSED", () => {
  // Ungated, unlike an ordinary wheel. An unfocused window's scroll usefully falls through to page
  // scrolling; a pinch falling through zooms the client, which is never wanted.
  const { sent, fire } = scrollSurface(false);
  const e = fire("wheel", { ctrlKey: true, deltaY: -4.25 });
  expect(sent).toEqual([]);
  expect(e.defaultPrevented).toBe(true);
});

test("an ordinary wheel is untouched by the pinch arm", () => {
  const { sent, fire } = scrollSurface();
  fire("wheel", { deltaY: 12 });
  expect(sent).toHaveLength(1);
  expect(sent[0]).toMatchObject({ t: "scroll", unit: "px", dy: 12, mods: 0 });
});

test("an unfocused ordinary wheel still falls through to the page", () => {
  const { sent, fire } = scrollSurface(false);
  const e = fire("wheel", { deltaY: 12 });
  expect(sent).toEqual([]);
  expect(e.defaultPrevented).toBe(false);   // the page scrolls, as it always has
});

test("Safari's non-standard gesture events are prevented", () => {
  // MEASURED: one Safari pinch fires 78 of these ALONGSIDE the ctrlKey wheels, scale 1.00 -> 1.14.
  // Their default action is browser zoom — Apple's own doc says preventDefault is how you stop it —
  // and zooming the client moves the viewport width that `chooseLayoutMode` reads.
  const { fire } = scrollSurface();
  for (const g of ["gesturestart", "gesturechange", "gestureend"]) {
    expect(fire(g).defaultPrevented).toBe(true);
  }
});

// ── zoom mode ────────────────────────────────────────────────────────────────────────────────

/// A surface with the pointer-capture methods jsdom lacks, and a channel that records what was sent.
const mkSurface = () => {
  const el = document.createElement("div");
  el.setPointerCapture = () => {};
  el.releasePointerCapture = () => {};
  el.getBoundingClientRect = () => ({ left: 0, top: 0, width: 400, height: 300,
    right: 400, bottom: 300, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
  const sent: unknown[] = [];
  const ch = { send: (b: Uint8Array) => sent.push(decodeJson(b)) } as unknown as RTCDataChannel;
  return { el, ch, sent };
};
/// jsdom has no `PointerEvent` constructor, so the house idiom is an `Event` with the fields the
/// handlers read assigned onto it — the same helper shape `at` uses above.
const finger = (type: string, id: number, x: number, y: number) =>
  Object.assign(new Event(type, { bubbles: true }),
    { clientX: x, clientY: y, pointerId: id, pointerType: "touch" });

test("zoom mode sends NOTHING on the input channel and reports the gesture instead", () => {
  const { el, ch, sent } = mkSurface();
  const seen: string[] = [];
  attachPointer(el, ch, () => 0, {
    viewMode: () => "zoom",
    onViewGesture: (kind, id, x, y) => seen.push(`${kind}:${id}:${x},${y}`),
  });
  el.dispatchEvent(finger("pointerdown", 1, 10, 20));
  el.dispatchEvent(finger("pointermove", 1, 30, 40));
  el.dispatchEvent(finger("pointerup", 1, 30, 40));
  expect(sent).toEqual([]);
  expect(seen).toEqual(["down:1:10,20", "move:1:30,40", "up:1:30,40"]);
});

test("input mode is unchanged — the non-zero guard for the assertion above", () => {
  const { el, ch, sent } = mkSurface();
  attachPointer(el, ch, () => 0, { viewMode: () => "input" });
  el.dispatchEvent(finger("pointerdown", 1, 10, 20));
  el.dispatchEvent(finger("pointerup", 1, 10, 20));
  // A lift inside the two-finger window is a tap: down + up.
  expect(sent.filter((m) => (m as { t: string }).t === "touch")).toHaveLength(2);
});

test("cancelGesture RELEASES a press the host is holding", () => {
  // THE FALSIFICATION IS A STUCK BUTTON. A finger on the glass when the mode button is pressed has a
  // real leftMouseDown behind it, so the assertion is on the wire message, not on any internal phase.
  const { el, ch, sent } = mkSurface();
  const handle = attachPointer(el, ch, () => 0, { viewMode: () => "input" });
  el.dispatchEvent(finger("pointerdown", 1, 10, 20));
  el.dispatchEvent(finger("pointermove", 1, 100, 120));   // past the slop -> the press is sent
  expect(sent.some((m) => (m as { t: string; phase: string }).phase === "down")).toBe(true);
  sent.length = 0;
  handle.cancelGesture();
  expect(sent.filter((m) => (m as { phase?: string }).phase === "up")).toHaveLength(1);
});

test("a wheel sends nothing while the mode is zoom", () => {
  const { el, ch, sent } = mkSurface();
  attachScroll(el, ch, { viewMode: () => "zoom" });
  el.dispatchEvent(new WheelEvent("wheel", { deltaY: 40, bubbles: true, cancelable: true }));
  expect(sent).toEqual([]);
});
test("losing pointer capture releases the original host press", () => {
  const {el,ch,sent}=mkSurface();attachPointer(el,ch,()=>0,{viewMode:()=>"input"});
  el.dispatchEvent(finger("pointerdown",1,10,20));el.dispatchEvent(finger("pointermove",1,100,120));sent.length=0;
  el.dispatchEvent(finger("lostpointercapture",1,100,120));
  expect(sent.filter(m=>(m as {phase?:string}).phase==='up')).toHaveLength(1);
});

test('cancelGesture removes a scheduled hover before a later native activation can reuse it', () => {
  const originalRaf=globalThis.requestAnimationFrame, originalCancel=globalThis.cancelAnimationFrame;
  let next=0;const frames=new Map<number,FrameRequestCallback>();
  globalThis.requestAnimationFrame=callback=>{frames.set(++next,callback);return next;};
  globalThis.cancelAnimationFrame=id=>{frames.delete(id);};
  try {
    const {el,ch,sent}=mkSurface();const pointer=attachPointer(el,ch,()=>0);
    el.dispatchEvent(Object.assign(new MouseEvent('pointermove',{clientX:80,clientY:90}),{pointerId:1,pointerType:'mouse'}));
    expect(frames.size).toBe(1);pointer.cancelGesture();
    for(const callback of frames.values())callback(16);
    expect(sent).toEqual([]);
  }finally{globalThis.requestAnimationFrame=originalRaf;globalThis.cancelAnimationFrame=originalCancel;}
});
