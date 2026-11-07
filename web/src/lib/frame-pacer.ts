/// Decides WHICH decoded frame to present on THIS vsync, and when.
///
/// Generic over the frame type with a caller-supplied `release`, so tests drive it with strings and
/// it can hold ring-slot indices, ImageBitmaps or VideoFrames without knowing the difference.
/// Everything here is arithmetic — no DOM, no timers, no clock of its own.
///
/// THE MEDIA CLOCK IS ONLY TRUSTWORTHY SINCE 2026-08-25. `FrameTrack` used to pace every frame on a
/// fixed +1500 ticks while `Session.WriteVideo` discarded the real `ptsNanoseconds` — a media clock
/// running -5.87% against the wall clock. A pacer keyed on that would schedule against a lie. The
/// RTP timestamp now carries real capture time anchored to an epoch, which is what makes this work.

export interface PacedFrame<T> {
  frame: T;
  mediaMs: number;
  arrivalMs: number;
  /// When the decoder finished this frame, on the SHARED epoch (`timeOrigin + now`), so it can be
  /// compared against a main-thread instant across the worker boundary. Carried, never used to pace —
  /// it exists so a probe can split g2g into upstream (capture -> decoded) and hold (decoded ->
  /// presented) with no clock synchronisation. Optional: the canvas pacer has no decoder of its own.
  decodedAbs?: number;
}

export interface PacerStats {
  presented: number; starve: number; dropped: number; queueMax: number; offsetMs: number | null;
  /// WHY A VSYNC SHOWED NOTHING — the two causes need opposite fixes, and they are indistinguishable
  /// from the dwell distribution alone.
  ///
  ///   waiting  a frame was in hand but its target had not come. A target/boundary effect: the
  ///            cadence lock addresses it, a bigger margin does not.
  ///   empty    no frame was in hand. A late arrival: only a bigger margin addresses it, and locking
  ///            cannot, because locking does not create frames.
  ///
  /// Measured on a real stream, whichever dominates says which lever is the right one. Two attempts
  /// to reproduce the observed roughness in simulation failed, so this is how it gets identified.
  waiting: number; empty: number;
}

/// Frames may pin GPU memory (a ring slot, an ImageBitmap), and a hidden tab stops rAF entirely while
/// frames keep arriving. This bound plus `reset()` on hide is what stops the renderer growing without
/// limit when nothing is consuming.
export const MAX_QUEUE = 8;

const OFFSET_WINDOW_MS = 4000;   // how far back the arrival distribution is measured
/// ONLY A FALLBACK NOW — see `sourcePeriodMs`. Used until enough of the source's own intervals have
/// been seen to measure it, and nowhere else.
const FRAME_PERIOD_MS = 1000 / 60;

/// STARVE IS MEASURED AGAINST THE SOURCE'S OWN CADENCE, not against 60fps.
///
/// It used to compare the gap to a hardcoded `1000/60`, which asks "is this source keeping up with
/// 60fps?" — a question about the SOURCE's rate, not about whether the pacer went hungry. Every rdev
/// window source is content-driven and therefore below 60 and irregular (measured on a healthy
/// window: 52.3fps produced, intervals p50 16.7 / p95 19.3 / max 26.5), so the counter reported the
/// source's ordinary behaviour as a fault and its value depended on the DISPLAY as well: the check
/// only runs at a vsync, so on a 120Hz panel a 16.67ms threshold really fires at 25ms and on a 60Hz
/// panel at 33ms. The same stream scored differently on two monitors.
///
/// Keyed to the median interval this source actually produces, a starve means what the name says:
/// this source went quiet for longer than this source normally goes quiet.
const SOURCE_PERIOD_SAMPLES_MIN = 8;
/// The gap that counts, in source periods. 1.5 is the ROUNDING BOUNDARY rather than a tuning knob —
/// past it the gap is closer to two frame periods than to one, i.e. a slot's worth of time really did
/// pass with nothing in it. Below that the source merely jittered inside its own period.
const STARVE_PERIODS = 1.5;

/// ADAPTIVE MARGIN BOUNDS.
///
/// The floor is not zero even on a perfect link: a frame arriving a microsecond late has nowhere to
/// go, so the smallest hold worth having is one that absorbs the noise floor. The ceiling is the
/// point past which the hold costs more than the judder it removes — rdev's whole premise is
/// "cloud-gaming fast", and 120ms of deliberate delay is not that.
///
/// 10ms, RAISED FROM 4 AFTER WATCHING IT. Over loopback the adaptive margin converges to the floor —
/// there is nothing to smooth — and at 4ms the picture was still not perfectly smooth. That is the
/// measurement the original 4 never had: it was reasoned as a "noise floor" rather than judged
/// against the thing the margin exists to buy.
///
/// The reason 4 cannot be enough is that arrival jitter is not what the margin is racing. Frames are
/// presented on vsync, so a frame that misses its refresh does not slip by the amount it was late —
/// it waits a WHOLE refresh period, 8.3ms on a 120Hz panel and 16.7ms on a 60Hz one. A 4ms hold
/// therefore converts a 5ms hiccup into a 16.7ms one. The receive path also runs on the MAIN THREAD
/// on the DataChannel arm, and `mainLate` has been observed at 12ms on a healthy session: below one
/// refresh period the margin cannot absorb the client's own scheduling, never mind the network's.
///
/// STRICTLY, THE PRINCIPLED FLOOR IS ONE REFRESH PERIOD, which is display-dependent and which this
/// class is already told (`pick` takes `refreshMs`). 10ms is a fixed value that covers a 120Hz panel
/// with headroom and most of a 60Hz one, chosen deliberately over 16.7 because a floor is
/// UNCONDITIONAL latency paid by every link, including the ones that needed nothing.
const MARGIN_FLOOR_MS = 10;
/// THE CEILING IS A BOUND, NOT A TARGET, and that is what makes raising it cheap. The margin is
/// `p98(arrival spread)` and sits at the 4ms floor on a clean link, so a higher ceiling costs
/// nothing where nothing is needed — it only binds on a path that is genuinely that uneven.
///
/// 120ms was too low for a real one. Measured over a VPN-over-TCP relay, which retransmits
/// underneath us and so STALLS rather than drops: 250-350ms of silence and then everything at once,
/// with 185 frames arriving after the receiver had given up on them against 55 genuinely lost. A
/// margin pinned at 120 cannot cover that, and every frame past it is discarded despite having
/// arrived.
///
/// 500ms is the most this will hold. Past that a link is not interactive by any definition and
/// needs a different answer than patience — a lower bitrate, or a path without a tunnel in it.
const MARGIN_CEILING_MS = 500;

/// The arrival percentile the margin covers. 0.98 rather than the maximum: the extreme is one packet
/// having a bad day, and sizing every frame's latency to it is how a jitter buffer becomes a latency
/// buffer.
const MARGIN_PERCENTILE = 0.98;
/// Headroom on top of the measured spread, as a fraction of it.
///
/// A PERCENTILE LEAVES ITS COMPLEMENT LATE, BY CONSTRUCTION. p98 over a 4s window at 60fps is about
/// 240 samples, so roughly five frames per window — one a second — arrive later than a margin sized
/// exactly to it. That is not a defect in the measurement; it is what choosing the 98th percentile
/// means, and it is visible as micro-judder on an otherwise settled stream.
///
/// The obvious fix is a higher percentile, and it is a trap: p99.5 of 240 samples is the 239th, so a
/// single unlucky arrival would set the next four seconds of latency — the failure the percentile was
/// chosen to avoid in the first place. Headroom on a ROBUST percentile buys the same coverage without
/// handing the tail a veto.
///
/// PROPORTIONAL, not absolute, so it costs nothing where there is nothing to absorb: a clean LAN path
/// measuring 4ms of spread gains 0.6ms, while a relay measuring 70ms gains 10.5ms. Latency is the
/// product's whole promise, and a fixed addition would be charged to the paths that least need it.
const MARGIN_HEADROOM_FRACTION = 0.15;

/// How fast the margin may move, in ms per second.
///
/// LOAD-BEARING. A margin that jumps moves every future frame's target at once, which is exactly the
/// hitch this whole mechanism exists to remove — an adaptive control that steps is a hitch generator.
/// Slow enough to be invisible, fast enough to cover a link that degrades over a few seconds.
const MARGIN_SLEW_MS_PER_S = 2;

/// CADENCE LOCK.
///
/// A pacer that asks "is the next frame due?" at every vsync re-decides on every tick, so a frame
/// whose target lands near a vsync boundary flips between two of them on a millisecond of noise —
/// producing a 1x/3x pair. Measured: ~6% of frames shown for the wrong number of refreshes,
/// continuously, which reads as roughness rather than as a hitch. Chromium's own video renderer
/// avoids it by DETECTING a stable cadence and rendering to it, which is why the plain <video> path
/// measures 97.8% where this measured 93.3%.
///
/// Locked, the dwell is N BY CONSTRUCTION rather than by luck. It costs no latency: the margin is
/// untouched, only the moment of presentation is decided differently.
const CADENCE_STABLE_FRAMES = 30;      // ~0.5s at 60fps before trusting a cadence
const CADENCE_TOLERANCE = 0.18;        // how close to a whole number the ratio must sit
const CADENCE_MAX = 6;                 // beyond this the source is far slower than the display
const CADENCE_STARVE_LIMIT = 8;        // consecutive missed slots before the lock is abandoned

export class FramePacer<T> {
  private queue: PacedFrame<T>[] = [];
  private delays: Array<{ t: number; d: number }> = [];
  /// The fixed margin, or null when adapting. Null is `Auto`.
  private fixedMargin: number | null;
  /// The current adaptive margin. Starts at the floor and slews toward the measured jitter.
  private adaptive = MARGIN_FLOOR_MS;
  private lastAdaptAt: number | null = null;
  private lastMedia = -Infinity;
  /// Intervals between consecutively PRESENTED frames, on the MEDIA clock, within the window. The
  /// media clock rather than arrival: this measures what the source produced, and arrival deltas
  /// would fold the transport's jitter into the source's cadence.
  private mediaGaps: Array<{ t: number; d: number }> = [];
  private lastPickAt: number | null = null;
  /// The locked number of refreshes per presented frame, or null while free-running.
  private locked: number | null = null;
  private candidate: number | null = null;
  private candidateRuns = 0;
  private missedSlots = 0;
  private readonly cadenceLockEnabled: boolean;
  private s: PacerStats = { presented: 0, starve: 0, dropped: 0, queueMax: 0, offsetMs: null, waiting: 0, empty: 0 };

  constructor(
    private readonly release: (f: T) => void,
    opts?: { marginMs?: number | "auto"; cadenceLock?: boolean },
  ) {
    const m = opts?.marginMs;
    this.fixedMargin = m === undefined || m === "auto" ? null : m;
    this.cadenceLockEnabled = opts?.cadenceLock ?? true;
  }

  /// The locked cadence in refreshes per frame, or null while free-running. Exposed so a session can
  /// say whether it is locked — "smooth" and "locked" are not the same claim, and conflating them is
  /// how a broken lock would hide.
  cadence(): number | null { return this.locked; }

  setMargin(ms: number | "auto"): void { this.fixedMargin = ms === "auto" ? null : ms; }

  /// The margin in force right now — the fixed value, or the adaptive one.
  ///
  /// EXPOSED BECAUSE IT IS THE LATENCY THIS RENDERER IS CHOOSING TO PAY. A hold nobody can read is a
  /// hold nobody can argue with, and `Auto` used to silently mean ZERO — the pacer held nothing and
  /// degenerated into "show whatever is newest", which is the unpaced behaviour it exists to replace.
  marginMs(): number { return this.fixedMargin ?? this.adaptive; }

  /// Move the adaptive margin toward the jitter actually observed.
  ///
  /// TARGET = (p98(arrival delay) - min(arrival delay)) x (1 + headroom). The percentile is the spread
  /// the link is currently showing; the headroom covers its complement, which is late BY CONSTRUCTION
  /// and shows up as micro-judder on a stream that has otherwise settled. Sizing to the max instead
  /// of a percentile would let one unlucky packet set every future frame's latency, which is why the
  /// slack is added on top of a robust statistic rather than taken from a more extreme one.
  private adapt(nowMs: number): void {
    if (this.fixedMargin !== null || this.delays.length < 30) return;
    // HIGH-WATER MARK, NOT THE LAST VALUE SEEN. `nowMs` is monotonic when `pick` is driven from
    // requestAnimationFrame, which is how it runs in production — but a caller that passes arrival
    // times can hand over a value that goes BACKWARDS, and assigning it unconditionally would lower
    // the mark so the next forward jump measures far more elapsed time than really passed. The slew
    // limit would then be silently exceeded, which is the one thing it exists to prevent.
    const last = this.lastAdaptAt ?? nowMs;
    const elapsedS = Math.max(0, (nowMs - last) / 1000);
    this.lastAdaptAt = Math.max(last, nowMs);
    if (elapsedS === 0) return;

    const ds = this.delays.map((x) => x.d).sort((a, b) => a - b);
    const spread = ds[Math.min(ds.length - 1, Math.floor(MARGIN_PERCENTILE * ds.length))]! - ds[0]!;
    const withHeadroom = spread * (1 + MARGIN_HEADROOM_FRACTION);
    const target = Math.min(MARGIN_CEILING_MS, Math.max(MARGIN_FLOOR_MS, withHeadroom));

    // SLEW-LIMITED IN BOTH DIRECTIONS. Coming down matters as much as going up: a margin that
    // collapsed the moment a link improved would drop frames that were already scheduled.
    const step = MARGIN_SLEW_MS_PER_S * elapsedS;
    this.adaptive = target > this.adaptive
      ? Math.min(target, this.adaptive + step)
      : Math.max(target, this.adaptive - step);
  }

  push(f: PacedFrame<T>): void {
    this.delays.push({ t: f.arrivalMs, d: f.arrivalMs - f.mediaMs });
    const cutoff = f.arrivalMs - OFFSET_WINDOW_MS;
    while (this.delays.length > 1 && this.delays[0]!.t < cutoff) this.delays.shift();

    this.queue.push(f);
    // Media order regardless of arrival order: a reordered frame must not be presented after a newer
    // one has already been shown.
    this.queue.sort((a, b) => a.mediaMs - b.mediaMs);
    while (this.queue.length > MAX_QUEUE) { this.s.dropped++; this.release(this.queue.shift()!.frame); }
    if (this.queue.length > this.s.queueMax) this.s.queueMax = this.queue.length;
  }

  /// The media->local mapping. The MINIMUM recent arrival delay is the fastest path the link has
  /// shown; the margin is the knob on top of it.
  ///
  /// ALWAYS RECOMPUTED FROM THE WINDOW, never accumulated from its own previous value. Two bugs in
  /// this repo have exactly that shape — the FEC bitrate ratchet, where writing the reduced figure
  /// back made every step look correct while the bitrate walked downward, and the RTP timestamp
  /// summed from rounded per-frame deltas, where a constant interval rounded the same way every time
  /// so the residual never cancelled.
  private offset(): number | null {
    if (this.delays.length === 0) return null;
    let min = Infinity;
    for (const x of this.delays) if (x.d < min) min = x.d;
    return min + this.marginMs();
  }

  /// `refreshMs` is REQUIRED, not optional, and null must be passed explicitly when the display grid
  /// is not yet known.
  ///
  /// It was optional once. Both call sites then called `pick(t)`, `observeCadence` was never reached,
  /// and the cadence lock shipped completely inert — a 27-minute session reported `cadence: null`
  /// throughout. A required parameter makes that omission a compile error instead of a silent
  /// no-feature.
  pick(nowMs: number, refreshMs: number | null): PacedFrame<T> | null {
    this.adapt(nowMs);
    const off = this.offset();
    this.s.offsetMs = off;
    if (off === null) return null;

    // LOCKED: THIS IS NOT OUR SLOT. Returning early is the whole mechanism — the frame is not
    // discarded, it simply waits for the vsync the cadence says it belongs on. A half-refresh of
    // tolerance so a slot is not missed by floating-point noise.
    if (this.locked !== null && refreshMs !== null && this.lastPickAt !== null) {
      if (nowMs < this.lastPickAt + (this.locked - 0.5) * refreshMs) return null;
    }

    let chosen: PacedFrame<T> | null = null;
    // A HALF-REFRESH LOOKAHEAD WHILE LOCKED. At its slot the pacer takes the frame that belongs
    // there even if its target is a fraction of a refresh away — otherwise the lock would starve on
    // exactly the boundary noise it exists to absorb.
    const horizon = this.locked !== null && refreshMs !== null ? nowMs + refreshMs * 0.5 : nowMs;
    while (this.queue.length > 0 && this.queue[0]!.mediaMs + off <= horizon) {
      const next = this.queue.shift()!;
      if (next.mediaMs <= this.lastMedia) { this.release(next.frame); continue; }
      if (chosen) this.release(chosen.frame);      // superseded by a newer one that is also due
      chosen = next;
    }

    if (chosen) {
      if (refreshMs !== null) this.observeCadence(nowMs, refreshMs);
      // FINITE GUARD: `lastMedia` starts at -Infinity, and the first presentation has no predecessor
      // to measure against.
      if (Number.isFinite(this.lastMedia)) {
        this.mediaGaps.push({ t: nowMs, d: chosen.mediaMs - this.lastMedia });
        const cutoff = nowMs - OFFSET_WINDOW_MS;
        while (this.mediaGaps.length > 0 && this.mediaGaps[0]!.t < cutoff) this.mediaGaps.shift();
      }
      this.lastMedia = chosen.mediaMs;
      this.s.presented++;
      this.lastPickAt = nowMs;
      this.missedSlots = 0;
      return chosen;
    }
    // NOTHING PRESENTED THIS VSYNC — classify why, because the two causes need opposite fixes.
    if (this.queue.length > 0) this.s.waiting++;
    else this.s.empty++;
    // A LOCKED SLOT WITH NOTHING TO SHOW. A few are noise; a run of them means the cadence we locked
    // to no longer exists — the source rate changed, or frames stopped — and holding a dead lock
    // would keep refusing perfectly good frames at every non-slot vsync.
    if (this.locked !== null && refreshMs !== null && this.lastPickAt !== null
        && nowMs >= this.lastPickAt + (this.locked - 0.5) * refreshMs) {
      this.missedSlots++;
      if (this.missedSlots > CADENCE_STARVE_LIMIT) this.unlock();
    }
    // A SOURCE FRAME PERIOD AND A HALF passed with nothing to show. That is a starve, not merely a
    // repeat — and it is judged against what this source actually produces, so a 52fps window is not
    // scored against 60.
    //
    // NOTHING IS COUNTED UNTIL THE CADENCE IS KNOWN, rather than counting against a 60fps guess.
    // Before the source's own period has been measured there is no way to tell "the pacer went
    // hungry" from "this source is simply slower than 60", and guessing produced a burst of starves
    // at every session start — a 30fps window scored seven in its first eight frames, purely from
    // the fallback. Absent means unknown here, as everywhere else. No information is lost: `empty`
    // and `waiting` already classify why nothing was presented, and they need no cadence to do it.
    const sourcePeriod = this.sourcePeriodMs();
    const starveAfter = sourcePeriod === null ? null : sourcePeriod * STARVE_PERIODS;
    if (this.lastPickAt !== null && starveAfter !== null && nowMs - this.lastPickAt >= starveAfter) {
      this.s.starve++;
      this.lastPickAt = nowMs;
    }
    return null;
  }

  /// The source's own frame period: the MEDIAN interval between recently presented frames.
  ///
  /// Median, not mean: a content-driven window sits idle and then bursts, and a mean is dragged by
  /// exactly the long gaps this estimate is used to judge. Null until there are enough samples to
  /// mean anything, and the caller falls back to 60fps rather than to a number built from three
  /// frames.
  sourcePeriodMs(): number | null {
    if (this.mediaGaps.length < SOURCE_PERIOD_SAMPLES_MIN) return null;
    const sorted = this.mediaGaps.map((g) => g.d).sort((a, b) => a - b);
    return sorted[Math.floor(sorted.length / 2)]!;
  }

  /// Watch the interval between presentations and lock when it is reliably a whole number.
  ///
  /// LOCKING ON AN IRREGULAR SOURCE WOULD INVENT MOTION the source never had — a content-driven
  /// window repaints unevenly, and forcing it onto a fixed cadence is resampling, not pacing. So the
  /// ratio must sit close to a whole number for CADENCE_STABLE_FRAMES in a row before it is trusted,
  /// and any frame outside the tolerance resets the run.
  private observeCadence(nowMs: number, refreshMs: number): void {
    if (!this.cadenceLockEnabled || this.lastPickAt === null) return;
    const ratio = (nowMs - this.lastPickAt) / refreshMs;
    const n = Math.round(ratio);
    if (n < 1 || n > CADENCE_MAX || Math.abs(ratio - n) > CADENCE_TOLERANCE) {
      this.candidate = null; this.candidateRuns = 0;
      return;
    }
    if (n === this.candidate) this.candidateRuns++;
    else { this.candidate = n; this.candidateRuns = 1; }
    if (this.locked === null && this.candidateRuns >= CADENCE_STABLE_FRAMES) this.locked = n;
    // A locked pacer that keeps observing a DIFFERENT stable cadence has had its source rate change
    // under it — follow rather than fight, once the new one is as well established as the old.
    else if (this.locked !== null && n !== this.locked && this.candidateRuns >= CADENCE_STABLE_FRAMES) {
      this.locked = n;
    }
  }

  private unlock(): void {
    this.locked = null; this.candidate = null; this.candidateRuns = 0; this.missedSlots = 0;
  }

  /// Release everything queued. `lastMedia` is deliberately NOT rewound: a frame older than what is
  /// already on screen must still never be presented after a flush.
  reset(): void {
    for (const f of this.queue) this.release(f.frame);
    this.queue = [];
    this.delays = [];
    this.lastPickAt = null;
    // A flush means the stream was interrupted; the cadence observed before it says nothing about
    // the one after.
    this.unlock();
  }

  stats(): PacerStats { return { ...this.s, queueMax: Math.max(this.s.queueMax, this.queue.length) }; }

  resetStats(): void {
    this.s = { presented: 0, starve: 0, dropped: 0, queueMax: 0, offsetMs: this.s.offsetMs, waiting: 0, empty: 0 };
  }
}
