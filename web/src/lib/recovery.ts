export type RecoveryState = "live" | "wobbly" | "restarting" | "rebuilding" | "dead";
export type RecoveryEvent =
  | "pcConnected" | "pcDisconnected" | "pcFailed"
  | "debounceTimeout" | "restartTimeout" | "graceTimeout" | "retryTimeout"
  /// The HOST replaced the peer connection (a fresh, untagged offer) and the client rebuilt to match.
  /// That rebuild IS a recovery, already under way, so the old pc's timers are moot.
  | "pcReplaced"
  /// The Mac shares again in ANOTHER room and this connection follows it there (`host-follow.ts`).
  | "moved";

type TimerOp = "start" | "clear";
export interface RecoveryEffect {
  state: RecoveryState;
  attemptResume?: "ice" | "rebuild";
  timers: { debounce?: TimerOp; restart?: TimerOp; grace?: TimerOp; retry?: TimerOp };
}

/// Pure connection-recovery state machine. No DOM, no WebRTC — the glue owns real timers and feeds the
/// `*Timeout` events. `hasPc` = the client still holds a usable RTCPeerConnection (false once torn down),
/// which decides ICE-restart vs rebuild. See connection-resilience spec §"Recovery state machine".
///
/// **RECOVERY NEVER GIVES UP, AND IT NEVER JUST WAITS.** A rebuild asks the host for a fresh offer,
/// and that offer can be lost — a socket that died under it, a session that had to be replaced — and
/// `rebuilding` and `dead` used to leave only on `pcConnected`, so one lost offer was a page sitting
/// on "reconnecting…" forever with nothing trying. Both states now keep a `retry` timer running, and
/// every `retryTimeout` rebuilds again; the glue owns the backoff. `dead` is only what the status says
/// after the grace window — it is not a state that stops trying.
export function recoveryStep(state: RecoveryState, ev: RecoveryEvent, hasPc: boolean): RecoveryEffect {
  const recover = (fromWobbly: boolean): RecoveryEffect => {
    // The grace clock must span from the FIRST disconnect, not restart mid-recovery. Entering recovery
    // from `wobbly` means grace is ALREADY running (started on live→wobbly), so we only CLEAR the
    // debounce timer and leave grace untouched. Entering directly from `live` (the pcFailed fast-path
    // that skips debounce) is the first disconnect → START grace here; no debounce timer exists to clear.
    const graceOp: { grace?: TimerOp } = fromWobbly ? {} : { grace: "start" };
    const debounce: { debounce?: TimerOp } = fromWobbly ? { debounce: "clear" } : {};
    return hasPc
      ? { state: "restarting", attemptResume: "ice", timers: { ...debounce, restart: "start", ...graceOp } }
      : { state: "rebuilding", attemptResume: "rebuild", timers: { ...debounce, ...graceOp, retry: "start" } };
  };

  // Retry is (re)started here rather than cleared: arriving from `restarting` there is none running.
  if (ev === "graceTimeout") {
    return { state: "dead", timers: { debounce: "clear", restart: "clear", grace: "clear", retry: "start" } };
  }

  // A MOVE IS A REBUILD INTO THE MAC'S NEW ROOM, from any state: whatever the old room's timers were waiting
  // for will never come, and the grace clock starts again with the new attempt.
  if (ev === "moved") {
    return { state: "rebuilding", attemptResume: "rebuild",
             timers: { debounce: "clear", restart: "clear", grace: "start", retry: "start" } };
  }

  switch (state) {
    case "live":
      if (ev === "pcDisconnected") return { state: "wobbly", timers: { debounce: "start", grace: "start" } };
      if (ev === "pcFailed") return recover(false);   // first disconnect → start grace
      break;
    case "wobbly":
      if (ev === "pcConnected") return { state: "live", timers: { debounce: "clear", grace: "clear" } };
      // Grace is already running from the first disconnect, and stays.
      if (ev === "pcReplaced") return { state: "rebuilding", timers: { debounce: "clear", retry: "start" } };
      if (ev === "debounceTimeout" || ev === "pcFailed") return recover(true);   // grace already running
      break;
    case "restarting":
      if (ev === "pcConnected") return { state: "live", timers: { restart: "clear", grace: "clear" } };
      if (ev === "restartTimeout") return { state: "rebuilding", attemptResume: "rebuild", timers: { restart: "clear", retry: "start" } };
      if (ev === "pcReplaced") return { state: "rebuilding", timers: { restart: "clear", retry: "start" } };
      break;
    case "rebuilding":
      if (ev === "pcConnected") return { state: "live", timers: { grace: "clear", retry: "clear" } };
      if (ev === "retryTimeout") return { state: "rebuilding", attemptResume: "rebuild", timers: { retry: "start" } };
      break;
    case "dead":
      if (ev === "pcConnected") return { state: "live", timers: { retry: "clear" } };
      if (ev === "retryTimeout") return { state: "dead", attemptResume: "rebuild", timers: { retry: "start" } };
      break;
  }
  return { state, timers: {} };   // no-op for unhandled (state, event) pairs
}

export type StatusState = "connecting" | "connected" | "error";

export interface ConnStateEffect {
  /// What the status bar should say, or null to leave it to the recovery machine (which sets
  /// "reconnecting…"/"disconnected — reconnecting…" from its own state).
  status: { state: StatusState; text: string } | null;
  event: RecoveryEvent | null;
}

/// Map a browser `RTCPeerConnection.connectionState` to what the UI should say and which recovery event to
/// fire. Pure so the mapping is testable — the glue in main.ts owns the pc and the DOM.
///
/// `closed` is handled DEFENSIVELY, not because it was the observed bug. It used to fall through every
/// branch, so a closed pc would have left the status bar showing whatever it last said ("connected") —
/// but browsers do NOT fire `connectionstatechange` for `close()` (the spec sets the state silently), so
/// in practice this branch does not fire. It costs nothing and stops the fallthrough being a latent trap.
/// The real "UI claims connected while nothing works" defect was a DATA CHANNEL closing — see `channelLoss` below
/// and `onChannelClose`/`checkChannels` in rtc-connection.ts.
///
/// `closed` maps to `pcFailed` because `fire()` computes `hasPc = connectionState !== "closed"`, so
/// recovery picks a full REBUILD rather than an ICE restart, which a closed pc could never complete.
export function connectionStateEffect(s: RTCPeerConnectionState): ConnStateEffect {
  switch (s) {
    case "connected":    return { status: { state: "connected", text: "connected" }, event: "pcConnected" };
    case "connecting":   return { status: { state: "connecting", text: "connecting…" }, event: null };
    case "disconnected": return { status: null, event: "pcDisconnected" };
    case "failed":       return { status: null, event: "pcFailed" };
    // Status set explicitly as well as firing recovery: if the machine is already `dead`, pcFailed is a
    // no-op and nothing else would ever correct the stale "connected".
    case "closed":       return { status: { state: "error", text: "connection lost — reconnecting…" }, event: "pcFailed" };
    default:             return { status: null, event: null };   // "new"
  }
}

type RdevChannelLabel = "control" | "terminal" | "input" | "bulk";

/// **A DATA CHANNEL THAT DIED IS A DEAD CONNECTION, WHENEVER IT DIED** (docs/sources-and-focus.md, "Recovery never
/// gives up and never just waits"): the channel among rdev's three that is closing or closed, or null — but only
/// while the pc reads `connected`. While it does not, recovery owns the connection, and a channel lost then is named
/// when the pc comes back, so ONE rule serves both callers: a channel's `close`, and the pc reaching `connected`.
/// Before it, only `control`'s close was heard, and only while connected: a channel that closed while the pc was
/// down came back from an ICE restart (which keeps the pc, and cannot reopen a channel) still closed, and a terminal
/// or input channel that closed was never heard at all — the footer reading "connected" over a dead terminal.
export function channelLoss(
  pc: RTCPeerConnectionState,
  channels: Record<RdevChannelLabel, { readyState: string }>,
): RdevChannelLabel | null {
  if (pc !== "connected") return null;
  for (const label of ["control", "terminal", "input", "bulk"] as const) {
    const s = channels[label].readyState;
    if (s === "closing" || s === "closed") return label;
  }
  return null;
}

/// **A CONNECTED PC WHOSE CHANNELS NEVER OPEN IS NOT A CONNECTION** (docs/sources-and-focus.md, "A dead data channel
/// is a dead connection"): true while the pc reads `connected` and rdev's four channels have not all arrived, or one
/// that arrived is still `connecting`. The host's SCTP association can fail to form under a pc that connected — its
/// INIT gives up after pion's 8 retransmits, ~24 s since `sctpRTOMax` caps the backoff at 3 s — and then no channel
/// ever arrives: "connected", and nothing. `rtc-connection.ts` rebuilds a pc that has read `connected` this way for
/// `CHANNELS_OPEN_MS`. A channel that opened and then CLOSED is `channelLoss`'s, not this: the two nets are disjoint,
/// so neither covers for the other by the accident of a timer (each is proven on its own by term-recovery-check).
export function channelsUnopened(
  pc: RTCPeerConnectionState,
  channels: Record<RdevChannelLabel, { readyState: string }> | undefined,
): boolean {
  if (pc !== "connected") return false;
  if (!channels) return true;
  return (["control", "terminal", "input", "bulk"] as const).some((label) => channels[label].readyState === "connecting");
}
