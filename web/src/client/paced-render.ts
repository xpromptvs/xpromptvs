import type { DisplayCadenceStats } from "../lib/display-cadence";
/// The contract both paced renderers implement, so `__rdev.pacer()` reads identically whichever is
/// selected and the two can be compared without translating counters.
///
/// There are three receive paths, chosen by `?render=`:
///   unset       the ordinary <video> element — untouched, and still the default
///   canvas      <video> decodes; a canvas presents on rdev's schedule (canvas-pacer.ts)
///   webcodecs   RTCRtpScriptTransform -> VideoDecoder -> canvas (webcodecs-pacer.ts)
export interface PacedRenderStats {
  mode: "canvas" | "webcodecs";
  incoming: number; presented: number; starve: number; dropped: number; queueMax: number;
  offsetMs: number | null; refreshMs: number | null;
  /// The SOURCE's own median frame interval, measured from media timestamps. Null until enough
  /// intervals exist to mean anything. This is what `starve` is judged against, and it is the number
  /// that says whether a source's rate divides the display's refresh — the difference between judder
  /// that can be fixed and judder that is arithmetic.
  sourcePeriodMs?: number | null;
  /// How well the presentation LOOP kept up with the display, independent of the media. See
  /// `lib/display-cadence.ts` — a cadence miss caused by a skipped vsync and one caused by the
  /// source's rate not dividing the refresh need opposite fixes and look identical without this.
  display?: DisplayCadenceStats;
  /// Time spent inside our own presentation callback. Separates "we are slow" from "the compositor
  /// did not call us", which a skipped vsync alone cannot.
  draw?: { p50: number; p95: number; max: number } | null;
  /// Why a vsync showed nothing: `waiting` = a frame was in hand but not yet due (a target/boundary
  /// effect, which cadence locking addresses); `empty` = no frame in hand (a late arrival, which only
  /// a larger margin addresses). Whichever dominates names the right lever.
  waiting: number; empty: number;
  /// The locked cadence in refreshes per frame, or null while free-running.
  cadence: number | null;
  /// The hold actually in force, in ms. Under `Auto` this is the adaptive value, not the word
  /// "auto" — it is the latency the renderer is choosing to pay, and it must be readable.
  marginMs: number;
  /// refreshes-per-presented-frame -> count. THE judder number: on a 120.5Hz panel with a 60fps
  /// source every entry should be `2`. Frame SELECTION is already ~99.8% correct on the plain path;
  /// this is the quantity that is not.
  dwell: Record<number, number>;
  /// What the SOURCE asked for, same units as `dwell` — the media-time gap between consecutively
  /// presented frames in refresh periods. `dwell` against `asked` separates the pacer's error from
  /// the source's own cadence, which content-driven capture makes irregular by nature.
  asked?: Record<number, number>;
  /// Presented dwell == asked dwell. THIS is the pacer's grade; `dwell[2]` grades the source too.
  cadenceHit?: number;
  cadenceMiss?: number;
  /// Glass-to-glass, from the host's stamp to the moment this renderer drew the pixels, when
  /// `?probe=1` is on. Optional: absent means the probe was off or found no readable stamp.
  g2g?: { p50: number; p95: number; max: number } | null;
  g2gSamples?: number;
  width: number; height: number;
  /// Why the renderer stopped, when it did. A paced renderer that silently falls back to <video> is
  /// worse than one that fails: you would believe you were measuring something you were not.
  error?: string;
  /// webcodecs only: the codec string `configure()` accepted, and how many IDRs we had to ask for.
  codec?: string | null;
  keyframeRequests?: number;
}

export interface PacedRenderHandle {
  /// webcodecs only: hand over the negotiated payload-type map once the answer exists. The pacer is
  /// created before it does — see updateCodecMap.
  updateCodecMap?(map: Map<number, string>, fallback: string | null): void;
  /// webcodecs only: begin presenting into this window. The transform is already attached and frames
  /// are already queueing — see startWebCodecsPacer for why capture cannot wait for the window.
  attachCanvas?(video: HTMLVideoElement): void;
  /// Feed one access unit that arrived over the video DataChannel
  /// instead of from the encoded transform. `data` is TRANSFERRED — do not touch it afterwards.
  pushEncoded?(data: ArrayBuffer, rtp: number, key: boolean, payloadType: number): void;
  stop(): void;
  setMargin(ms: number | "auto"): void;
  stats(): PacedRenderStats;
  resetStats(): void;
}

/// p50/p95/max of a sample array, or null when there are none. SHARED by both paced renderers so a
/// comparison between them is arithmetic-identical — the whole point of measuring the canvas path and
/// the WebCodecs path with one probe is that the difference between them means something.
export function percentiles(xs: readonly number[]): { p50: number; p95: number; max: number } | null {
  if (xs.length < 5) return null;
  const s = [...xs].sort((a, b) => a - b);
  return {
    p50: s[Math.floor(s.length * 0.5)]!,
    p95: s[Math.floor(s.length * 0.95)]!,
    max: s[s.length - 1]!,
  };
}
