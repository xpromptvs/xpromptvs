import { Uint8ArrayList } from "uint8arraylist";
import { x25519 } from "@noble/curves/ed25519.js";
import { XXHandshakeState } from "./noise/protocol.js";
import { XXpsk3HandshakeState } from "./noise/xxpsk3.js";
import { pureJsCrypto } from "./noise/crypto-js.js";
import { wrapCrypto } from "./noise/crypto.js";
import { NoiseTransport } from "./noise/transport.js";
import { E2EInitiator } from "./e2e-session.js";
import type { SessionFailure } from "./e2e-session.js";
import { APP_HELLO_MAX } from "./e2e-wire.js";
import type { E2EPolicy, VerifiedChain } from "./e2e-verify.js";

/**
 * **§11's gate, on the CLIENT's side.** One Noise session, one `E2EInitiator`, and the rule the
 * whole protocol rests on: §11.2 — "Before this gate, only bounded authentication, enrollment, and
 * resume messages may be processed. No SDP, ICE, media, shell, input, or subscription authority
 * exists yet."
 *
 * The mirror of `RdevHostKit.E2ESignallingGate`, and deliberately the same shape: the two are one
 * contract, and the failure mode is them drifting apart. The asymmetry that is real — the initiator
 * SPEAKS FIRST — is the only difference in the surface: `start()` exists here and has no counterpart
 * there.
 *
 * **After the gate, this is also the TRANSPORT** (§11.3: "Every subsequent signalling message,
 * including SDP, ICE, renegotiation, and ICE restart, is carried inside Noise transport"). The inner
 * payload is the same signalling JSON the plaintext envelopes carried, so both ends keep their
 * parsers.
 */

export interface ClientGateConfig {
  /** The room this session belongs to. Bound into the prologue, so both ends must agree. */
  roomCode: string;
  /** This device's §10.2 descriptor. Its DH key must be `noisePrivateKey`'s public key. */
  device: Uint8Array;
  signingPrivateKey: Uint8Array;
  noisePrivateKey: Uint8Array;
  /** §11.1: required for `auth`, EMPTY for `pair` and `enroll`. */
  bundle: Uint8Array;
  /**
   * **Null is legal ONLY in `pair`**, where §11.1 says the mode "may bootstrap its root through the
   * PSK". Everywhere else the root must already be trusted, because §10.1 forbids an incoming chain
   * from replacing one.
   */
  trustedRootId: Uint8Array | null;
  policy: E2EPolicy;
  revokedDeviceIds?: readonly Uint8Array[];
  /** §11.1: "A selected Host's `device_id` must also match the selection." */
  expectedResponderDeviceId?: Uint8Array;
  /**
   * §11.1's mode. `auth` connects with a chain this device holds; `enroll` presents one the ROOT
   * just signed; `pair` presents nothing and asks to be issued one.
   */
  mode?: "auth" | "pair" | "enroll";
  /**
   * §9.1's psk, required by `pair` and meaningless elsewhere. Derived from the seed a person
   * carried, and **never transmitted** — it authenticates the handshake itself, which is why an
   * unauthorised party cannot complete message 3 and there is nothing for anyone to approve.
   */
  pairingPsk?: Uint8Array;
  /** The chain to present in `enroll`: one the root passkey just signed. Empty otherwise. */
  newBundle?: Uint8Array;
  /**
   * The application's first words, carried by `client-confirm` (`ClientConfirm.appHello`) — the page's terminal
   * grid (docs/sources-and-focus.md, "The offer carries the tab bar"). Asked for when that message is written,
   * so it is measured then. One that throws, or is longer than `APP_HELLO_MAX`, is sent EMPTY: the application's
   * words never cost the handshake.
   */
  appHello?: () => Uint8Array;
  /**
   * This device's PUBLIC signing and Noise keys. **Required in `pair`**, where `device` is empty
   * because a §10.2 descriptor names its root and the newcomer does not know one until message 2.
   */
  devicePublicKeys?: { signing: Uint8Array; noise: Uint8Array };
}

export type GateFailure =
  /**
   * **§11.3: decryption failure TERMINATES the signalling session.** Never retried, never skipped: a
   * peer who can produce this at will is the adversary, and a retry loop is what turns one forged
   * frame into an oracle.
   */
  | { kind: "noise" }
  | { kind: "session"; failure: SessionFailure }
  /** Something was asked of a gate that has not opened, or has closed. */
  | { kind: "not-established" };

export type GateResult<T> = { ok: true; value: T } | { ok: false; failure: GateFailure };

/** What one incoming envelope produced. Mirrors the host's `Received`. */
export type Received =
  /**
   * Handshake traffic to send back, IN ORDER, one envelope each. A list rather than a single
   * ciphertext because message 3 and `client-confirm` are produced together and are two Noise
   * messages: Noise framing carries no length, so concatenating them would hand the host one
   * message with the other's bytes as its payload.
   */
  | { kind: "reply"; cts: Uint8Array[] }
  /** Received and absorbed; there is nothing to send yet. */
  | { kind: "nothing" }
  /** One signalling message from a peer this session has authenticated. */
  | { kind: "signalling"; inner: Uint8Array }
  /**
   * **A `pair` responder is authenticated and owes the newcomer a chain.** Produced only by
   * `E2EHostGate`, and only in `pair`: read `pendingIssuance`, mint, and call `issue`. Nothing has
   * been sent and the gate has not opened, so §11.2 holds while a person is asked for a passkey.
   */
  | { kind: "awaiting-issuance" };

const XX = "Noise_XX_25519_ChaChaPoly_SHA256";
const XXPSK3 = "Noise_XXpsk3_25519_ChaChaPoly_SHA256";

const bytes = (u: Uint8Array | Uint8ArrayList): Uint8Array => ("subarray" in u ? u.subarray() : u);

export class E2EClientGate {
  private handshake: XXHandshakeState | null = null;
  private transport: NoiseTransport | null = null;
  private session: E2EInitiator | null = null;
  private handshakeHash: Uint8Array | null = null;
  private dead = false;

  constructor (private readonly config: ClientGateConfig) {}

  /**
   * §11.2's sentence, as a property. False until the host has presented a chain that verifies under
   * this device's trusted root AND this device has proved, inside the handshake, that it holds its
   * own signing key.
   */
  get maySignal (): boolean { return this.session?.maySignal === true; }

  /** The host's verified chain, once there is one. Null before the gate opens. */
  get peerChain (): VerifiedChain | null { return this.session?.responderChain ?? null; }

  /**
   * **The chain this device walked away with** — minted for it in `pair`, echoed back as accepted in
   * `enroll`. Null in `auth`, which issues nothing. The caller persists it: §12.3 says "an
   * unsuccessful durable write grants no authority", so that is deliberately not done here.
   */
  get acceptedBundle (): Uint8Array | null { return this.session?.acceptedBundle ?? null; }

  /**
   * Begin. **The initiator speaks first**, and this is the only envelope that carries a mode —
   * §11.3: "Mode is supplied with the initial handshake and bound into the prologue."
   */
  start (): GateResult<{ ct: Uint8Array; mode: "auth" | "pair" | "enroll" }> {
    if (this.dead || this.handshake) return this.terminate({ kind: "not-established" });
    const mode = this.config.mode ?? "auth";
    // A `pair` without its key could only fail inside Noise two messages later, and "you gave me no
    // key" is a different sentence from "your key is wrong".
    if (mode === "pair" && !this.config.pairingPsk) {
      return this.terminate({ kind: "not-established" });
    }

    const session = E2EInitiator.create({
      mode, roomCode: this.config.roomCode, device: this.config.device,
      signingPrivateKey: this.config.signingPrivateKey, bundle: this.config.bundle,
      // §11.1: "An ordinary `auth` uses an all-zero operation ID." Not a missing value — a meaning.
      // The enrolling modes carry a random one: they are operations that can be resumed, and an
      // all-zero id names none of them.
      operationId: mode === "auth" ? new Uint8Array(32) : crypto.getRandomValues(new Uint8Array(32)),
      trustedRootId: this.config.trustedRootId, policy: this.config.policy,
      revokedDeviceIds: this.config.revokedDeviceIds,
      ...(this.config.expectedResponderDeviceId
        ? { expectedResponderDeviceId: this.config.expectedResponderDeviceId }
        : {}),
      // §12.3: in `pair` the descriptor is assembled after the root is adopted, so the session gets
      // KEYS. Dropping them here made `E2EInitiator.create` return null and the gate refuse with
      // nothing on the wire — measured end to end, where it looked like a host that never answered.
      ...(this.config.devicePublicKeys
        ? { devicePublicKeys: this.config.devicePublicKeys }
        : {}),
    });
    if (!session) return this.terminate({ kind: "session", failure: "malformed" });

    const pro = session.prologue;
    if (!pro) return this.terminate({ kind: "session", failure: "malformed" });

    // §11.1's table: `pair` is `Noise_XXpsk3`, everything else `Noise_XX`. The prologue binds the
    // mode, so neither end can choose a pattern the other did not.
    const init = {
      crypto: wrapCrypto(pureJsCrypto), prologue: pro, initiator: true,
      s: {
        privateKey: this.config.noisePrivateKey,
        publicKey: x25519.getPublicKey(this.config.noisePrivateKey),
      },
    };
    const handshake = mode === "pair"
      ? new XXpsk3HandshakeState({ ...init, protocolName: XXPSK3,
                                   psk: this.config.pairingPsk! })
      : new XXHandshakeState({ ...init, protocolName: XX });

    let ct: Uint8Array;
    try {
      ct = bytes(handshake.writeMessageA(session.message1Payload));
    } catch {
      return this.terminate({ kind: "noise" });
    }
    this.handshake = handshake;
    this.session = session;
    return { ok: true, value: { ct, mode } };
  }

  /**
   * Handle one §11.3 envelope's ciphertext.
   *
   * **Any failure terminates.** §11.3 leaves no room for recovery, and a gate that answered a second
   * time after refusing once would be exactly the oracle that rule exists to prevent.
   */
  receive (ct: Uint8Array): GateResult<Received> {
    if (this.dead || !this.session || !this.handshake) {
      return this.terminate({ kind: "not-established" });
    }

    // Established sessions carry signalling, and nothing else reaches this branch — the handshake
    // arms below all advance the stage before it can.
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
      return this.receiveSessionStart(ct);
    }

    return this.receiveMessage2(ct);
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

  private receiveMessage2 (ct: Uint8Array): GateResult<Received> {
    const handshake = this.handshake!;
    const session = this.session!;

    let plaintext: Uint8Array;
    try {
      plaintext = bytes(handshake.readMessageB(new Uint8ArrayList(ct)));
    } catch {
      return this.terminate({ kind: "noise" });
    }
    // The static key NOISE authenticated, never one read out of the payload — which would be the
    // peer's own claim about itself.
    if (!handshake.rs) return this.terminate({ kind: "noise" });
    const step = session.receiveMessage2(plaintext, bytes(handshake.rs));
    if (!step.ok) return this.terminate({ kind: "session", failure: step.failure });

    const message3 = session.message3Payload();
    if (!message3.ok) return this.terminate({ kind: "session", failure: message3.failure });

    let m3: Uint8Array;
    try {
      m3 = bytes(handshake.writeMessageC(message3.value));
    } catch {
      return this.terminate({ kind: "noise" });
    }

    // Split HERE, not on the next message: message 3 is the last handshake message this side
    // writes, and `client-confirm` immediately after it is already transport.
    this.transport = new NoiseTransport(handshake.ss.split(), true);
    this.handshakeHash = new Uint8Array(handshake.ss.h);

    let appHello: Uint8Array = new Uint8Array(0);
    try { appHello = this.config.appHello?.() ?? appHello; } catch { /* the application's words never cost the handshake */ }
    if (appHello.length > APP_HELLO_MAX) appHello = new Uint8Array(0);
    const confirm = session.clientConfirm(this.handshakeHash, this.config.newBundle, appHello);
    if (!confirm.ok) return this.terminate({ kind: "session", failure: confirm.failure });

    let sealed: Uint8Array;
    try {
      sealed = bytes(this.transport.write(confirm.value));
    } catch {
      return this.terminate({ kind: "noise" });
    }

    // TWO envelopes, sent in order: §11 has the initiator send message 3 and `client-confirm` back
    // to back, and an ordered connection delivers them in order.
    return { ok: true, value: { kind: "reply", cts: [m3, sealed] } };
  }

  private receiveSessionStart (ct: Uint8Array): GateResult<Received> {
    const session = this.session!;
    const transport = this.transport!;
    if (!this.handshakeHash) return this.terminate({ kind: "noise" });

    let plaintext: Uint8Array;
    try {
      plaintext = bytes(transport.read(new Uint8ArrayList(ct)));
    } catch {
      return this.terminate({ kind: "noise" });
    }
    const done = session.receiveSessionStart(plaintext, this.handshakeHash);
    if (!done.ok) return this.terminate({ kind: "session", failure: done.failure });
    return { ok: true, value: { kind: "nothing" } };
  }

  private terminate<T> (failure: GateFailure): GateResult<T> {
    this.session?.terminate();
    this.dead = true;
    this.transport = null;
    return { ok: false, failure };
  }
}
