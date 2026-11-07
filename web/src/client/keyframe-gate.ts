/// Admits frames to a VideoDecoder only once the first keyframe has been seen — a decoder must start
/// on one. `reset()` re-enters the gated state (call it after a decoder reset).
///
/// RESTORED 2026-08-27 from the WebCodecs path deleted in 03bee96, for a reason that deletion did not
/// anticipate: piping the encoded transform's `readable` into our own decoder STARVES the browser's,
/// so the browser never sends a PLI again and decoder-driven recovery becomes ours.
export class KeyframeGate {
  private seenKey = false;
  accept(type: "key" | "delta"): boolean {
    if (type === "key") { this.seenKey = true; return true; }
    return this.seenKey;
  }
  reset(): void { this.seenKey = false; }
  get armed(): boolean { return this.seenKey; }
}

/// Wraps `send` so it forwards at most once per `minIntervalMs`. `nowMs` is injected for testability.
///
/// This only keeps a burst of decode errors off the control channel. The HOST already does the real
/// work: `KeyframeDebounce` is 500ms per source and a suppressed request is DEFERRED, never dropped —
/// measured over 20s under 1% loss as the difference between 21 frames and 1131.
export function makeKeyframeRequester(
  send: () => void,
  nowMs: () => number,
  minIntervalMs = 250,
): () => void {
  let last = -Infinity;
  return () => {
    const t = nowMs();
    if (t - last < minIntervalMs) return;
    last = t;
    send();
  };
}
