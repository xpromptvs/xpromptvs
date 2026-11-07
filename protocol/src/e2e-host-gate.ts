import { Uint8ArrayList } from "uint8arraylist";
import { x25519 } from "@noble/curves/ed25519.js";
import { XXHandshakeState } from "./noise/protocol.js";
import { XXpsk3HandshakeState } from "./noise/xxpsk3.js";
import { pureJsCrypto } from "./noise/crypto-js.js";
import { wrapCrypto } from "./noise/crypto.js";
import { NoiseTransport } from "./noise/transport.js";
import { E2EResponder } from "./e2e-session.js";
import { PublicationStatus, prologue, type E2EMode } from "./e2e-wire.js";
import { verifyBundle, type E2EPolicy, type VerifiedChain } from "./e2e-verify.js";
import { deviceId } from "./e2e-identity.js";
import { bytesEqual } from "./e2e-wire.js";
import type { RendezvousRoute } from "./rendezvous-seed.js";
import type { GateFailure, GateResult, Received } from "./e2e-signalling-gate.js";

/**
 * **§11's gate for a RESPONDER in the browser** — the mirror of `RdevHostKit.E2ESignallingGate`, and
 * the counterpart of `E2EClientGate` beside it.
 *
 * The Mac is the responder in the product; this exists because a browser can be one too — the dev
 * harness peer (`web/host.html`) is exactly that, and under E2E-only signalling it cannot answer a
 * client without running the same machine the Mac runs.
 *
 * Deliberately the same shape as the other two. The one real asymmetry is the same one: the
 * responder never speaks first, so there is no `start()` — it answers, or it does not.
 */

export interface HostGateConfig {
  roomCode: string;
  /** This device's §10.2 descriptor. Its DH key must be `noisePrivateKey`'s public key. */
  device: Uint8Array;
  bundle: Uint8Array;
  noisePrivateKey: Uint8Array;
  /** §9.2's durable address, sent in message 2. Empty strings when there is none. */
  route: RendezvousRoute;
  trustedRootId: Uint8Array;
  policy: E2EPolicy;
  revokedDeviceIds?: readonly Uint8Array[];
  /** §12.2: what this endpoint knows about the publication of the grant it holds. */
  publicationStatus?: PublicationStatus;
  /**
   * §9.1's psk for the pairing window the PEER is showing, or absent when this side is answering no
   * pairing at all. **Its presence is what admits `pair`**: without it the handshake could not
   * complete anyway, so refusing at the door names the reason instead of failing inside Noise.
   *
   * **Here the newcomer showed the code and this side issues** — the reverse of the guest flow, and
   * the reason §9.1 says a directly enrolled Issuer may ISSUE rather than may open a window. A
   * window is a rendezvous; the seed authenticates whoever holds it in either direction.
   */
  pairingPsk?: Uint8Array;
}

/** What an issuer needs in order to mint for a parked `pair` session. */
export interface PendingIssuance {
  /** The newcomer's §10.2 descriptor, as message 3 delivered it and Noise authenticated it. */
  device: Uint8Array;
  /** §10.3's remote binding `h` — this exact transcript. */
  handshakeHash: Uint8Array;
  /** §10.3's remote binding `responder_device_id` — this device. */
  responderDeviceId: Uint8Array;
}

const XX = "Noise_XX_25519_ChaChaPoly_SHA256";
const XXPSK3 = "Noise_XXpsk3_25519_ChaChaPoly_SHA256";
const bytes = (u: Uint8Array | Uint8ArrayList): Uint8Array => ("subarray" in u ? u.subarray() : u);

export class E2EHostGate {
  private handshake: XXHandshakeState | null = null;
  private transport: NoiseTransport | null = null;
  private session: E2EResponder | null = null;
  private handshakeHash: Uint8Array | null = null;
  private dead = false;
  private mode: E2EMode | null = null;
  private pending: PendingIssuance | null = null;

  constructor (private readonly config: HostGateConfig) {}

  /**
   * **A PARKED SESSION HAS NOT OPENED.** `E2EResponder` reaches `established` when `client-confirm`
   * verifies, which in `auth` is the same moment the gate opens — but a `pair` session still owes the
   * newcomer a chain, and §11.2's "the responder replies only after authorization and the required
   * durable writes" is exactly about that gap. So this asks the session AND this gate.
   */
  get maySignal (): boolean { return this.pending === null && this.session?.maySignal === true; }

  /**
   * What an issuer must mint over, or null when nothing is parked.
   *
   * **The gate cannot mint for itself.** `receive` is synchronous and a WebAuthn ceremony is not, and
   * the grant cannot be prepared in advance: it covers this descriptor and its binding covers this
   * `h`, neither of which exists before message 3. So the `pair` arm stops here and the caller —
   * which can await a person's fingerprint — supplies the answer to `issue`.
   */
  get pendingIssuance (): PendingIssuance | null { return this.pending; }

  /** The peer's verified chain, once there is one. Null before the gate opens. */
  get peerChain (): VerifiedChain | null { return this.session?.initiatorChain ?? null; }
  /** What the client's `client-confirm` said for the APPLICATION (its terminal grid), and nothing until the gate is
   *  open: §11.2 grants no shell authority before it. */
  get appHello (): Uint8Array { return this.maySignal ? this.session?.appHello ?? new Uint8Array(0) : new Uint8Array(0); }

  /**
   * Handle one §11.3 envelope. `mode` rides the initiator's FIRST message only, and its absence
   * there is a refusal: §11.3 binds the mode into the prologue, so guessing one would let a peer
   * choose the pattern by omission.
   */
  receive (ct: Uint8Array, mode?: string): GateResult<Received> {
    if (this.dead) return this.terminate({ kind: "not-established" });

    if (!this.session) {
      if (mode === undefined) return this.terminate({ kind: "session", failure: "malformed" });
      // `pair` is served only while a window is open — §9.1 in code, and a gate holding no psk could
      // not finish the handshake in any case. `enroll` needs an issuer this gate does not have.
      // "Not here" is a different answer from "you are wrong", and both are a refusal.
      if (mode !== "auth" && !(mode === "pair" && this.config.pairingPsk)) {
        return this.terminate({ kind: "not-established" });
      }
      return this.open(ct, mode as E2EMode);
    }

    if (this.transport) {
      if (this.session.maySignal) {
        let inner: Uint8Array;
        try {
          inner = bytes(this.transport.read(new Uint8ArrayList(ct)));
        } catch {
          return this.terminate({ kind: "noise" });
        }
        return { ok: true, value: { kind: "signalling", inner } };
      }
      return this.receiveConfirm(ct);
    }
    return this.receiveMessage3(ct);
  }

  /**
   * Wrap one outgoing signalling message. §11.2: nothing may be sent before the gate opens, and this
   * is where that stops being a convention.
   */
  seal (message: Uint8Array): GateResult<Uint8Array> {
    if (this.dead || !this.transport || !this.maySignal) {
      return { ok: false, failure: { kind: "not-established" } };
    }
    try {
      return { ok: true, value: bytes(this.transport.write(message)) };
    } catch {
      return this.terminate({ kind: "noise" });
    }
  }

  close (): void {
    this.session?.terminate();
    this.dead = true;
    this.transport = null;
  }

  // ------------------------------------------------------------------ the handshake

  /**
   * **THIS RESPONDER SERVES `auth` AND `pair`.**
   *
   * It served `auth` only until 2026-09-15, and the reason recorded here was that serving `pair`
   * "would mean a TypeScript re-implementation of §10.3's minting for a caller that does not exist".
   * **The caller now exists and the objection does not apply.** Adopt-by-code has a browser holding
   * the passkey answer a Mac that showed its own code, and what it issues is a DIRECT, root-signed
   * grant through `issueDirectGrant` — §12.1's path, already written — not a subordinate one. The
   * minting stays out of this file entirely: the gate parks and the caller supplies the chain.
   *
   * `enroll` is still refused here. The Swift responder (`RdevE2E.E2ESignallingGate`) is where all
   * four modes live.
   */
  private open (ct: Uint8Array, mode: E2EMode): GateResult<Received> {
    const pro = prologue(mode, this.config.roomCode);
    if (!pro) return this.terminate({ kind: "session", failure: "malformed" });

    // §11.1's table: `pair` is `Noise_XXpsk3`, everything else `Noise_XX`. The prologue binds the
    // mode, so neither end can choose a pattern the other did not.
    const init = {
      crypto: wrapCrypto(pureJsCrypto), prologue: pro, initiator: false,
      s: {
        privateKey: this.config.noisePrivateKey,
        publicKey: x25519.getPublicKey(this.config.noisePrivateKey),
      },
    };
    const handshake = mode === "pair"
      ? new XXpsk3HandshakeState({ ...init, protocolName: XXPSK3, psk: this.config.pairingPsk! })
      : new XXHandshakeState({ ...init, protocolName: XX });
    const session = new E2EResponder({
      mode, roomCode: this.config.roomCode, device: this.config.device,
      bundle: this.config.bundle, route: this.config.route,
      trustedRootId: this.config.trustedRootId, policy: this.config.policy,
      ...(this.config.revokedDeviceIds ? { revokedDeviceIds: this.config.revokedDeviceIds } : {}),
    });

    let message1: Uint8Array;
    try {
      message1 = bytes(handshake.readMessageA(new Uint8ArrayList(ct)));
    } catch {
      return this.terminate({ kind: "noise" });
    }
    const step = session.receiveMessage1(message1);
    if (!step.ok) {
      this.session = session;
      return this.terminate({ kind: "session", failure: step.failure });
    }
    const payload = session.message2Payload();
    if (!payload.ok) {
      this.session = session;
      return this.terminate({ kind: "session", failure: payload.failure });
    }
    let reply: Uint8Array;
    try {
      reply = bytes(handshake.writeMessageB(payload.value));
    } catch {
      return this.terminate({ kind: "noise" });
    }
    this.handshake = handshake;
    this.session = session;
    this.mode = mode;
    return { ok: true, value: { kind: "reply", cts: [reply] } };
  }

  private receiveMessage3 (ct: Uint8Array): GateResult<Received> {
    const handshake = this.handshake!;
    const session = this.session!;
    let plaintext: Uint8Array;
    try {
      plaintext = bytes(handshake.readMessageC(new Uint8ArrayList(ct)));
    } catch {
      return this.terminate({ kind: "noise" });
    }
    // The static key NOISE authenticated, never one read out of the payload — which would be the
    // peer's own claim about itself. §11.1: "The descriptor's DH key must match the initiator's
    // Noise static."
    if (!handshake.rs) return this.terminate({ kind: "noise" });
    const step = session.receiveMessage3(plaintext, bytes(handshake.rs));
    if (!step.ok) return this.terminate({ kind: "session", failure: step.failure });

    // Split here: message 3 is the last handshake message, and `client-confirm` after it is already
    // transport.
    this.transport = new NoiseTransport(handshake.ss.split(), false);
    this.handshakeHash = new Uint8Array(handshake.ss.h);
    return { ok: true, value: { kind: "nothing" } };
  }

  private receiveConfirm (ct: Uint8Array): GateResult<Received> {
    const session = this.session!;
    const transport = this.transport!;
    if (!this.handshakeHash) return this.terminate({ kind: "noise" });

    let plaintext: Uint8Array;
    try {
      plaintext = bytes(transport.read(new Uint8ArrayList(ct)));
    } catch {
      return this.terminate({ kind: "noise" });
    }
    const gate = session.receiveClientConfirm(plaintext, this.handshakeHash);
    if (!gate.ok) return this.terminate({ kind: "session", failure: gate.failure });

    // **`pair` STOPS HERE.** The newcomer is authenticated and is owed a chain, and minting one takes
    // a passkey — which is a person, a prompt and seconds, none of which fit in a synchronous
    // `receive`. §11.2's "the responder replies only after authorization and the required durable
    // writes" is the same gap read from the specification's side, so nothing is sent and the gate
    // stays shut until `issue` is called.
    if (this.mode === "pair") {
      const ownDevice = this.config.device;
      if (!session.initiatorDevice) return this.terminate({ kind: "session", failure: "malformed" });
      this.pending = {
        device: session.initiatorDevice.bytes,
        handshakeHash: this.handshakeHash,
        responderDeviceId: deviceId(ownDevice),
      };
      return { ok: true, value: { kind: "awaiting-issuance" } };
    }

    // §11.2: "The responder replies only after authorization and the required durable writes."
    // `acceptedBundle` is empty because `auth` issues nothing.
    const start = session.sessionStart(
      this.handshakeHash,
      this.config.publicationStatus ?? PublicationStatus.Unconfirmed,
      new Uint8Array(0));
    if (!start.ok) return this.terminate({ kind: "session", failure: start.failure });
    try {
      return { ok: true, value: { kind: "reply", cts: [bytes(transport.write(start.value))] } };
    } catch {
      return this.terminate({ kind: "noise" });
    }
  }

  /**
   * **Supply the chain a parked `pair` session is waiting for, and open the gate.**
   *
   * The bundle is checked against this gate's OWN view before it is sent: it must verify under the
   * root this device trusts, and it must certify the exact descriptor that arrived in message 3. A
   * caller that minted for the wrong device — in a session that holds two of them — is refused here,
   * where the mistake is legible, rather than by the far side a moment later.
   *
   * **The BINDING is deliberately not checked here.** §10.4 has the far side check `h` and the
   * responder's device id against its own view, and that is where the check means something; an
   * issuer comparing its own binding against its own transcript proves nothing to anybody.
   * `pendingIssuance` is what a caller builds the binding from.
   *
   * A refusal TERMINATES. The session is spent either way — one window issues one chain — and a
   * caller that may retry with a different bundle is one that may shop for an accepted one.
   */
  issue (bundle: Uint8Array): GateResult<{ ct: Uint8Array }> {
    if (this.dead) return { ok: false, failure: { kind: "not-established" } };
    const pending = this.pending;
    const session = this.session;
    const transport = this.transport;
    if (!pending || !session || !transport || !this.handshakeHash) {
      return this.terminate({ kind: "not-established" });
    }

    const verified = verifyBundle(bundle, {
      trustedRootId: this.config.trustedRootId,
      policy: this.config.policy,
      revokedDeviceIds: this.config.revokedDeviceIds ?? [],
    });
    if (!verified.ok) return this.terminate({ kind: "session", failure: "peer-chain" });
    if (!bytesEqual(verified.chain.leafDevice.bytes, pending.device)) {
      return this.terminate({ kind: "session", failure: "peer-chain" });
    }

    const start = session.sessionStart(
      this.handshakeHash,
      this.config.publicationStatus ?? PublicationStatus.Unconfirmed,
      bundle);
    if (!start.ok) return this.terminate({ kind: "session", failure: start.failure });
    let ct: Uint8Array;
    try {
      ct = bytes(transport.write(start.value));
    } catch {
      return this.terminate({ kind: "noise" });
    }
    // Cleared LAST: `maySignal` reads it, so the gate opens at exactly this point and not earlier.
    this.pending = null;
    return { ok: true, value: { ct } };
  }

  private terminate<T> (failure: GateFailure): GateResult<T> {
    this.session?.terminate();
    this.dead = true;
    this.transport = null;
    return { ok: false, failure };
  }
}
