/// The §10 identity encodings — root descriptor, device descriptor, grant body, grant id and
/// revocation — and the authority rules that decide whether a grant may exist at all.
///
/// Mirror of `RdevCore.E2EIdentity` (Swift), held to `protocol/fixtures/e2e-identity.json`.
///
/// **THESE BYTES ARE WHAT SIGNATURES COVER.** A layout disagreement between the two implementations
/// is not a parse error; it is a signature that verifies against the wrong statement, which is the
/// quietest failure in the whole protocol.
///
/// PURE. Nothing here signs or verifies — that needs key material and belongs with it. This decides
/// exactly which bytes a signature is over, which is the part that must agree.
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesEqual, E2EReader, lengthPrefixed } from "./e2e-wire";

/// §7 widths. Hashes and raw Ed25519/X25519 public keys are 32 bytes; the root public key is a
/// validated 65-byte uncompressed SEC1 P-256 point.
export const E2E_IDENTITY_ID_LENGTH = 32;
export const E2E_ROOT_PUBLIC_KEY_LENGTH = 65;

const ROOT_LABEL = "rdev-e2e/root/v1";
const DEVICE_LABEL = "rdev-e2e/device/v1";
/// **v2, and THE FIELDS DID NOT CHANGE.** What changed is what a signature over them MEANS: a v1
/// grant's assertion covered the whole grant, a v2 grant's covers `grantCommitment`'s projection of
/// it. Domain separation exists so a signature made under one meaning can never be read under
/// another. It also buys the migration a decent failure — a pre-change bundle now dies at
/// `parseGrant` as `malformed-grant`, rather than reaching the challenge comparison and reporting
/// `clientdata-challenge`, which reads like corruption instead of staleness.
const GRANT_LABEL = "rdev-e2e/grant/v2";
const GRANT_ID_LABEL = "rdev-e2e/grant-id/v1";
const GRANT_COMMIT_LABEL = "rdev-e2e/grant-commit/v1";
const REVOKE_LABEL = "rdev-e2e/revoke/v1";

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);
const lp = (s: string): Uint8Array => lengthPrefixed(utf8(s))!;

const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

const isId = (b: Uint8Array): boolean => b.length === E2E_IDENTITY_ID_LENGTH;

/// §10.3. A bit mask, but only four values are legal and the set is closed on purpose:
/// "**Accept exactly `{1, 2, 3, 7}`** and reject every other value". `4`, `5` and `6` are all
/// expressible and none is a role this protocol grants.
///
/// **`2` WAS ADDED 2026-09-15**, when adopt-by-code gave it a holder: a Mac enrolled by scanning its
/// own code, which shares a screen and may do nothing else. §10.3 refused it until then for a stated
/// reason — "`host` without `connect` is a device that may share a screen it can never reach" —
/// which is a semantic judgement rather than a security invariant, and is the exact property that
/// Mac wants. On a Mac the `connect` bit buys nothing anyway: its only client is the app's renderer,
/// which needs a subordinate grant that neither `2` nor `3` can issue.
///
/// **This is wire-visible.** An older verifier reads a capability-2 grant as malformed, so a Mac
/// enrolled this way is unreachable from a peer on a build predating this line.
export const CAP_CONNECT = 1;
export const CAP_HOST = 2;
export const CAP_ENROLL = 4;
const ACCEPTED_CAPABILITIES = new Set([1, 2, 3, 7]);

export function capabilitiesAreAccepted (raw: number): boolean {
  return ACCEPTED_CAPABILITIES.has(raw);
}

/// §10.3: `0` root-issued, `1` device-issued. "Unknown issuer kinds or permissions are rejected,
/// never partially interpreted."
export enum IssuerKind { Root = 0, Device = 1 }

/// §10.3's two binding shapes. The binding ties a grant to the ceremony that produced it — without
/// it a signed grant could be replayed into a different enrollment.
export type Binding =
  /** `U8(0) || random(32)` — a local passkey ceremony. */
  | { kind: "local"; randomness: Uint8Array }
  /** `U8(1) || h || responder_device_id` — a live remote enrollment, bound to the exact Noise
   *  transcript and the exact responder; §10.4 has the responder check both against its own view. */
  | { kind: "remote"; handshakeHash: Uint8Array; responderDeviceId: Uint8Array };

export function encodeBinding (b: Binding): Uint8Array | null {
  if (b.kind === "local") {
    return isId(b.randomness) ? concat(new Uint8Array([0]), b.randomness) : null;
  }
  return isId(b.handshakeHash) && isId(b.responderDeviceId)
    ? concat(new Uint8Array([1]), b.handshakeHash, b.responderDeviceId)
    : null;
}

/// `root = LP("rdev-e2e/root/v1") || LP(rp_id) || LP(credential_id) || root_public_key`
export function root (rpId: string, credentialId: Uint8Array,
                      rootPublicKey: Uint8Array): Uint8Array | null {
  if (rootPublicKey.length !== E2E_ROOT_PUBLIC_KEY_LENGTH) return null;
  const rp = lengthPrefixed(utf8(rpId));
  const cred = lengthPrefixed(credentialId);
  return rp && cred && concat(lp(ROOT_LABEL), rp, cred, rootPublicKey);
}

export const rootId = (rootBytes: Uint8Array): Uint8Array => sha256(rootBytes);

/// A root descriptor, decoded. The bytes are kept because `root_id` is their hash, and a verifier
/// must be able to prove the descriptor it was handed is the root it already trusts.
export interface ParsedRoot {
  bytes: Uint8Array;
  rpId: string;
  credentialId: Uint8Array;
  publicKey: Uint8Array;
}

/// Decode a root descriptor, or null. The public key is the tail — unprefixed, fixed width — so a
/// descriptor with anything after it is refused rather than read as a longer key.
///
/// `rp_id` must be ASCII: §10.1 calls it "the canonical ASCII relying-party ID", and its hash appears
/// in `authenticatorData`. A non-ASCII byte string that decodes to the same string under two
/// normalisations would hash two ways, so the encoding is pinned here rather than discovered at the
/// point of comparison.
export function parseRoot (bytes: Uint8Array): ParsedRoot | null {
  const r = new E2EReader(bytes);
  if (!r.expectLabel(ROOT_LABEL)) return null;
  const rp = r.lengthPrefixed();
  const credentialId = r.lengthPrefixed();
  const publicKey = r.take(E2E_ROOT_PUBLIC_KEY_LENGTH);
  if (!rp || !credentialId || !publicKey || !r.atEnd) return null;
  if (!rp.every((b) => b < 0x80)) return null;
  // SEC1 uncompressed; the compressed and hybrid forms are not what this field holds.
  if (publicKey[0] !== 0x04) return null;
  return { bytes, rpId: new TextDecoder().decode(rp), credentialId, publicKey };
}

/// `device = LP("rdev-e2e/device/v1") || root_id || signing_public_key || noise_public_key`
///
/// The signing and DH keys are INDEPENDENT (§7: never converted from each other). Both appear here,
/// so a device that swapped one has a different identity rather than a quietly altered one.
export function device (rootIdBytes: Uint8Array, signingPublicKey: Uint8Array,
                        noisePublicKey: Uint8Array): Uint8Array | null {
  if (!isId(rootIdBytes) || !isId(signingPublicKey) || !isId(noisePublicKey)) return null;
  return concat(lp(DEVICE_LABEL), rootIdBytes, signingPublicKey, noisePublicKey);
}

export const deviceId = (deviceBytes: Uint8Array): Uint8Array => sha256(deviceBytes);

/// A device descriptor, decoded. Both keys matter to a verifier and for different reasons: the
/// signing key certifies any grant this device issues, and the Noise key is what §10.4 requires to
/// equal the static key the handshake authenticated.
export interface ParsedDevice {
  bytes: Uint8Array;
  rootId: Uint8Array;
  signingPublicKey: Uint8Array;
  noisePublicKey: Uint8Array;
}

export function parseDevice (bytes: Uint8Array): ParsedDevice | null {
  const r = new E2EReader(bytes);
  if (!r.expectLabel(DEVICE_LABEL)) return null;
  const rootIdBytes = r.take(E2E_IDENTITY_ID_LENGTH);
  const signingPublicKey = r.take(E2E_IDENTITY_ID_LENGTH);
  const noisePublicKey = r.take(E2E_IDENTITY_ID_LENGTH);
  if (!rootIdBytes || !signingPublicKey || !noisePublicKey || !r.atEnd) return null;
  return { bytes, rootId: rootIdBytes, signingPublicKey, noisePublicKey };
}

/// §10.3's authority rule, separated so it applies to a RECEIVED grant as well as a constructed one.
/// A leaf cannot extend the chain, which is what bounds chain depth at two without counting anything.
export function authorityIsWellFormed (issuerKind: IssuerKind, capabilities: number): boolean {
  return (capabilities & CAP_ENROLL) === 0 || issuerKind === IssuerKind.Root;
}

/// `grant = LP("rdev-e2e/grant/v1") || root_id || operation_id || issuer_kind || issuer_id
///        || LP(device) || capabilities || LP(binding)`
///
/// REFUSES A GRANT THE PROTOCOL WOULD NOT ACCEPT rather than encoding it and leaving the verifier to
/// catch it: a device-issued grant carrying `enroll` is not one to reject later, it is one that must
/// never be constructed — and therefore never signed.
export function grant (args: {
  rootId: Uint8Array; operationId: Uint8Array; issuerKind: IssuerKind; issuerId: Uint8Array;
  device: Uint8Array; capabilities: number; binding: Binding;
}): Uint8Array | null {
  const { rootId: r, operationId, issuerKind, issuerId, device: dev, capabilities, binding } = args;
  if (!isId(r) || !isId(operationId) || !isId(issuerId)) return null;
  if (!capabilitiesAreAccepted(capabilities)) return null;
  if (issuerKind !== IssuerKind.Root && issuerKind !== IssuerKind.Device) return null;
  if (!authorityIsWellFormed(issuerKind, capabilities)) return null;
  const encodedBinding = encodeBinding(binding);
  const devLp = lengthPrefixed(dev);
  const bindLp = encodedBinding && lengthPrefixed(encodedBinding);
  if (!devLp || !bindLp) return null;
  return concat(lp(GRANT_LABEL), r, operationId, new Uint8Array([issuerKind]), issuerId,
                devLp, new Uint8Array([capabilities]), bindLp);
}

/// `grant_id = H(LP("rdev-e2e/grant-id/v1") || grant)`
///
/// A SECOND LABEL over the same bytes, which is the point: a grant id must not be confusable with a
/// hash of the grant taken for any other purpose.
export const grantId = (grantBytes: Uint8Array): Uint8Array =>
  sha256(concat(lp(GRANT_ID_LABEL), grantBytes));

/// `grant_commitment = LP("rdev-e2e/grant-commit/v1") || operation_id || issuer_kind
///                  || signing_public_key || noise_public_key || capabilities || LP(binding)`
///
/// **THE BYTES A ROOT PASSKEY SIGNS, AND THEY NAME NO ROOT.** That is the entire point. A browser
/// signing in has not yet learned which credential will answer, so it cannot know `root_id`; a
/// challenge containing one could not exist until a FIRST ceremony had produced it, which is exactly
/// the second prompt this removes. `root_id` and `issuer_id` are pinned by the verifier instead —
/// see `grantCommitment`, which is where that pin lives so it cannot be skipped.
///
/// The field order mirrors `grant()`'s with the root-dependent fields elided, so this reads as the
/// projection it is. **`LP(device)` is deliberately NOT used**: a §10.2 descriptor names its root,
/// which would put `root_id` straight back in. The two keys are carried directly and the verifier
/// reassembles the descriptor from the root it already trusts.
///
/// Refuses exactly what `grant()` refuses, for the same reason: bytes that could not be a legal
/// grant must never be signed, rather than rejected by somebody later.
export function grantCommitmentPreimage (args: {
  operationId: Uint8Array; issuerKind: IssuerKind;
  signingPublicKey: Uint8Array; noisePublicKey: Uint8Array;
  capabilities: number; binding: Binding;
}): Uint8Array | null {
  const { operationId, issuerKind, signingPublicKey, noisePublicKey, capabilities, binding } = args;
  if (!isId(operationId) || !isId(signingPublicKey) || !isId(noisePublicKey)) return null;
  if (!capabilitiesAreAccepted(capabilities)) return null;
  if (issuerKind !== IssuerKind.Root && issuerKind !== IssuerKind.Device) return null;
  if (!authorityIsWellFormed(issuerKind, capabilities)) return null;
  const encodedBinding = encodeBinding(binding);
  const bindLp = encodedBinding && lengthPrefixed(encodedBinding);
  if (!bindLp) return null;
  return concat(lp(GRANT_COMMIT_LABEL), operationId, new Uint8Array([issuerKind]),
                signingPublicKey, noisePublicKey, new Uint8Array([capabilities]), bindLp);
}

/// **The verifier's half — and the reason the root binding is still safe without being signed.**
///
/// Because the signature no longer covers `root_id` or `issuer_id`, a verifier has to pin them. This
/// is where that pin lives, so it CANNOT BE SKIPPED: a verifier that omits the check does not get an
/// insecure success, it gets no challenge at all and fails closed. Same idiom as `grant()` in the
/// other direction — bytes that must never be produced are simply never produced.
///
/// It is deliberately redundant with the chain rules, which reject all three disagreements earlier.
/// That redundancy is the point: it makes the ORDER of those checks irrelevant rather than
/// load-bearing, and it is the primary protection for any verifier that validates a chain
/// differently. `protocol/test/e2e-identity.test.ts` is the only place the refusal is observable,
/// because `verifyBundle` never reaches it.
///
/// Refuses a device-issued grant outright: those are evidenced by a raw Ed25519 signature over the
/// whole grant, never by an assertion, so there is no case in which this should answer for one.
export function grantCommitment (g: ParsedGrant, trustedRootId: Uint8Array): Uint8Array | null {
  if (g.issuerKind !== IssuerKind.Root) return null;
  if (!isId(trustedRootId)) return null;
  if (!bytesEqual(g.rootId, trustedRootId)) return null;
  if (!bytesEqual(g.issuerId, trustedRootId)) return null;
  const d = parseDevice(g.device);
  if (!d || !bytesEqual(d.rootId, trustedRootId)) return null;
  return grantCommitmentPreimage({
    operationId: g.operationId, issuerKind: g.issuerKind,
    signingPublicKey: d.signingPublicKey, noisePublicKey: d.noisePublicKey,
    capabilities: g.capabilities, binding: g.binding,
  });
}

/// `revocation = LP("rdev-e2e/revoke/v1") || root_id || operation_id || target_device_id`
///
/// The target is the WHOLE DEVICE IDENTITY, not one grant: revoking a grant would leave a device free
/// to present a sibling. §10.5 keeps an irreversible tombstone, and re-enrollment needs NEW keys.
export function revocation (rootIdBytes: Uint8Array, operationId: Uint8Array,
                            targetDeviceId: Uint8Array): Uint8Array | null {
  if (!isId(rootIdBytes) || !isId(operationId) || !isId(targetDeviceId)) return null;
  return concat(lp(REVOKE_LABEL), rootIdBytes, operationId, targetDeviceId);
}

/// A grant, decoded. Holding the ORIGINAL BYTES is not a convenience: the signature covers them, and
/// §7 forbids reserialising to verify. A re-encoded grant differing by one byte is a signature check
/// that fails for a reason nobody will find.
export interface ParsedGrant {
  bytes: Uint8Array;
  rootId: Uint8Array;
  operationId: Uint8Array;
  issuerKind: IssuerKind;
  issuerId: Uint8Array;
  device: Uint8Array;
  capabilities: number;
  binding: Binding;
}

function parseBinding (b: Uint8Array): Binding | null {
  if (b[0] === 0 && b.length === 1 + E2E_IDENTITY_ID_LENGTH) {
    return { kind: "local", randomness: b.subarray(1) };
  }
  if (b[0] === 1 && b.length === 1 + E2E_IDENTITY_ID_LENGTH * 2) {
    return { kind: "remote", handshakeHash: b.subarray(1, 33), responderDeviceId: b.subarray(33) };
  }
  return null;   // an unknown binding kind is rejected, never partially interpreted
}

/// Decode a grant, or null. EVERY rejection is one §7 asks for — unsupported enum values, wrong
/// widths, oversized fields and extra trailing bytes — all BEFORE any signature is checked.
export function parseGrant (bytes: Uint8Array): ParsedGrant | null {
  const r = new E2EReader(bytes);
  if (!r.expectLabel(GRANT_LABEL)) return null;
  const rootIdBytes = r.take(E2E_IDENTITY_ID_LENGTH);
  const operationId = r.take(E2E_IDENTITY_ID_LENGTH);
  const kind = r.takeByte();
  const issuerId = r.take(E2E_IDENTITY_ID_LENGTH);
  const dev = r.lengthPrefixed();
  const caps = r.takeByte();
  const bindingBytes = r.lengthPrefixed();
  if (!rootIdBytes || !operationId || kind === null || !issuerId || !dev || caps === null || !bindingBytes) {
    return null;
  }
  if (kind !== IssuerKind.Root && kind !== IssuerKind.Device) return null;
  if (!capabilitiesAreAccepted(caps)) return null;
  const binding = parseBinding(bindingBytes);
  if (!binding || !r.atEnd) return null;
  // The authority rule is structural, so it applies at PARSE time: a device-issued grant carrying
  // `enroll` is not a grant with a bad field, it is not a grant.
  if (!authorityIsWellFormed(kind, caps)) return null;
  return { bytes, rootId: rootIdBytes, operationId, issuerKind: kind, issuerId,
           device: dev, capabilities: caps, binding };
}

export type ChainFailure =
  | "empty" | "too-long" | "malformed-grant"
  /** A grant naming a different root. An incoming chain may never replace a trusted root. */
  | "root-mismatch"
  /** The first grant must be issued BY THE ROOT, and name it. */
  | "first-not-root-issued"
  /** A second grant must be issued by a device and name its parent's exact grant id. */
  | "second-not-chained-to-first"
  /** §10.3: only root-issued grants may carry `enroll`. */
  | "unauthorised-capabilities";

/// The STRUCTURAL half of chain validation — everything decidable without a signature.
///
/// Separated deliberately: signatures need key material and two different algorithms (WebAuthn ES256
/// for a root grant, Ed25519 for a device grant), while these rules are pure and are the ones a
/// reader can check against §10.3 line by line. **A caller MUST also verify signatures**; success
/// here is necessary and not sufficient, and the name says so.
///
/// `chain` is ordered from the root outward: `[direct]` or `[direct, leaf]`.
export function validateChainStructure (chain: Uint8Array[], trustedRootId: Uint8Array):
  { ok: true; grant: ParsedGrant } | { ok: false; failure: ChainFailure } {
  if (chain.length === 0) return { ok: false, failure: "empty" };
  // §10.3: "No chain has more than two grants." Checked first, so a long chain costs one comparison
  // rather than a parse per element.
  if (chain.length > 2) return { ok: false, failure: "too-long" };

  const parsed: ParsedGrant[] = [];
  for (const bytes of chain) {
    const g = parseGrant(bytes);
    if (!g) return { ok: false, failure: "malformed-grant" };
    if (!bytesEqual(g.rootId, trustedRootId)) return { ok: false, failure: "root-mismatch" };
    parsed.push(g);
  }

  const direct = parsed[0]!;
  if (direct.issuerKind !== IssuerKind.Root || !bytesEqual(direct.issuerId, trustedRootId)) {
    return { ok: false, failure: "first-not-root-issued" };
  }
  if (parsed.length === 1) return { ok: true, grant: direct };

  const leaf = parsed[1]!;
  if (leaf.issuerKind !== IssuerKind.Device || !bytesEqual(leaf.issuerId, grantId(direct.bytes))) {
    return { ok: false, failure: "second-not-chained-to-first" };
  }
  // Re-stated here as well as at parse time: that rule protects a single grant, this protects the
  // CHAIN, and a future parser relaxation must not silently widen authority.
  if ((leaf.capabilities & CAP_ENROLL) !== 0) {
    return { ok: false, failure: "unauthorised-capabilities" };
  }
  return { ok: true, grant: leaf };
}
