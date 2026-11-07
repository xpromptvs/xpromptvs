/// Refuses frames the decoder cannot decode, so it is never asked to.
///
/// WHY. Taking the encoded frames means rdev owns what Chrome's receive stream normally does for
/// itself: only hand the decoder frames whose reference frames it actually has. Without this the
/// decoder is fed every delta, including ones whose references were lost — it raises
/// `EncodingError: Decoding error`, and WebCodecs CLOSES the codec on error, so each one costs a
/// decoder rebuild and a keyframe request. Measured under a 10% RTX-loss profile: 83 decoder
/// recreations in 80 seconds, roughly one a second, and the host pushed ~2 IDRs a second to keep up
/// — the self-sustaining keyframe storm AGENTS.md describes, arriving from a new direction.
///
/// NOT A SUBSTITUTE FOR THE KEYFRAME GATE. That decides when decoding may START; this decides which
/// frames may continue it.
///
/// DEGRADES TO ACCEPT-EVERYTHING. `frameId` and `dependencies` are optional in the encoded-transform
/// spec. Both Chromium and WebKit were measured exposing them on 2026-08-27, but an engine that
/// omits them must behave exactly as before this existed rather than lose its video to a question it
/// cannot answer.
export interface FrameRefs {
  type: "key" | "delta";
  frameId?: number;
  dependencies?: readonly number[];
}

/// Enough history for a few seconds at 60fps; a broken chain is recovered by a keyframe long before
/// this matters, and the bound is what keeps a long session from growing without limit.
const MAX_TRACKED = 256;

export class FrameReferenceTracker {
  private decoded = new Set<number>();
  private order: number[] = [];

  get size(): number { return this.decoded.size; }

  /// May this frame be handed to the decoder? Records it as decodable when the answer is yes.
  accept(frame: FrameRefs): boolean {
    if (frame.type === "key") {
      // A keyframe re-bases the chain: everything before it is irrelevant, and keeping it would let a
      // stale id satisfy a later dependency by coincidence.
      this.decoded.clear();
      this.order = [];
      this.remember(frame.frameId);
      return true;
    }
    // Nothing to check against: this engine does not describe its references.
    if (frame.frameId === undefined || frame.dependencies === undefined) return true;
    for (const dep of frame.dependencies) {
      if (!this.decoded.has(dep)) return false;
    }
    this.remember(frame.frameId);
    return true;
  }

  reset(): void { this.decoded.clear(); this.order = []; }

  private remember(id: number | undefined): void {
    if (id === undefined || this.decoded.has(id)) return;
    this.decoded.add(id);
    this.order.push(id);
    while (this.order.length > MAX_TRACKED) {
      const old = this.order.shift();
      if (old !== undefined) this.decoded.delete(old);
    }
  }
}
