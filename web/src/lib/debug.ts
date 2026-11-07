import type { Channels } from "./peer";

export interface RdevDebug {
  role: "host" | "client";
  readonly connectionState: RTCPeerConnectionState;
  readonly channelStates: Partial<Record<"terminal" | "input" | "control" | "bulk", RTCDataChannelState>>;
  inputLog: unknown[];
  latency?: { g2gMs: number; samples: number };
  /// Raw recent probe samples (last ~600) for steady-state profiling — `latency.g2gMs` is a
  /// cumulative mean and hides both the distribution and any post-startup improvement.
  latencySamples?: Array<{ g2gMs: number; pipelineMs: number; wireMs?: number; renderMs?: number; decodeMs?: number }>;
  receiverStats?: import("./probe").ReceiverLatencyStats;
  /// The receiver's own inbound-video counters, one entry per subscribed source. A FUNCTION, not a
  /// snapshot — it calls getStats() only when asked, so it costs nothing until used, and it is
  /// available ALWAYS rather than behind `?probe=1`: an instrument you have to opt into is not there
  /// when you need it. Added to separate real packet loss from decoder-side discard on a receiver
  /// that stutters while asking for a keyframe a second; see receiver-stats.ts.
  rxStats?: () => Promise<import("./receiver-stats").InboundVideoDiagnostics[]>;
  /// Whether any per-source audio element is waiting for a user gesture before it may play.
  ///
  /// AN INSTRUMENT FOR A STATE WITH NO OTHER SYMPTOM: a blocked element is silent and reports
  /// nothing — `getStats` shows packets arriving and the track live, because the DECODER is fine and
  /// only playout is refused. Without this, "the host is not sending audio" and "the browser will
  /// not play it yet" look identical from the console.
  audioBlocked?: boolean;
  /// The receiver's own inbound-AUDIO counters. `energy` is `totalAudioEnergy`, computed from the
  /// DECODED samples — the only one of these that separates sound from a perfectly delivered stream
  /// of zeroes, which is what every broken stage in the audio path actually produces.
  audioStats?: () => Promise<{ packets: number | null; energy: number; samples: number; concealed: number }>;
  inputLatencyMs?: number;
  termEcho?: unknown;
  /// TEST-ONLY: type into the visible terminal tab exactly as xterm.js's `onData` does (`e2e/app-local-check.mjs`
  /// — the app's automation port can produce no trusted key events). Set by session.ts.
  sendKey?: (data: string) => boolean;
  /// TEST-ONLY: every row of xterm's buffer (scrollback + screen) as text. Set by main.ts.
  termBuffer?: () => string[];
  /// TEST-ONLY: xterm.js's `term.modes` (origin, bracketed paste, synchronized output, …). Set by main.ts.
  termModes?: () => Record<string, unknown>;
  termCursor?: () => { x: number; y: number } | null;
  /// TEST-ONLY: how many server writes the terminal has applied (WriteCoalescer drains). Set by main.ts.
  termWrites?: number;
  /// TEST-ONLY: one tab's buffer (scrollback + screen) as text, whether or not it is visible. Set by main.ts.
  termBufferOf?: (tab: string) => string[];
  /// TEST-ONLY: the visible tab's 256-colour backgrounds, cells counted per palette index (session.ts).
  termBgCells?: () => Record<number, number>;
  /// TEST-ONLY: the terminal tabs whose bell is unseen (term-bell.ts).
  termBells?: () => string[];
  /// TEST-ONLY: switch tabs exactly as the tab strip does (client-side). Set by main.ts.
  termSwitch?: (tab: string) => void;
  /// TEST-ONLY: the tab on screen, and every tab with an instance. Set by main.ts.
  termVisible?: () => string | null;
  termTabs?: () => string[];
  /// TEST-ONLY: the last `term-list` as the host sent it (names included), beside `viewSet`. Set by session.ts.
  termList?: unknown;
  /// TEST-ONLY: the tab bar the host's first offer carried (`onEarlyState`), standing in for the control channel's. Set by session.ts.
  earlyState?: unknown;
  /// TEST-ONLY: the tab whose screen the offer carried and the page still paints (offer-screen.ts), or null. Set by session.ts.
  termPreview?: () => string | null;
  /// TEST-ONLY: the grid this page said as it joined (`client-confirm`'s app_hello), or null. Set by session.ts.
  joinGrid?: { cols: number; rows: number } | null;
  /// TEST-ONLY: terminal-channel messages and wire bytes received, characters decoded, sink errors. LIVE object.
  termRx?: { messages: number; bytes: number; inflated: number; decoded: number; sinkErrors: number };
  /// TEST-ONLY: how many times the client asked the host for a new terminal wire after an undecodable
  /// stream. Set by main.ts.
  termResyncs?: number;
  /// Tabs rebuilt from their late history (docs/terminal.md, "Scrollback comes after the screen").
  termRebuilds?: number;
  /** TEST-ONLY: per tab, the tail (4 KB) of the live text the last committed rebuild replayed after its history — what
   *  `term-slow-link-check` arm H reads to know a typed line went through the replay, not inside a snapshot. */
  termRebuildLive?: Record<string, string>;
  /// Last terminal clipboard write: which mechanism ran and whether it took. The only way to tell a
  /// dead ⌘C apart from a dead clipboard permission on a device with no devtools (see terminal-copy.ts).
  termCopy?: unknown;
  /// Multi-source smoke observability (Task 10): the last `source-list` / `view-set` seen, so the
  /// e2e spec can locate a picker row by source id and read the current focus without a DOM
  /// data-attribute. Set by main.ts's control-message dispatch; untyped here (like termEcho) to avoid
  /// pulling client-only types into this shared lib module.
  sources?: unknown;
  apps?: import("../client/source-picker").AppsState;
  viewSet?: unknown;
  /// Every `source-thumb` this client has received, as `{id, dataUrl}`. TEST-ONLY, for
  /// `e2e/capture-boundary.spec.ts`.
  ///
  /// Thumbnails are the path §16 of the E2E protocol specification calls the easiest to overlook:
  /// they reach a client that subscribed to NOTHING, so they are the cheapest way to see a source you
  /// were never granted. The gate has to inspect every one, and scraping the palette's `<img>` tiles
  /// instead would measure lazy loading at least as much as the capture boundary.
  thumbs?: () => Array<{ id: string; dataUrl: string | null }>;
  /// Auto resolution mode observability for `e2e/auto-scale-check.mjs`: per source, the mode, the measured
  /// box/dpr/native size and the last scale Auto sent. A function, not a snapshot — the gate reads it
  /// after driving the UI. Untyped here (like termEcho) to keep client-only types out of this shared lib.
  autoRes?: () => unknown;
  /// TESTING (`?render=canvas`): the paced canvas renderer's counters, and live control of its
  /// margin so one session can A/B several values without a reload.
  pacer?: () => unknown;
  setPace?: (ms: number | "auto") => void;
  resetPace?: () => void;
  /// The negotiated inbound video codec's mimeType ("video/AV1", "video/H265", …), refreshed by the
  /// same 1s stats poll that drives the footer. UI-invisible by design — this is the only place the
  /// codec is reported, so `e2e/av1-verify.mjs` and the AV1-vs-H.265 measurement can read it.
  codec?: string | null;
  /// Send one control-channel message. TEST-ONLY, and the only way a harness can drive a control
  /// that is not reachable by clicking — `scripts/probe-forced-recovery.sh` sets the session's
  /// forced FEC overhead through it. Untyped payload (like termEcho) to keep client-only message
  /// types out of this shared lib module.
  sendControl?: (msg: unknown) => void;
  /// TEST-ONLY: one paste/drop delivery (`{to, at?, items}` — `paste-upload.ts`'s `Delivery`) through the
  /// session's own uploader, resolving to the host's answer. Untyped for the reason `sendControl` is. Set by
  /// session.ts; `e2e/paste-live-check.mjs` is its one caller.
  paste?: (delivery: unknown) => Promise<unknown>;
  /// DataChannel video delivery: whether the path is live, what the capability gate decided, and the
  /// per-source integrity counters underneath the pacer's latency and smoothness numbers.
  ///
  /// A FUNCTION, not a snapshot — the gate reads it after letting the stream run. `sources[id]` being
  /// absent while the host reports `activeDelivery: "dc"` is the shape of "routed but delivering
  /// nothing", which is the failure this whole transport keeps producing in new disguises.
  dcDelivery?: () => unknown;
  /// Which sources gave up on WebCodecs and why — empty on a healthy session.
  renderFallback?: () => unknown;
  /// The adaptive playout floor's state, the arrival spread it last read, and its sample count.
  playoutFloor?: () => unknown;
  /// Source ids that currently hold an inbound video stream. A window without a picture is either a
  /// track that never arrived or one that arrived and was dropped; `viewSet` beside this says which.
  videoStreams?: () => string[];
  /** Native routing state/counters only. Never exposes a host focus lease. */
  nativeSourceInput?: () => Record<string, unknown> | undefined;
}

export interface DebugOptions {
  role: "host" | "client";
  pc: { connectionState: RTCPeerConnectionState };
  getChannels: () => Partial<Channels>;
  /// Assign `window.__rdev` (default). The browser session passes FALSE: the page publishes a GETTER
  /// onto the current session instead (`session-lifecycle.ts`), and assigning over it would throw.
  publish?: boolean;
}

/** Attach a live, read-only observability object at window.__rdev for the e2e smokes. */
export function installDebugHook(opts: DebugOptions): RdevDebug {
  const inputLog: unknown[] = [];
  const hook: RdevDebug = {
    role: opts.role,
    get connectionState() {
      return opts.pc.connectionState;
    },
    get channelStates() {
      const ch = opts.getChannels();
      const out: Partial<Record<"terminal" | "input" | "control" | "bulk", RTCDataChannelState>> = {};
      for (const label of ["terminal", "input", "control", "bulk"] as const) {
        const c = ch[label];
        if (c) out[label] = c.readyState;
      }
      return out;
    },
    inputLog,
    latency: undefined,
    receiverStats: undefined,
    inputLatencyMs: undefined,
    termEcho: undefined,
    sources: undefined,
    viewSet: undefined,
    codec: undefined,
  };
  if (opts.publish ?? true) (globalThis as unknown as { __rdev?: RdevDebug }).__rdev = hook;
  return hook;
}
