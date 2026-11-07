/// §11.3's bounded ICE candidate buffer.
///
/// > "Buffer early ICE candidates until their remote description is installed, with a bounded size
/// > and deadline. Discard the buffer with its attempt."
///
/// **TS ONLY, AND DELIBERATELY SO.** The host does not buffer candidates in Swift at all —
/// `PionPeer.addIce` hands them straight to pion, which owns that queue — so a Swift mirror would be
/// code with no caller. Every other E2E module in this package has one; this is the exception, and
/// the reason is here rather than in a reviewer's head.
///
/// **Why a queue exists at all**, quoted from the code it replaces: `addIceCandidate` before
/// `setRemoteDescription` is an `InvalidStateError` by spec. Chrome tolerates it; **Safari rejects**,
/// which is how it surfaced — an unhandled rejection on every reload. A REJECTED CANDIDATE IS A
/// DROPPED ONE, and losing the host's early candidates makes the winning pair more likely to be
/// peer-reflexive, which this project has measured: pion holds a prflx pair for
/// `prflxAcceptanceMinWait` (1000 ms) before accepting it, and that reads as input being dead for a
/// second after a reconnect while every state says connected.
///
/// **Why it is bounded** is the part §11.3 adds. The queue it replaces had no cap and no deadline,
/// so anything that could deliver candidates could grow it without limit. §4 puts the Control Plane
/// inside the adversary model, so before E2E that is the relay; after E2E it is an authenticated
/// peer misbehaving. Neither should be able to make a tab allocate without bound.

/// Chosen well above any real negotiation — a dual-stack host with a TURN server offers on the order
/// of a dozen — so the cap is only ever reached by something pathological.
export const ICE_BUFFER_MAX = 64;

/// A candidate that has waited this long is stale: its remote description never arrived, and ICE
/// will have moved on. Generous, because a slow signalling round trip is not an attack.
export const ICE_BUFFER_DEADLINE_MS = 10_000;

export type IceBufferPush = "buffered" | "dropped-full";

export interface IceBufferStats {
  /** Refused because the buffer was full. */
  droppedFull: number;
  /** Discarded at drain time for having waited past the deadline. */
  droppedExpired: number;
  /** Thrown away with an abandoned attempt. */
  discarded: number;
}

/// Generic over the candidate type so it can be tested without a browser: nothing here inspects a
/// candidate, and a buffer that understood ICE would be a buffer that could be wrong about ICE.
export class IceBuffer<T> {
  private entries: Array<{ candidate: T; at: number }> = [];
  private readonly stats: IceBufferStats = { droppedFull: 0, droppedExpired: 0, discarded: 0 };

  constructor (private readonly max: number = ICE_BUFFER_MAX,
               private readonly deadlineMs: number = ICE_BUFFER_DEADLINE_MS) {}

  get size (): number { return this.entries.length; }
  get counters (): IceBufferStats { return { ...this.stats }; }

  /// Buffer a candidate, or refuse it because the buffer is full.
  ///
  /// **The NEWEST is dropped, not the oldest.** Candidates arrive roughly in usefulness order for
  /// latency — host first, then server-reflexive, then relay — and the early ones are exactly the
  /// ones whose loss produces the peer-reflexive delay described above. Neither policy survives a
  /// determined flood, and that is not what the cap is for: the cap exists so the allocation is
  /// bounded, and the defence against a flood is that after §11 the sender is authenticated.
  push (candidate: T, nowMs: number): IceBufferPush {
    if (this.entries.length >= this.max) {
      this.stats.droppedFull += 1;
      return "dropped-full";
    }
    this.entries.push({ candidate, at: nowMs });
    return "buffered";
  }

  /// Everything still fresh, IN ARRIVAL ORDER, emptying the buffer.
  ///
  /// Emptied BEFORE the caller can await anything, so a re-entrant drain cannot deliver a candidate
  /// twice — the property the code this replaces also had, and worth keeping deliberately.
  drain (nowMs: number): T[] {
    const entries = this.entries;
    this.entries = [];
    const fresh: T[] = [];
    for (const e of entries) {
      if (nowMs - e.at > this.deadlineMs) this.stats.droppedExpired += 1;
      else fresh.push(e.candidate);
    }
    return fresh;
  }

  /// §11.3: "Discard the buffer with its attempt." A new attempt has fresh ephemerals and a fresh
  /// remote description; candidates gathered for the old one describe a path that no longer exists.
  discard (): void {
    this.stats.discarded += this.entries.length;
    this.entries = [];
  }
}
