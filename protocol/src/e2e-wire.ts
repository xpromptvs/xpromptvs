/// The §11 wire encodings of the E2E protocol specification — the prologue that binds a Noise
/// handshake to its mode and room, and the two authenticated transport messages that gate access.
///
/// Mirror of `RdevCore.E2EWire` (Swift). Both are held to `protocol/fixtures/e2e-wire.json`, whose
/// vectors a THIRD implementation produced — byte layouts are exactly where two implementations
/// drift while both look correct.
///
/// **PARSING IS AS MUCH THE POINT AS ENCODING.** §7 requires rejecting wrong widths, unsupported
/// values and extra trailing bytes BEFORE verification: a parser that is lenient about framing hands
/// an attacker the ability to make one byte string mean two things to two peers.

/// §11.1's modes. The pattern differs (`pair` is XXpsk3, the rest XX) but the mode is ALSO carried in
/// the prologue, so two peers that disagree about it cannot complete a handshake — which is what
/// stops a `pair` transcript being replayed as an `auth`.
export type E2EMode = "pair" | "enroll" | "auth" | "resume";
export const E2E_MODES: readonly E2EMode[] = ["pair", "enroll", "auth", "resume"];

/// §12.2, carried in `session-start` so the newcomer learns it from the endpoint that KNOWS rather
/// than inferring it from a directory listing that cannot answer the question.
export enum PublicationStatus { Confirmed = 0, Unconfirmed = 1, Rejected = 2 }

/// §7 field widths. Hashes, operation IDs and raw public keys are 32 bytes; Ed25519 signatures 64.
export const E2E_ID_LENGTH = 32;
export const E2E_SIGNATURE_LENGTH = 64;

const PROLOGUE_LABEL = "rdev-e2e/v3";
const PROOF_LABEL = "rdev-e2e/device-proof/v1";
const CONFIRM_LABEL = "rdev-e2e/confirm/v3";
const SESSION_START_LABEL = "rdev-e2e/session-start/v3";

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);

const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

/// `LP(x) = uint16be(len(x)) || x`. Null above 65,535 rather than truncating — a silent truncation
/// would produce a well-formed message carrying the wrong content.
export function lengthPrefixed(bytes: Uint8Array): Uint8Array | null {
  if (bytes.length > 0xffff) return null;
  return concat(new Uint8Array([bytes.length >> 8, bytes.length & 0xff]), bytes);
}

const lp = (s: string): Uint8Array => lengthPrefixed(utf8(s))!;

/// `prologue = LP("rdev-e2e/v3") || LP(mode) || LP(room_code)`
export function prologue(mode: E2EMode, roomCode: string): Uint8Array | null {
  const room = lengthPrefixed(utf8(roomCode));
  return room && concat(lp(PROLOGUE_LABEL), lp(mode), room);
}

/// §11.1: "Message 1 has an empty payload." Stated as a function because the check is the point — a
/// payload here is carried before ANY authentication, so anything in it is bytes an unauthenticated
/// stranger chose, arriving before the handshake can say who they are.
export const message1PayloadIsAcceptable = (payload: Uint8Array): boolean => payload.length === 0;

/// Noise message 2's payload: `LP(responder_bundle) || LP(rcode) || LP(rtoken)`.
///
/// **NO LABEL, and that is deliberate rather than an omission.** Its position in the handshake fixes
/// its meaning: it can only ever be read as message 2 of a transcript whose prologue already bound
/// the mode and the room, and Noise's hash covers everything before it. A label would add a second,
/// weaker statement of something the transcript already settles.
///
/// §9.2: the Issuer sends its DURABLE address here, "before the newcomer can request an enrollment
/// that might commit" — so a lost acknowledgement can be resumed rather than stranding a
/// half-finished enrollment.
export function responderHello (bundle: Uint8Array, rcode: string,
                                rtoken: string): Uint8Array | null {
  const b = lengthPrefixed(bundle);
  const c = lengthPrefixed(utf8(rcode));
  const t = lengthPrefixed(utf8(rtoken));
  return b && c && t ? concat(b, c, t) : null;
}

export interface ResponderHello {
  bundle: Uint8Array;
  rcode: string;
  rtoken: string;
}

export function parseResponderHello (bytes: Uint8Array): ResponderHello | null {
  const r = new E2EReader(bytes);
  const bundle = r.lengthPrefixed();
  const code = r.lengthPrefixed();
  const token = r.lengthPrefixed();
  if (!bundle || !code || !token || !r.atEnd) return null;
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });
  try {
    return { bundle, rcode: decoder.decode(code), rtoken: decoder.decode(token) };
  } catch {
    return null;              // §7: an invalid encoding is a rejection, not a replacement character
  }
}

/// Noise message 3's payload: `LP(initiator_device) || operation_id || LP(initiator_bundle)`.
///
/// §11.1: "The descriptor's DH key must match the initiator's Noise static." That check is the
/// responder's and cannot be made here — this layer only guarantees the descriptor ARRIVES, as its
/// own bytes, so the responder compares a parsed key against the key Noise authenticated rather than
/// against a key the same message asserted twice.
export function initiatorHello (device: Uint8Array, operationId: Uint8Array,
                                bundle: Uint8Array): Uint8Array | null {
  if (operationId.length !== E2E_ID_LENGTH) return null;
  const d = lengthPrefixed(device);
  const b = lengthPrefixed(bundle);
  return d && b ? concat(d, operationId, b) : null;
}

export interface InitiatorHello {
  device: Uint8Array;
  operationId: Uint8Array;
  bundle: Uint8Array;
}

/// §11.1: "An ordinary `auth` uses an all-zero operation ID." Named rather than open-coded, because
/// `operation_id == 0` is a MEANING here and not a missing value.
export const isOrdinaryAuth = (hello: InitiatorHello): boolean =>
  hello.operationId.every((b) => b === 0);

export function parseInitiatorHello (bytes: Uint8Array): InitiatorHello | null {
  const r = new E2EReader(bytes);
  const device = r.lengthPrefixed();
  const operationId = r.take(E2E_ID_LENGTH);
  const bundle = r.lengthPrefixed();
  if (!device || !operationId || !bundle || !r.atEnd) return null;
  return { device, operationId, bundle };
}

/// `proof_body = LP("rdev-e2e/device-proof/v1") || LP(mode) || h || device_id
///             || responder_device_id || operation_id`
///
/// Binds the request to BOTH peers, the mode, and the complete DH transcript. Without the responder's
/// id a proof is replayable at a different Host; without `h` it is replayable in a different session.
export function deviceProofBody (
  mode: E2EMode, h: Uint8Array, deviceId: Uint8Array,
  responderDeviceId: Uint8Array, operationId: Uint8Array,
): Uint8Array | null {
  for (const f of [h, deviceId, responderDeviceId, operationId]) {
    if (f.length !== E2E_ID_LENGTH) return null;
  }
  return concat(lp(PROOF_LABEL), lp(mode), h, deviceId, responderDeviceId, operationId);
}

/// `appHello`: the APPLICATION's first words, opaque here — the client's terminal grid (docs/sources-and-focus.md,
/// "The offer carries the tab bar"). Read only once the gate has opened.
export interface ClientConfirm { proofBody: Uint8Array; proof: Uint8Array; newBundle: Uint8Array; appHello: Uint8Array }

/// §11.2: "only BOUNDED authentication … messages may be processed" before the gate — so the one application
/// field the gate's own message carries is capped, and a longer one is a rejection.
export const APP_HELLO_MAX = 1024;

/// `client-confirm = LP("rdev-e2e/confirm/v3") || LP(proof_body) || proof || LP(new_bundle) || LP(app_hello)`
export function clientConfirm (proofBody: Uint8Array, proof: Uint8Array, newBundle: Uint8Array,
                               appHello: Uint8Array = new Uint8Array(0)): Uint8Array | null {
  if (proof.length !== E2E_SIGNATURE_LENGTH || appHello.length > APP_HELLO_MAX) return null;
  const body = lengthPrefixed(proofBody);
  const bundle = lengthPrefixed(newBundle);
  const hello = lengthPrefixed(appHello);
  return body && bundle && hello && concat(lp(CONFIRM_LABEL), body, proof, bundle, hello);
}

export function parseClientConfirm (bytes: Uint8Array): ClientConfirm | null {
  const r = new E2EReader(bytes);
  if (!r.expectLabel(CONFIRM_LABEL)) return null;
  const proofBody = r.lengthPrefixed();
  const proof = r.take(E2E_SIGNATURE_LENGTH);
  const newBundle = r.lengthPrefixed();
  const appHello = r.lengthPrefixed();
  if (!proofBody || !proof || !newBundle || !appHello || appHello.length > APP_HELLO_MAX || !r.atEnd) return null;   // §7: no trailing bytes
  return { proofBody, proof, newBundle, appHello };
}

export interface SessionStart {
  handshakeHash: Uint8Array; operationId: Uint8Array;
  publicationStatus: PublicationStatus; acceptedBundle: Uint8Array;
}

/// `session-start = LP("rdev-e2e/session-start/v3") || h || operation_id
///                || U8(publication_status) || LP(accepted_bundle)`
export function sessionStart (h: Uint8Array, operationId: Uint8Array,
                              status: PublicationStatus,
                              acceptedBundle: Uint8Array): Uint8Array | null {
  if (h.length !== E2E_ID_LENGTH || operationId.length !== E2E_ID_LENGTH) return null;
  const bundle = lengthPrefixed(acceptedBundle);
  return bundle && concat(lp(SESSION_START_LABEL), h, operationId, new Uint8Array([status]), bundle);
}

export function parseSessionStart (bytes: Uint8Array): SessionStart | null {
  const r = new E2EReader(bytes);
  if (!r.expectLabel(SESSION_START_LABEL)) return null;
  const handshakeHash = r.take(E2E_ID_LENGTH);
  const operationId = r.take(E2E_ID_LENGTH);
  const raw = r.takeByte();
  // §7: an unsupported enum value is REJECTED, never partially interpreted. A future status this
  // build does not know is not "probably fine".
  if (raw === null || !(raw in PublicationStatus)) return null;
  const acceptedBundle = r.lengthPrefixed();
  if (!handshakeHash || !operationId || !acceptedBundle || !r.atEnd) return null;
  return { handshakeHash, operationId, publicationStatus: raw as PublicationStatus, acceptedBundle };
}

/// Constant-shape byte comparison. Not constant-TIME, and it must not be used where that matters:
/// everything it compares here is public (hashes, ids, public keys), and the one secret comparison
/// in this protocol is Noise's own AEAD tag check, inside the cipher.
export const bytesEqual = (a: Uint8Array, b: Uint8Array): boolean =>
  a.length === b.length && a.every((v, i) => v === b[i]);

/// A cursor that refuses to read past the end. Every accessor returns null rather than throwing,
/// because this parses bytes an adversary chose.
///
/// Exported under a qualified name because §10 and §10.4 parse with it too — the Swift side reaches
/// it as `E2EWire.Reader`, and one adversary-facing parser with one set of tests is the point. It
/// was briefly copied into `e2e-identity.ts`; a third copy in `e2e-certificate.ts` is what settled it.
export class E2EReader {
  private i = 0;
  constructor (private readonly b: Uint8Array) {}

  get atEnd (): boolean { return this.i === this.b.length; }

  take (n: number): Uint8Array | null {
    if (n < 0 || this.b.length - this.i < n) return null;
    const out = this.b.subarray(this.i, this.i + n);
    this.i += n;
    return out;
  }

  takeByte (): number | null { return this.take(1)?.[0] ?? null; }

  lengthPrefixed (): Uint8Array | null {
    const hdr = this.take(2);
    return hdr ? this.take((hdr[0]! << 8) | hdr[1]!) : null;
  }

  /// A label must match EXACTLY, including its length prefix — it is the message's type tag, and
  /// accepting a prefix of it would let one encoding be read as another.
  expectLabel (label: string): boolean {
    const got = this.lengthPrefixed();
    return got !== null && bytesEqual(got, utf8(label));
  }
}
