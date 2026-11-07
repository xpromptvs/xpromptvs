/// How faithfully the picture is being painted against the timeline it was captured on.
///
/// **A PAINT GAP IS NOT JUDDER.** That mistake shaped an entire afternoon. rdev's RTP timestamps
/// carry REAL CAPTURE TIME, and a window source is content-driven: ScreenCaptureKit delivers a frame
/// when the window changes, so a window that does not redraw for 33ms produces a genuine 33ms gap
/// with nothing lost and nothing late. Counting those as damage made a controller buy 250ms of
/// buffer to close gaps where no frame had ever existed — and no buffer can close those, which is
/// why more of it never helped.
///
/// THE DISCRIMINATOR IS THE MEDIA CLOCK. `requestVideoFrameCallback` reports each painted frame's
/// `mediaTime` beside the instant it was painted:
///
///   - media advanced 33ms, painted 33ms later  -> faithful; the source simply had nothing new
///   - media advanced 17ms, painted 33ms later  -> a frame missed its slot; that is judder
///
/// So the quantity is how far each paint INTERVAL strays from its own media interval — not the
/// spread of paint alone, and not an absolute offset either. `pacing-probe.mjs` calls the same idea
/// `offsetJitter` and `docs/instruments.md` records that it is the judder number while a frame rate
/// is not; this is that measurement, moved into the client so a controller can use it.
///
/// TWO WAYS THE MEDIA CLOCK LIES, both met in the field and both refused rather than smoothed:
/// re-attaching `srcObject` restarts the timeline mid-window (one sample discarded, not a window),
/// and some engines report a `mediaTime` for a MediaStream that barely advances at all (the whole
/// window refused — against a stalled clock every interval looks like a full frame period of
/// deviation, which is not merely noisy but consistently wrong in the direction that costs latency).
///
/// KNOWN LIMIT: a frame received and never painted at all moves both clocks together and is
/// therefore invisible here. That is a conservative failure — it under-reports judder rather than
/// inventing it — and `dropped=` on the `[rx]` line is the counter that sees it.
export interface PaintSample {
  /// When the frame was painted, from the callback's own timestamp.
  paintMs: number;
  /// Where that frame sat on the media timeline (`mediaTime`, converted to ms).
  mediaMs: number;
}

export interface Cadence {
  /// Typical gap between painted frames. Near `nominalMs` on a smoothly redrawing source, and
  /// legitimately far above it on one that is mostly static.
  p50Ms: number;
  /// The tail of that gap. Reported because it is what a reader looks at first, NOT because it
  /// measures judder — on a content-driven source it mostly measures the content.
  p95Ms: number;
  /// Gaps beyond one and a half frame periods. Kept for the log line for the same reason as `p95Ms`.
  skips: number;
  /// Painted intervals the window covered.
  count: number;
  /// THE JUDDER NUMBER: the p95 of how far each paint interval strayed from its own media interval.
  /// Zero means every frame landed exactly where its timestamp said, however irregular the source
  /// itself was.
  ///
  /// NULL WHEN THE MEDIA CLOCK IS UNUSABLE, and null ALONE — the interval statistics beside it are
  /// computed from paint times only and stay valid. Refusing the whole reading used to take them with
  /// it, which cost exactly what it was protecting: a relayed session painting 47-56fps of a 60fps
  /// source reported no `drift`, no `gaps` and no `skips`, so the shape of a visible half-second beat
  /// could not be seen at all. One unusable number must not silence three good ones.
  offsetSpreadMs: number | null;
}

/// Null when there is not enough to say. ABSENT MEANS UNKNOWN, never "healthy" — a window with two
/// samples would otherwise report a confident spread drawn from nothing.
export function presentationCadence(samples: readonly PaintSample[], nominalMs: number): Cadence | null {
  if (samples.length < MIN_SAMPLES || !(nominalMs > 0)) return null;
  const intervals: number[] = [];
  for (let i = 1; i < samples.length; i++) intervals.push(samples[i]!.paintMs - samples[i - 1]!.paintMs);
  if (intervals.length === 0) return null;
  const sortedIntervals = [...intervals].sort((a, b) => a - b);
  // PER-INTERVAL DEVIATION, not the spread of an absolute offset.
  //
  // The two clocks have unrelated epochs, so only differences mean anything — but differencing the
  // WHOLE WINDOW against a single origin is not robust either: re-attaching `srcObject` restarts the
  // media timeline while `performance.now()` keeps running, and one such reset inside a window makes
  // the offset spread read the size of the reset. Measured in the field as `drift=4782.0ms` on a
  // stream that was painting 52fps, and it drove the adaptive floor upward on the strength of it.
  //
  // Comparing each interval against its own media interval is immune: a reset costs one sample.
  const deviations: number[] = [];
  let paintTotal = 0, mediaTotal = 0;
  for (let i = 1; i < samples.length; i++) {
    const paintDelta = samples[i]!.paintMs - samples[i - 1]!.paintMs;
    const mediaDelta = samples[i]!.mediaMs - samples[i - 1]!.mediaMs;
    paintTotal += paintDelta;
    // A NEGATIVE OR ENORMOUS media step is a discontinuity, not a measurement: a timeline reset, or
    // a gap across a pause. Discarded rather than clamped — a clamped discontinuity is still a
    // fabricated deviation.
    if (mediaDelta < 0 || mediaDelta > MAX_MEDIA_STEP_MS) continue;
    mediaTotal += mediaDelta;
    deviations.push(Math.abs(paintDelta - mediaDelta));
  }
  // THE MEDIA CLOCK MUST ACTUALLY BE A CLOCK. Some engines report a `mediaTime` that barely advances
  // for a MediaStream source; against that, every interval looks like a full frame period of
  // deviation and the reading is not merely noisy but consistently wrong in the damaging direction.
  // Refusing is the only safe answer — ABSENT MEANS UNKNOWN, and the controller does nothing with it.
  // THE PAINT INTERVALS ARE ALWAYS REPORTABLE. They need no media clock — they are differences of
  // `performance.now()` — so the only thing an unusable media clock can take away is `offsetSpreadMs`.
  if (intervals.length < MIN_SAMPLES) return null;
  const mediaClockUsable =
    deviations.length >= MIN_SAMPLES && mediaTotal >= paintTotal * MIN_MEDIA_CLOCK_FRACTION;
  const sortedDeviations = [...deviations].sort((a, b) => a - b);
  const skipAboveMs = nominalMs * 1.5;
  return {
    p50Ms: percentile(sortedIntervals, 0.5),
    p95Ms: percentile(sortedIntervals, 0.95),
    skips: intervals.reduce((n, ms) => n + (ms > skipAboveMs ? 1 : 0), 0),
    count: intervals.length,
    // THE TAIL of how far each interval strayed from the media clock. p95 rather than the maximum:
    // one bad interval is an event, and judder is the rate at which they happen.
    offsetSpreadMs: mediaClockUsable ? percentile(sortedDeviations, 0.95) : null,
  };
}

/// Fewer than this and the percentiles describe the sample, not the stream.
const MIN_SAMPLES = 10;
/// A media step longer than this is a discontinuity — a reset, or a gap across a pause — not a frame
/// interval. Generous, because a legitimately static window source really can go this long.
const MAX_MEDIA_STEP_MS = 1000;
/// The media clock must advance at least this much of wall time to be believed at all.
const MIN_MEDIA_CLOCK_FRACTION = 0.5;

/// NEAREST-RANK, on an already-sorted array. Deliberately not interpolating: an interpolated p95
/// reports a value no frame actually experienced, and the point of the tail is that the long waits
/// are real events someone saw.
function percentile(sorted: readonly number[], q: number): number {
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(q * sorted.length) - 1));
  return sorted[index]!;
}
