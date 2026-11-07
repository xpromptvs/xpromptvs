/// HOW WELL THE PRESENTATION LOOP ITSELF IS RUNNING — separately from the media.
///
/// Every other counter in the pacer describes FRAMES: how long each was held, whether that matched
/// what its timestamps asked for, whether one was missing. None of them describe the loop that draws
/// them. A tab whose `requestAnimationFrame` callback is skipped presents nothing at that vsync, and
/// the frame it was about to draw is simply held a refresh longer — which shows up as a cadence miss
/// with no indication that the cause was the CLIENT rather than the source or the network.
///
/// That distinction is the whole point. A miss caused by a skipped vsync is fixed by getting work off
/// the main thread; a miss caused by the source's rate not dividing the refresh is arithmetic and
/// cannot be fixed by the client at all. They are indistinguishable in `cadenceMiss`.
///
/// The measurement is the interval between consecutive rAF callbacks, in units of the display's
/// refresh period. One refresh is smooth. Two means one vsync came and went with no callback.
export interface DisplayCadenceStats {
  /// Intervals classified. Zero until the loop has run twice.
  ticks: number;
  /// Intervals of exactly one refresh — the loop kept up.
  smooth: number;
  /// Intervals of two or more refreshes: at least one vsync passed with no callback.
  skips: number;
  /// Total refreshes lost across those skips. Two skips of one refresh each and one skip of four are
  /// very different experiences, and `skips` alone cannot tell them apart.
  lostRefreshes: number;
  /// Gaps too long to be a skipped vsync — see STALL_MS. Counted, never folded into `skips`.
  stalls: number;
  /// The worst single gap, in refreshes, among those short enough to be a skip.
  worstSteps: number;
  /// `smooth / ticks` as a percentage, or null when nothing has been classified.
  smoothPercent: number | null;
  /// The refresh period this classification used. Null when it cannot be determined yet.
  refreshMs: number | null;
}

/// How many intervals to keep. ~10s at 120Hz: long enough for a percentile to be stable, short
/// enough that the report describes now rather than the whole session.
const WINDOW = 1200;

/// Past this a gap is not a skipped vsync — it is the loop having STOPPED: a hidden tab, a
/// navigation, a long collection. Folding one backgrounded second into `lostRefreshes` would add
/// sixty and let a single moment dominate a statistic about smoothness.
const STALL_MS = 250;

/// Minimum intervals before a refresh period can be claimed. Below this the percentile is being
/// taken over noise.
const SAMPLES_MIN = 30;

/// THE REFRESH IS THE CENTRE OF THE FASTEST CLUSTER — found with a low percentile, then MEASURED
/// with a median over that cluster.
///
/// A low percentile alone was the first version and it was BIASED LOW, which mattered: on a healthy
/// 60Hz loop it reported 16.00ms for a true 16.67ms, and that error was then compared against the
/// source's frame period and read as a 4.4% "beat" that does not exist. The claim survived three
/// separate analyses before the data refuted it — `miss` froze at 25 across nine hundred frames,
/// where a real beat would have added about thirteen per three hundred.
///
/// The percentile still does the job it was chosen for: finding the one-refresh cluster without
/// being dragged by skips, since a median over ALL gaps reads as two refreshes when a third of
/// callbacks are missed. Taking the median WITHIN that cluster then removes the low bias, because
/// jitter around the true period is symmetric while skips are strictly above it.
const REFRESH_PERCENTILE = 0.1;
/// How far above the low percentile still counts as the same one-refresh cluster. Comfortably below
/// 2x, which is the next cluster (one skipped vsync), and comfortably above ordinary jitter.
const CLUSTER_WIDTH = 1.4;

export class DisplayCadence {
  private gaps: number[] = [];

  /// Record the interval between two consecutive presentation-loop callbacks.
  observe(gapMs: number): void {
    // A non-finite or non-positive gap is a clock artefact, not an observation. `performance.now()`
    // is monotonic per spec, but a paused-and-resumed tab has produced zero deltas in the wild.
    if (!Number.isFinite(gapMs) || gapMs <= 0) return;
    this.gaps.push(gapMs);
    if (this.gaps.length > WINDOW) this.gaps.shift();
  }

  /// CLASSIFIED AT READ TIME, not as each gap arrives.
  ///
  /// The refresh period is derived from the same gaps being classified, so classifying on arrival
  /// would judge the first thirty intervals against an estimate built from almost nothing and then
  /// keep those verdicts forever. Reading is cheap and happens once per report.
  stats(): DisplayCadenceStats {
    const empty: DisplayCadenceStats = {
      ticks: 0, smooth: 0, skips: 0, lostRefreshes: 0, stalls: 0, worstSteps: 0,
      smoothPercent: null, refreshMs: null,
    };
    if (this.gaps.length < SAMPLES_MIN) return empty;

    // The estimate ignores stalls: a backgrounded second must not drag the percentile.
    const usable = this.gaps.filter((g) => g < STALL_MS);
    if (usable.length < SAMPLES_MIN) return { ...empty, stalls: this.gaps.length - usable.length };
    const sorted = [...usable].sort((a, b) => a - b);
    const low = sorted[Math.min(sorted.length - 1, Math.floor(REFRESH_PERCENTILE * sorted.length))]!;
    if (low <= 0) return empty;
    // The median OF THE CLUSTER, not of everything: `low` locates the one-refresh gaps, and their
    // middle is the period. Anything at or above `low * CLUSTER_WIDTH` is a skipped vsync and belongs
    // to a different cluster entirely.
    const cluster = sorted.filter((g) => g < low * CLUSTER_WIDTH);
    const refreshMs = cluster.length === 0 ? low : cluster[cluster.length >> 1]!;
    if (refreshMs <= 0) return empty;

    let smooth = 0, skips = 0, lostRefreshes = 0, stalls = 0, worstSteps = 0;
    for (const gap of this.gaps) {
      if (gap >= STALL_MS) { stalls++; continue; }
      const steps = Math.max(1, Math.round(gap / refreshMs));
      if (steps === 1) smooth++;
      else {
        skips++;
        lostRefreshes += steps - 1;
        if (steps > worstSteps) worstSteps = steps;
      }
    }
    const ticks = smooth + skips;
    return {
      ticks, smooth, skips, lostRefreshes, stalls, worstSteps,
      smoothPercent: ticks === 0 ? null : (smooth / ticks) * 100,
      refreshMs,
    };
  }

  reset(): void { this.gaps = []; }
}
