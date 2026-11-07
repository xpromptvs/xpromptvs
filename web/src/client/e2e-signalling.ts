import type { GateFailure, GateResult, Received } from "@rdev/protocol";
import { base64urlDecode, base64urlEncode } from "../lib/base64url";

/**
 * **Either gate.** `E2EClientGate` opens a session and `E2EHostGate` answers one, and the carrier
 * is the same for both — the one real asymmetry is that a responder never speaks first, which is
 * why `start` is OPTIONAL here rather than a method that does nothing.
 */
export interface SignallingGate {
  readonly maySignal: boolean;
  receive(ct: Uint8Array, mode?: string): GateResult<Received>;
  seal(message: Uint8Array): GateResult<Uint8Array>;
  close(): void;
  start?(): GateResult<{ ct: Uint8Array; mode: string }>;
}

/**
 * **The client's §11 session, driven over the signalling socket.**
 *
 * `E2EClientGate` decides everything; this carries envelopes to and from it, and owns the one rule
 * that cannot live inside the gate because it is about the CALLER: §11.2 — nothing is sent until the
 * gate opens, and what is sent afterwards goes inside it or not at all.
 *
 * Its host counterpart is `RdevHostRuntime`'s `receiveE2E`/`sendSealed` pair.
 */

export interface SecureSignallingIO {
  /** Put one §11.3 envelope on the wire. `mode` rides the first message only. */
  sendE2E(ct: string, mode?: string): void;
  /** One signalling message that arrived inside the session — the same JSON the plain arms carry. */
  deliver(message: unknown): void;
  /** The session ended and cannot be recovered; §11.3 says reconnect rather than retry. */
  onClosed(reason: string): void;
  /**
   * §11.2's gate has just opened — the first moment the peer is authenticated and anything this
   * session earned exists.
   *
   * Fired ONCE, on the transition, because `maySignal` is true for the rest of the session and a
   * caller committing a paired chain on every envelope would write the same bytes forever.
   */
  onOpen?(): void;
}

const b64u = base64urlEncode;
const fromB64u = base64urlDecode;

export class SecureSignalling {
  private closed = false;

  constructor (private readonly gate: SignallingGate, private readonly io: SecureSignallingIO) {}

  /** §11.2's sentence, for the caller that has to decide whether it may answer an offer yet. */
  get maySignal (): boolean { return !this.closed && this.gate.maySignal; }

  /**
   * Open the session. **The initiator speaks first**, so this is called as soon as the socket is
   * usable rather than in response to anything.
   */
  start (): void {
    if (this.closed) return;
    // A RESPONDER has nothing to open — it answers, or it does not. Silence here is the whole of
    // its start.
    if (!this.gate.start) return;
    const started = this.gate.start();
    if (!started.ok) return this.fail(started.failure);
    this.io.sendE2E(b64u(started.value.ct), started.value.mode);
  }

  /**
   * One incoming §11.3 envelope. `mode` rides the initiator's FIRST message only, and a RESPONDER
   * needs it: §11.3 binds the mode into the prologue, so a gate that had to guess would let a peer
   * choose the pattern by omission.
   */
  receive (ct: string, mode?: string): void {
    if (this.closed) return;
    const bytes = fromB64u(ct);
    // An envelope that is not base64url never reached a Noise session, so it is not a decryption
    // failure and must not terminate one — §11.3's rule is about ciphertext, and this is framing.
    if (!bytes) return;

    // **THE PEER OPENED A HANDSHAKE OF ITS OWN** (2026-10-07): only an initiator names a mode, and an
    // INITIATOR here (`start`) is waiting for a reply. A Mac showing a code to be ADDED to an identity
    // speaks first — it initiates that `pair` (`AdoptByCode`) — so its code pasted into Connect meets it as
    // two openings, and read as a reply its first message is a decryption failure (`noise`) and a reconnect
    // loop. Said as what it is, and not retried.
    if (this.gate.start && mode !== undefined && !this.opened) {
      this.close();
      this.io.onClosed("peer-initiated");
      return;
    }

    const result = this.gate.receive(bytes, mode);
    if (!result.ok) return this.fail(result.failure);
    this.handle(result.value);
  }

  /**
   * Send one signalling message inside the session.
   *
   * **Returns false rather than falling back.** §11.2 says no SDP or ICE authority exists before the
   * gate, and a caller that answered in plaintext when this refused would be the whole protocol
   * opted out of by a peer that declined to handshake.
   */
  send (message: unknown): boolean {
    if (this.closed) return false;
    const sealed = this.gate.seal(new TextEncoder().encode(JSON.stringify(message)));
    if (!sealed.ok) {
      this.fail(sealed.failure);
      return false;
    }
    this.io.sendE2E(b64u(sealed.value));
    return true;
  }

  close (): void {
    if (this.closed) return;
    this.closed = true;
    this.gate.close();
  }

  /// §11.2's sentence as an EDGE, not a level: it becomes true once and stays true.
  private opened = false;

  private handle (received: Received): void {
    const announce = (): void => {
      if (this.opened || !this.gate.maySignal) return;
      this.opened = true;
      this.io.onOpen?.();
    };
    switch (received.kind) {
      case "reply":
        // In order, one envelope each — message 3 and `client-confirm` arrive together and are two
        // Noise messages.
        for (const ct of received.cts) this.io.sendE2E(b64u(ct));
        return;
      case "nothing":
        // `session-start` lands here: nothing to send back, and everything to notice.
        announce();
        return;
      case "awaiting-issuance":
        // **An initiator never sees this.** It is the `pair` RESPONDER's state, and this class only
        // ever drives a client gate — but the two share one `Received`, so the arm is written rather
        // than left to a silent fall-through. A browser adopting a Mac drives its gate directly.
        return;
      case "signalling": {
        let message: unknown;
        try {
          message = JSON.parse(new TextDecoder().decode(received.inner));
        } catch {
          // An authenticated peer sending nonsense is a protocol error, not an attack — but it is
          // still not a reason to guess, and it is not a decryption failure either.
          this.io.onClosed("unreadable-inner-message");
          return;
        }
        announce();
        this.io.deliver(message);
        return;
      }
    }
  }

  private fail (failure: GateFailure): void {
    this.closed = true;
    // §11.3: "Decryption failure terminates the signalling session; never skip a failed ciphertext."
    // A reconnect starts a fresh handshake with fresh ephemerals, which is the only recovery there
    // is — so the caller is told, and nothing here retries.
    this.io.onClosed(failure.kind === "session" ? `session:${failure.failure}` : failure.kind);
  }
}
