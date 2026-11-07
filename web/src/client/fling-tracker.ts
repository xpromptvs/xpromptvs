/// The velocity trail behind a two-finger flick, shared by both pointer modes.
///
/// WHY THIS IS ITS OWN MODULE. `Trackpad` (indirect mode) and `DirectTouch` (direct mode) run
/// different gesture vocabularies over the same two-finger pan, and this is the part of it that must
/// not be duplicated: the trim rule keeps one sample OLDER than the window, and a lift after the
/// finger has already stopped is refused outright. Both are non-obvious, and a second copy would
/// fork the day either constant is tuned — the same reasoning that keeps rdev from restating the
/// engine's FlexFEC controller policy.
///
/// PURE — no DOM, no timers. Every decision is a function of the samples handed to it.

/// How far back a flick's velocity is measured, in ms. ONE DELTA IS NOISE — a single frame of finger
/// jitter — and the whole gesture is worse still, since it averages the slow part of a drag into the
/// flick that ended it.
export const FLING_WINDOW_MS = 60;
/// Below this speed, in content px per second, a lift is not a flick. The HOST keeps its own floor
/// too; this one is here so an ordinary slow release sends nothing at all.
export const FLING_MIN_SPEED = 200;
/// A lift more than this long after the last movement is not a flick either: the finger stopped
/// first and then let go, which means "leave it here", not "throw it".
export const FLING_IDLE_MS = 80;

// THE THREE CONSTANTS ABOVE ARE UNTUNED STARTING POINTS, not measured values.

export class FlingTracker {
  /// Cumulative SIGNED travel in the same convention as the deltas it is fed, stamped with the time
  /// of each sample. Only the last `FLING_WINDOW_MS` is kept, plus one baseline older than it.
  private trail: { t: number; x: number; y: number }[] = [];
  private travel = { x: 0, y: 0 };

  /// Fold one pan delta into the trail.
  push(t: number, dx: number, dy: number): void {
    this.travel = { x: this.travel.x + dx, y: this.travel.y + dy };
    this.trail.push({ t, x: this.travel.x, y: this.travel.y });
    // KEEP ONE SAMPLE OLDER THAN THE WINDOW as the baseline to difference against, or a gesture
    // whose last frames all fall inside it has nothing to measure from.
    while (this.trail.length > 2 && this.trail[1]!.t < t - FLING_WINDOW_MS) this.trail.shift();
  }

  /// Forget the gesture. Called on the FIRST of two fingers lifting, which is what stops the second
  /// lift throwing the view a second time, and on a cancel.
  reset(): void {
    this.trail = [];
    this.travel = { x: 0, y: 0 };
  }

  /// The flick's velocity in content px per SECOND, or null when the lift was not a flick.
  velocity(now: number): { vx: number; vy: number } | null {
    const first = this.trail[0];
    const last = this.trail[this.trail.length - 1];
    if (!first || !last || last === first) return null;
    if (now - last.t > FLING_IDLE_MS) return null;
    const dt = last.t - first.t;
    if (dt <= 0) return null;
    const vx = ((last.x - first.x) / dt) * 1000;
    const vy = ((last.y - first.y) / dt) * 1000;
    return Math.hypot(vx, vy) < FLING_MIN_SPEED ? null : { vx, vy };
  }
}
