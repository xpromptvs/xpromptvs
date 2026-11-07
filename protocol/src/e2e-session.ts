/// The §11 session state machine: who may say what, in what order, and what must be true before a
/// session carries any authority at all.
///
/// Mirror of `RdevCore.E2ESession` (Swift). The two are two statements of ONE contract and the
/// failure mode is them drifting apart, so both are driven by the same fixture.
///
/// **THE WHOLE POINT IS THE GATE.** §11.2: "Before this gate, only bounded authentication,
/// enrollment, and resume messages may be processed. No SDP, ICE, media, shell, input, or
/// subscription authority exists yet." `maySignal` is that sentence, and it is false until the
/// responder has verified a chain, a device proof and a registration state, and the initiator has
/// verified the answer names its own session and its own keys.
///
/// **PURE, AND CRYPTO-FREE APART FROM SIGNATURES.** It never touches Noise. The caller drives the
/// handshake and hands this machine PLAINTEXTS plus the two facts only the handshake knows: the
/// peer's authenticated static key and the final handshake hash `h`. That split is what lets every
/// rule below be tested without a handshake at all.
import {
  parseBundle,
} from "./e2e-certificate";
import {
  device as deviceDescriptor, deviceId as hashDevice, parseDevice, parseRoot, rootId as hashRoot,
  IssuerKind, CAP_ENROLL, CAP_HOST,
  type ParsedDevice,
} from "./e2e-identity";
import {
  E2E_ID_LENGTH, PublicationStatus, bytesEqual, clientConfirm as encodeClientConfirm,
  deviceProofBody, initiatorHello, isOrdinaryAuth, message1PayloadIsAcceptable,
  parseClientConfirm, parseInitiatorHello, parseResponderHello, parseSessionStart, prologue,
  responderHello, sessionStart as encodeSessionStart,
  type E2EMode,
} from "./e2e-wire";
import { signEd25519, verifyBundle, verifyEd25519, type E2EPolicy, type VerifiedChain }
  from "./e2e-verify";
import type { RendezvousRoute } from "./rendezvous-seed";

/// Every way a session can refuse to establish. These strings are the codes the shared fixture uses,
/// so both implementations name the same reason — "refused for the wrong reason" hides real defects.
export type SessionFailure =
  /** A payload that did not parse, or carried trailing bytes. */
  | "malformed"
  /** §11.1: "Message 1 has an empty payload." */
  | "message1-not-empty"
  /** A message arrived in a state that does not accept it. */
  | "out-of-order"
  /** The peer's chain did not verify. */
  | "peer-chain"
  /** §11.1's role table: the responder does not hold what this mode requires of it. */
  | "responder-role"
  /** §11.1: "A selected Host's `device_id` must also match the selection." */
  | "responder-not-selected"
  /** §11.1: "The descriptor's DH key must match the initiator's Noise static." */
  | "descriptor-key-mismatch"
  /** §11.1's bundle rules: required for `auth`, empty for `pair` and `enroll`. */
  | "bundle-presence"
  /** §11.1: "An ordinary `auth` uses an all-zero operation ID." */
  | "operation-id-mismatch"
  /** The `client-confirm` proof body is not the one this session's facts produce. */
  | "proof-body-mismatch"
  /** The Ed25519 device proof did not verify against the certified signing key. */
  | "proof-signature"
  /** `session-start` does not name this handshake. */
  | "handshake-hash-mismatch"
  /** The accepted chain does not certify this device's exact keys. */
  | "accepted-chain-mismatch"
  /** §10.1: an incoming chain may never replace a trusted root. */
  | "root-not-trusted"
  /** §11.3: "Decryption failure terminates the signalling session." */
  | "terminated";

export type SessionResult<T> = { ok: true; value: T } | { ok: false; failure: SessionFailure };

const ok = <T>(value: T): SessionResult<T> => ({ ok: true, value });
const no = <T>(failure: SessionFailure): SessionResult<T> => ({ ok: false, failure });

/// §11.1's table of what the RESPONDER must hold, per mode. One function because the table is four
/// lines in the spec and four lines here; spreading it across the two machines is how it becomes
/// three-quarters right.
///
/// - `pair`: "the responder must have a direct grant with `enroll`" — DIRECT is the operative word.
/// - `enroll`, `auth`: "it must have `host`".
/// - `resume`: "must match the persisted responder ID and the original operation's role
///   requirements" — the identity half is `expectedResponderDeviceId`, the role half is whatever the
///   original operation demanded, so it is the CALLER's and this function deliberately asks nothing.
export function responderSatisfiesRole (mode: E2EMode, chain: VerifiedChain): boolean {
  switch (mode) {
    case "pair":
      return chain.leaf.issuerKind === IssuerKind.Root
          && (chain.leaf.capabilities & CAP_ENROLL) !== 0;
    case "enroll":
    case "auth":
      return (chain.leaf.capabilities & CAP_HOST) !== 0;
    case "resume":
      return true;
  }
}

/// §11.1's bundle rules for Noise message 3: "The bundle is required for `auth`; it is empty for
/// `pair` and `enroll`. In `resume`, include any persisted grant" — so `resume` accepts either.
///
/// EMPTY IS ENFORCED, not merely unused. A `pair` initiator shipping a bundle would be presenting a
/// chain nobody reads, and a responder tolerating it would differ from one that did read it.
export function bundlePresenceIsCorrect (mode: E2EMode, bundleIsEmpty: boolean): boolean {
  switch (mode) {
    case "auth": return !bundleIsEmpty;
    case "pair":
    case "enroll": return bundleIsEmpty;
    case "resume": return true;
  }
}

// ------------------------------------------------------------------------------- the initiator

export interface InitiatorConfig {
  mode: E2EMode;
  roomCode: string;
  /**
   * This device's §10.2 descriptor bytes.
   *
   * **EMPTY IS CORRECT IN `pair`, and required there.** A descriptor NAMES its root (§10.2), and a
   * newcomer does not learn that root until message 2 — §12.3 orders it exactly so: "persist trusted
   * root … ── message 3: own descriptor". So in `pair` it is assembled here, after the root is
   * adopted, from `devicePublicKeys`.
   */
  device: Uint8Array;
  /**
   * This device's PUBLIC signing and Noise keys. Required in `pair` — they are what the descriptor
   * is assembled from once the root is known — and ignored elsewhere.
   */
  devicePublicKeys?: { signing: Uint8Array; noise: Uint8Array };
  signingPrivateKey: Uint8Array;
  /** §11.1's message-3 bundle. Empty for `pair` and `enroll`. */
  bundle: Uint8Array;
  /** All-zero for an ordinary `auth`; the persisted random one for enrollment and resume. */
  operationId: Uint8Array;
  /**
   * **Null is legal ONLY in `pair`**, where §11.1 says the mode "may bootstrap its root through the
   * PSK". In every other mode the root must already be trusted, because §10.1 forbids an incoming
   * chain from replacing one.
   */
  trustedRootId: Uint8Array | null;
  policy: E2EPolicy;
  revokedDeviceIds?: readonly Uint8Array[];
  /** §11.1: "A selected Host's `device_id` must also match the selection." */
  expectedResponderDeviceId?: Uint8Array;
}

export type InitiatorStage =
  "awaiting-message2" | "awaiting-split" | "awaiting-session-start" | "established" | "terminated";

export class E2EInitiator {
  stage: InitiatorStage = "awaiting-message2";
  responderChain: VerifiedChain | null = null;
  /** §9.2: persisting the route "permits resume after a lost acknowledgement". */
  responderRoute: RendezvousRoute | null = null;
  acceptedBundle: Uint8Array | null = null;
  publicationStatus: PublicationStatus | null = null;

  private adoptedRootId: Uint8Array | null = null;
  /**
   * **The descriptor this device presents, which in `pair` is not known at construction.** Message
   * 3, the proof body and the accepted-chain check must all use the same bytes, so there is one
   * place they come from.
   */
  private ownDevice: Uint8Array;

  private constructor (private readonly config: InitiatorConfig) {
    this.ownDevice = config.device;
  }

  /// Null when the configuration is one this protocol has no mode for — today that is exactly "no
  /// trusted root outside `pair`". Refused at construction rather than at message 2, because a
  /// machine that cannot state its own trust anchor has nothing to check against.
  static create (config: InitiatorConfig): E2EInitiator | null {
    if (config.mode !== "pair" && config.trustedRootId === null) return null;
    if (config.operationId.length !== E2E_ID_LENGTH) return null;
    // `pair` names itself after message 2 and needs the keys to do it; every other mode must arrive
    // with a descriptor already. Refused here rather than three messages in, where the failure
    // would name neither the missing input nor the mode that wanted it.
    if (config.mode === "pair") {
      if (!config.devicePublicKeys) return null;
    } else if (config.device.length === 0) {
      return null;
    }
    return new E2EInitiator(config);
  }

  get prologue (): Uint8Array | null {
    return prologue(this.config.mode, this.config.roomCode);
  }

  /** §11.1: message 1's payload is empty. */
  get message1Payload (): Uint8Array { return new Uint8Array(0); }

  get isEstablished (): boolean { return this.stage === "established"; }

  /// §11.2's gate. Until this is true, a peer's SDP, ICE, media, shell, input and subscriptions are
  /// all things it is not yet entitled to send.
  get maySignal (): boolean { return this.stage === "established"; }

  /// `responderNoiseStatic` is the static key the HANDSHAKE authenticated — never a key read out of
  /// the payload, which is the peer's own claim.
  receiveMessage2 (payload: Uint8Array, responderNoiseStatic: Uint8Array): SessionResult<void> {
    if (this.stage !== "awaiting-message2") return this.fail("out-of-order");
    const hello = parseResponderHello(payload);
    if (!hello) return this.fail("malformed");

    // In `pair` the root is bootstrapped from the chain itself, authenticated by the PSK: completing
    // an `XXpsk3` handshake at all is the proof that the peer holds the pairing secret. In every
    // other mode the trusted root is supplied and a chain naming a different one is refused.
    let rootId: Uint8Array;
    if (this.config.trustedRootId) {
      rootId = this.config.trustedRootId;
    } else {
      const parsed = parseBundle(hello.bundle);
      const root = parsed.ok ? parseRoot(parsed.bundle.root) : null;
      if (!root) return this.fail("malformed");
      rootId = hashRoot(root.bytes);
    }

    const verified = verifyBundle(hello.bundle, {
      trustedRootId: rootId,
      policy: this.config.policy,
      revokedDeviceIds: this.config.revokedDeviceIds ?? [],
      expectedNoiseStatic: responderNoiseStatic,
    });
    if (!verified.ok) return this.fail("peer-chain");

    const expected = this.config.expectedResponderDeviceId;
    if (expected && !bytesEqual(hashDevice(verified.chain.leafDevice.bytes), expected)) {
      return this.fail("responder-not-selected");
    }
    if (!responderSatisfiesRole(this.config.mode, verified.chain)) {
      return this.fail("responder-role");
    }

    this.adoptedRootId = rootId;
    // §12.3: the descriptor is built once the trusted root is persisted, and NOT before — a
    // newcomer that named a root it invented would be certifying nothing.
    if (this.config.mode === "pair") {
      const keys = this.config.devicePublicKeys;
      const built = keys ? deviceDescriptor(rootId, keys.signing, keys.noise) : null;
      if (!built) return this.fail("malformed");
      this.ownDevice = built;
    }
    this.responderChain = verified.chain;
    this.responderRoute = { rcode: hello.rcode, rtoken: hello.rtoken };
    this.stage = "awaiting-split";
    return ok(undefined);
  }

  /// Noise message 3's payload. Available only once message 2 has been accepted — sending a device
  /// descriptor and a chain to a peer whose own chain has not verified would publish this device's
  /// identity to anyone who answered the room.
  message3Payload (): SessionResult<Uint8Array> {
    if (this.stage !== "awaiting-split") return no("out-of-order");
    if (!bundlePresenceIsCorrect(this.config.mode, this.config.bundle.length === 0)) {
      return this.fail("bundle-presence");
    }
    const payload = initiatorHello(this.ownDevice, this.config.operationId, this.config.bundle);
    return payload ? ok(payload) : this.fail("malformed");
  }

  /** §11.2: "After Split, the initiator sends the first transport message unprompted." */
  /** `appHello`: the application's first words (`ClientConfirm.appHello`), at most `APP_HELLO_MAX` bytes. */
  clientConfirm (h: Uint8Array, newBundle: Uint8Array = new Uint8Array(0),
                 appHello: Uint8Array = new Uint8Array(0)): SessionResult<Uint8Array> {
    if (this.stage !== "awaiting-split") return no("out-of-order");
    // `ownDevice`, not the config's — in `pair` they differ, and the proof body must name the
    // device id message 3 actually carried.
    const device = parseDevice(this.ownDevice);
    if (!this.responderChain || !device) return this.fail("malformed");
    const body = deviceProofBody(this.config.mode, h, hashDevice(device.bytes),
                                 hashDevice(this.responderChain.leafDevice.bytes),
                                 this.config.operationId);
    if (!body) return this.fail("malformed");
    const message = encodeClientConfirm(body, signEd25519(body, this.config.signingPrivateKey),
                                        newBundle, appHello);
    if (!message) return this.fail("malformed");
    this.stage = "awaiting-session-start";
    return ok(message);
  }

  /// §11.2: "The initiator verifies `h`, operation ID, exact local device keys, and the accepted
  /// grant chain, then persists its committed record together with `publication_status`. Only then
  /// may it negotiate WebRTC."
  receiveSessionStart (plaintext: Uint8Array, h: Uint8Array): SessionResult<void> {
    if (this.stage !== "awaiting-session-start") return this.fail("out-of-order");
    const start = parseSessionStart(plaintext);
    if (!start) return this.fail("malformed");
    // `h` first: everything after it is only meaningful about THIS session.
    if (!bytesEqual(start.handshakeHash, h)) return this.fail("handshake-hash-mismatch");
    if (!bytesEqual(start.operationId, this.config.operationId)) {
      return this.fail("operation-id-mismatch");
    }

    // An accepted chain is only an answer if it certifies THIS device's exact keys. A responder
    // returning someone else's perfectly valid grant would otherwise be accepted, and the device
    // would persist a record it can never use.
    if (start.acceptedBundle.length > 0) {
      const device = parseDevice(this.ownDevice);
      if (!this.adoptedRootId || !device) return this.fail("malformed");
      const accepted = verifyBundle(start.acceptedBundle, {
        trustedRootId: this.adoptedRootId,
        policy: this.config.policy,
        revokedDeviceIds: this.config.revokedDeviceIds ?? [],
        expectedNoiseStatic: device.noisePublicKey,
      });
      if (!accepted.ok || !bytesEqual(accepted.chain.leafDevice.bytes, device.bytes)) {
        return this.fail("accepted-chain-mismatch");
      }
    }

    this.acceptedBundle = start.acceptedBundle;
    this.publicationStatus = start.publicationStatus;
    this.stage = "established";
    return ok(undefined);
  }

  /// §11.3: "Decryption failure terminates the signalling session; never skip a failed ciphertext."
  /// Terminal and one-way — there is no path back to any other stage.
  terminate (): void { this.stage = "terminated"; }

  private fail<T> (failure: SessionFailure): SessionResult<T> {
    this.stage = "terminated";
    return no(failure);
  }
}

// ------------------------------------------------------------------------------- the responder

export interface ResponderConfig {
  mode: E2EMode;
  roomCode: string;
  device: Uint8Array;
  bundle: Uint8Array;
  route: RendezvousRoute;
  trustedRootId: Uint8Array;
  policy: E2EPolicy;
  revokedDeviceIds?: readonly Uint8Array[];
}

export type ResponderStage =
  "awaiting-message1" | "awaiting-message3" | "awaiting-confirm" | "established" | "terminated";

export class E2EResponder {
  stage: ResponderStage = "awaiting-message1";
  /** The initiator's descriptor, once its DH key has been matched against the Noise static. */
  initiatorDevice: ParsedDevice | null = null;
  initiatorChain: VerifiedChain | null = null;
  operationId: Uint8Array | null = null;
  /**
   * The `new_bundle` from `client-confirm` — an enrollment request, still UNVERIFIED here: §12
   * decides whether to issue against it, and this machine only guarantees it arrived inside an
   * authenticated session from a proven device.
   */
  requestedBundle: Uint8Array | null = null;
  /**
   * The `app_hello` from `client-confirm` — the application's first words (the client's terminal grid), set
   * only once the proof has verified: nothing acts on it before the gate opens (§11.2).
   */
  appHello: Uint8Array = new Uint8Array(0);

  constructor (private readonly config: ResponderConfig) {}

  get prologue (): Uint8Array | null {
    return prologue(this.config.mode, this.config.roomCode);
  }

  get isEstablished (): boolean { return this.stage === "established"; }
  get maySignal (): boolean { return this.stage === "established"; }

  receiveMessage1 (payload: Uint8Array): SessionResult<void> {
    if (this.stage !== "awaiting-message1") return this.fail("out-of-order");
    if (!message1PayloadIsAcceptable(payload)) return this.fail("message1-not-empty");
    this.stage = "awaiting-message3";
    return ok(undefined);
  }

  /// §9.2: the Issuer sends its durable address here, "before the newcomer can request an enrollment
  /// that might commit."
  message2Payload (): SessionResult<Uint8Array> {
    if (this.stage !== "awaiting-message3") return no("out-of-order");
    const payload = responderHello(this.config.bundle, this.config.route.rcode,
                                   this.config.route.rtoken);
    return payload ? ok(payload) : no("malformed");
  }

  receiveMessage3 (payload: Uint8Array, initiatorNoiseStatic: Uint8Array): SessionResult<void> {
    if (this.stage !== "awaiting-message3") return this.fail("out-of-order");
    const hello = parseInitiatorHello(payload);
    const device = hello && parseDevice(hello.device);
    if (!hello || !device) return this.fail("malformed");

    // §11.1: "The descriptor's DH key must match the initiator's Noise static." Compared against the
    // key NOISE authenticated, not against anything else in this message — a descriptor is a claim,
    // and only the handshake proves possession.
    if (!bytesEqual(device.noisePublicKey, initiatorNoiseStatic)) {
      return this.fail("descriptor-key-mismatch");
    }
    if (!bundlePresenceIsCorrect(this.config.mode, hello.bundle.length === 0)) {
      return this.fail("bundle-presence");
    }
    // §11.1: "An ordinary `auth` uses an all-zero operation ID."
    if (this.config.mode === "auth" && !isOrdinaryAuth(hello)) {
      return this.fail("operation-id-mismatch");
    }

    if (hello.bundle.length > 0) {
      const verified = verifyBundle(hello.bundle, {
        trustedRootId: this.config.trustedRootId,
        policy: this.config.policy,
        revokedDeviceIds: this.config.revokedDeviceIds ?? [],
        expectedNoiseStatic: initiatorNoiseStatic,
      });
      // The chain must certify the very descriptor this message carried, not merely some device
      // holding the same DH key.
      if (!verified.ok || !bytesEqual(verified.chain.leafDevice.bytes, device.bytes)) {
        return this.fail("peer-chain");
      }
      this.initiatorChain = verified.chain;
    }

    this.initiatorDevice = device;
    this.operationId = hello.operationId;
    this.stage = "awaiting-confirm";
    return ok(undefined);
  }

  /// §11.2's gate. "The responder validates the descriptor, proof, chain or enrollment request, and
  /// registration state."
  ///
  /// **THE PROOF BODY IS REBUILT HERE AND COMPARED BYTE FOR BYTE.** Verifying the signature over the
  /// body the message SUPPLIED would prove only that the device signed something — and the something
  /// it signed could name a different session, a different responder or a different mode. The body
  /// is a statement about facts this side already knows, so this side composes it and the wire only
  /// gets to agree.
  receiveClientConfirm (plaintext: Uint8Array, h: Uint8Array): SessionResult<void> {
    if (this.stage !== "awaiting-confirm") return this.fail("out-of-order");
    const confirm = parseClientConfirm(plaintext);
    const ownDevice = parseDevice(this.config.device);
    if (!confirm || !this.initiatorDevice || !this.operationId || !ownDevice) {
      return this.fail("malformed");
    }
    const expected = deviceProofBody(this.config.mode, h, hashDevice(this.initiatorDevice.bytes),
                                     hashDevice(ownDevice.bytes), this.operationId);
    if (!expected) return this.fail("malformed");
    if (!bytesEqual(confirm.proofBody, expected)) return this.fail("proof-body-mismatch");

    // The signing key comes from the DESCRIPTOR, which the handshake bound to this peer via its DH
    // key, and — in `auth` — which a verified chain additionally certifies.
    if (!verifyEd25519(confirm.proof, confirm.proofBody, this.initiatorDevice.signingPublicKey)) {
      return this.fail("proof-signature");
    }

    this.requestedBundle = confirm.newBundle;
    this.appHello = confirm.appHello;
    this.stage = "established";
    return ok(undefined);
  }

  /// §11.2: "The responder replies only after authorization and the required durable writes."
  /// Reachable only once the gate above has passed, which is what makes that sentence true of the
  /// code rather than only of the specification.
  sessionStart (h: Uint8Array, status: PublicationStatus,
                acceptedBundle: Uint8Array): SessionResult<Uint8Array> {
    if (this.stage !== "established" || !this.operationId) return no("out-of-order");
    const payload = encodeSessionStart(h, this.operationId, status, acceptedBundle);
    return payload ? ok(payload) : no("malformed");
  }

  terminate (): void { this.stage = "terminated"; }

  private fail<T> (failure: SessionFailure): SessionResult<T> {
    this.stage = "terminated";
    return no(failure);
  }
}
