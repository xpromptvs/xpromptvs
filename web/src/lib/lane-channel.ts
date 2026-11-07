/// THE LANE UNDER THE SESSION'S CHANNELS (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §1, §4).
/// `LaneLink` is the glue — one `lane` data channel, the clock, the timer and one `LaneEngine`; `LaneChannel` is one
/// stream shaped as the session expects an RTCDataChannel to be, so session.ts cannot tell the difference. The Mac's
/// glue is the same design (host/streaming-engine/PionBridge/rdev_lane.go).
import type { ChannelLike } from "./channel";
import { LaneEngine } from "./lane";
import { LANE_PACKET_MAX } from "./lane-codec";

/// The data channel's bufferedamountlow refills its queue from here up to the engine's queueTarget.
const LANE_QUEUE_LOW = 4096;
/// The longest a flush waits for room once the data channel's queue has none left for a packet (`laneFlushWake`).
export const LANE_REPOLL_MS = 5;

/// Once the link has dropped and come back, a lane whose oldest unacknowledged symbol sees no progress for this long
/// closes and the session rebuilds — on a fresh SCTP association. After a network blink this browser's SCTP may hold
/// everything the page sends behind its retransmission backoff (a phone over TURN, 2026-10-13: its keystrokes reached
/// the Mac ~25 s late), which the lane's own repair cannot get past: its repairs queue behind the same backoff. 30 s
/// (the engine's stuck) stays the threshold for a link that never dropped. The Mac's glue does the same
/// (`laneStalledAfterReconnectMs`).
export const LANE_STALLED_AFTER_RECONNECT_MS = 5000;
const LABELS = ["terminal", "input", "control"] as const;
type LaneLabel = (typeof LABELS)[number];

/// What LaneLink needs of the `lane` RTCDataChannel — a real one, or a test's double.
export interface LaneDataChannel extends EventTarget {
  readonly readyState: RTCDataChannelState;
  readonly bufferedAmount: number;
  bufferedAmountLowThreshold: number;
  binaryType: BinaryType;
  send(data: Uint8Array<ArrayBuffer>): void;
  close(): void;
}

export interface LaneLinkOptions {
  /// Whether the peer connection reads `connected`: a stuck lane is closed only then (an outage is not a stuck lane).
  connected: () => boolean;
  /// Milliseconds; performance.now() by default.
  now?: () => number;
  seed?: number;
}

/// When flush runs next: the engine's own wake (−1: none), brought forward to at most LANE_REPOLL_MS away when this
/// flush left the data channel's queue with less room than one packet (`roomLeft`: queueTarget − bufferedAmount − the
/// bytes just sent; feedback ignores room, so it can be negative). The low-water event alone can come late, and what
/// the queue refused is not always in nextWake: an urgent (gap or timer) repair too big for the room stays queued in
/// the engine, which nextWake does not look at. The Mac's laneFlushWake, the same rule.
export function laneFlushWake(now: number, engineWake: number, roomLeft: number): number {
  if (roomLeft >= LANE_PACKET_MAX) return engineWake;
  const soon = now + LANE_REPOLL_MS;
  return engineWake < 0 || engineWake > soon ? soon : engineWake;
}

export class LaneLink {
  readonly channels: readonly [LaneChannel, LaneChannel, LaneChannel];
  private readonly engine: LaneEngine;
  private readonly start: number;
  private timer: ReturnType<typeof setTimeout> | null = null;
  /// The three streams' `open` went out — from the data channel's own `open`, or from the constructor's microtask for
  /// one handed over already open — and never goes out again.
  private announced = false;
  private stuckSaid = false;
  private receiveFailedSaid = false;
  private sendFailedSaid = false;
  /// close() ran: no flush, no timer. disposed: the peer session is gone (dispose) — nothing the data channel does later
  /// reaches the streams.
  private closed = false;
  private disposed = false;

  constructor(private readonly dc: LaneDataChannel, private readonly opts: LaneLinkOptions) {
    this.engine = new LaneEngine(opts.seed ?? Math.floor(Math.random() * 2 ** 32));
    this.start = this.clock();
    this.channels = [new LaneChannel("terminal", 0, this), new LaneChannel("input", 1, this), new LaneChannel("control", 2, this)];
    dc.binaryType = "arraybuffer";
    dc.bufferedAmountLowThreshold = LANE_QUEUE_LOW;
    dc.addEventListener("bufferedamountlow", () => this.flush());
    dc.addEventListener("open", () => this.announce());
    dc.addEventListener("close", () => {
      this.stopTimer();
      if (this.disposed) return;
      for (const c of this.channels) c.dispatchEvent(new Event("close"));
    });
    dc.addEventListener("message", (e) => this.onMessage((e as MessageEvent).data));
    // HANDED OVER ALREADY OPEN — the answering side's usual case: a channel the peer opened is OPEN when
    // `ondatachannel` runs, and its own `open` event comes after the hand-over. The streams' open goes out once, in a
    // microtask, so the listeners the hand-over binds right after this constructor hear it.
    if (dc.readyState === "open") queueMicrotask(() => this.announce());
  }

  get readyState(): RTCDataChannelState { return this.dc.readyState; }
  buffered(stream: number): number { return this.engine.buffered(stream); }

  send(stream: number, data: Uint8Array): void {
    if (this.dc.readyState !== "open") throw new DOMException(`the ${LABELS[stream]} channel is not open`, "InvalidStateError");
    this.engine.send(stream, data);
    this.flush();
  }

  /// Closes the LANE (a stream's close): the timer stops and nothing more is sent at once — the data channel's `close`
  /// event comes later, in a task — and that event then closes the three streams.
  close(): void {
    this.closed = true;
    this.stopTimer();
    this.dc.close();
  }

  /// THE PEER SESSION IS GONE (PeerSession.close): nothing of this lane outlives it (AGENTS.md, "A SESSION IS A
  /// `createSession` CALL"). Closed as above, and silenced — no message, low-water event or `close` from the data channel
  /// reaches the streams afterwards, as closing a peer connection closes its real channels without an event.
  dispose(): void {
    this.disposed = true;
    this.close();
  }

  private stopTimer(): void {
    if (this.timer !== null) { clearTimeout(this.timer); this.timer = null; }
  }

  /// The peer connection reached `connected`: the stuck clocks start over. A browser stores the new state and fires
  /// `connectionstatechange` in ONE task, so no flush can read the link up before this ran (the Mac needs `linkUp`
  /// for that; the page does not).
  connected(): void {
    const now = this.now();
    this.engine.resetStuck(now);
    if (this.downSeen) { this.downSeen = false; this.reconnectedAt = now; }
  }

  /// The peer connection read disconnected or failed: its next `connected` is a RECONNECT
  /// (LANE_STALLED_AFTER_RECONNECT_MS).
  linkLost(): void { this.downSeen = true; }

  private downSeen = false;
  /// When the link connected AGAIN after a drop (−1: never).
  private reconnectedAt = -1;

  private announce(): void {
    if (this.announced || this.disposed || this.dc.readyState !== "open") return;
    this.announced = true;
    for (const c of this.channels) c.dispatchEvent(new Event("open"));
    this.flush();
  }

  private onMessage(data: unknown): void {
    if (this.disposed || !(data instanceof ArrayBuffer)) return;
    // A NON-CONFORMING PEER CAN MAKE THE ENGINE THROW (a pruned ESI); it must not reach the page's event loop. The
    // packet is dropped — the lane repairs what it carried — and the lane carries on.
    try {
      this.engine.receive(new Uint8Array(data), this.now());
    } catch (err) {
      if (!this.receiveFailedSaid) {
        this.receiveFailedSaid = true;
        console.warn(`[lane] a packet the engine could not take was dropped: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
    // Each delivery's buffer IS the message: the engine slices it out of its stream, a fresh ArrayBuffer at offset 0.
    for (const d of this.engine.takeDelivered()) {
      this.channels[d.stream]!.dispatchEvent(new MessageEvent("message", { data: d.data.buffer }));
    }
    this.flush();
  }

  private clock(): number { return this.opts.now ? this.opts.now() : performance.now(); }
  /// WHOLE milliseconds: the engine's timing is held to the Mac's (Go, integer ms) by the same arithmetic.
  private now(): number { return Math.floor(this.clock() - this.start); }

  private flush(): void {
    if (this.closed || this.dc.readyState !== "open") return;
    const now = this.now();
    let room = this.engine.queueTarget(now) - this.dc.bufferedAmount;
    const packets = this.engine.poll(now, room);
    for (const p of packets) room -= p.length;
    const stuck = this.engine.stuck(now);
    this.stopTimer();
    const wake = laneFlushWake(now, this.engine.nextWake(now), room);
    if (wake >= 0) this.timer = setTimeout(() => { this.timer = null; this.flush(); }, wake - now);
    for (const p of packets) {
      // A REFUSED SEND THROWS NOWHERE (a channel closing under us, a full queue): it would drop the rest of this poll AND
      // reach LaneChannel.send's caller or the timer. The packets were numbered and are held, so the lane's own repair
      // rebuilds what did not go; the rest of this poll waits for the next.
      try {
        this.dc.send(p);
      } catch (err) {
        if (!this.sendFailedSaid) {
          this.sendFailedSaid = true;
          console.warn(`[lane] the data channel refused a packet: ${err instanceof Error ? err.message : String(err)}`);
        }
        break;
      }
    }
    const stalled = this.reconnectedAt >= 0 && this.engine.stalledFor(now) >= LANE_STALLED_AFTER_RECONNECT_MS;
    if ((stuck || stalled) && this.opts.connected()) {
      if (!this.stuckSaid) {
        this.stuckSaid = true;
        console.warn(this.engine.protocolViolated ? "[recovery] the Mac broke the lane's protocol; closing it"
          : stalled ? `[recovery] the lane made no progress for ${LANE_STALLED_AFTER_RECONNECT_MS / 1000} s after the link came back; closing it`
          : "[recovery] the lane made no progress for 30 s on a connected link; closing it");
      }
      this.close();
    }
  }
}

/// One stream of the lane, as the session expects an RTCDataChannel to behave: CONNECTING until the lane opens,
/// `send` throws while it is not open, and a message's `data` is an ArrayBuffer whatever `binaryType` says.
export class LaneChannel extends EventTarget implements ChannelLike {
  binaryType: BinaryType = "arraybuffer";
  constructor(readonly label: LaneLabel, private readonly stream: number, private readonly link: LaneLink) { super(); }
  get readyState(): RTCDataChannelState { return this.link.readyState; }
  get bufferedAmount(): number { return this.link.buffered(this.stream); }
  send(data: string | ArrayBuffer | ArrayBufferView): void {
    const bytes = typeof data === "string" ? new TextEncoder().encode(data)
      : data instanceof ArrayBuffer ? new Uint8Array(data)
      : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    this.link.send(this.stream, bytes);
  }
  /// Closes the LANE: its three streams close together, as a dead lane is a dead terminal, input and control.
  close(): void { this.link.close(); }
}

// TEST-ONLY: the browser checks patch the session's channels by prototype, as they patch RTCDataChannel's
// (e2e/*-check.mjs: `patchChannelPrototypes`). Assigned when this module loads, before any channel exists.
(globalThis as { __rdevLaneChannel?: unknown }).__rdevLaneChannel = LaneChannel;
