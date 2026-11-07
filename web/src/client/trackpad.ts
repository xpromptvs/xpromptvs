/// Indirect ("trackpad") pointer control for a touchscreen.
///
/// PURE — no DOM, no timers, no layout. Every transition is a function of the events handed to it,
/// which is what makes the whole gesture vocabulary testable with plain numbers. `input.ts` does
/// nothing but feed it pointer events and send what it returns.
///
/// COORDINATES. Inputs are CONTENT-rect pixels (the picture's own space, from `containedRect`).
/// Every output x/y is the NORMALIZED cursor, which is what the wire wants. `scroll` deltas come out
/// in CONTENT PIXELS and the attachment divides by `drawScale`: that is a layout quantity and the
/// machine has no business knowing it.
import { FlingTracker } from "./fling-tracker";
import type { Box } from "./pointer-map";

/// Movement below which a press is still a tap, in content pixels.
export const TAP_SLOP_PX = 10;
/// Press duration below which a release is a tap.
export const TAP_MAX_MS = 300;
/// Window after a tap in which a new press arms a drag.
export const DOUBLE_TAP_MS = 300;
/// Cursor pixels per finger pixel at rest. BELOW 1 on purpose — a Mac's UI targets are far smaller
/// than a finger, and the whole reason for an indirect mode is to be able to hit them.
export const MIN_GAIN = 0.6;
/// Cursor pixels per finger pixel at full speed, so a flick still crosses a 1700pt desktop.
export const MAX_GAIN = 3.0;
/// The speed, in content px per ms, at which the gain saturates.
export const ACCEL_REF = 2.0;
/// Fingers moving down scroll the content down. Flipping this is the whole of "unnatural" scrolling.
export const TWO_FINGER_NATURAL = true;
// The three fling constants live in `fling-tracker.ts` beside the algorithm that reads them, and
// are re-exported here so every existing importer is unchanged.
export { FLING_IDLE_MS, FLING_MIN_SPEED, FLING_WINDOW_MS } from "./fling-tracker";

// THE CONSTANTS ABOVE ARE UNTUNED STARTING POINTS, not measured values. The tests assert the
// curve's SHAPE — monotonic, bounded, direction-preserving — so tuning them stays a one-line change.

export interface TrackpadEvent {
  kind: "down" | "move" | "up" | "cancel";
  id: number;
  /// CONTENT-rect pixels.
  x: number;
  y: number;
  /// Milliseconds; any monotonic clock will do.
  t: number;
}

export type TrackpadOutput =
  | { t: "hover"; x: number; y: number }
  | { t: "touch"; phase: "down" | "move" | "up"; button: "left" | "right"; x: number; y: number }
  | { t: "scroll"; dx: number; dy: number; x: number; y: number }
  /// The two-finger gesture ended in a flick: the HOST runs the glide from here. `vx`/`vy` are
  /// content px per SECOND in the same sign convention as `scroll`'s deltas, and ZERO means stop.
  | { t: "fling"; vx: number; vy: number; x: number; y: number };

/// A linear ramp saturating at `ACCEL_REF`, applied as a SCALAR on the movement vector so direction
/// is untouched.
export function accelGain(speedPxPerMs: number): number {
  const k = Math.min(1, Math.max(0, speedPxPerMs) / ACCEL_REF);
  return MIN_GAIN + (MAX_GAIN - MIN_GAIN) * k;
}

type Phase = "idle" | "pressing" | "moving" | "dragging" | "twoFinger" | "twoScroll";

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));
const dist = (a: { x: number; y: number }, b: { x: number; y: number }) => Math.hypot(a.x - b.x, a.y - b.y);

export class Trackpad {
  private pos = { x: 0.5, y: 0.5 };
  private phase: Phase = "idle";
  private pointers = new Map<number, { x: number; y: number }>();
  private startPt = { x: 0, y: 0 };
  private startT = 0;
  private lastPt = { x: 0, y: 0 };
  private lastT = 0;
  /// When the last completed tap ended, so the NEXT press can arm a drag. `-Infinity` means "no tap
  /// is pending", which is also how a consumed tap is cleared — a third press must not re-arm.
  private lastTapT = -Infinity;
  /// The tail of the two-finger gesture. Shared with direct mode — see `fling-tracker.ts`.
  private fling = new FlingTracker();
  /// A glide may be running ON THE HOST. There is no acknowledgement and none is wanted — this only
  /// decides whether the next press must send a stop, and sending one too many is harmless.
  private glideMaybeRunning = false;

  get cursor(): { x: number; y: number } { return { ...this.pos }; }

  handle(e: TrackpadEvent, box: Box): TrackpadOutput[] {
    switch (e.kind) {
      case "down": return this.onDown(e);
      case "move": return this.onMove(e, box);
      default:     return this.onRelease(e);
    }
  }

  private centroid(): { x: number; y: number } {
    let x = 0, y = 0;
    for (const p of this.pointers.values()) { x += p.x; y += p.y; }
    const n = this.pointers.size || 1;
    return { x: x / n, y: y / n };
  }

  private at(phase: "down" | "move" | "up", button: "left" | "right"): TrackpadOutput {
    return { t: "touch", phase, button, x: this.pos.x, y: this.pos.y };
  }

  private onDown(e: TrackpadEvent): TrackpadOutput[] {
    const out: TrackpadOutput[] = [];
    // A PRESS STOPS A GLIDE, the way a finger landing on a trackpad does. It has to be sent from
    // here: in this mode a press is otherwise SILENT until it becomes a tap or a move, so nothing
    // else would reach the host, and it would keep coasting under a finger already on the glass.
    if (this.glideMaybeRunning) {
      this.glideMaybeRunning = false;
      out.push({ t: "fling", vx: 0, vy: 0, x: this.pos.x, y: this.pos.y });
    }
    this.pointers.set(e.id, { x: e.x, y: e.y });
    if (this.pointers.size === 1) {
      this.startPt = { x: e.x, y: e.y };
      this.lastPt = { x: e.x, y: e.y };
      this.startT = e.t;
      this.lastT = e.t;
      if (e.t - this.lastTapT <= DOUBLE_TAP_MS) {
        // Double-tap-and-hold: the press that follows a tap closely IS the drag.
        this.lastTapT = -Infinity;
        this.phase = "dragging";
        out.push(this.at("down", "left"));
      } else {
        this.phase = "pressing";
      }
    } else if (this.pointers.size === 2) {
      // A drag in progress must be released before the gesture changes meaning.
      if (this.phase === "dragging") out.push(this.at("up", "left"));
      this.phase = "twoFinger";
      const c = this.centroid();
      this.startPt = c;
      this.lastPt = c;
      this.startT = e.t;
      this.lastT = e.t;
      this.fling.reset();
    }
    return out;
  }

  private onMove(e: TrackpadEvent, box: Box): TrackpadOutput[] {
    const out: TrackpadOutput[] = [];
    if (!this.pointers.has(e.id)) return out;
    this.pointers.set(e.id, { x: e.x, y: e.y });

    if (this.phase === "twoFinger" || this.phase === "twoScroll") {
      // EXACTLY TWO. After one of two fingers lifts, the centroid of the survivor would jump by half
      // the gap between them and scroll the page for a gesture that has already ended.
      if (this.pointers.size !== 2) return out;
      const c = this.centroid();
      if (this.phase === "twoFinger" && dist(c, this.startPt) < TAP_SLOP_PX) return out;
      this.phase = "twoScroll";
      const sign = TWO_FINGER_NATURAL ? -1 : 1;
      const dx = sign * (c.x - this.lastPt.x);
      const dy = sign * (c.y - this.lastPt.y);
      this.lastPt = c;
      this.lastT = e.t;
      this.fling.push(e.t, dx, dy);
      out.push({ t: "scroll", dx, dy, x: this.pos.x, y: this.pos.y });
      return out;
    }

    if (this.phase === "pressing") {
      if (dist({ x: e.x, y: e.y }, this.startPt) < TAP_SLOP_PX) return out;
      // Cross into movement FROM THE ORIGIN, so the slop the finger already travelled is spent on
      // the cursor rather than discarded — otherwise every drag starts with a dead zone.
      this.phase = "moving";
      this.lastPt = { ...this.startPt };
      this.lastT = this.startT;
    }

    if (this.phase !== "moving" && this.phase !== "dragging") return out;
    const dx = e.x - this.lastPt.x;
    const dy = e.y - this.lastPt.y;
    const dt = Math.max(1, e.t - this.lastT);
    const g = accelGain(Math.hypot(dx, dy) / dt);
    this.lastPt = { x: e.x, y: e.y };
    this.lastT = e.t;
    this.pos = {
      x: clamp01(this.pos.x + (dx * g) / (box.w || 1)),
      y: clamp01(this.pos.y + (dy * g) / (box.h || 1)),
    };
    out.push(this.phase === "dragging" ? this.at("move", "left") : { t: "hover", ...this.pos });
    return out;
  }

  private onRelease(e: TrackpadEvent): TrackpadOutput[] {
    const out: TrackpadOutput[] = [];
    if (!this.pointers.delete(e.id)) return out;
    const was = this.phase;

    if (was === "dragging") {
      // ALWAYS release, cancel included: a press that is never released leaves the host holding a
      // stuck button, with nothing on either side reporting it.
      out.push(this.at("up", "left"));
      this.phase = "idle";
      return out;
    }
    if (e.kind === "cancel") {
      // A CANCELLED GESTURE IS NOT A FLICK. The browser took it away — from a system edge swipe, or
      // a call arriving — and throwing the view on the way out is the one thing the user did not ask
      // for.
      this.fling.reset();
      if (this.pointers.size === 0) { this.phase = "idle"; this.lastTapT = -Infinity; }
      return out;
    }
    if (was === "twoScroll") {
      // The FIRST of the two fingers to lift is the moment of the flick; clearing the trail here is
      // what stops the second lift throwing the view a second time.
      const v = this.fling.velocity(e.t);
      this.fling.reset();
      if (this.pointers.size === 0) this.phase = "idle";
      if (!v) return out;
      this.glideMaybeRunning = true;
      out.push({ t: "fling", vx: v.vx, vy: v.vy, x: this.pos.x, y: this.pos.y });
      return out;
    }
    if (was === "pressing"
        && e.t - this.startT <= TAP_MAX_MS
        && dist({ x: e.x, y: e.y }, this.startPt) < TAP_SLOP_PX) {
      out.push(this.at("down", "left"), this.at("up", "left"));
      this.lastTapT = e.t;
      this.phase = "idle";
      return out;
    }
    if (was === "twoFinger" && this.pointers.size === 0 && e.t - this.startT <= TAP_MAX_MS) {
      // Both fingers down and up, having gone nowhere: a secondary click. `twoScroll` never reaches
      // here, so a gesture that scrolled cannot also click.
      out.push(this.at("down", "right"), this.at("up", "right"));
      this.phase = "idle";
      return out;
    }
    if (this.pointers.size === 0) this.phase = "idle";
    return out;
  }

}
