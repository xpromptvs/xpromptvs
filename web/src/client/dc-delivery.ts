/// The client half of DataChannel video delivery: one multiplexed channel in, whole frames out,
/// demultiplexed by the `sourceIndex` the host assigns and `view-set` announces as `dcIndex`.
///
/// WHAT THIS OWNS: the two channels, one decoder+assembler per source index, the capability gate that
/// decides whether this client may ask for the path at all, and the fallback that gives it up.
///
/// WHAT IT DOES NOT OWN: presentation. Frames go to the caller, which hands them to the same pacer
/// the RTP path uses — the two transports differ in nothing downstream of here.
import { parseDcPacket } from "../lib/dc-wire";
import { DcSourceFeed, type CompleteFrame } from "../lib/dc-feed";

export interface DcCapabilities {
  hasVideoDecoder: boolean;
  isSecureContext: boolean;
}

/// Probed from the real environment. Split out so tests can state a capability rather than fake a
/// global, and so the two reasons a client cannot use this path stay separately visible.
function probeCapabilities(): DcCapabilities {
  return {
    hasVideoDecoder: typeof (globalThis as { VideoDecoder?: unknown }).VideoDecoder !== "undefined",
    isSecureContext: Boolean((globalThis as { isSecureContext?: boolean }).isSecureContext),
  };
}

type FrameHandler = (source: string, frame: CompleteFrame) => void;
type FallbackHandler = (reason: string) => void;

/// Undecodable frames before asking for the keyframe again. Half a second at 60fps — long enough
/// that a host inside its own 500ms debounce has had its chance to answer the first request.
const REASK_KEYFRAME_EVERY = 30;

export class DcDelivery {
  private readonly capabilities: DcCapabilities;
  private readonly feeds = new Map<number, DcSourceFeed>();
  /// sourceIndex -> source id. Populated from `view-set`; a symbol for an index absent here is still
  /// DECODED, because decoding needs no mapping and only presentation does.
  private readonly bound = new Map<number, string>();
  private frameHandler: FrameHandler | undefined;
  private keyframeHandler: ((source: string) => void) | undefined;
  private mainLate: (() => number) | undefined;
  private transport: (() => string | null) | undefined;
  /// The feed's undecodable count when a keyframe was last asked for, so the request repeats while
  /// frames keep being refused rather than once per gap.
  private undecodableAtLastAsk = 0;
  private fallbackHandler: FallbackHandler | undefined;
  private videoChannel: RTCDataChannel | undefined;
  private feedbackChannel: RTCDataChannel | undefined;
  private active = false;
  private reportTimer: ReturnType<typeof setInterval> | undefined;
  /// The session is over. Checked by every listener a bind installs — the listeners themselves
  /// outlive `dispose()` (the channels close with the peer connection, on their own schedule), so a
  /// message still delivered afterward must find this rather than repopulating what dispose forgot.
  private disposed = false;

  private malformed = 0;
  /// Main-thread milliseconds spent in `onMessage` since the last report, and when that window began.
  private busyMs = 0;
  private busySince = performance.now();
  private unboundIndexSymbols = 0;
  private framesDroppedUnbound = 0;
  private mapsReceived = 0;

  constructor(capabilities: DcCapabilities = probeCapabilities()) {
    this.capabilities = capabilities;
  }

  /// May this client ask the host for DataChannel delivery?
  ///
  /// BOTH CONDITIONS ARE REAL AND MEASURED. `VideoDecoder` is `[SecureContext]` per the WebCodecs
  /// spec, so Chromium exposes none on a plain-http origin — which is exactly how an iPad on the LAN
  /// reaches this app. Asking for a path this client cannot decode would produce a blank canvas
  /// rather than a fallback, because the host would happily route away from RTP.
  canUseDataChannel(): boolean {
    return this.capabilities.hasVideoDecoder && this.capabilities.isSecureContext;
  }

  /// Is this source currently delivered over the channel? Read when a pacer is built, so a source on
  /// the RTP path still installs its encoded transform and one on this path does not — installing
  /// both would hand the decoder every frame twice.
  deliversSource(source: string): boolean {
    for (const bound of this.bound.values()) if (bound === source) return true;
    return false;
  }

  onFrames(handler: FrameHandler): void { this.frameHandler = handler; }
  /// Called when a gap in the stream leaves the decoder without a reference it needs.
  onKeyframeNeeded(handler: (source: string) => void): void { this.keyframeHandler = handler; }
  /// Worst main-thread stall since the last report. Supplied from outside because the ticker that
  /// measures it belongs to the page, not to this channel.
  onMainLate(provider: () => number): void { this.mainLate = provider; }

  /// Which ICE path the session is on, for the `[dc-rx]` line. A PROVIDER, not a stored value: the
  /// winning candidate pair can change mid-session (an ICE restart, a network move), so a value
  /// captured once would keep reporting the path the session STARTED on.
  onTransport(provider: () => string | null): void { this.transport = provider; }
  onFallback(handler: FallbackHandler): void { this.fallbackHandler = handler; }

  bindVideoChannel(channel: RTCDataChannel): void {
    if (this.disposed) return;
    // SET BEFORE ANY LISTENER, so it cannot be observed as "blob" by a message that arrives during
    // binding. Reading a Blob is asynchronous, and a file-reader round trip inside the arrival path
    // would add latency to the one thing this transport exists to shorten.
    channel.binaryType = "arraybuffer";
    this.videoChannel = channel;
    this.active = true;
    channel.addEventListener("message", (e) => this.onMessage((e as MessageEvent).data));
    channel.addEventListener("close", () => this.giveUp("channel closed"));
    channel.addEventListener("error", () => this.giveUp("channel error"));
  }

  bindFeedbackChannel(channel: RTCDataChannel): void {
    if (this.disposed) return;
    channel.binaryType = "arraybuffer";
    this.feedbackChannel = channel;
    // THE HOST ANNOUNCES index -> source THE MOMENT IT ROUTES. `view-set` carries the same mapping
    // and stays authoritative, but it is sent by SimManager — which the headless path does not have,
    // so its eager track would be routed and never bound. This also removes the startup race: the
    // binding arrives with the symbols rather than a message later.
    channel.addEventListener("message", (e) => {
      // A LATE MESSAGE ON A CHANNEL THAT OUTLIVES DISPOSE: `dispose()` removes no listener (the
      // channel closes with the peer connection, on its own schedule), so without this a still-open
      // channel's `dc-map` would repopulate `bound` after dispose forgot it.
      if (this.disposed) return;
      // ACCEPTS BOTH BINARY AND TEXT, and the binary arm is the one that matters: pion's
      // `DataChannel.Send([]byte)` emits a BINARY message, not a text one, so a string-only guard
      // silently discarded every announcement the host made. Measured as 1,195 symbols arriving,
      // decoding perfectly, and every frame dropped for want of a mapping the host had already sent
      // twice.
      const raw = (e as MessageEvent).data;
      const data = typeof raw === "string" ? raw
        : raw instanceof ArrayBuffer ? new TextDecoder().decode(raw)
        : null;
      if (data === null) return;
      try {
        const message = JSON.parse(data) as { t?: string; sources?: Record<string, string> };
        if (message.t === "dc-map" && message.sources) {
          this.mapsReceived++;
          for (const [index, source] of Object.entries(message.sources)) {
            this.setSourceIndex(source, Number(index));
          }
        }
      } catch { /* a malformed control message is not worth failing the transport over */ }
    });
    // ONE REPORT PER BOUND SOURCE EVERY 5s, matching `[rx]`'s cadence on the RTP path so the two
    // read on one timeline. The host prints them; increment 2's adaptive FEC reads them.
    if (this.reportTimer === undefined) {
      this.reportTimer = setInterval(() => this.report(), 5_000);
    }
    // ASK FOR THE MAPPING, rather than waiting to be told. The host announces on routing and on
    // channel-open, but both can precede this listener existing — so the only race-free order is the
    // client asking once it is ready to hear the answer.
    const ask = () => this.sendFeedback({ t: "dc-map-request" });
    if (channel.readyState === "open") ask();
    else channel.addEventListener("open", ask);
  }

  /// The session is over (`session.ts`). Stops the 5 s report and forgets every feed, binding and
  /// handler, so a disposed delivery holds nothing and says nothing. The channels themselves close
  /// with the peer connection; a message they still deliver finds no feed and no handler.
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    if (this.reportTimer !== undefined) { clearInterval(this.reportTimer); this.reportTimer = undefined; }
    this.active = false;
    this.feeds.clear();
    this.bound.clear();
    this.videoChannel = undefined;
    this.feedbackChannel = undefined;
    this.frameHandler = undefined;
    this.keyframeHandler = undefined;
    this.fallbackHandler = undefined;
    this.mainLate = undefined;
    this.transport = undefined;
  }

  private report(): void {
    for (const [index, feed] of this.feeds) {
      // Reset AFTER the loop, below — every bound source reports the same figure, because the cost
      // is the channel's and not any one source's.
      const source = this.bound.get(index);
      if (source === undefined) continue;
      // `cpuMsPerS` is the share of ONE SECOND this path spent on the main thread. Above ~200 the
      // tab is visibly struggling; approaching 1000 it is wedged, and no other counter here says so.
      const elapsed = performance.now() - this.busySince;
      const cpuMsPerS = elapsed > 0 ? (1000 * this.busyMs) / elapsed : 0;
      this.sendFeedback({ t: "dc-report", source, ...feed.summary(), cpuMsPerS, nacked: feed.nacked,
                          mainLateMs: this.mainLate?.() ?? 0,
                          via: this.transport?.() ?? "" });
    }
    this.busyMs = 0;
    this.busySince = performance.now();
  }

  /// Bind an index to a source, or clear it with `null` when the source falls back to RTP.
  ///
  /// CLEARING DROPS THE FEED. A source rendering from RTP must stop consuming the channel, or its
  /// stale decoder would hold a window open and keep routing frames to a window that is no longer
  /// drawing them.
  setSourceIndex(source: string, index: number | null): void {
    for (const [existing, boundSource] of this.bound) {
      if (boundSource === source && existing !== index) {
        this.bound.delete(existing);
        this.feeds.delete(existing);
        this.undecodableAtLastAsk = 0;   // the count it was measured against went with the feed
      }
    }
    if (index !== null) this.bound.set(index, source);
  }

  private onMessage(data: unknown): void {
    // MAIN-THREAD COST, MEASURED. Every symbol is parsed, assembled and — for repair — solved
    // through GF(256) Gaussian elimination over 1200-byte payloads, all on the main thread. A
    // session reported the whole tab locking up hard enough to refuse console input, and there was
    // no way to tell that apart from any other stall because nothing counted the work. Reading a
    // clock twice per message is far cheaper than the parse that follows it.
    const startedAt = performance.now();
    try {
      this.onMessageInner(data);
    } finally {
      this.busyMs += performance.now() - startedAt;
    }
  }

  private onMessageInner(data: unknown): void {
    // A video message delivered after dispose (the channel outlives it, on its own schedule) must not
    // relearn what dispose forgot — no fresh `DcSourceFeed`, no NACK, no frame.
    if (this.disposed) return;
    if (!(data instanceof ArrayBuffer)) { this.malformed++; return; }
    const packet = parseDcPacket(data);
    if (!packet) { this.malformed++; return; }
    let feed = this.feeds.get(packet.sourceIndex);
    if (!feed) {
      feed = new DcSourceFeed();
      this.feeds.set(packet.sourceIndex, feed);
    }
    const source = this.bound.get(packet.sourceIndex);
    if (source === undefined) this.unboundIndexSymbols++;
    const frames = feed.push(packet);
    // ASK FOR WHAT DID NOT ARRIVE, on the same beat as the symbols themselves. Checked per packet
    // rather than on a timer because the request has a DEADLINE — the frame is going to be presented
    // one margin from now, and a request that waits for a tick has already spent part of the budget
    // it needs. `takeNackable` returns each symbol once, so this is cheap when nothing is missing.
    const missing = feed.takeNackable();
    if (missing.length > 0) {
      this.sendFeedback({ t: "dc-nack", index: packet.sourceIndex, esis: missing });
    }
    // ASKED FOR BEFORE THE EARLY RETURN, because a harvest that produced NOTHING is exactly the case
    // that needs a keyframe: the frames were refused for want of a reference. Below the return, the
    // request was made only when something got through — so the one situation it exists for was the
    // one situation it could not reach.
    if (source !== undefined && feed.takeDiscontinuity()) this.keyframeHandler?.(source);
    if (source !== undefined && feed.undecodable - this.undecodableAtLastAsk >= REASK_KEYFRAME_EVERY) {
      this.undecodableAtLastAsk = feed.undecodable;
      this.keyframeHandler?.(source);
    }
    if (frames.length === 0) return;
    if (source === undefined) {
      // Decoded but unroutable. Dropping is correct rather than buffering: a held frame is stale by
      // the time a binding arrives, and the decoder needs a keyframe to start anyway.
      this.framesDroppedUnbound += frames.length;
      return;
    }
    // ONE KEYFRAME PER BURST, ASKED FOR BEFORE THE FRAMES ARE HANDED ON. A gap means the decoder is
    // about to reference a picture it never received, and nothing else on this path can tell: the
    // frames that DID arrive are byte-exact, and the reference tracker accepts everything because the
    // DataChannel carries no dependency metadata. Without this the artifacts persist until the host
    // happens to send an IDR for its own reasons.
    for (const frame of frames) {
      // AFTER A HOLE, FEED THE DECODER NOTHING UNTIL A KEYFRAME. The frames that follow a lost one
      // reference a picture it never received, so decoding them renders artifacts — visually
      // indistinguishable from data corruption, and lasting until the host's next IDR, which its own
      // debounce can hold for up to 500ms. A brief freeze is far better than half a second of
      // garbage, and the frames are worthless either way.
      //
      // Measured on a poor link: `lost=57 (0.81%)`, `gaps=57`, and ZERO corrupt frames. Every frame
      // reaching the decoder was byte-exact and the picture was still wrong, because the frames were
      // fine and their REFERENCE was missing.
      this.frameHandler?.(source, frame);
    }
  }

  /// Give up the path. The caller re-subscribes the affected sources over RTP.
  private giveUp(reason: string): void {
    if (!this.active) return;
    this.active = false;
    // THE FEEDS GO TOO. A retained decoder would hold a dead stream's window and try to solve
    // equations against symbols that can never arrive.
    this.feeds.clear();
    this.bound.clear();
    if (this.reportTimer !== undefined) { clearInterval(this.reportTimer); this.reportTimer = undefined; }
    this.fallbackHandler?.(reason);
  }

  /// Send one JSON message on the feedback channel. Best effort: a report that cannot be sent is not
  /// worth failing anything over.
  sendFeedback(message: unknown): void {
    const channel = this.feedbackChannel;
    if (!channel || channel.readyState !== "open") return;
    try { channel.send(JSON.stringify(message)); } catch { /* the report is not load-bearing */ }
  }

  stats(): Record<string, unknown> {
    const sources: Record<string, unknown> = {};
    for (const [index, feed] of this.feeds) {
      const source = this.bound.get(index);
      if (source !== undefined) sources[source] = feed.summary();
    }
    return {
      active: this.active,
      canUseDataChannel: this.canUseDataChannel(),
      capabilities: this.capabilities,
      malformed: this.malformed,

      feedbackBound: this.feedbackChannel !== undefined,
      feedbackState: this.feedbackChannel?.readyState ?? "-",
      mapsReceived: this.mapsReceived,
      bound: [...this.bound.entries()],
      // NON-ZERO AT STARTUP IS NORMAL — symbols can precede the view-set that names their index.
      // Non-zero in steady state means the host is routing a source the client never bound.
      unboundIndexSymbols: this.unboundIndexSymbols,
      framesDroppedUnbound: this.framesDroppedUnbound,
      sources,
    };
  }
}
