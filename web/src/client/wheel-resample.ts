/// THE WHEEL, RESAMPLED (2026-09-29) — the smooth scrollback follows a trackpad's wheel stream a frame at a
/// time instead of jumping by whatever events landed since the last frame.
///
/// Measured in Safari at its default 60 fps limit (`?scrollprobe=1`): the trackpad's events arrive every
/// ~9 ms, in pairs about 4 ms apart, and the frames' timestamps wobble between 12 and 21 ms around a steady
/// 16.7 — so a frame got 1, 2 or 3 events and the text moved −383, −225, −102, −296, −95 … px in a flick
/// whose speed fell smoothly (unevenness 0.48; ≳ 0.3 is visible). Replaying those events offline as they
/// landed reproduced it (0.46); averaged over two event gaps and sampled on a steadied frame clock, the
/// same events move the view in even steps (0.09) — `test/fixtures/safari-wheel-flick.json` is that flick.
///
/// Two parts, both pure:
///   - `WheelResampler` keeps the gesture's CUMULATIVE distance as a step function of event time and
///     answers its AVERAGE over the last `window()` ms — two mean event gaps (16…34 ms): one window of a
///     stream's own period cancels its ripple, and averaging a step function is exact, so nothing is lost
///     (settled, it holds the sum). Latency is half the window: ~8 ms for a 120 Hz stream.
///   - `FramePacer` puts the frames' wobbling timestamps back on the display's steady clock: each frame is
///     predicted one period on (more across a frame that never came) and pulled a tenth of the way toward
///     its timestamp, and the period learns from the same error — a second-order loop, because a period
///     guessed from wobbling intervals is biased and a first-order pull alone leaves that bias, times
///     ten, as a standing error.
///
/// `wheelPixels` is the distance xterm.js's OWN scrollable would move for an event (VS Code's
/// `StandardWheelEvent` and `ScrollableElement._onMouseWheel`), so resampling changes WHEN the view
/// moves, never how far. `smooth-scroll.ts` owns the motion; `xterm-view.ts` takes the wheel.

/// The window never averages less than this (a 120 Hz stream's two gaps), nor more than a 60 Hz
/// stream's two — beyond it the latency is felt.
export const WINDOW_MIN_MS = 16;
export const WINDOW_MAX_MS = 34;
/// The mean event gap is taken over the events of the last this-many ms.
const RATE_SPAN_MS = 100;

export class WheelResampler {
  /// Each event's time and the cumulative distance after it.
  private readonly t: number[] = [];
  private readonly v: number[] = [];
  private w = WINDOW_MIN_MS;

  /// An event: `px` more, at `time` (clamped so time never runs backwards).
  add(time: number, px: number): void {
    const n = this.t.length;
    this.t.push(n > 0 ? Math.max(time, this.t[n - 1]!) : time);
    this.v.push((n > 0 ? this.v[n - 1]! : 0) + px);
    this.w = this.measureWindow();
  }

  /// The averaging window, in ms.
  window(): number { return this.w; }

  /// The stream's distance averaged over `[time − window, time]`.
  at(time: number): number {
    const n = this.t.length;
    if (n === 0) return 0;
    const w = this.w, a = time - w;
    // The step function's value at `a`, and the integral from `a` to `time` walking the events between.
    let i = n - 1;
    while (i >= 0 && this.t[i]! > a) i--;
    let cur = i >= 0 ? this.v[i]! : 0, x = a, acc = 0;
    for (let k = i + 1; k < n && this.t[k]! < time; k++) {
      acc += cur * (this.t[k]! - x);
      x = this.t[k]!;
      cur = this.v[k]!;
    }
    return (acc + cur * (time - x)) / w;
  }

  /// The whole distance.
  total(): number { return this.v.length ? this.v[this.v.length - 1]! : 0; }

  /// The average has caught up with the last event: it holds the stream's whole distance.
  settled(time: number): boolean {
    const n = this.t.length;
    return n === 0 || time - this.w >= this.t[n - 1]!;
  }

  private measureWindow(): number {
    const n = this.t.length;
    if (n < 3) return this.w;
    const last = this.t[n - 1]!;
    let first = n - 1;
    while (first > 0 && last - this.t[first - 1]! <= RATE_SPAN_MS) first--;
    if (n - 1 - first < 2) return this.w;
    const gap = (last - this.t[first]!) / (n - 1 - first);
    return Math.min(WINDOW_MAX_MS, Math.max(WINDOW_MIN_MS, 2 * gap));
  }
}

/// A frame's pull toward its own timestamp — enough to follow the display, too little to pass on a
/// timestamp's wobble — and the period's (a second-order loop, so a first guess that is off converges
/// instead of leaving a standing phase error).
const PULL = 0.1;
const PERIOD_PULL = 0.02;
/// The period is first guessed as the mean interval over this many frames (the median of fewer, wobbling,
/// was off by 3 ms and the loop took most of a gesture to recover); until then frames keep their stamps.
const PERIOD_GUESS_FRAMES = 8;

export class FramePacer {
  private last: number | null = null;
  private period: number | null = null;
  private readonly first: number[] = [];

  /// The steadied time of the frame whose timestamp is `raw`. A frame that never came (twice the
  /// period) keeps the clock on its grid.
  tick(raw: number): number {
    if (this.last === null || this.period === null) {
      this.first.push(raw);
      const n = this.first.length;
      if (n > PERIOD_GUESS_FRAMES && raw > this.first[0]!) this.period = (raw - this.first[0]!) / (n - 1);
      return (this.last = raw);
    }
    const p = this.period;
    const k = Math.max(1, Math.round((raw - this.last) / p));
    const err = raw - (this.last + k * p);
    this.last = this.last + k * p + PULL * err;
    this.period = p + (PERIOD_PULL * err) / k;
    return this.last;
  }
}

/// VS Code's wheel constant: its scrollable moves 50 px per unit of `StandardWheelEvent` delta.
const SCROLL_WHEEL_SENSITIVITY = 50;

/// How far — CSS px, positive toward the bottom — xterm.js's own scrollable moves for `e`, as it would
/// have: the legacy `wheelDeltaY` ÷ 120 when the event has one (WebKit and Chromium do), else pixels ÷ 40
/// or lines as lines; times xterm.js's `scrollSensitivity` (and `fastScrollSensitivity` with ⌥); a
/// mostly sideways wheel moves nothing (its predominant axis is X); rounded AWAY from zero, as VS Code
/// does so a slow scroll still moves.
export function wheelPixels(e: WheelEvent, sensitivity: number, fastSensitivity: number): number {
  const legacy = e as WheelEvent & { wheelDeltaY?: number; wheelDeltaX?: number };
  const std = (wheel: number | undefined, delta: number) =>
    typeof wheel === "number" ? wheel / 120 : e.deltaMode === 1 ? -delta : -delta / 40;
  const y = std(legacy.wheelDeltaY, e.deltaY), x = std(legacy.wheelDeltaX, e.deltaX);
  if (Math.abs(x) > Math.abs(y)) return 0;
  const d = y * sensitivity * (e.altKey ? fastSensitivity : 1) * SCROLL_WHEEL_SENSITIVITY;
  if (d === 0) return 0;
  return -(d < 0 ? Math.floor(d) : Math.ceil(d));
}
