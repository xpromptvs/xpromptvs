import type { ChannelLike } from "../lib/channel";
import { encodeJson } from "../lib/codec";
import { toNormalized, type PointerHandle, type ViewGestureKind } from "./input";
import type { ClientRect } from "./pointer-map";

/// A SIMULATOR window's input (docs/superpowers/specs/2026-10-13-simulator-sources-design.md, "The client"): every
/// finger PASSES THROUGH as a touch of the simulator — no deferred press, no two-finger scroll, no trackpad cursor;
/// the simulator's own UIKit decides what a gesture means. A mouse is one finger, ⌥ adds a mirrored second (a pinch)
/// and ⌥⇧ a parallel one (a two-finger pan), as Simulator.app has them.

export type SimTouchPhase = "down" | "move" | "up";
export interface SimPointWire { x: number; y: number }
export interface SimTouchWire { t: "sim-touch"; phase: SimTouchPhase; points: SimPointWire[] }

const clamp = (v: number): number => Math.min(1, Math.max(0, v));
const onPicture = (p: SimPointWire): SimPointWire => ({ x: clamp(p.x), y: clamp(p.y) });
const wire = (phase: SimTouchPhase, points: SimPointWire[]): SimTouchWire => ({ t: "sim-touch", phase, points });

/// FINGER SLOTS. The simulator carries ONE gesture of one or two contacts, in slots it never reorders, so a finger
/// takes slot 0 or 1 at its down and keeps it to its up: `points[0]` is always slot 0's finger. Whenever the COUNT
/// changes the gesture ends and a new one starts — a second finger landing ends the one-finger gesture; one of two
/// lifting ends the pair and the other finger starts its own — because a contact cannot join or leave a DTUHID
/// gesture midway. A third finger is ignored.
export class SimFingers {
  private readonly slots: Array<number | null> = [null, null];
  private readonly at = new Map<number, SimPointWire>();

  private points(): SimPointWire[] {
    return this.slots.filter((id): id is number => id !== null).map((id) => this.at.get(id)!);
  }
  private count(): number { return this.slots.filter((s) => s !== null).length; }

  down(id: number, p: SimPointWire): SimTouchWire[] {
    if (this.slots.includes(id)) return [];
    const free = this.slots.indexOf(null);
    if (free < 0) return [];
    const out: SimTouchWire[] = [];
    if (this.count() === 1) out.push(wire("up", this.points()));
    this.slots[free] = id;
    this.at.set(id, onPicture(p));
    out.push(wire("down", this.points()));
    return out;
  }

  move(id: number, p: SimPointWire): SimTouchWire[] {
    if (!this.slots.includes(id)) return [];
    this.at.set(id, onPicture(p));
    return [wire("move", this.points())];
  }

  up(id: number, p: SimPointWire): SimTouchWire[] {
    const slot = this.slots.indexOf(id);
    if (slot < 0) return [];
    this.at.set(id, onPicture(p));
    const out = [wire("up", this.points())];
    this.slots[slot] = null;
    this.at.delete(id);
    if (this.count() === 1) out.push(wire("down", this.points()));
    return out;
  }

  cancel(): SimTouchWire[] {
    if (this.count() === 0) return [];
    const out = [wire("up", this.points())];
    this.slots[0] = null; this.slots[1] = null;
    this.at.clear();
    return out;
  }
}

/// The fingers a MOUSE makes: `p` the pointer, `press` where the button went down (normalised). ⌥: a second finger
/// mirrored about the picture's centre. ⌥⇧: a second finger that starts mirrored at the press and moves WITH the
/// first.
export function mouseFingers(p: SimPointWire, press: SimPointWire, alt: boolean, shift: boolean): SimPointWire[] {
  if (!alt) return [onPicture(p)];
  if (shift) {
    const start = { x: 1 - press.x, y: 1 - press.y };
    return [onPicture(p), onPicture({ x: start.x + (p.x - press.x), y: start.y + (p.y - press.y) })];
  }
  return [onPicture(p), onPicture({ x: 1 - p.x, y: 1 - p.y })];
}

export interface SimTouchOptions {
  /// Only the FOCUSED window sends, as for every window (the host routes input to the focused source). Does not gate
  /// the release: a press that started must end, or the simulator is left with a finger down.
  isActive: () => boolean;
  /// The PICTURE's rect, letterbox and zoom included — the same one a window's touch is normalised against.
  contentRect: () => ClientRect;
  /// "zoom" gives every pointer to `onViewGesture` and the simulator NOTHING, as on any window.
  viewMode?: () => "input" | "zoom";
  onViewGesture?: (kind: ViewGestureKind, id: number, clientX: number, clientY: number) => void;
}

export function attachSimTouch(surface: HTMLElement, inputChannel: ChannelLike, opts: SimTouchOptions): PointerHandle {
  const send = (m: SimTouchWire) => inputChannel.send(encodeJson(m) as Uint8Array<ArrayBuffer>);
  const fingers = new SimFingers();
  let mouse: { press: SimPointWire; alt: boolean; shift: boolean; last: SimPointWire[] } | null = null;
  const inZoom = () => opts.viewMode?.() === "zoom";
  const at = (e: PointerEvent): SimPointWire => toNormalized(opts.contentRect(), e.clientX, e.clientY);
  // THE BROWSER'S CONTEXT MENU IS SUPPRESSED OVER THE PICTURE, NOT GATED ON FOCUS (AGENTS.md; final review I8): a
  // right-click showed Chrome's video menu over the simulator, and an Android long press — a `contextmenu` — opened it
  // and cancelled the simulator's own long press.
  surface.addEventListener("contextmenu", (e) => e.preventDefault());

  surface.addEventListener("pointerdown", (e) => {
    const pe = e as PointerEvent;
    if (inZoom()) {
      surface.setPointerCapture(pe.pointerId);
      opts.onViewGesture?.("down", pe.pointerId, pe.clientX, pe.clientY);
      return;
    }
    if (!opts.isActive()) return;
    if (pe.pointerType === "mouse" && pe.button !== 0) return;   // the primary button is the finger
    pe.preventDefault();
    surface.setPointerCapture(pe.pointerId);
    const p = at(pe);
    if (pe.pointerType === "mouse") {
      const pts = mouseFingers(p, p, pe.altKey, pe.shiftKey);
      mouse = { press: p, alt: pe.altKey, shift: pe.shiftKey, last: pts };
      send(wire("down", pts));
      return;
    }
    for (const m of fingers.down(pe.pointerId, p)) send(m);
  });

  surface.addEventListener("pointermove", (e) => {
    const pe = e as PointerEvent;
    if (inZoom()) { opts.onViewGesture?.("move", pe.pointerId, pe.clientX, pe.clientY); return; }
    if (pe.pointerType === "mouse") {
      if (!mouse) return;
      mouse.last = mouseFingers(at(pe), mouse.press, mouse.alt, mouse.shift);
      send(wire("move", mouse.last));
      return;
    }
    for (const m of fingers.move(pe.pointerId, at(pe))) send(m);
  });

  const end = (e: Event) => {
    const pe = e as PointerEvent;
    try { surface.releasePointerCapture(pe.pointerId); } catch { /* already released */ }
    if (inZoom()) {
      opts.onViewGesture?.(e.type === "pointercancel" ? "cancel" : "up", pe.pointerId, pe.clientX, pe.clientY);
      return;
    }
    if (pe.pointerType === "mouse") {
      if (!mouse) return;
      send(wire("up", mouseFingers(at(pe), mouse.press, mouse.alt, mouse.shift)));
      mouse = null;
      return;
    }
    for (const m of fingers.up(pe.pointerId, at(pe))) send(m);
  };
  surface.addEventListener("pointerup", end);
  surface.addEventListener("pointercancel", end);
  surface.addEventListener("lostpointercapture", end);

  return {
    cancelGesture() {
      for (const m of fingers.cancel()) send(m);
      if (mouse) { send(wire("up", mouse.last)); mouse = null; }
    },
  };
}
