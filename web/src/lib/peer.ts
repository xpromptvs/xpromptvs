import { remoteTrackIdentity } from "./remote-track-identity";
import { IceBuffer } from "@rdev/protocol";

import type { Channels } from "./channel";
import { LaneLink } from "./lane-channel";
export type { Channels } from "./channel";
export interface RTCPeerConnectionLike {
  createDataChannel(label: string, init?: RTCDataChannelInit): RTCDataChannel;
  createOffer(): Promise<RTCSessionDescriptionInit>;
  createAnswer(): Promise<RTCSessionDescriptionInit>;
  setLocalDescription(d: RTCSessionDescriptionInit): Promise<void>;
  setRemoteDescription(d: RTCSessionDescriptionInit): Promise<void>;
  addIceCandidate(c: RTCIceCandidateInit): Promise<void>;
  addTrack(track: MediaStreamTrack, stream: MediaStream): RTCRtpSender;
  close(): void;
  onicecandidate: ((e: RTCPeerConnectionIceEvent) => void) | null;
  ontrack: ((e: RTCTrackEvent) => void) | null;
  ondatachannel: ((e: RTCDataChannelEvent) => void) | null;
  localDescription: RTCSessionDescription | null;
  readonly connectionState?: RTCPeerConnectionState;
  addEventListener?(type: "connectionstatechange", listener: () => void): void;
}


export interface PeerHandlers {
  onLocalDescription?(d: RTCSessionDescriptionInit): void;
  onIceCandidate?(c: RTCIceCandidate): void;
  onChannels?(ch: Channels): void;
  onDataChannels?(ch: Partial<Channels>): void;
  /// Only a fast adapter has listeners ready before the complete legacy set.
  earlyDataChannels?(): boolean;
  onTrack?(stream: MediaStream, receiver?: RTCRtpReceiver, negotiatedTrackId?: string): void;
  /// A DataChannel the host opens whose label is none of rdev's — today `video` and
  /// `video-feedback` (see dc-delivery.ts). Routed out rather than left in `pending`, where it would
  /// sit unread forever AND hold `onChannels` hostage to a readiness set it can never complete.
  onExtraChannel?(ch: RTCDataChannel): void;
  /// The answer round-trip for this negotiation is complete.
  ///
  /// EXISTS FOR `RTCRtpScriptTransform`. A transform installed from `ontrack` — which fires DURING
  /// `setRemoteDescription` — never delivers: `onrtctransform` does not fire even though the property
  /// reads set on the correct live receiver. A throwaway probe that attached after this point
  /// received frames normally, and that difference is the only one left after ruling out worker
  /// load, handler installation, worker type, receiver identity and attach-time deferral.
  onNegotiated?(): void;
}

/// rdev's receiver jitter-buffer target, in milliseconds.
///
/// ZERO IS A MODE, NOT A QUANTITY, AND THAT IS THE WHOLE POINT. Both here and in the playout-delay
/// RTP extension, 0 does not mean "please hold 0ms" — it means "disable smoothing, render as soon as
/// possible". WebRTC's own spec says so of the extension: a value of 0 is "meaningless from the
/// perspective of actually meeting the suggested delay, but it indicates to the receiver that the
/// frame should be rendered as soon as possible". rdev asked for that mode in BOTH places at once.
///
/// MEASURED ON A REAL iPad, and the difference is not subtle. With a zero target the receiver ran a
/// ~1ms buffer, reported NO loss, NO dropped frames and NO freezes — and still sent 78 keyframe
/// requests in 35s, which the host answered with full IDRs until 84% of the bitrate was keyframes
/// and the stream collapsed to 15.7 fps. With a target of ONE MILLISECOND: 1 request in 45s, 0% of
/// bits on keyframes, a steady 51-56 fps.
///
/// ANY NON-ZERO VALUE RESTORES ADAPTIVE BEHAVIOUR, and smaller is better because the estimator
/// adapts UPWARD from there: target 1ms settled at ~15ms of real buffer, target 50ms at ~25ms. So
/// the smallest non-zero value is the one that serves this project's goal. `?jbuf=<ms>` overrides
/// it, and `?jbuf=0` still selects the old disable-smoothing mode for testing.
///
/// CHROME NEVER EXHIBITED ANY OF THIS: it clamps to a ~16-18ms minimum and ignores 0, which is the
/// wall the whole latency milestone hit — and the reason this shipped broken for so long is that the
/// browser rdev is developed against silently protected it from its own setting.
export const DEFAULT_JITTER_BUFFER_TARGET_MS = 1;

/// Parse the `jbuf` URL override — the receiver jitter-buffer target in MILLISECONDS.
///
/// Anything unparseable falls back to the shipped default rather than failing: a typo in a
/// diagnostic parameter must not change how video is received.
export function parseJitterBufferTargetMs(raw: string | null): number {
  if (raw === null) return DEFAULT_JITTER_BUFFER_TARGET_MS;
  const ms = Number(raw);
  if (raw.trim() === "" || !Number.isFinite(ms) || ms < 0) return DEFAULT_JITTER_BUFFER_TARGET_MS;
  // Beyond a second this is not a latency experiment, it is a broken session.
  return Math.min(ms, 1000);
}

const RELIABLE: RTCDataChannelInit = { ordered: true };

/// rdev's channel labels: the lane and bulk (the product), or the old three and bulk (RDEV_TEST_SCTP_CHANNELS).
const RDEV_CHANNEL_LABELS = ["terminal", "input", "control", "bulk", "lane"] as const;
type RdevChannelLabel = (typeof RDEV_CHANNEL_LABELS)[number];

export class PeerSession {
  /// The lane under terminal, input and control, once the host's `lane` channel arrived (client only).
  private lane: LaneLink | null = null;
  private remoteSDP = "";

  constructor(
    private readonly pc: RTCPeerConnectionLike,
    public readonly role: "host" | "client",
    private readonly handlers: PeerHandlers,
    private readonly jitterBufferTargetMs: number = DEFAULT_JITTER_BUFFER_TARGET_MS,
  ) {
    pc.onicecandidate = (e) => { if (e.candidate) this.handlers.onIceCandidate?.(e.candidate); };
    pc.ontrack = (e) => {
      // Minimize the receiver jitter buffer. Browsers buffer ~100-300ms of video before playout to
      // absorb network jitter; on a local link there is none, so that delay is pure latency. 0 ms
      // targets immediate playout. (RTCRtpReceiver.jitterBufferTarget: Chrome/Edge 114+; ignored
      // where unsupported.)
      const recv = (e as { receiver?: { jitterBufferTarget?: number | null; playoutDelayHint?: number } }).receiver;
      if (recv) {
        // Minimize the receiver jitter buffer AND the playout-delay buffer. On a local link there is no
        // jitter to absorb, so both are pure latency. jitterBufferTarget: Chrome/Edge 114+;
        // playoutDelayHint: the older Chrome knob / complement to the sender's playout-delay extension.
        // UNITS DIFFER AND ARE INVISIBLE AT ZERO: jitterBufferTarget is MILLISECONDS,
        // playoutDelayHint is SECONDS. Both read 0 today, so passing the same number to each looks
        // correct right up until the value is non-zero, when it would ask for a fifty-SECOND delay.
        const ms = this.jitterBufferTargetMs;
        try { recv.jitterBufferTarget = ms; } catch { /* unsupported */ }
        try { recv.playoutDelayHint = ms / 1000; } catch { /* unsupported */ }
      }
      const s = e.streams[0]; if (s) this.handlers.onTrack?.(s, (e as RTCTrackEvent).receiver, remoteTrackIdentity(this.remoteSDP, e.transceiver?.mid ?? null, s.id));
    };
    if (role === "client") {
      const pending: Partial<Record<RdevChannelLabel, RTCDataChannel>> = {};
      let handed = false;
      // TWO COMPLETE SETS (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §4): `lane` + `bulk`, whose
      // three streams become terminal, input and control; or the SCTP baseline's four. Whichever completes first.
      let logical: Partial<Channels> = {};
      const handOver = () => {
        if (pending.lane && !this.lane && (pending.bulk || this.handlers.earlyDataChannels?.())) {
          this.lane = new LaneLink(pending.lane, { connected: () => pc.connectionState === "connected" });
          const [terminal, input, control] = this.lane.channels;
          logical = { ...logical, terminal, input, control };
          this.handlers.onDataChannels?.({ terminal, input, control });
        } else if (!pending.lane && pending.terminal && pending.input && pending.control && !logical.control) {
          logical = { ...logical, terminal: pending.terminal, input: pending.input, control: pending.control };
          this.handlers.onDataChannels?.(logical);
        }
        if (pending.bulk && !logical.bulk) { logical.bulk = pending.bulk; this.handlers.onDataChannels?.({ bulk: pending.bulk }); }
        if (!handed && logical.terminal && logical.input && logical.control && logical.bulk) {
          handed = true; this.handlers.onChannels?.(logical as Channels);
        }
      };
      pc.ondatachannel = (e) => {
        const ch = e.channel;
        // KEYED ON rdev's LABELS BY NAME, rather than on "not one of ours": an unexpected label must reach the
        // extra-channel hook instead of silently joining a set and holding `onChannels` hostage to it.
        if (!(RDEV_CHANNEL_LABELS as readonly string[]).includes(ch.label)) {
          this.handlers.onExtraChannel?.(ch);
          return;
        }
        pending[ch.label as RdevChannelLabel] = ch;
        handOver();
      };
      pc.addEventListener?.("connectionstatechange", () => {
        if (pc.connectionState === "connected") this.lane?.connected();
        else if (pc.connectionState === "disconnected" || pc.connectionState === "failed") this.lane?.linkLost();
      });
    }
  }

  /** Host only: create the three channels and emit an offer. */
  async startOffer(): Promise<void> {
    const channels: Channels = {
      terminal: this.pc.createDataChannel("terminal", RELIABLE),
      input: this.pc.createDataChannel("input", RELIABLE),
      control: this.pc.createDataChannel("control", RELIABLE),
      bulk: this.pc.createDataChannel("bulk", RELIABLE),
    };
    this.handlers.onChannels?.(channels);
    const offer = await this.pc.createOffer();
    await this.pc.setLocalDescription(offer);
    this.handlers.onLocalDescription?.(offer);
  }

  /// ICE candidates that arrived before a remote description existed, in arrival order.
  ///
  /// `addIceCandidate` before `setRemoteDescription` is an InvalidStateError by spec. Chrome tolerates
  /// it; SAFARI REJECTS, which is how this surfaced — an unhandled rejection on every reload:
  /// `InvalidStateError: The remote description was null`.
  ///
  /// A REJECTED CANDIDATE IS A DROPPED ONE, and that is the part that is not cosmetic. Losing the
  /// host's early candidates makes the winning pair more likely to be peer-reflexive, and this
  /// project has already measured what that costs: pion holds a prflx pair for
  /// `prflxAcceptanceMinWait` — 1000 ms — before accepting it, which reads as input being dead for a
  /// second after a reconnect while every state says connected.
  ///
  /// **BOUNDED since the E2E work (§11.3: "with a bounded size and deadline").** It was a plain
  /// array with no cap and no expiry, so anything that could deliver a candidate could grow it
  /// without limit — and §4 puts the Control Plane inside the adversary model, so today that is the
  /// relay. `IceBuffer` keeps the ordering and the drain-before-await property this had.
  private pendingIce = new IceBuffer<RTCIceCandidateInit>();
  private hasRemoteDescription = false;

  /** Client only: accept a remote offer and emit an answer. */
  async acceptOffer(sdp: string): Promise<void> {
    this.remoteSDP = sdp;
    await this.pc.setRemoteDescription({ type: "offer", sdp });
    await this.drainIce();
    const answer = await this.pc.createAnswer();
    await this.pc.setLocalDescription(answer);
    this.handlers.onLocalDescription?.(answer);
    this.handlers.onNegotiated?.();
  }

  async acceptAnswer(sdp: string): Promise<void> {
    this.remoteSDP = sdp;
    await this.pc.setRemoteDescription({ type: "answer", sdp });
    await this.drainIce();
  }

  async addIce(cand: RTCIceCandidateInit): Promise<void> {
    if (!this.hasRemoteDescription) {
      this.pendingIce.push(cand, Date.now());
      return;
    }
    await this.pc.addIceCandidate(cand);
  }

  /// Flush what arrived early, IN ORDER, once a remote description exists.
  ///
  /// The queue is emptied BEFORE the first await so a re-entrant drain cannot deliver a candidate
  /// twice, and the flag is set first so anything arriving mid-drain goes straight through rather
  /// than joining a queue nothing will come back for.
  private async drainIce(): Promise<void> {
    this.hasRemoteDescription = true;
    for (const cand of this.pendingIce.drain(Date.now())) {
      await this.pc.addIceCandidate(cand);
    }
  }

  addTrack(track: MediaStreamTrack, stream: MediaStream): void {
    this.pc.addTrack(track, stream);
  }

  close(): void {
    // §11.3: "Discard the buffer with its attempt." A new attempt has fresh ephemerals and a fresh
    // remote description, so candidates gathered for this one describe a path that is gone.
    this.pendingIce.discard();
    // THE LANE GOES WITH ITS PEER: its timer and its data channel's events must not outlive the session that owned
    // them (AGENTS.md, "A SESSION IS A `createSession` CALL") — left, its timer fired up to a second later.
    this.lane?.dispose();
    this.lane = null;
    this.pc.close();
  }
}
