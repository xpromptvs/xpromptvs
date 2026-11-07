/// Owns the VideoDecoder's LIFETIME, because a decoder error is terminal and reuse is not allowed.
///
/// THE BUG THIS EXISTS TO PREVENT. WebCodecs CLOSES the codec when it reports an error — the object
/// is dead, not merely faulted. Calling `reset()` on it throws, and `configure()` throws
/// `InvalidStateError: Cannot call 'decode' on a closed codec`. The renderer treated that throw as
/// fatal, so ONE lost reference frame killed the whole path until a page reload.
///
/// It never showed up on loopback, where nothing is lost. Reproduced immediately under the host's
/// 10%-loss impairment profile: 54 frames in, then dead.
///
/// So: on error, throw the decoder away and build another. Cheap — a decoder is a handle over a
/// hardware or library session, and rebuilding costs one keyframe, which the caller must ask for
/// anyway because the new decoder starts unconfigured and un-gated.
export interface DecoderLike {
  configure(config: { codec: string; optimizeForLatency?: boolean }): void;
  readonly state: string;
  close?(): void;
}

export class DecoderSession<D extends DecoderLike> {
  private decoder: D | undefined;
  private configuredAs: string | null = null;
  private gen = 0;

  constructor(private readonly create: () => D) {}

  /// How many decoders have been built. The caller re-gates on a keyframe when this changes — an
  /// in-place reconfigure does NOT bump it, because a codec change on a live decoder needs no IDR
  /// beyond the one the codec change itself brings.
  get generation(): number { return this.gen; }

  /// A decoder configured for `codec`, building a replacement if the current one is gone or closed.
  /// Never returns a closed decoder, and never throws for a closed one.
  ready(codec: string): D {
    // STATE IS AUTHORITATIVE, not just the error callback. The callback is the normal signal, but a
    // decoder can be found closed without one, and configuring a closed decoder is the exact throw
    // that used to be fatal.
    if (!this.decoder || this.decoder.state === "closed") {
      this.decoder = this.create();
      this.configuredAs = null;
      this.gen++;
    }
    if (this.configuredAs !== codec) {
      this.decoder.configure({ codec, optimizeForLatency: true });
      this.configuredAs = codec;
    }
    return this.decoder;
  }

  /// The decoder reported an error, or a decode threw. Drop it; `ready` will build another.
  failed(): void {
    try { this.decoder?.close?.(); } catch { /* already closed */ }
    this.decoder = undefined;
    this.configuredAs = null;
  }

  /// Tear down for good (the pacer is stopping).
  dispose(): void { this.failed(); }
}
