/// §10.4 signature verification — Ed25519 over a device-issued grant, WebAuthn ES256 over a
/// root-issued one, and the whole-bundle check that combines them with §10.3's chain rules and
/// §10.5's tombstones.
///
/// Mirror of `RdevCore.E2EVerify` (Swift). `validateChainStructure` decides everything a signature
/// is not needed for, and says in its own documentation that success there is necessary and not
/// sufficient. **This is the sufficient half.** Nothing above this layer may treat a chain as
/// authority without it.
///
/// Held to `protocol/fixtures/e2e-certificate.json`, whose 36 verification cases each mutate ONE
/// thing and are re-signed, so a case fails for exactly one reason and names it. A verifier that
/// rejects everything passes none of them.
import { ed25519 } from "@noble/curves/ed25519.js";
import { p256 } from "@noble/curves/nist.js";
import { sha256 } from "@noble/hashes/sha2.js";
import {
  parseAssertion, parseBundle, type ParsedAssertion, type ParsedCertificate,
} from "./e2e-certificate";
import {
  IssuerKind, grantCommitment, parseDevice, parseGrant, rootId as hashRoot, parseRoot,
  validateChainStructure,
  type ChainFailure, type ParsedDevice, type ParsedGrant, type ParsedRoot,
} from "./e2e-identity";
import { bytesEqual, E2E_SIGNATURE_LENGTH } from "./e2e-wire";

/// Deployment configuration, and §10.1 is emphatic about where it comes from: the relying-party ID
/// and the accepted ceremony origins "are also configured in trusted application code, not in an
/// incoming certificate". Nothing on the wire may widen either.
export interface E2EPolicy {
  rpId: string;
  allowedOrigins: readonly string[];
}

/// Every way a bundle can be refused. These strings are the codes the shared fixture uses, so the
/// three implementations agree on the REASON and not merely on the rejection — "rejected for the
/// wrong reason" is a real class of defect, and the one that survives a suite asserting only failure.
export type VerifyFailure =
  | "malformed"
  | "count-invalid"
  /** The bundle's own root descriptor is not the root this endpoint trusts. */
  | "root-mismatch"
  | `chain/${ChainFailure}`
  | "credential-mismatch"
  | "clientdata-type"
  | "clientdata-challenge"
  | "clientdata-origin"
  | "clientdata-crossorigin"
  | "clientdata-duplicate"
  | "rpid-hash"
  | "user-presence"
  | "user-verification"
  | "signature"
  | "revoked"
  /** The certified leaf is not the peer this Noise session authenticated. */
  | "noise-static-mismatch";

export interface VerifiedChain {
  root: ParsedRoot;
  grants: ParsedGrant[];
  leaf: ParsedGrant;
  leafDevice: ParsedDevice;
}

export type VerifyResult =
  | { ok: true; chain: VerifiedChain }
  | { ok: false; failure: VerifyFailure };

// ------------------------------------------------------------------------------------- Ed25519

export const ed25519PublicKey = (privateKey: Uint8Array): Uint8Array =>
  ed25519.getPublicKey(privateKey);

export const signEd25519 = (message: Uint8Array, privateKey: Uint8Array): Uint8Array =>
  ed25519.sign(message, privateKey);

export function verifyEd25519 (signature: Uint8Array, message: Uint8Array,
                               publicKey: Uint8Array): boolean {
  if (signature.length !== E2E_SIGNATURE_LENGTH) return false;
  try {
    return ed25519.verify(signature, message, publicKey);
  } catch {
    return false;               // a malformed public key is a refusal, not an exception to raise
  }
}

// ------------------------------------------------------------------------------- WebAuthn ES256

const FLAG_USER_PRESENT = 0x01;
const FLAG_USER_VERIFIED = 0x04;
/// 32-byte RP-ID hash + 1 flags byte + 4 signature-counter bytes. §10.4 reads the counter and then
/// ignores it: syncable credentials may report non-monotonic or zero counters, and they are not a
/// freshness or revocation mechanism.
const AUTHENTICATOR_DATA_MINIMUM = 37;

/// Verify a WebAuthn assertion as the evidence for `preimage`. Null on success, or the one
/// reason.
///
/// **`preimage` is NOT always a grant**, which is why it is no longer called one: §10.1's
/// discovery passes its own pre-image, §10.5's revocation passes a revocation, and a §10.3
/// grant now passes `grantCommitment`'s projection rather than the grant itself.
///
/// The order is deliberate: everything decidable from the message itself runs BEFORE the elliptic
/// curve operation, so a flood of malformed assertions costs parsing rather than verification.
export function verifyAssertion (a: ParsedAssertion, preimage: Uint8Array, root: ParsedRoot,
                                 policy: E2EPolicy): VerifyFailure | null {
  // §10.1/§10.4: "Restrict the request to that candidate's credential ID ... and reject an
  // assertion returning any other credential ID."
  if (!bytesEqual(a.credentialId, root.credentialId)) return "credential-mismatch";

  const members = topLevelMembers(a.clientDataJSON);
  if (!members) return "malformed";
  const fields = new Map<string, string>();
  for (const [keyToken, valueToken] of members) {
    const key = jsonString(keyToken);
    if (key === null) return "malformed";
    // §10.4: "Reject duplicate security-relevant JSON fields." STRICTER THAN THAT ON PURPOSE — any
    // duplicate top-level name is refused, because "security-relevant" is a judgement someone would
    // have to re-make correctly for every field added later, and the two parsers that disagree
    // about which copy wins are the whole attack.
    if (fields.has(key)) return "clientdata-duplicate";
    fields.set(key, valueToken);
  }

  if (jsonString(fields.get("type") ?? null) !== "webauthn.get") return "clientdata-type";

  const challenge = jsonString(fields.get("challenge") ?? null);
  const decoded = challenge === null ? null : base64urlDecode(challenge);
  if (!decoded || !bytesEqual(decoded, sha256(preimage))) return "clientdata-challenge";

  // §10.4: "reject cross-origin ceremonies in this version". Compared against the literal token
  // rather than a decoded value: `"crossOrigin": 1` must not coerce to false.
  const cross = fields.get("crossOrigin");
  if (cross !== undefined) {
    if (cross === "true") return "clientdata-crossorigin";
    if (cross !== "false") return "malformed";
  }

  const origin = jsonString(fields.get("origin") ?? null);
  if (origin === null || !policy.allowedOrigins.includes(origin)) return "clientdata-origin";

  if (a.authenticatorData.length < AUTHENTICATOR_DATA_MINIMUM) return "malformed";
  if (!bytesEqual(a.authenticatorData.slice(0, 32), sha256(new TextEncoder().encode(policy.rpId)))) {
    return "rpid-hash";
  }
  const flags = a.authenticatorData[32]!;
  if ((flags & FLAG_USER_PRESENT) === 0) return "user-presence";
  // §10.4: "Require `userVerification: \"required\"`" — which is only a request at ceremony time.
  // This bit is the part that can be checked afterwards.
  if ((flags & FLAG_USER_VERIFIED) === 0) return "user-verification";

  const signed = new Uint8Array(a.authenticatorData.length + 32);
  signed.set(a.authenticatorData, 0);
  signed.set(sha256(a.clientDataJSON), a.authenticatorData.length);
  try {
    // ES256 is ECDSA-P256-SHA256 over `authenticatorData || H(clientDataJSON)`, and BOTH options
    // here are load-bearing:
    //
    // `prehash: true` says this argument is the MESSAGE, which @noble hashes itself. That is the
    // v2 default, stated explicitly because it inverts v1's contract — v1 took a digest — and a
    // silent flip of that default is a verifier that hashes twice and refuses every real assertion.
    //
    // `lowS: false` is not a loosening: @noble rejects a high-S signature by default, WebAuthn
    // authenticators are under no obligation to normalise, and a verifier enforcing low-S rejects
    // real passkeys. CryptoKit accepts them, so enforcing it here would also split the two
    // implementations. The fixture carries a high-S assertion so neither can drift into doing it.
    if (!p256.verify(a.signature, signed, root.publicKey,
                     { format: "der", lowS: false, prehash: true })) {
      return "signature";
    }
  } catch {
    return "signature";         // an unparseable DER signature or an off-curve key
  }
  return null;
}

// ------------------------------------------------- usernameless discovery (§10.1)

/// One reason a discovered root can be refused that no BUNDLE can be, so it is not in
/// `VerifyFailure`: that union is the shared vocabulary three implementations assert against
/// `protocol/fixtures/e2e-certificate.json`, and widening it here would make the fixture incomplete
/// in TypeScript alone.
export type DiscoveryFailure = VerifyFailure | "root-rpid";

export type DiscoveryResult =
  | { ok: true; root: ParsedRoot; rootId: Uint8Array }
  | { ok: false; failure: DiscoveryFailure };

/// **Adopt a root this endpoint has never seen, on the strength of an assertion and nothing else.**
///
/// §10.1's descriptor is `rp_id || credential_id || root_public_key`, and a fresh browser learns
/// only the credential id — an assertion does not return a public key, and WebAuthn's `user.id` is
/// chosen before the authenticator generates the key, so it cannot commit to one either. The
/// Control Plane therefore ANSWERS with the descriptor it holds for that credential, and this
/// function is the reason that is safe: §4 puts the Worker inside the adversary model, so its answer
/// is a hint, and every field of it is pinned by something the Worker does not control.
///
/// - `credential_id` — pinned by `verifyAssertion`'s `credential-mismatch`: the descriptor must
///   name the credential the authenticator actually returned.
/// - `root_public_key` — pinned by the ECDSA check. A substituted key verifies nothing.
/// - `rp_id` — pinned HERE, against the policy, and this is the check that is easy to leave out.
///   `verifyBundle` has no need of it because `trustedRootId` already fixes the exact descriptor
///   byte for byte; discovery has no trusted root id, because learning one is the point. Without
///   this line a Worker could return a descriptor identical to the real one but for its `rp_id`:
///   the assertion still verifies (`verifyAssertion` hashes the POLICY's rpId, not the
///   descriptor's), and the browser adopts a root whose id is a hash of bytes no other device
///   shares. Nothing is forged — M holds no key — but the person confirms an identity that cannot
///   talk to any of their Macs, which is a denial of service dressed as a successful setup.
///
/// What this does NOT establish is that the person meant THIS identity. That is §10.1's naming
/// obligation and it stays with the caller: a discovered root is presented in full and confirmed
/// before anything is written.
export function verifyDiscoveredRoot (opts: {
  root: Uint8Array;
  assertion: Uint8Array;
  /// The pre-image of the challenge the ceremony ran with — `rootDiscoveryPreimage`'s output, held
  /// by the caller across the ceremony. Frozen before the call, exactly as §17.1 requires of
  /// §10.1's root check: this verifies the evidence for the material the caller already holds.
  preimage: Uint8Array;
  policy: E2EPolicy;
}): DiscoveryResult {
  const assertion = parseAssertion(opts.assertion);
  if (!assertion) return { ok: false, failure: "malformed" };
  const root = parseRoot(opts.root);
  if (!root) return { ok: false, failure: "malformed" };
  if (root.rpId !== opts.policy.rpId) return { ok: false, failure: "root-rpid" };

  const failure = verifyAssertion(assertion, opts.preimage, root, opts.policy);
  if (failure) return { ok: false, failure };
  return { ok: true, root, rootId: hashRoot(root.bytes) };
}

// -------------------------------------------------------------------------------- the bundle

/// Verify a §10.4 bundle end to end: framing, the trusted root, §10.3's chain rules, §10.5's
/// tombstones, every signature, and — when given — that the certified leaf is the Noise peer.
///
/// `expectedNoiseStatic` is optional because §10.4 asks for that equality only where a live
/// handshake supplies the static key. Omitting it verifies the certificate; it does not bind it to a
/// session, and a caller holding a session must not omit it.
export function verifyBundle (bytes: Uint8Array, opts: {
  trustedRootId: Uint8Array;
  policy: E2EPolicy;
  revokedDeviceIds?: readonly Uint8Array[];
  expectedNoiseStatic?: Uint8Array;
}): VerifyResult {
  const parsed = parseBundle(bytes);
  if (!parsed.ok) return { ok: false, failure: parsed.failure };

  const root = parseRoot(parsed.bundle.root);
  if (!root) return { ok: false, failure: "malformed" };
  // The bundle carries its own root descriptor, so this is the step that makes it OURS. An attacker
  // may present a perfectly signed chain under a root of their own creation.
  if (!bytesEqual(hashRoot(root.bytes), opts.trustedRootId)) {
    return { ok: false, failure: "root-mismatch" };
  }

  const certificates: ParsedCertificate[] = parsed.bundle.certificates;
  const structure = validateChainStructure(certificates.map((c) => c.grant), opts.trustedRootId);
  if (!structure.ok) return { ok: false, failure: `chain/${structure.failure}` };

  const grants: ParsedGrant[] = [];
  const devices: ParsedDevice[] = [];
  for (const certificate of certificates) {
    const g = parseGrant(certificate.grant);
    const d = g && parseDevice(g.device);
    if (!g || !d) return { ok: false, failure: "malformed" };
    // The device descriptor names a root too, and a device scoped to another root inside a grant
    // for this one is incoherent rather than merely unlucky. Fail closed on nonsense.
    if (!bytesEqual(d.rootId, opts.trustedRootId)) {
      return { ok: false, failure: "chain/root-mismatch" };
    }
    grants.push(g);
    devices.push(d);
  }

  // §10.5: "Reject any chain containing a tombstoned device, including an Issuer." Before the
  // signatures, so a revoked device costs no curve operations — its status is not a secret.
  const revoked = opts.revokedDeviceIds ?? [];
  for (const d of devices) {
    if (revoked.some((r) => bytesEqual(r, sha256(d.bytes)))) {
      return { ok: false, failure: "revoked" };
    }
  }

  for (let i = 0; i < certificates.length; i++) {
    const g = grants[i]!;
    const evidence = certificates[i]!.evidence;
    if (g.issuerKind === IssuerKind.Root) {
      // The evidence form is chosen HERE, by the grant. Never by probing the bytes: the forms
      // are not disjoint (a crafted 64-byte value parses as an assertion), so a verifier that falls
      // back from one to the other lets the sender pick which check it faces.
      const assertion = parseAssertion(evidence);
      if (!assertion) return { ok: false, failure: "malformed" };
      // **THE PIN IS INSIDE THIS CALL, WHICH IS WHY IT CANNOT BE SKIPPED.** §10.4's challenge is
      // `H(grant_commitment)`, and the commitment deliberately does NOT cover `root_id` or
      // `issuer_id` — that is what lets ONE ceremony both identify the credential and sign, since a
      // challenge naming the root could not exist before the ceremony that learns which credential
      // answered. `grantCommitment` refuses to produce a pre-image unless the grant's `root_id`, its
      // `issuer_id` and its device's `root_id` all equal the trusted root id, so a verifier that
      // omits that check gets NO CHALLENGE rather than an insecure success.
      //
      // Redundant here BY DESIGN: the chain rules above already rejected all three. That redundancy
      // is what makes their ORDER irrelevant rather than load-bearing, and it is the primary
      // protection for any verifier that validates a chain differently.
      const preimage = grantCommitment(g, opts.trustedRootId);
      if (!preimage) return { ok: false, failure: "chain/root-mismatch" };
      const failure = verifyAssertion(assertion, preimage, root, opts.policy);
      if (failure) return { ok: false, failure };
    } else {
      // §10.3: a device-issued grant must "use its certified signing key" — the parent's, which the
      // chain rules have already established is `grants[i - 1]`.
      if (i === 0) return { ok: false, failure: "chain/first-not-root-issued" };
      if (evidence.length !== E2E_SIGNATURE_LENGTH) return { ok: false, failure: "malformed" };
      if (!verifyEd25519(evidence, g.bytes, devices[i - 1]!.signingPublicKey)) {
        return { ok: false, failure: "signature" };
      }
    }
  }

  const leafDevice = devices[devices.length - 1]!;
  if (opts.expectedNoiseStatic && !bytesEqual(leafDevice.noisePublicKey, opts.expectedNoiseStatic)) {
    return { ok: false, failure: "noise-static-mismatch" };
  }
  return { ok: true, chain: { root, grants, leaf: structure.grant, leafDevice } };
}

// ----------------------------------------------- the JSON clientDataJSON needs, and no more

/// Decode ONE JSON string token (quotes included) with the platform parser, so escapes, surrogate
/// pairs and UTF-8 are handled by code that is already correct. Null for anything else.
function jsonString (token: string | null): string | null {
  if (token === null) return null;
  try {
    const v: unknown = JSON.parse(token);
    return typeof v === "string" ? v : null;
  } catch {
    return null;
  }
}

function base64urlDecode (s: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) return null;
  try {
    const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

/// The ordered top-level members of a JSON object, as raw (key token, value token) source slices.
///
/// **THIS EXISTS BECAUSE EVERY PLATFORM JSON PARSER DESTROYS THE EVIDENCE.** `JSON.parse` and
/// `JSONSerialization` both collapse a duplicated name silently — one keeps the last, and a
/// different parser elsewhere may keep the first — so `{"origin":"good","origin":"evil"}` is exactly
/// the ambiguity §10.4 asks to be rejected, and by the time an object exists it is gone. The scanner
/// only has to find member boundaries; the values are still decoded by the platform parser after.
function topLevelMembers (json: Uint8Array): Array<[string, string]> | null {
  const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });
  let src: string;
  try {
    src = text.decode(json);
  } catch {
    return null;                // clientDataJSON is UTF-8 by definition (WebAuthn §5.8.1)
  }

  let i = 0;
  const n = src.length;
  const isSpace = (c: string): boolean => c === " " || c === "\t" || c === "\n" || c === "\r";
  const skipSpace = (): void => { while (i < n && isSpace(src[i]!)) i++; };

  const skipString = (): boolean => {
    if (src[i] !== '"') return false;
    i++;
    while (i < n) {
      const c = src[i]!;
      if (c === "\\") { i += 2; continue; }    // an escape consumes the next unit, whole
      i++;
      if (c === '"') return true;
    }
    return false;
  };

  const skipValue = (): string | null => {
    const start = i;
    if (i >= n) return null;
    const c = src[i]!;
    if (c === '"') {
      if (!skipString()) return null;
    } else if (c === "{" || c === "[") {       // a nested object or array is skipped whole
      let depth = 0;
      for (;;) {
        if (i >= n) return null;
        const d = src[i]!;
        if (d === '"') { if (!skipString()) return null; continue; }
        if (d === "{" || d === "[") { depth++; i++; continue; }
        if (d === "}" || d === "]") { depth--; i++; if (depth === 0) break; continue; }
        i++;
      }
    } else {                                    // number, true, false, null
      while (i < n && src[i] !== "," && src[i] !== "}" && src[i] !== "]" && !isSpace(src[i]!)) i++;
      if (i === start) return null;
    }
    return src.slice(start, i);
  };

  skipSpace();
  if (src[i] !== "{") return null;
  i++;
  const members: Array<[string, string]> = [];
  skipSpace();
  if (src[i] === "}") { i++; skipSpace(); return i === n ? members : null; }

  for (;;) {
    skipSpace();
    const keyStart = i;
    if (!skipString()) return null;
    const key = src.slice(keyStart, i);
    skipSpace();
    if (src[i] !== ":") return null;
    i++;
    skipSpace();
    const value = skipValue();
    if (value === null) return null;
    members.push([key, value]);
    skipSpace();
    if (src[i] === ",") { i++; continue; }
    if (src[i] === "}") { i++; break; }
    return null;
  }
  skipSpace();
  return i === n ? members : null;
}
