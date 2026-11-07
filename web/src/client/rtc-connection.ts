import { closeClientDialog } from "./instance/overlays";
import { decodeFastRecord, E2EClientGate, LEAVE_CLOSE_CODE, deviceId as hashDevice, identityCode, rootId as hashRoot } from "@rdev/protocol";
import { joinHello } from "./offer-screen";
import { FastChannels } from "../lib/fast-channels";
import { PeerSession, type PeerHandlers } from "../lib/peer";
import { whenOpen, type Channels } from "../lib/channel";
import { SignalingClient, type Role, type SignalingHandlers } from "../lib/signaling";
import { ReconnectingSocket } from "../lib/reconnecting-socket";
import { resumeId } from "../lib/resume-id";
import { recoveryStep, connectionStateEffect, channelLoss, channelsUnopened, type RecoveryState } from "../lib/recovery";
import { controlPlaneOrigin, shellGrantIssuer, shellIdentity, signalingBase } from "../lib/signaling-base";
import { base64urlDecode, base64urlEncode } from "../lib/base64url";
import { listDirectorySessions } from "../lib/directory-api";
import { watchDirectory } from "../lib/directory-watch";
import { HostFollow, type Room } from "../lib/host-follow";
import { SecureSignalling } from "./e2e-signalling";
import { ClientE2EIdentity, shellScopedIdentity } from "./e2e-identity";
import { mountIdentitySetup } from "./identity-setup";
import { identityMismatch, mismatchView } from "./identity-mismatch";
import { askIdentityMismatch } from "./identity-mismatch-dialog";
import type { Connection, ConnectionDeps, Transport } from "./connection";

/**
 * **THE WEBRTC TRANSPORT, THROUGH THE RELAY** (docs/client-web.md, "The connection"): the signalling
 * socket to the Worker, §11's Noise session carrying the offer, answer and ICE, the peer connection
 * with its three data channels and the media, and the recovery that keeps all of it alive. Moved out
 * of `session.ts` unchanged on 2026-09-30 — every comment below still records the defect behind its rule.
 */
/// What a Connect says when the code it was given is a NEW Mac's, shown to be added (`SecureSignalling`'s
/// `peer-initiated`).
export const ADD_DEVICE_CODE = "That code adds a new Mac to your identity. Choose Add device, beside My Devices, and enter it there.";

export interface RtcTarget {
  code: string;
  token: string;
  /** §9.1's psk when a seed was carried, else null — awaited by the handshake, never raced. */
  psk: Promise<Uint8Array | null>;
  params: URLSearchParams;
}

export function rtcTransport(target: RtcTarget): Transport {
  return { carriesMedia: true, sameMac: false, connect: (deps) => createRtcConnection(target, deps) };
}

function createRtcConnection(target: RtcTarget, deps: ConnectionDeps): Connection {
const { params } = target;
/// The room this connection is in: the target's, until its Mac shares again in another and the connection follows it
/// there (`follow` below). Read at every socket and every handshake, never captured.
let room: Room = { code: target.code, token: target.token };
/// The Mac's §10.2 device id once a connection has FOLLOWED it, pinning every later handshake to that device
/// (`expectedResponderDeviceId`): the directory that named the new room is only a hint.
let pinnedHost: Uint8Array | undefined;
const opts = { psk: target.psk };
const { scope, dbg, sink, jitterBufferTargetMs } = deps;
let fast: FastChannels | undefined;
let fastAccepted = false;
let rawChannels: Partial<Channels> = {};
Object.defineProperty(dbg, "fastData", { configurable: true, get: () => fast ? {
  carrier: fast.selected, ready: fast.isReady, generation: base64urlEncode(fast.generation),
  mediaState: typeof pc === "undefined" ? "new" : pc.connectionState,
} : null });
const setStatus = (state: Parameters<typeof sink.status>[0], text: string) => {
  if (fast?.isUsable && !sessionEnded && state !== "error") sink.status("connected", fast.selected === "webSocket" ? "connected · WebSocket" : "connected");
  else sink.status(state, text);
};
const context = deps.context;
const dom = context?.root ?? document;
const base = context ? requiredRemote().signalingEndpoint.replace(/^http/, "ws").replace(/\/+$/, "") : signalingBase();
function requiredRemote() {
  const remote = context?.options.remote;
  if (!remote) throw new Error("Remote client identity and signaling endpoint are required");
  return remote;
}
/// Set by `leave()`: a connection that said goodbye stops recovering.
let sessionEnded = false;
let leaveForNavigation = () => {};
/// The CURRENT peer's three channels — what `onChannelClose` compares a closing channel with, and what the pc
/// reaching `connected` checks (`checkChannels`). Cleared by `rebuildPc`: a fresh pc has none until its own arrive.
let currentChannels: Channels | undefined;

// ── MOVED FROM session.ts, in this order ────────────────────────────────────────────────────────

// ?relay=1 forces media through the TURN relay: ICE otherwise prefers a direct candidate pair (and on
// loopback that bypasses TURN entirely). Used to measure real relay latency; harmless when unset.
const relayOnly = params.get("relay") === "1";

// Auto-reconnecting signaling socket (Task 4): a dropped WS transparently reconnects, and SignalingClient's
// persistent "open" listener re-sends hello on every (re)open. `myResumeId` (Task 3) is the stable per-tab
// id the host maps a reconnecting socket back to the same peer with; `pendingResumeMode` tags a reconnect as
// an ICE-restart ("ice") vs a full PC rebuild ("rebuild"), set by the RecoveryController below.
const myResumeId = context?.resumeId ?? resumeId();
// Starts "rebuild", NOT undefined: a fresh page load reuses the stable per-tab resumeId, so the host (if it
// still holds this peer in its grace window) treats the reconnect as a RESUME. But a reloaded page has a
// brand-new RTCPeerConnection with a NEW DTLS identity — an ICE restart (which the DO picks by default when
// the hello carries no `resume` mode: `peerResumedMsg(id, resume ?? "ice")`) preserves the OLD DTLS and can
// never complete the handshake against the fresh PC → an endless suspend/ICE-restart loop stuck at "waiting
// for host". Announcing "rebuild" makes the host tear down + send a fresh offer. Cleared to undefined once
// live (below), so in-page WS blips (PC still alive) still use the recovery controller's "ice" fast-path.
let pendingResumeMode: "ice" | "rebuild" | undefined = "rebuild";
/// THE JOIN INTENT (docs/sources-and-focus.md, "The join intent"), said in each handshake's `client-confirm` (its
/// app_hello — never to the relay, which could read and forge it): this session's joins say `connect` —
/// a person connecting this client, and the HOST makes it the driver — until its control channel first
/// opens, which is after the host admitted it and decided; every join after that is a RECOVERY of the
/// same session (a dropped socket, a rebuild, a phone back after the relay's grace) and says
/// `reconnect`, which keeps its place. Not flipped on the hello itself: a socket that drops before the
/// host admitted this client has not connected it yet.
let joinIntent: "connect" | "reconnect" = "connect";
/**
 * **Watchdogs on, because a weak network strands a socket instead of closing it** (see
 * `ReconnectingSocket`). The heartbeat at the bottom of this file pings every 15 s and the control
 * plane answers each one, so 40 s of silence is two missed pongs plus slack; 10 s in CONNECTING
 * (doubling on repeats) is well past a healthy TLS handshake on a slow link.
 */
const socket = new ReconnectingSocket(() => new WebSocket(`${base}/session/${room.code}`),
                                      { connectTimeoutMs: 10_000, staleAfterMs: 40_000,
                                        staleDeferred: () => document.visibilityState === "hidden" });
// PROVISIONAL, until the full leave further down replaces it — and nothing can call it before then:
// this function's only catch is the one around the FIRST `buildPeer()` at its end (a throwing
// `RTCPeerConnection`), and that runs the FULL leave. The steps between here and there only declare
// state and register listeners (the signalling client's, the heartbeat), so nothing is expected to
// throw between; one that did would leave this socket open, since the session holds no Connection.
leaveForNavigation = () => {
  sessionEnded = true;
  try { socket.close(LEAVE_CLOSE_CODE, "leaving"); } catch { /* already gone */ }
};
// The network coming back, or the tab being looked at again, is no reason to sit out the rest of an
// 8 s backoff. `kick` only brings a PENDING retry forward, so a healthy socket is untouched.
/// The control plane answers a ping at once; a socket still silent after this is presumed stranded.
/// Generous for a radio waking up, and an eighth of the stale verdict it stands in for.
const PROBE_MS = 5000;
scope.listen(window, "online", () => {
  socket.kick();
  follow.kick();
  // A network that came back may be a DIFFERENT network, which strands the socket on the old one.
  try { signaling.ping(); socket.probe(PROBE_MS); } catch { /* socket mid-reconnect */ }
});
scope.listen(document, "visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  socket.kick();
  follow.kick();
  retryRecoveryNow();
  // Fresh evidence for the stale watchdog, which a hidden tab's throttled heartbeat may have starved —
  // and a PROBE on it: a phone's socket is far more often stranded by the suspension than closed by
  // it, and anything signalled into it before the 40 s stale verdict is simply lost.
  try { signaling.ping(); socket.probe(PROBE_MS); } catch { /* socket mid-reconnect */ }
});
/**
 * **Say when the control plane cannot be reached at all.**
 *
 * A socket that has never opened retries forever behind an exponential backoff, so DNS failing, TLS
 * failing or the origin being down all presented as a window that sat on "connecting…" with nothing
 * to read — and, inside the app, a Connect button that span until someone gave up. Nothing here
 * changes the retry: it keeps trying underneath and a later open still reports "connected".
 *
 * `opened` is the guard that keeps this off a MID-SESSION drop, which has its own wording and its own
 * recovery. Three consecutive failures is ~3.5s of backoff — long enough that a blip on the way up
 * does not earn an error, short enough to beat a person's patience. The reason is deliberately about
 * REACHABILITY and names no cause: a browser tells a page nothing about why a TLS handshake failed,
 * so anything more specific here would be invented.
 */
socket.onDown(({opened, failures}) => {
  dropSecureSession();
  if (opened || failures < 3) return;
  let host = base;
  try { host = new URL(base).host; } catch { /* a malformed base is worth printing whole */ }
  setStatus("error", `can't reach ${host} — check your network connection`);
});
// pc/peer are rebuilt on connection loss (rebuildPc → buildPeer), so they're mutable lets of this
// connection's closure. Each build hands the session FRESH channels (`sink.channels`), and the SESSION's
// `channels` holder (session.ts) is what re-points every data-channel send in one place.
let pc: RTCPeerConnection;
let peer: PeerSession;
let lastTurn: { urls: string[]; username: string; credential: string } | undefined;   // cached TURN creds, re-applied on rebuild
let signaling: SignalingClient;

// ---- FOLLOWING THE MAC TO ITS NEXT ROOM (docs/client-web.md, "A Mac that shares again") ----------------------------
/// The Mac's §10.2 device id, from the last §11 session that opened here — what `follow` looks for in the directory.
let hostDevice: Uint8Array | undefined;
/// The relay said the host LEFT and no room has been followed since: the status says the Mac is gone rather than
/// "reconnecting…", which a room nobody will ever answer again would say for good.
let hostGone = false;
/// A Mac that quit or crashed and shares again is in ANOTHER room (every Share opens a fresh pairing window), so
/// while this connection is not live the directory is asked whether its Mac is listed elsewhere (`host-follow.ts`):
/// at once when the relay says the host left, and `FOLLOW_AFTER_DROP_MS` after the connection stops being live for
/// any other reason — a crashed host is noticed late, and a client that slept through the restart is told nothing.
const FOLLOW_AFTER_DROP_MS = 3000;
const WAITING_FOR_MAC = "the Mac stopped sharing — waiting for it to share again…";
const follow = new HostFollow(room.code, {
  list: async () => {
    const id = await clientIdentity().directoryIdentity();
    return id ? listDirectorySessions(context ? base.replace(/^ws/, "http") : controlPlaneOrigin(), id, context ? (requiredRemote().fetch ?? globalThis.fetch.bind(globalThis)) : undefined) : null;
  },
  watch: (onRows, signal) => {
    void clientIdentity().directoryIdentity().then((id) => {
      if (!id || signal.aborted) return;
      watchDirectory({ base: context ? base.replace(/^ws/, "http") : controlPlaneOrigin(), identity: id, signal,
                       onEvent: (e) => { if (e.kind === "sessions") onRows(e.sessions); } });
    }).catch(() => { /* the poll carries on */ });
  },
  schedule: (fn, ms) => scope.timeout(fn, ms),
  clear: (t) => scope.clearTimeout(t as Parameters<typeof scope.clearTimeout>[0]),
  found: (next) => moveTo(next),
});
scope.defer(() => follow.dispose(), "host-follow");

/**
 * **THE MAC SHARES AGAIN IN ANOTHER ROOM, AND THIS CONNECTION GOES THERE** — as a rebuild: a fresh peer and a fresh
 * §11 session on a socket to that room, every later handshake PINNED to the device the last one reached (the
 * directory that named the room is only a hint). The page that drove says `connect` as it joins, so it drives the Mac
 * again; a passive one says `reconnect` and keeps its place. A restarted host has no driver, so whichever arrives
 * first drives until the old driver does.
 */
function moveTo(next: Room): void {
  if (sessionEnded || scope.disposed || !hostDevice) return;
  console.info(`[follow] the Mac shares again in room ${next.code}; following it there`);
  room = next;
  pinnedHost = hostDevice;
  hostGone = false;
  joinIntent = sink.drives?.() ? "connect" : "reconnect";
  sink.moved?.(next);
  dropSecureSession();
  retryMs = RETRY_MIN_MS;
  fire("moved");          // a rebuild: a fresh pc, and the live socket recycled — into the new room
  socket.kick();          // a socket between two attempts tries the new room now
}

/// §11's session. Null only before it is open or after it has closed — **there is no other path**:
/// SDP and ICE travel inside it and nowhere else, so a null here means this client is not connected,
/// not that it is connected some other way.
let secure: SecureSignalling | null = null;
/// Bumped whenever the session is dropped, so an `openSecureSession` still awaiting its identity
/// when the socket went cannot install a session on the socket that replaced it — the next welcome
/// opens that one.
let secureEpoch = 0;
/// How long a failed session waits before reconnecting for a fresh one — doubling to 30 s and reset
/// by a session that opens, so a relay that keeps injecting garbage costs a reconnect every 30 s
/// rather than a loop.
let handshakeRetryMs = 1000;

/**
 * **A SOCKET THAT DROPS TAKES ITS SESSION WITH IT.** §11.3: "One signalling connection carries one
 * Noise session … A reconnect starts a fresh handshake with fresh ephemerals." Nothing did this, so a
 * reconnect kept the old session and the welcome's `if (!secure)` never fired. That held only while
 * both ends' nonce counters stayed in step — and the relay drops whatever is sent to a side whose
 * socket is down, so one lost envelope desynchronised them for good. Worse, a host that had REAPED
 * this client (180 s gone — any phone left in the background) had no session at all, and the page
 * sat on "reconnecting…" forever. The host replaces its session when the fresh handshake arrives, and
 * holds the resume until it has.
 */
function dropSecureSession(): void {
  fastAccepted = false;
  fast?.setWebSocketSender(null);
  secureEpoch += 1;
  if (!secure) return;
  const old = secure;
  secure = null;
  old.close();
}

// A DELIBERATE close: tell the control plane now rather than letting it hold this client for the
// full 180s grace window while the host keeps capturing and encoding for a page that is gone. The
// host's own connection-state release is the backstop for everything this cannot cover (a crash, a
// force-quit, a lost network) — measured at 32s, against this path's near-zero.
//
// The PAGE's `pagehide` calls this (`Session.leave()`, session-lifecycle.ts) — `pagehide` rather than
// `beforeunload`, which is unreliable and frequently ignored on mobile. Fired even when
// `event.persisted` is true (bfcache): the restored page restarts the session fresh, whereas skipping it would keep the exact 180s defect for the bfcache case, which
// is common on iOS — the platform this was reported from.
leaveForNavigation = () => {
  sessionEnded = true;
  fast?.close();
  follow.dispose();
  // `signaling` is assigned well after this: a build that threw in between has only the socket.
  try { if (signaling) signaling.leave(); else socket.close(LEAVE_CLOSE_CODE, "leaving"); } catch { /* already gone */ }
  try { pc.removeEventListener("connectionstatechange", onConnStateChange); peer.close(); } catch { /* already gone */ }
};

/// **§11.2: nothing leaves outside the session, and there is nowhere else to send it.** Withheld is
/// the only other outcome — sending in the clear would be the whole protocol opted out of by a peer
/// that declined to handshake, which is the one thing §11.2 exists to forbid.
function sendSignalling(message: Record<string, unknown>): void {
  if (!secure || !secure.send(message)) {
    console.warn("[e2e] withheld a signalling message: no open session");
  }
}

function onLocalDescription(d: RTCSessionDescriptionInit): void {
  if (!d.sdp) return;
  sendSignalling({ t: "answer", sdp: d.sdp });
}
function onIceCandidate(c: RTCIceCandidate): void {
  sendSignalling({ t: "ice", cand: c.toJSON() as Record<string, unknown> });
}

/// RDEV'S THREE CHANNELS ARE THE SESSION, AND NOTHING ELSE NOTICES WHEN ONE DIES: `sendControl` returns quietly
/// unless `readyState === "open"`, so every button silently no-ops, and the status bar keeps showing whatever it
/// last said. Reproduced in a real browser by closing just the control channel: the footer still read "connected
/// p2p · 0 ms · 294 kbps" — bitrate still ticking, since the VIDEO track is independent — while ✕ did nothing. A
/// dead TERMINAL channel is the same: "connected", and a terminal that never updates again. Treat either as a
/// connection failure and let recovery rebuild (`hasPc: false` forces the rebuild branch — an ICE restart cannot
/// revive a closed SCTP stream).
///
/// ONE RULE, TWO MOMENTS (`channelLoss`): a channel's own `close`, and the pc reaching `connected`. A close while
/// the pc is down is recovery's — and it used to be FORGOTTEN there: an ICE restart, or ICE coming back by itself,
/// keeps the pc and its closed channels, so the pc read "connected" again over them. Now the pc reaching
/// `connected` looks. A channel of a peer that is no longer the live one is ignored (our OWN teardown).
function onChannelClose(e: Event): void {
  const ch = currentChannels;
  if (!ch || (e.target !== ch.control && e.target !== ch.terminal && e.target !== ch.input && e.target !== ch.bulk)) return;
  checkChannels();
}
function checkChannels(): void {
  const ch = currentChannels;
  if (!ch) return;
  const lost = channelLoss(pc.connectionState, ch);
  if (!lost) return;
  console.warn(`[recovery] the ${lost} channel is ${ch[lost].readyState} on a connected pc; rebuilding`);
  setStatus("error", "connection lost — reconnecting…");
  fire("pcFailed", false);
}

/// **A CONNECTED PC WHOSE CHANNELS NEVER OPEN IS REBUILT** (`channelsUnopened`): the host's SCTP association can fail
/// to form under a pc that connected — its INIT gives up after ~24 s of outage since `sctpRTOMax` — and then no channel
/// ever arrives and nothing else notices. Armed when the pc reaches `connected`, judged when it fires against the pc
/// and channels of THAT moment, and cleared by `rebuildPc` — an old pc's timer must not judge a fresh pc whose
/// channels are still opening. Generous: channels open one round trip after DTLS.
const CHANNELS_OPEN_MS = 15_000;
let channelsOpenTimer: ReturnType<typeof setTimeout> | undefined;
function armChannelsOpenGuard(): void {
  if (channelsOpenTimer !== undefined) scope.clearTimeout(channelsOpenTimer);
  channelsOpenTimer = undefined;
  if (!channelsUnopened(pc.connectionState, currentChannels)) return;
  channelsOpenTimer = scope.timeout(() => {
    channelsOpenTimer = undefined;
    if (sessionEnded || !channelsUnopened(pc.connectionState, currentChannels)) return;
    console.warn(`[recovery] connected for ${CHANNELS_OPEN_MS / 1000} s without its channels open; rebuilding`);
    setStatus("error", "connection lost — reconnecting…");
    fire("pcFailed", false);
  }, CHANNELS_OPEN_MS);
}

const clientHandlers: PeerHandlers = {
  earlyDataChannels: () => !!fast,
  onDataChannels: (ch) => { rawChannels = { ...rawChannels, ...ch }; fast?.attachWebRTC(ch); },
  onLocalDescription, onIceCandidate,
  onTrack: (stream, receiver, negotiatedTrackId) => sink.track?.(stream, receiver, negotiatedTrackId),
  // THIS connection's own listeners go on FIRST, as the lines they replace ran first in session.ts:
  // the join intent flips before the session's control-open batch, and a closing control channel is
  // recovery's to judge.
  onChannels: (ch: Channels) => {
    currentChannels = ch;
    whenOpen(ch.control, () => { joinIntent = "reconnect"; });   // at once if control is ALREADY open (`whenOpen`)
    for (const c of [ch.control, ch.terminal, ch.input, ch.bulk]) c.addEventListener("close", onChannelClose);
    if (fast) fast.attachWebRTC(ch); else sink.channels(ch);
  },
  onExtraChannel: (ch: RTCDataChannel) => sink.extraChannel?.(ch),
  onNegotiated: () => sink.negotiated?.(),
};

function applyTurn(t: { urls: string[]; username: string; credential: string }): void {
  pc.setConfiguration({
    iceServers: [{ urls: t.urls, username: t.username, credential: t.credential }],
    ...(relayOnly ? { iceTransportPolicy: "relay" as RTCIceTransportPolicy } : {}),
  });
}

// Create a fresh pc + peer and wire its state listener. Called once at startup and again by rebuildPc().
function buildPeer(): void {
  pc = new RTCPeerConnection();
  if (lastTurn) applyTurn(lastTurn);   // a rebuilt pc has no config yet — re-apply the cached TURN creds
  peer = new PeerSession(pc, "client", clientHandlers, jitterBufferTargetMs);
  pc.addEventListener("connectionstatechange", onConnStateChange);
}

// ---- RecoveryController: drives the pure recoveryStep FSM from pc state + owns the three timers --------
const recovery = { state: "live" as RecoveryState };
type RecoveryTimer = ReturnType<typeof setTimeout> | undefined;
const timers: { debounce?: RecoveryTimer; restart?: RecoveryTimer; grace?: RecoveryTimer; retry?: RecoveryTimer } = {};
const DEBOUNCE_MS = 2500, RESTART_MS = 5000, GRACE_MS = 180_000;
/// A rebuild that has not connected is tried again, forever, backing off to RETRY_MAX_MS (see
/// `recoveryStep`). The first wait is longer than RESTART_MS because a rebuild is a handshake, an
/// offer and a fresh ICE run, and cutting a TURN path that is about to connect costs more than it saves.
const RETRY_MIN_MS = 8000, RETRY_MAX_MS = 30_000;
let retryMs = RETRY_MIN_MS;

function applyTimer(k: "debounce" | "restart" | "grace" | "retry", op: "start" | "clear" | undefined, ms: number, cb: () => void): void {
  if (op === "clear" && timers[k] != null) { scope.clearTimeout(timers[k]); timers[k] = undefined; }
  if (op === "start") { if (timers[k] != null) scope.clearTimeout(timers[k]); timers[k] = scope.timeout(cb, ms); }
}

/// `hasPcOverride` forces the REBUILD branch for failures the pc itself doesn't reflect — specifically a
/// closed control channel, where the pc still reads "connected" but an ICE restart could never revive the
/// dead SCTP stream. Everything else derives it from the pc as before.
function fire(ev: Parameters<typeof recoveryStep>[1], hasPcOverride?: boolean): void {
  if (sessionEnded) return;
  const hasPc = hasPcOverride ?? (pc.connectionState !== "closed");
  const fx = recoveryStep(recovery.state, ev, hasPc);
  // Transitions only, so a quiet session logs nothing; `[rx]` cannot say why a socket was recycled.
  if (fx.state !== recovery.state || fx.attemptResume) {
    console.info(`[recovery] ${recovery.state} --${ev}--> ${fx.state}${fx.attemptResume ? ` (${fx.attemptResume})` : ""}`);
  }
  recovery.state = fx.state;
  (dbg as unknown as { recovery: string }).recovery = fx.state;
  applyTimer("debounce", fx.timers.debounce, DEBOUNCE_MS, () => fire("debounceTimeout"));
  applyTimer("restart", fx.timers.restart, RESTART_MS, () => fire("restartTimeout"));
  applyTimer("grace", fx.timers.grace, GRACE_MS, () => fire("graceTimeout"));
  if (fx.timers.retry === "start") {
    applyTimer("retry", "start", retryMs, () => { timers.retry = undefined; fire("retryTimeout"); });
    retryMs = Math.min(retryMs * 2, RETRY_MAX_MS);
  } else applyTimer("retry", fx.timers.retry, 0, () => {});
  if (fx.attemptResume) {
    pendingResumeMode = fx.attemptResume;
    // "rebuild" tears the pc down + recreates it now; "ice" keeps the pc and waits (Phase 5 fast-path). In
    // both cases the reconnecting socket re-hellos with the resume mode and the host sends a fresh offer.
    if (fx.attemptResume === "rebuild") rebuildPc();
    // Force a WS reconnect (fixes a gap left by Task 12): recovery depends on a re-hello, which only fires
    // on a WS reopen. A PC-only failure (e.g. the TURN/media path dies) while the signaling WS stays up
    // would otherwise never re-hello — the host never re-offers, and the client stalls to "dead" after the
    // grace timeout. recycle() reuses the SAME WS-drop → DO-suspend → reopen → re-hello(resume) → host-offer
    // path a real network change already takes (no new protocol). It's a safe no-op if the socket is
    // already down (the ordinary case where recovery was triggered by an actual WS drop).
    if (fast?.isReady && secure?.maySignal) {
      sendSignalling({ t: "fast-media-rebuild", generation: base64urlEncode(fast.generation), mode: fx.attemptResume });
    } else socket.recycle();
  }
  if (fast?.isReady && secure?.maySignal) setStatus("connected", "connected");
  else if (hostGone && fx.state !== "live") setStatus("connecting", WAITING_FOR_MAC);
  else if (fx.state === "dead") setStatus("error", "disconnected — reconnecting…");
  else if (fx.state !== "live") setStatus("connecting", "reconnecting…");
  if (fx.state === "live") { pendingResumeMode = undefined; retryMs = RETRY_MIN_MS; }   // recovered → clear the pending resume tag
  // Not live: perhaps the Mac went and shares elsewhere. Live: in its room, nothing to look for.
  if (fx.state === "live") { hostGone = false; follow.disarm(); } else follow.arm(FOLLOW_AFTER_DROP_MS);
}

/// **A page coming back to the foreground retries NOW.** A backgrounded phone throttles or freezes
/// timers, so the retry it armed may be most of a backoff away — and the moment someone looks at the
/// page is exactly when it should be trying. Only a PENDING retry is brought forward, as with `kick`.
function retryRecoveryNow(): void {
  if (timers.retry == null) return;
  scope.clearTimeout(timers.retry); timers.retry = undefined;
  retryMs = RETRY_MIN_MS;
  fire("retryTimeout");
}

function onConnStateChange(): void {
  const fx = connectionStateEffect(pc.connectionState);
  if (fx.status) setStatus(fast?.isReady && secure?.maySignal ? "connected" : fx.status.state, fx.status.text);
  if (fx.event) fire(fx.event);
  // Live again: are its channels? One lost while the pc was down rebuilds now (`checkChannels`) — and then `pc`
  // is the fresh one, not connected, so the media below waits for it.
  if (pc.connectionState === "connected") checkChannels();
  // …and ones that never opened (`armChannelsOpenGuard`) — not armed when the line above rebuilt.
  if (pc.connectionState === "connected") armChannelsOpenGuard();
  if (pc.connectionState === "connected") sink.mediaConnected?.();
}

function rebuildPc(): void {
  // Tear the old pc/peer + the old track's decoders down BEFORE the new pc's ontrack can fire. The old pc's
  // state listener is removed first so its teardown "closed"/"failed" transitions can't re-enter recovery.
  try { pc.removeEventListener("connectionstatechange", onConnStateChange); } catch { /* ignore */ }
  // AND THE OLD CHANNELS', for the same reason: their `close` is delivered asynchronously and can land after the
  // NEW pc reached `connected`. They stop being the current ones here, so the new pc's `connected` checks only its
  // own (`checkChannels`), once they arrive.
  for (const c of currentChannels ? [currentChannels.control, currentChannels.terminal, currentChannels.input, currentChannels.bulk] : []) {
    try { c.removeEventListener("close", onChannelClose); } catch { /* ignore */ }
  }
  currentChannels = undefined;
  rawChannels = {}; fast?.detachWebRTC();
  if (channelsOpenTimer !== undefined) { scope.clearTimeout(channelsOpenTimer); channelsOpenTimer = undefined; }
  try { peer.close(); } catch { /* already gone */ }
  sink.peerClosed?.({ controlRetained: fast?.isReady === true });
  buildPeer();                       // fresh pc + peer, cached TURN creds re-applied
  pendingResumeMode = "rebuild";     // the resumed socket re-hellos with resume:"rebuild"; the host sends a fresh offer
  (dbg as unknown as { rebuilds: number }).rebuilds++;
}

const handlers: SignalingHandlers = {
  onWelcome: (turn) => {
    lastTurn = { urls: turn.urls, username: turn.username, credential: turn.credential };
    applyTurn(lastTurn);
    if (relayOnly) console.log("[rdev] iceTransportPolicy=relay — forcing TURN relay");
    // "waiting for host…" is a FIRST-CONNECT status. On a RECONNECT the welcome fires again (re-hello), and on
    // a WAN link the P2P recovery (ICE restart / self-heal) can finish BEFORE the WS round-trip delivers this
    // welcome — so the pc may already be "connected" (or still mid-recovery) when it lands. Announcing the wait
    // unconditionally would then clobber the real "connected"/"reconnecting…" status and stick there, since a
    // pc that's already connected fires no further connectionstatechange to correct it. Only announce the wait
    // when we're genuinely still waiting for the host's offer: pc not connected AND not mid-recovery.
    if (pc.connectionState !== "connected" && recovery.state === "live") {
      setStatus("connecting", relayOnly ? "waiting for host… (relay)" : "waiting for host…");
    }
    // **AFTER the welcome, because the initiator speaks first and the socket must be usable.** On a
    // reconnect the welcome fires again and §11.3 wants a FRESH handshake with fresh ephemerals —
    // which is what a null `secure` produces, because `dropSecureSession` runs on every drop.
    if (!secure) void openSecureSession();
  },
  onError: (codeStr, msg) => { setStatus("error", `${codeStr} ${msg ?? ""}`.trim()); },
  // THE HOST LEFT — quit, crashed or stopped sharing. A Mac this connection reached is looked for at once: if it
  // shares again, it is in another room (`follow`). One it never reached cannot be told from any other.
  onPeerLeft: () => {
    // The host's process may return to the SAME room after an update. Its Noise
    // session is gone even though our signalling socket and fast lane stayed open.
    // Otherwise media recovery keeps using that dead session and HostFollow ignores
    // the unchanged room forever. Re-authenticate on the shared, bounded backoff.
    dropSecureSession();
    freshSessionSoon("the host left");
    if (!follow.known) { setStatus("error", "host left"); return; }
    hostGone = true;
    setStatus("connecting", WAITING_FOR_MAC);
    follow.arm(0);
  },
  // §11.3's envelope. Everything it decides is `E2EClientGate`'s; `SecureSignalling` carries it.
  onE2E: (ct, _peer, mode) => { secure?.receive(ct, mode); },
  // **THE HOST HAS NO SESSION FOR US.** Its gate died — an envelope lost on a socket that read open,
  // or its own socket reconnecting — and only this end can start again. Dropped at once so nothing
  // more is sealed into a session nobody holds; the reconnect is on the shared backoff, because a
  // relay can forge this and a forged stream of them must cost a reconnect every 30 s, not a loop.
  onE2EReset: () => {
    dropSecureSession();
    freshSessionSoon("the host reset it");
  },
};

// Hoisted to a named object rather than passed inline, so `deliverSecure` can reach the SAME arms:
// §11.3's inner payload is the plaintext signalling JSON precisely so both routes end in one place.
signaling = new SignalingClient(socket, {
  role: "client" as Role, token: room.token, getToken: () => room.token, codecs: ["deflate"], resumeId: myResumeId,
  getResume: () => pendingResumeMode,
}, handlers);

/// **SDP AND ICE ARRIVE ONLY FROM INSIDE THE SESSION.** These were `SignalingHandlers` arms until
/// the plaintext ones were deleted; they are plain functions now, and `deliverSecure` is their only
/// caller — which is the shape §11.2 asks for: there is no route to them that skipped the gate.
function applyOffer(sdp: string, restart: boolean): void {
  // A fresh, NON-restart offer arriving mid-recovery means the host rebuilt its side → we must rebuild our
  // pc too before answering. (A restart offer keeps the pc for an ICE restart — Phase 5.) `pc.new` means we
  // already rebuilt (buildPeer just ran), so we don't rebuild twice.
  //
  // **AND SO DOES ONE ARRIVING WHILE `live`.** The host tags every renegotiation and ICE restart
  // `restart`, so an untagged offer to a pc that already holds a remote description is a peer the
  // host REBUILT — which it now does on a resume whenever its old offer went unanswered. Applied to
  // the old pc it failed on m-line order, and that failure rebuilt AND recycled the socket: measured,
  // two extra sessions per recovery.
  if (!restart && (pc.remoteDescription !== null
                   || (recovery.state !== "live" && pc.connectionState !== "new"))) {
    rebuildPc();
    // THE HOST'S REBUILD IS THE RECOVERY. The old pc's wobble is moot once it is replaced, and left
    // running its debounce fired an ICE restart for a pc that no longer existed — recycling the socket
    // under the new one. Measured: an extra session and a second host rebuild per recovery.
    fire("pcReplaced");
  }
  // AN OFFER WE CANNOT APPLY IS A DEAD SESSION UNLESS SOMETHING ACTS ON IT.
  //
  // This was a floating promise, so a rejected `setRemoteDescription` surfaced as an unhandled
  // rejection in the console and nothing recovered — the peer sat in a state incompatible with the
  // host's, and every later offer failed the same way. Reported from a real session:
  //
  //   InvalidAccessError: Failed to set remote offer sdp: The order of m-lines in subsequent offer
  //   doesn't match order from previous offer/answer.
  //
  // AGENTS.md already records that string as a session-killer and names the cause: the host
  // removing and re-adding tracks, which reorders m-lines against a peer that remembers the old
  // order. A FRESH peer has no such history, so rebuilding is the one recovery that always works —
  // and `hasPc: false` forces the rebuild branch rather than an ICE restart, which cannot fix a
  // description mismatch.
  const offeredPeer = peer;
  void offeredPeer.acceptOffer(sdp).catch((err: unknown) => {
    if (scope.disposed || peer !== offeredPeer) return;
    console.error(`[peer] could not apply the host's offer, rebuilding: ${String(err)}`);
    setStatus("error", "renegotiation failed — reconnecting…");
    fire("pcFailed", false);
  });
}

// CAUGHT, NOT SWALLOWED. `addIce` now queues anything arriving before the remote description, so
// the reported rejection is gone at source — but addIceCandidate can still legitimately reject (a
// malformed candidate, a peer connection closed mid-flight), and an UNHANDLED rejection is how a
// real fault reaches the console looking like noise. Warn so it stays visible; the session
// continues, because one refused candidate is not a dead connection.
function applyIce(cand: Record<string, unknown>): void {
  peer.addIce(cand as RTCIceCandidateInit)
  .catch((e: unknown) => console.warn("[ice] candidate refused:", e));
}

/// §11.3: "Every subsequent signalling message, including SDP, ICE, renegotiation, and ICE restart,
/// is carried inside Noise transport." The inner payload is the same JSON the retired plaintext
/// messages carried, which is what lets one set of arms serve it.
///
/// A FRESH offer also carries THE TAB BAR (`state`, docs/sources-and-focus.md, "The offer carries the tab bar") — handed
/// to the session before the offer is applied, so it draws the session's real tabs while WebRTC connects. It arrived
/// inside the §11 session like the SDP, so it is the host's.
function deliverSecure(message: unknown): void {
  const f = message as { t?: string; generation?: string; version?: number; data?: string; offsets?: string[] };
  if (f.t === "fast-error" && fast && f.generation === base64urlEncode(fast.generation)) {
    fast.close(); fast = undefined;
    setStatus("error", "connection interrupted — reconnecting…");
    // A lost delivery generation cannot safely replay input. Reauthenticate for fresh state.
    dropSecureSession(); socket.recycle();
    return;
  }
  if (f.t === "fast-start" && f.version === 1 && typeof f.generation === "string") {
    const generation = base64urlDecode(f.generation);
    if (!generation || generation.length !== 16) return;
    if (!Array.isArray(f.offsets) || f.offsets.length !== 3 ||
        f.offsets.some(value => typeof value !== "string" || !/^\d{1,20}$/.test(value) || BigInt(value) > 0xffffffffffffffffn)) return;
    fastAccepted = true;
    const offsets = f.offsets.map(BigInt);
    const same = fast && base64urlEncode(fast.generation) === f.generation;
    if (!same) {
      fast?.close();
      fast = new FastChannels(generation, {
        onFailure: (reason) => { console.warn(`[fast] ${reason}`); fast = undefined; setStatus("error", "connection interrupted — reconnecting…"); dropSecureSession(); socket.recycle(); },
        onCarrier: () => setStatus("connected", "connected"),
      });
      sink.channels(fast.channels);
      fast.attachWebRTC(rawChannels);
      const initial = fast;
      // No remote candidate can leave a peer in "new" forever, with no failure event.
      // Begin the existing bounded retry loop without retiring healthy data channels.
      scope.timeout(() => {
        if (fast === initial && !sessionEnded && pc.connectionState !== "connected" && recovery.state === "live") fire("pcFailed", false);
      }, 15_000);
    }
    const current = fast!;
    current.setWebSocketSender(bytes => secure?.maySignal ? secure.send({ t: "fast-record", data: base64urlEncode(bytes) }) : false);
    if (same && f.offsets?.length === 3) {
      for (const stream of [0,1,2] as const) {
        current.receive({kind:2,generation,stream,value:offsets[stream]!,bytes:new Uint8Array()}, "webSocket");
      }
    }
    sendSignalling({ t: "fast-ready", generation: f.generation, offsets: current.receiveOffsets().map(String) });
    current.markReady();
    current.replayPending();
    joinIntent = "reconnect";
    setStatus("connected", "connected · WebSocket");
    return;
  }
  if (f.t === "fast-record" && typeof f.data === "string" && f.data.length <= 12000) {
    const bytes = base64urlDecode(f.data), record = bytes && decodeFastRecord(bytes);
    if (record) fast?.receive(record, "webSocket");
    return;
  }
  const m = message as { t?: string; sdp?: string; restart?: boolean; cand?: Record<string, unknown>; state?: unknown };
  if (m.t === "offer" && typeof m.sdp === "string") {
    // Retain RTC through reauthentication, but an authenticated legacy offer
    // retires the old generation. Its framed bytes cannot reach a legacy peer.
    if (!fastAccepted && fast) { fast.close(); fast = undefined; }
    if (Array.isArray(m.state)) sink.earlyState?.(m.state);
    applyOffer(m.sdp, m.restart === true);
    return;
  }
  if (m.t === "ice" && m.cand) {
    applyIce(m.cand);
    return;
  }
  console.warn(`[e2e] unhandled inner message "${String(m.t)}"`);
}

/**
 * Open the §11 session. Signalling exists only inside it.
 *
 * **It never enrols on its own.** A browser with no identity gets the setup panel and a person;
 * enrolling silently on the way into a session is exactly the "yes to anything" §10.1 refuses to
 * have anywhere.
 */
async function openSecureSession(): Promise<void> {
  const epoch = secureEpoch;
  const identity = clientIdentity();
  let config = await identity.gateConfig(room.code, pinnedHost);
  if (scope.disposed) return;
  // **The one client that cannot be sent to a setup panel.** The app's own window runs at
  // `app://client/`, where no passkey ceremony is possible (§2, profile P-A) — so instead of a
  // person it asks the app, which holds `enroll`, to certify the keys it already generated
  // (§10.3, `root → A → B`). This is not "enrolling silently": the person named this identity when
  // they enrolled the app, on this machine, and the renderer is part of that app.
  const shell = context ? context.platform.native?.issueGrant : shellGrantIssuer();
  // **A CONFIG IS NOT ENOUGH — IT HAS TO NAME THIS MAC'S IDENTITY.** `adoptFromShell` runs only when
  // there is no config and §10.1 forbids an incoming chain replacing one, so a Mac whose root changed
  // underneath this window (adopted by code at capability `2`, then upgraded through §12.1) left it
  // holding the previous root with no route back: every connect ran a full handshake and died at
  // `verifyBundle`, reported as `peer-chain`, which names neither root. Asked BEFORE the gate, so the
  // answer costs one dialog rather than a failed session. `identity-mismatch.ts`.
  if (config && shell) {
    const mine = await identity.trustedRoot();
    if (scope.disposed) return;
    const readIdentity = context ? context.platform.native?.identity : shellIdentity();
    const mismatch = identityMismatch(mine ? identityCode(hashRoot(mine)) : null,
                                      readIdentity ? await readIdentity().catch(() => null) : null);
    if (scope.disposed) return;
    if (mismatch.kind === "mismatch") {
      if (await askIdentityMismatch(mismatch, dom) === "replace") {
        if (scope.disposed) return;
        // §10.1's explicit local reset: the TRUST goes, the keys stay — a change of identity is not a
        // change of device — and the Mac certifies those same keys again below.
        await identity.resetTrust();
        if (scope.disposed) return;
        config = null;
      } else {
        // Declining is permanent and the wording says so; reporting it as an error is what settles
        // the app's pending connect instead of leaving its button spinning.
        setStatus("error", mismatchView(mismatch).declined);
        return;
      }
    }
  }
  if (!config && shell) {
    const adopted = await identity.adoptFromShell(shell);
    if (scope.disposed) return;
    if (adopted.ok) { config = await identity.gateConfig(room.code, pinnedHost); if (scope.disposed) return; }
    else if (adopted.failure.kind === "shell") {
      // The app is not enrolled either. That is a person's job, in the app's own window, and
      // saying so beats a client that looks broken.
      setStatus("connecting", "this Mac needs an encryption identity — enrol it in Xpromptvs");
      return;
    } else {
      // A certification was attempted and REFUSED. Falling through to the setup panel here would
      // report "this browser needs an encryption identity", which is the one thing that is not the
      // problem — it asked, and the answer was no. Measured: an origin disagreement between the
      // app and its renderer read exactly that way.
      const detail = "failure" in adopted.failure ? `${adopted.failure.kind}/${adopted.failure.failure}`
                                                  : adopted.failure.kind;
      setStatus("error", `this Mac refused to certify its own window (${detail})`);
      return;
    }
  }
  // **§9.1's pairing: a browser with nothing, and a code someone carried.** The psk is what makes
  // this safe — an unauthorised party cannot complete `Noise_XXpsk3` message 3, so nobody is asked
  // to approve anything. The Mac mints the chain and this session carries signalling from the same
  // handshake, so there is no second connection.
  let pairing = false;
  // A followed room is not the one the seed was for: its psk would only fail.
  const pairingPSK = config || pinnedHost ? null : await opts.psk;
  if (scope.disposed) return;
  if (!config && pairingPSK) {
    const paired = await identity.pairGateConfig(room.code, pairingPSK);
    if (scope.disposed) return;
    if (paired) { config = paired; pairing = true; }
  }
  if (!config) {
    setStatus("connecting", "sign in with a passkey to continue");
    openE2ESetup(identity);
    return;
  }
  // The socket this was started for has gone; the next welcome opens a session on its replacement.
  if (epoch !== secureEpoch || secure) return;
  // What the page says as it joins (`client-confirm`'s app_hello), inside the session: its join intent, and its
  // terminal grid, measured as that is written.
  const gate = new E2EClientGate({ ...config, appHello: () => new TextEncoder().encode(JSON.stringify({
    ...JSON.parse(new TextDecoder().decode(joinHello({ grid: sink.joinGrid?.() ?? null, intent: joinIntent, fastData: 1 }))),
    ...(fast?.isReady ? { fastGeneration: base64urlEncode(fast.generation) } : {})
  })) });
  let established = false;
  const session: SecureSignalling = new SecureSignalling(gate, {
    sendE2E: (ct, mode) => { signaling.sendE2E(ct, mode); },
    deliver: (message) => { established = true; handshakeRetryMs = 1000; deliverSecure(message); },
    onOpen: () => {
      established = true;
      handshakeRetryMs = 1000;
      // The Mac this session reached — the one to follow if it goes and shares again (`follow`).
      const chain = gate.peerChain;
      if (chain) { hostDevice = hashDevice(chain.leafDevice.bytes); follow.learn(base64urlEncode(hostDevice)); }
      if (pairing) void commitPairing(identity, gate);
    },
    onClosed: (reason) => {
      if (secure !== session) return;   // already replaced: this is the old socket's session ending
      secure = null;
      handshakeFailed(reason, established);
    },
  });
  secure = session;
  session.start();
}

/// A session that ended on its own. `established` says whether it had ever opened.
function handshakeFailed(reason: string, established: boolean): void {
  // §11.3 has one recovery and it is a fresh connection, so take it for a TRANSPORT failure:
  //   - a session that WAS established and then failed is a desynchronised one — an envelope
  //     lost while a socket was dying;
  //   - a handshake that died on a NOISE failure met a stray: an envelope the host sealed into
  //     the session being replaced can reach this socket before message 2 does (measured, when
  //     the host resumed too early).
  // Each reconnect is fresh ephemerals, so none of this retries a session — what §11.3 forbids.
  // A POLICY refusal (`session:…`) would only be asked the same question again, so it says so.
  // A Mac that spoke FIRST is asking to be added to an identity: its code belongs in Add device.
  if (reason === "peer-initiated") {
    setStatus("error", ADD_DEVICE_CODE);
    return;
  }
  if (established || reason === "noise") {
    freshSessionSoon(reason);
    return;
  }
  setStatus("error", `encrypted session ended (${reason})`);
}

/// Reconnect for a fresh §11 session — §11.3's one recovery — on the shared backoff.
function freshSessionSoon(reason: string): void {
  const wait = handshakeRetryMs;
  handshakeRetryMs = Math.min(handshakeRetryMs * 2, 30_000);
  console.warn(`[e2e] session ended (${reason}); a fresh handshake in ${wait} ms`);
  // A socket that dropped by itself in the meantime has already brought a fresh session; recycling
  // it too would throw that one away.
  const epoch = secureEpoch;
  scope.timeout(() => { if (epoch === secureEpoch) socket.recycle(); }, wait);
}

/**
 * **Persist what a `pair` session earned, and erase the secret that bought it.**
 *
 * §12.3's last line: "persist committed chain; erase pairing secret and pending-only state". The
 * session is already usable — `maySignal` is what opened this — so a failed write costs this browser
 * its identity NEXT time rather than this connection, which is why it is reported and not fatal.
 */
async function commitPairing(identity: ClientE2EIdentity, gate: E2EClientGate): Promise<void> {
  const bundle = gate.acceptedBundle;
  if (!bundle) {
    console.warn("[e2e] a pair session opened without issuing a chain");
    return;
  }
  const committed = await identity.commitPaired(bundle);
  if (scope.disposed) return;
  if (!committed.ok) {
    const detail = "failure" in committed.failure
      ? `${committed.failure.kind}/${committed.failure.failure}` : committed.failure.kind;
    console.warn(`[e2e] the paired identity was not stored (${detail})`);
    setStatus("connecting", "paired, but this browser could not store its identity");
    return;
  }
  // **The seed leaves the URL the moment it is spent.** A one-time secret in the address bar is one
  // a screenshot, a shared link or a browser's own history can hand to someone else.
  context?.environment.pairingCommitted?.();
  if (!context && location.hash.includes("pair=")) {
    history.replaceState(null, "", location.pathname + location.search);
  }
}

/**
 * This client's identity, built with the origin §10.1's policy is about.
 *
 * In a browser that is `location.origin` — the default, and not configurable. Inside the app it is
 * the control plane's, because the chain the renderer holds was signed in a ceremony there and a
 * chain checked under the wrong policy is refused for a reason naming neither. `welcome.ts`'s
 * open-time adoption needs the SAME scoping, so it lives in `e2e-identity.ts` as `shellScopedIdentity`
 * and this is now a thin, still-named wrapper around it.
 */
function clientIdentity(): ClientE2EIdentity {
  return context ? requiredRemote().identity : shellScopedIdentity();
}

/**
 * The setup panel, and the flow behind it.
 *
 * **THE IDENTITIES ON OFFER COME FROM THE AUTHENTICATOR, not from a server.** They used to come from
 * an account listing, which §4 puts inside the adversary model — the ask was safe only because
 * joining meant asserting the root's passkey afterwards. Discovery inverts that: §10.1's root is a
 * discoverable credential, so the browser asks the authenticator directly and the Control Plane is
 * consulted for one field it cannot supply — the root's public key, which WebAuthn returns only at
 * creation. `ClientE2EIdentity.discover` pins every byte of that answer against the assertion that
 * was just made, so the worst a hostile Worker can do is refuse to answer.
 */
/// Whether THIS session opened `#e2e-setup`. The dashboard opens the same body-level dialog for
/// sign-in, and a session must close only its own.
let e2eSetupOpened = false;
function openE2ESetup(identity: ClientE2EIdentity): void {
  // The one effect no later line blocks: a body-level panel opened after `closeDialogs` ran
  // would sit over the dashboard with nothing left to close it.
  if (scope.disposed) return;
  e2eSetupOpened = true;
  mountIdentitySetup({
    root: dom.getElementById("e2e-setup")!,
    signal: scope.signal,
    identity,
    // A session is already trying to start; the panel is what was blocking it. GUARDED: a panel
    // finished after this session was disposed must not start a handshake for it.
    onDone: scope.guard(() => { void openSecureSession(); }),
  });
}

/// The identity panels this connection may have opened are BODY-LEVEL and outlive it; closing
/// `#identity-mismatch` resolves its question as Cancel, which the fence after that `await` ignores.
function closeDialogs(): void {
  for (const id of ["identity-mismatch", ...(e2eSetupOpened ? ["e2e-setup"] : [])]) {
    const d = dom.getElementById(id) as HTMLDialogElement | null;
    if (!d?.hasAttribute("open")) continue;
    closeClientDialog(d);
  }
}

// Client heartbeat: keep the WS warm through proxies and let the DO detect our death promptly (both-ends
// heartbeat). ReconnectingSocket.send routes to the live socket; a dropped socket no-ops. The try/catch
// guards the rare tick that lands while the replacement socket is still CONNECTING (send() throws then).
scope.interval(() => { try { signaling.ping(); } catch { /* socket mid-reconnect */ } }, 15_000);

// ── END OF MOVED CODE ───────────────────────────────────────────────────────────────────────────

// Established LAST, as in session.ts: a throwing `RTCPeerConnection` (WebRTC disabled or blocked)
// must not leave this connection's socket open — the session holds no Connection to release.
try { buildPeer(); } catch (e) { leaveForNavigation(); throw e; }

return {
  get connectionState() { return fast?.isUsable ? "connected" : pc.connectionState; },
  media: { getStats: () => pc.getStats(), getReceivers: () => pc.getReceivers(),
           localSdp: () => pc.localDescription?.sdp ?? "" },
  closeDialogs,
  leave: () => leaveForNavigation(),
  close: dropSecureSession,
};
}
