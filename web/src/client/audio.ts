/// Audio playback for the per-source streams the host sends.
///
/// AUDIO NEVER GOES ON THE `<video>`'s srcObject. Browsers form an A/V synchronisation group from
/// tracks that share a MediaStream and delay whichever is ahead — in practice the video — to line
/// the two up. The host puts audio on its own MSID precisely so that group never forms; binding it
/// back into the video element here would rebuild it and quietly cost the video latency this whole
/// design protects. The accepted cost is drift between picture and sound.

const AUDIO_PREFIX = "audio:";

/// The source id an audio stream belongs to, or null if this is not one of ours.
///
/// ONLY THE FIRST SEGMENT IS STRIPPED — a source id contains colons of its own ("win:1234"), so
/// splitting on every colon would resolve "audio:win:1234" to "win".
export function sourceIdFromAudioStream(streamId: string): string | null {
  if (!streamId.startsWith(AUDIO_PREFIX)) return null;
  const id = streamId.slice(AUDIO_PREFIX.length);
  return id.length > 0 ? id : null;
}

export class AudioPlayback {
  constructor(private readonly container: HTMLElement = document.body) {}
  private readonly els = new Map<string, HTMLAudioElement>();
  private readonly pending = new Set<string>();
  private readonly muted = new Set<string>();

  /// True while at least one element is waiting for a user gesture. The status bar renders ONE
  /// affordance from this rather than prompting per window.
  get blocked(): boolean { return this.pending.size > 0; }

  /// The sources currently held, for teardown on a peer rebuild.
  get sources(): string[] { return [...this.els.keys()]; }

  attach(sourceId: string, stream: MediaStream): void {
    let el = this.els.get(sourceId);
    if (!el) {
      el = document.createElement("audio");
      el.autoplay = true;
      // IN THE DOM, BUT NEVER SEEN. Some engines will not play a detached element, and unlike the
      // terminal's hidden input — which must keep a non-zero box or iOS refuses it a keyboard —
      // `display: none` is safe for audio, which has nothing to lay out.
      el.style.display = "none";
      this.container.appendChild(el);
      this.els.set(sourceId, el);
    }
    el.muted = this.muted.has(sourceId);
    if (el.srcObject !== stream) el.srcObject = stream;
    void this.play(sourceId, el);
  }

  detach(sourceId: string): void {
    const el = this.els.get(sourceId);
    if (!el) return;
    el.srcObject = null;
    el.remove();
    this.els.delete(sourceId);
    this.pending.delete(sourceId);
  }

  detachAll(): void {
    for (const sourceId of this.sources) this.detach(sourceId);
  }

  /// Mute or unmute locally. THE LOCAL MUTE IS WHAT MAKES IT INSTANT; the caller separately tells
  /// the host to stop sending, which is what makes it cheap. Waiting for the host's reply to
  /// silence the speaker would put a round trip between the tap and the silence.
  ///
  /// Remembered even when no element exists yet, so a source muted before its track arrives does
  /// not blare the moment it does.
  setMuted(sourceId: string, muted: boolean): void {
    if (muted) this.muted.add(sourceId); else this.muted.delete(sourceId);
    const el = this.els.get(sourceId);
    if (!el) return;
    el.muted = muted;
    if (!muted) void this.play(sourceId, el);
  }

  isMuted(sourceId: string): boolean { return this.muted.has(sourceId); }

  /// Retry everything a gesture just unblocked. Driven from ANY user gesture, because the browser's
  /// requirement is a gesture and not a particular control.
  async retryBlocked(): Promise<void> {
    for (const sourceId of [...this.pending]) {
      const el = this.els.get(sourceId);
      if (el) await this.play(sourceId, el);
    }
  }

  private async play(sourceId: string, el: HTMLAudioElement): Promise<void> {
    try {
      await el.play();
      this.pending.delete(sourceId);
    } catch {
      // NotAllowedError until a gesture. RECORDED RATHER THAN LOGGED AS AN ERROR: it is the
      // browser's documented default, and the status bar is where the user is actually told.
      this.pending.add(sourceId);
    }
  }
}

/// What, if anything, a window's titlebar should say about its audio.
///
/// TWO FALSE STATES, RENDERED DIFFERENTLY. `audio: false` with no owner is MUTED — a setting the
/// user chose and can undo. With an owner it is YIELDED — SCK cannot isolate a window's audio from
/// its application's, so another window of the same app carries it, and this window is silent
/// through no choice of theirs. A correct outcome that looks identical to a broken one becomes a
/// bug report; that is the same reasoning behind the amber `data-unmet` on a refused codec pin.
///
/// AUDIBLE NEEDS NO ORNAMENT and UNKNOWN IS NOT A STATE TO RENDER: a host that predates audio sends
/// neither field, and it must show nothing rather than assert silence.
export function audioBadge(
  sub: { audio?: boolean; audioOwner?: string },
  locallyMuted = false,
): { state: "muted" | "yielded"; title: string } | null {
  // The local mute wins when both apply: it is the state the user can act on, and it is the reason
  // THEY specifically hear nothing.
  if (locallyMuted) return { state: "muted", title: "Audio muted" };
  if (sub.audio !== false) return null;
  if (sub.audioOwner) {
    return {
      state: "yielded",
      title: `Audio comes from another window of the same app (${sub.audioOwner})`,
    };
  }
  return { state: "muted", title: "Audio muted" };
}
