/// WHICH RENDER PATH A SOURCE ENDS UP ON, once the fast one has proven it cannot work.
///
/// WHY THIS EXISTS AT ALL, and why it did not before. The WebCodecs path used to be opt-in
/// (`?render=webcodecs`), so `webcodecs-pacer.ts` deliberately REFUSED to fall back:
///
///   "A silent fallback to <video> is worse than a failure here: you would believe you were
///    measuring WebCodecs while watching the ordinary path."
///
/// That was right for an instrument. It stopped being right the moment the DataChannel path became
/// the default, and the give-up message still said so — "reload, or drop ?render=webcodecs" — advice
/// nobody can follow when no parameter put them there. A browser whose WebCodecs cannot decode the
/// negotiated codec then gets a permanently black window with a message telling it to remove a
/// parameter it never had.
///
/// So the refusal is kept and INVERTED: fall back, but never SILENTLY. Every fallback carries the
/// reason it happened and the caller is told once, so it reaches the host log and the UI. What the
/// original comment protected against was mistaking one path for the other; a fallback that
/// announces itself is not that.
export type RenderPath = "webcodecs" | "video";

export class RenderFallback {
  private readonly reasons = new Map<string, string>();

  /// Drop this source to the `<video>` element for the rest of the session.
  ///
  /// Returns true ONLY the first time, which is what keeps the announcement to one line. The give-up
  /// path can be reached more than once — a resubscribe brings a fresh track, and a fresh track can
  /// stall too — and a fallback that re-reported on each would bury the first, which is the one
  /// naming the original cause.
  fallBack(source: string, reason: string): boolean {
    if (this.reasons.has(source)) return false;
    this.reasons.set(source, reason);
    return true;
  }

  /// A LATCH, NOT A PREFERENCE. Whatever put a source here — an unsupported codec, a decoder that
  /// errors on every keyframe — does not fix itself on a retry, and each retry costs a renegotiation
  /// and about a second of video. It holds for the session.
  pathFor(source: string): RenderPath {
    return this.reasons.has(source) ? "video" : "webcodecs";
  }

  reasonFor(source: string): string | undefined { return this.reasons.get(source); }

  has(source: string): boolean { return this.reasons.has(source); }

  /// For the debug hook and the status line: every source that fell back, and why.
  entries(): Array<{ source: string; reason: string }> {
    return [...this.reasons].map(([source, reason]) => ({ source, reason }));
  }
}
