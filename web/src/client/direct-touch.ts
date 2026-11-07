/// Multi-finger gestures for DIRECT pointer mode.
///
/// WHY THIS EXISTS. Direct mode's whole contract is that a tap lands where you touched, and for one
/// finger that is all it ever needed to do. But `.win-body` carries `touch-action: none`, so a
/// touchscreen never produces a wheel event over the picture and there was NO WAY TO SCROLL a remote
/// window in the default mode at all. Worse, the shipped path had no notion of a second pointer:
/// measured, two fingers sent `down`, `down`, moves and ONE `up` — two `leftMouseDown`s against one
/// `leftMouseUp`, i.e. A STUCK BUTTON on the host, with nothing on either side reporting it.
///
/// SCOPE: TOUCH POINTERS ONLY. `input.ts` routes a mouse or a pen down the original immediate path,
/// byte for byte — a mouse can never produce a second pointer, and the press deferral below would
/// otherwise put 50 ms on every desktop click, on a product whose thesis is latency.
///
/// PURE — no DOM, no timers, no layout. `flush` is the one concession, and it is still a function of
/// the timestamp handed to it; `input.ts` owns the clock.
///
/// COORDINATES: inputs are CONTENT-rect pixels, every output x/y is NORMALIZED, and `scroll` deltas
/// come out in content pixels for the attachment to divide by `drawScale` — the same contract
/// `Trackpad` follows, which is what lets both feed one `emit()`.
import { FlingTracker } from "./fling-tracker";
import type { Box } from "./pointer-map";
// The gesture vocabulary is shared with indirect mode; only the state machine over it differs.
import { TAP_MAX_MS, TAP_SLOP_PX, TWO_FINGER_NATURAL, type TrackpadEvent, type TrackpadOutput } from "./trackpad";

/// How long a single finger's press is held back, waiting to see whether a second one lands.
///
/// THE PRESS CANNOT BE SENT AND THEN WITHDRAWN. Two fingers land milliseconds apart, so a press sent
/// on the first one has already reached the host by the time the second arrives — and withdrawing it
/// is a real `leftMouseDown`/`leftMouseUp` pair on the remote Mac, which is a CLICK on whatever sits
/// under the finger. Deferring costs 50 ms on a touch tap; clicking the wrong thing is unrecoverable.
///
/// UNTUNED STARTING POINT, like `Trackpad`'s constants. Real fingers land 10–30 ms apart.
export const TWO_FINGER_WINDOW_MS = 50;

/// How soon after a tap a new press may still be snapped onto it — macOS's default double-click
/// interval. The HOST decides whether the pair is a double-click (`ClickCounter`, the user's real
/// interval and a few points of slop); this only removes the finger's jitter first, because a few
/// CSS pixels become tens of points once a large window is drawn on a phone, far past any slop that
/// would still be right for a mouse.
export const DOUBLE_TAP_SNAP_MS = 500;

type Phase =
  /// Nothing down.
  | "idle"
  /// One finger down, press NOT yet sent — the window above has not expired.
  | "pending"
  /// One finger down, press sent. A move is a drag.
  | "pressing"
  /// Two fingers down, still within the slop: this may yet become a right click.
  | "two"
  /// Two fingers panning.
  | "twoScroll"
  /// Fingers remain on the glass but the gesture is OVER. The survivor of a two-finger gesture must
  /// not silently become a new press the user never made.
  | "spent";

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));
const dist = (a: { x: number; y: number }, b: { x: number; y: number }) => Math.hypot(a.x - b.x, a.y - b.y);

export class DirectTouch {
  private phase: Phase = "idle";
  private pointers = new Map<number, { x: number; y: number }>();
  private fling = new FlingTracker();
  /// Where the CURRENT phase began, in content px: the finger for a press, the centroid for a pair.
  private startPt = { x: 0, y: 0 };
  /// Where the press is SENT: `startPt`, or the previous tap's point when this press snapped onto it.
  /// Kept apart from `startPt` so the drag slop is still measured from where the finger really landed.
  private pressPt = { x: 0, y: 0 };
  /// The last single-finger tap's sent point and release time, or null when the last gesture was not one.
  private lastTap: { x: number; y: number; t: number } | null = null;
  private startT = 0;
  private lastPt = { x: 0, y: 0 };

  handle(e: TrackpadEvent, box: Box): TrackpadOutput[] {
    switch (e.kind) {
      case "down": return this.onDown(e, box);
      case "move": return this.onMove(e, box);
      default:     return this.onRelease(e, box);
    }
  }

  /// Emit the deferred press if the window has expired and nothing has resolved it. Idempotent: the
  /// phase moves to `pressing`, so a second call — or a late timer after the finger already lifted —
  /// cannot send a second press.
  flush(t: number, box: Box): TrackpadOutput[] {
    if (this.phase !== "pending" || t - this.startT < TWO_FINGER_WINDOW_MS) return [];
    this.phase = "pressing";
    return [this.touch("down", "left", this.pressPt, box)];
  }

  private touch(
    phase: "down" | "move" | "up", button: "left" | "right",
    p: { x: number; y: number }, box: Box,
  ): TrackpadOutput {
    return {
      t: "touch", phase, button,
      x: clamp01(p.x / (box.w || 1)),
      y: clamp01(p.y / (box.h || 1)),
    };
  }

  private centroid(): { x: number; y: number } {
    let x = 0, y = 0;
    for (const p of this.pointers.values()) { x += p.x; y += p.y; }
    const n = this.pointers.size || 1;
    return { x: x / n, y: y / n };
  }

  private onDown(e: TrackpadEvent, box: Box): TrackpadOutput[] {
    const out: TrackpadOutput[] = [];
    this.pointers.set(e.id, { x: e.x, y: e.y });
    if (this.pointers.size === 1) {
      this.phase = "pending";
      this.startPt = { x: e.x, y: e.y };
      this.lastPt = { x: e.x, y: e.y };
      this.startT = e.t;
      const tap = this.lastTap;
      this.pressPt = tap && e.t - tap.t <= DOUBLE_TAP_SNAP_MS && dist(tap, this.startPt) < TAP_SLOP_PX
        ? { x: tap.x, y: tap.y } : this.startPt;
      // A press held still releases where it was SENT, or the snapped click becomes a tiny drag.
      this.lastPt = this.pressPt;
      return out;
    }
    if (this.pointers.size === 2) {
      // THE STUCK-BUTTON FIX. A press that already flushed must be released before the gesture
      // changes meaning — exactly the rule `Trackpad.onDown` follows for a drag. A press still
      // `pending` was never sent, which is the deferral earning its keep: nothing to withdraw.
      if (this.phase === "pressing") out.push(this.touch("up", "left", this.lastPt, box));
      this.phase = "two";
      const c = this.centroid();
      this.startPt = c;
      this.lastPt = c;
      this.startT = e.t;
      this.fling.reset();
    }
    // A THIRD FINGER STOPS THE PAN AND DOES NOT RESUME IT. `onMove` requires exactly two, so the
    // extra finger silences the gesture; the lift that follows then finds more than one pointer
    // left and ends it without a flick. Re-baselining back to two is the alternative and is NOT
    // built: removing a finger moves the centroid discontinuously, so resuming without re-anchoring
    // emits one large bogus delta, and three fingers on a remote window is not a gesture anyone
    // makes on purpose.
    return out;
  }

  private onMove(e: TrackpadEvent, box: Box): TrackpadOutput[] {
    const out: TrackpadOutput[] = [];
    if (!this.pointers.has(e.id)) return out;
    this.pointers.set(e.id, { x: e.x, y: e.y });

    if (this.phase === "two" || this.phase === "twoScroll") {
      // EXACTLY TWO. After one of two fingers lifts, the centroid of the survivor jumps by half the
      // gap between them and would scroll for a gesture that has already ended.
      if (this.pointers.size !== 2) return out;
      const c = this.centroid();
      if (this.phase === "two" && dist(c, this.startPt) < TAP_SLOP_PX) return out;
      this.phase = "twoScroll";
      const sign = TWO_FINGER_NATURAL ? -1 : 1;
      const dx = sign * (c.x - this.lastPt.x);
      const dy = sign * (c.y - this.lastPt.y);
      this.lastPt = c;
      this.fling.push(e.t, dx, dy);
      const n = this.touch("move", "left", c, box);   // reuse the normalizer; only x/y are read
      out.push({ t: "scroll", dx, dy, x: n.x, y: n.y });
      return out;
    }

    if (this.phase === "pending") {
      // MOVEMENT RESOLVES THE ARITY EARLY. One finger that has travelled is a drag, not the opening
      // of a two-finger gesture, so there is nothing left to wait for. The press is emitted at the
      // ORIGIN so the slop already travelled is spent rather than discarded — without that every
      // drag begins with a dead zone.
      if (dist({ x: e.x, y: e.y }, this.startPt) < TAP_SLOP_PX) return out;
      this.phase = "pressing";
      out.push(this.touch("down", "left", this.pressPt, box));
    }
    if (this.phase !== "pressing") return out;
    this.lastPt = { x: e.x, y: e.y };
    out.push(this.touch("move", "left", this.lastPt, box));
    return out;
  }

  private onRelease(e: TrackpadEvent, box: Box): TrackpadOutput[] {
    const out: TrackpadOutput[] = [];
    if (!this.pointers.delete(e.id)) return out;
    const was = this.phase;
    const idle = () => { if (this.pointers.size === 0) this.phase = "idle"; else this.phase = "spent"; };
    // Only a single finger that went nowhere is a tap a next press may snap onto; anything else ends
    // the run. A press held still past the window flushed and is `pressing`, and still counts.
    const tapped = e.kind !== "cancel" && this.pointers.size === 0
      && (was === "pending" || (was === "pressing" && dist(this.lastPt, this.startPt) < TAP_SLOP_PX));
    this.lastTap = tapped ? { x: this.pressPt.x, y: this.pressPt.y, t: e.t } : null;

    if (was === "pressing") {
      // ALWAYS release, cancel included: a press that is never released leaves the host holding a
      // stuck button, with nothing on either side reporting it.
      out.push(this.touch("up", "left", this.lastPt, box));
      idle();
      return out;
    }
    if (was === "pending") {
      // A LIFT INSIDE THE WINDOW IS A TAP, and it must never reach the host as a bare `down`.
      // A cancel is not: the browser took the gesture away, and a click is the one thing the user
      // did not ask for.
      if (e.kind !== "cancel") {
        out.push(this.touch("down", "left", this.pressPt, box), this.touch("up", "left", this.pressPt, box));
      }
      idle();
      return out;
    }
    if (e.kind === "cancel") {
      // A CANCELLED GESTURE IS NOT A FLICK — a system edge swipe or an arriving call took it away,
      // and throwing the view on the way out is not what was asked for.
      this.fling.reset();
      idle();
      return out;
    }
    if (was === "twoScroll") {
      // THE FIRST OF THE TWO FINGERS TO LIFT IS THE MOMENT OF THE FLICK, and `spent` below is what
      // stops the second lift throwing the view again — this branch is then unreachable for it.
      // (`Trackpad` needs an explicit trail reset here instead, because its phase PERSISTS through
      // the first lift; the same line here would be defensive code no test could falsify. A fresh
      // pair resets the trail in `onDown` regardless.)
      // A FLICK IS A TWO-FINGER GESTURE ENDING, so the velocity is read only when this lift leaves
      // exactly one finger. Reading it on any lift throws the view when a THIRD finger comes off —
      // a glide from a gesture that was already over, and one nothing else would explain.
      const v = this.pointers.size === 1 ? this.fling.velocity(e.t) : null;
      idle();
      if (v) {
        out.push({
          t: "fling", vx: v.vx, vy: v.vy,
          x: clamp01(this.lastPt.x / (box.w || 1)),
          y: clamp01(this.lastPt.y / (box.h || 1)),
        });
      }
      return out;
    }
    if (was === "two") {
      // THE PHASE MUST SURVIVE THE FIRST LIFT. Two fingers come off milliseconds apart, so demoting
      // to `spent` on the first one would mean the pair could never complete as a tap — the click
      // is decided on the LAST lift, when the whole gesture's duration is finally known.
      if (this.pointers.size > 0) return out;
      this.phase = "idle";
      // Both fingers down and up, having gone nowhere: a SECONDARY CLICK, at the centroid they
      // started from. `twoScroll` never reaches here, so a gesture that scrolled cannot also click.
      if (e.t - this.startT <= TAP_MAX_MS) {
        out.push(this.touch("down", "right", this.startPt, box),
                 this.touch("up", "right", this.startPt, box));
      }
      return out;
    }
    idle();
    return out;
  }
}
