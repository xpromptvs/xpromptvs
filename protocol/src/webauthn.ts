/// §10.1 and §10.4's WebAuthn ceremonies: what to ask an authenticator for, and how to read what it
/// hands back.
///
/// **PURE — nothing here touches `navigator.credentials`.** The DOM call is four lines and lives in
/// the client (`web/src/client/webauthn-ceremony.ts`); everything that can be wrong without a
/// browser is here, where it can be tested against fixtures. The part that cannot be tested without
/// a real authenticator is the call itself, and it is deliberately the smallest piece.
///
/// §10.1: the root is "a discoverable ES256 credential", `rp_id` is "the canonical ASCII
/// relying-party ID fixed by the application's deployment configuration", and "No `largeBlob` or PRF
/// extension is required." §10.4: "Require `userVerification: \"required\"`".
import { sha256 } from "@noble/hashes/sha2.js";
import { E2E_ID_LENGTH, lengthPrefixed } from "./e2e-wire";

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);
const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

/// ES256. **The only algorithm offered**, because §10.1 fixes it and §10.4 verifies it — a
/// credential created under any other algorithm is one this protocol cannot read.
export const COSE_ES256 = -7;

const ROOT_CHECK_LABEL = "rdev-e2e/root-check/v1";

/// §10.1's bootstrap challenge: `H(LP("rdev-e2e/root-check/v1") || root_id || random(32))`.
///
/// Its own label, so a root-check assertion can never be replayed as a grant or a revocation — all
/// three are WebAuthn assertions over a 32-byte challenge, and only the label separates them.
/// §10.1 is explicit that this "is local-only and is not an enrollment grant".
export function rootCheckChallenge (rootId: Uint8Array, random: Uint8Array): Uint8Array | null {
  const preimage = rootCheckPreimage(rootId, random);
  return preimage ? sha256(preimage) : null;
}

/// §10.1's bootstrap PRE-IMAGE: `LP("rdev-e2e/root-check/v1") || root_id || random(32)`.
///
/// Returned as the pre-image for `rootDiscoveryPreimage`'s reason: `verifyAssertion` takes the
/// pre-image and hashes it itself, so a helper that returned only the digest makes this the one
/// ceremony a verifier cannot check the same way as the others. With both, §10.1's LOCAL root check
/// and a DISCOVERED root go through the identical `verifyDiscoveredRoot`.
export function rootCheckPreimage (rootId: Uint8Array, random: Uint8Array): Uint8Array | null {
  if (rootId.length !== E2E_ID_LENGTH || random.length !== 32) return null;
  return concat(lengthPrefixed(utf8(ROOT_CHECK_LABEL))!, rootId, random);
}

// ----------------------------------------------------------------------- what we ask for

export interface CreationRequest {
  rpId: string;
  rpName: string;
  userId: Uint8Array;
  userName: string;
  userDisplayName?: string;
  challenge: Uint8Array;
}

/// §10.1's root credential. **Discoverable and user-verified**, ES256 only, no attestation.
///
/// `attestation: "none"` because this protocol never inspects an attestation statement: §10.1 asks
/// for a credential, not for a claim about the hardware holding it, and requesting one would collect
/// an identifier the deployment has no use for.
export function rootCreationOptions (req: CreationRequest): PublicKeyCredentialCreationOptions {
  return {
    rp: { id: req.rpId, name: req.rpName },
    user: {
      id: req.userId as BufferSource,
      name: req.userName,
      displayName: req.userDisplayName ?? req.userName,
    },
    challenge: req.challenge as BufferSource,
    pubKeyCredParams: [{ type: "public-key", alg: COSE_ES256 }],
    authenticatorSelection: {
      // §10.1: "The root uses a discoverable ES256 credential."
      residentKey: "required",
      requireResidentKey: true,
      // §10.4: "Require `userVerification: \"required\"`".
      userVerification: "required",
    },
    attestation: "none",
    timeout: 120_000,
    // §4: the root descriptor is written to the authenticator on the very next assertion, so a
    // second browser can learn it without asking the Control Plane — and so a creation that is
    // abandoned before it commits is still recoverable from the credential itself.
    //
    // **`"preferred"`, NEVER `"required"`.** Required fails creation outright where largeBlob is
    // unsupported, and §10.1 is explicit: "No `largeBlob` or PRF extension is required." This asks;
    // it does not depend.
    extensions: { largeBlob: { support: "preferred" } },
  };
}

export interface AssertionRequest {
  rpId: string;
  /// §10.1: "**Restrict the request to that candidate's credential ID via `allowCredentials`, and
  /// reject an assertion returning any other credential ID.**" Both halves are required — the
  /// restriction is a request, and an authenticator is free to answer with something else.
  credentialId: Uint8Array;
  challenge: Uint8Array;
  /// §4: bytes to store on the authenticator beside this credential, best-effort. A write requires
  /// `allowCredentials` to name EXACTLY ONE credential — with an empty list the platform answers
  /// `NotSupportedError` — which is why only this request shape can carry one, and why the write
  /// rides the grant assertion rather than the discovery one.
  writeBlob?: Uint8Array;
}

export function rootAssertionOptions (req: AssertionRequest): PublicKeyCredentialRequestOptions {
  return {
    rpId: req.rpId,
    challenge: req.challenge as BufferSource,
    allowCredentials: [{ type: "public-key", id: req.credentialId as BufferSource }],
    userVerification: "required",
    timeout: 120_000,
    // Omitted entirely when there is nothing to write: an extension asked for and not wanted is a
    // request an authenticator may refuse on, for no gain.
    ...(req.writeBlob
      ? { extensions: { largeBlob: { write: req.writeBlob as BufferSource } } }
      : {}),
  };
}

// ------------------------------------------------------- usernameless discovery (§10.1)

const ROOT_DISCOVERY_LABEL = "rdev-e2e/root-discovery/v1";

/// The pre-image a discovery assertion signs over: `LP("rdev-e2e/root-discovery/v1") || random(32)`.
///
/// **It names no root, and it cannot.** Every other WebAuthn challenge in this protocol is bound to
/// the thing it authorises — a grant, a revocation, §10.1's root check — and each of those is built
/// by a party that already knows which root it means. Discovery is the one ceremony that runs
/// BEFORE the root is known: its whole purpose is to find out which credential the authenticator
/// holds, and a challenge naming the answer would be a challenge only a caller who did not need it
/// could build.
///
/// So the label carries the entire separation. A discovery assertion is worthless as a grant, as a
/// revocation and as a root check, because none of those pre-images can begin with these bytes —
/// which is the same argument `rootCheckChallenge` makes, with one fewer field to bind.
///
/// Returned as the PRE-IMAGE rather than the challenge, because `verifyAssertion` takes the
/// pre-image and hashes it itself; the caller hands `sha256` of this to the authenticator. The grant
/// path already works exactly that way (`issueDirectGrant`), and a helper that returned the digest
/// would make this the one place where the two differ.
export function rootDiscoveryPreimage (random: Uint8Array): Uint8Array | null {
  if (random.length !== 32) return null;
  return concat(lengthPrefixed(utf8(ROOT_DISCOVERY_LABEL))!, random);
}

export interface DiscoveryRequest {
  rpId: string;
  challenge: Uint8Array;
}

/// §10.1's root is "a discoverable ES256 credential", and this is what discoverability is FOR: an
/// empty `allowCredentials` asks the authenticator to offer whatever roots it holds for this rpID,
/// and the person picks one. No username, no email, no account — which is the entire replacement for
/// OAuth sign-in (`docs/superpowers/specs/2026-09-13-passkey-only-identity.md`).
///
/// **`allowCredentials: []`, present and empty — not omitted.** They are equivalent in the
/// specification and are not equivalent in the field: some authenticator bridges branch on the
/// property EXISTING, and an omitted list has been read as "no credential permitted" rather than
/// "any". Present-and-empty is the form every platform reads the same way.
///
/// The reciprocal of `rootAssertionOptions`'s rule applies here and is worth stating because it
/// reads like its opposite: §10.1 says "reject an assertion returning any other credential ID",
/// which a caller can only enforce when it NAMED one. Here it named none, so any credential the
/// authenticator returns was legitimately offered — and the check that replaces it is that the root
/// descriptor claimed for that credential must contain exactly the credential id that came back.
/// `verifyDiscoveredRoot` is where that happens, and nothing may adopt a discovered root without it.
export function discoveryAssertionOptions (req: DiscoveryRequest): PublicKeyCredentialRequestOptions {
  return {
    rpId: req.rpId,
    challenge: req.challenge as BufferSource,
    allowCredentials: [],
    userVerification: "required",
    timeout: 120_000,
    // §4: read back the descriptor the authenticator may be carrying. A READ works with an empty
    // `allowCredentials`; only a write needs a named credential. Best-effort — an authenticator
    // holding no blob answers the assertion exactly as it did before.
    extensions: { largeBlob: { read: true } },
  };
}

// -------------------------------------------------------------- reading what comes back

export interface AttestedCredential {
  credentialId: Uint8Array;
  /// The 65-byte uncompressed SEC1 point §10.1 stores in the root descriptor.
  publicKey: Uint8Array;
  /// The flags byte, so a caller can see UV for itself rather than trust the ceremony ran as asked.
  flags: number;
}

/// Pull the credential id and public key out of a registration's `attestationObject`.
///
/// **DERIVED FROM THE BYTES, NEVER FROM `getPublicKey()`.** That helper returns SPKI and is a
/// perfectly good shortcut, but it is optional in the spec and absent on older Safari — and having
/// two paths to the one value that defines an identity means having two chances to disagree about
/// it. The bytes are always there.
export function parseAttestedCredential (attestationObject: Uint8Array): AttestedCredential | null {
  const outer = decodeCbor(attestationObject);
  if (!outer || !(outer.value instanceof Map)) return null;
  const authData = outer.value.get("authData");
  if (!(authData instanceof Uint8Array)) return null;
  return parseAuthenticatorData(authData);
}

/// `rpIdHash(32) || flags(1) || signCount(4) || aaguid(16) || credIdLen(2) || credId || COSE_Key`
export function parseAuthenticatorData (authData: Uint8Array): AttestedCredential | null {
  if (authData.length < 37) return null;
  const flags = authData[32]!;
  // Bit 6 (0x40) is AT: attested credential data present. Without it there is nothing to read, and
  // reading on regardless would interpret whatever follows as a key.
  if ((flags & 0x40) === 0) return null;
  if (authData.length < 37 + 16 + 2) return null;

  const credIdLength = (authData[53]! << 8) | authData[54]!;
  const credStart = 55;
  if (authData.length < credStart + credIdLength) return null;
  const credentialId = authData.slice(credStart, credStart + credIdLength);

  const cose = decodeCbor(authData.subarray(credStart + credIdLength));
  if (!cose || !(cose.value instanceof Map)) return null;
  const publicKey = seC1FromCoseKey(cose.value);
  return publicKey ? { credentialId, publicKey, flags } : null;
}

/// COSE_Key -> the 65-byte uncompressed SEC1 point.
///
/// Every field is checked rather than assumed: `kty` EC2, `alg` ES256, `crv` P-256, and both
/// coordinates exactly 32 bytes. §7 rejects "unsupported version/algorithm" rather than partially
/// interpreting it, and a key of another curve read as P-256 is a point that verifies nothing.
export function seC1FromCoseKey (cose: Map<unknown, unknown>): Uint8Array | null {
  if (cose.get(1) !== 2) return null;          // kty: EC2
  if (cose.get(3) !== COSE_ES256) return null; // alg: ES256
  if (cose.get(-1) !== 1) return null;         // crv: P-256
  const x = cose.get(-2);
  const y = cose.get(-3);
  if (!(x instanceof Uint8Array) || !(y instanceof Uint8Array)) return null;
  if (x.length !== 32 || y.length !== 32) return null;
  return concat(new Uint8Array([0x04]), x, y);
}

// ------------------------------------------------------------------------------- CBOR

/// The CBOR subset WebAuthn actually uses: unsigned and negative integers, byte and text strings,
/// arrays and maps. **Deliberately not a general decoder.**
///
/// Tags, floats, indefinite-length items and 64-bit integers are REFUSED rather than skipped —
/// none appears in an attestation object or a COSE key, and a decoder that tolerated them would be
/// interpreting bytes an authenticator (or something pretending to be one) chose.
export function decodeCbor (bytes: Uint8Array): { value: unknown; length: number } | null {
  const r = readItem(bytes, 0);
  return r ? { value: r.value, length: r.next } : null;
}

interface Read { value: unknown; next: number }

function readHead (b: Uint8Array, at: number): { major: number; arg: number; next: number } | null {
  if (at >= b.length) return null;
  const initial = b[at]!;
  const major = initial >> 5;
  const minor = initial & 0x1f;
  if (minor < 24) return { major, arg: minor, next: at + 1 };
  if (minor === 24) {
    if (at + 1 >= b.length) return null;
    return { major, arg: b[at + 1]!, next: at + 2 };
  }
  if (minor === 25) {
    if (at + 2 >= b.length) return null;
    return { major, arg: (b[at + 1]! << 8) | b[at + 2]!, next: at + 3 };
  }
  if (minor === 26) {
    if (at + 4 >= b.length) return null;
    const arg = ((b[at + 1]! << 24) | (b[at + 2]! << 16) | (b[at + 3]! << 8) | b[at + 4]!) >>> 0;
    return { major, arg, next: at + 5 };
  }
  // 27 is a 64-bit argument and 31 is indefinite length. Neither appears here, and both would need
  // decisions (bigint, streaming) that a parser of adversary bytes should not be making.
  return null;
}

function readItem (b: Uint8Array, at: number): Read | null {
  const head = readHead(b, at);
  if (!head) return null;
  const { major, arg, next } = head;
  switch (major) {
    case 0: return { value: arg, next };
    case 1: return { value: -1 - arg, next };
    case 2: {
      if (next + arg > b.length) return null;
      return { value: b.slice(next, next + arg), next: next + arg };
    }
    case 3: {
      if (next + arg > b.length) return null;
      try {
        return {
          value: new TextDecoder("utf-8", { fatal: true, ignoreBOM: false })
            .decode(b.subarray(next, next + arg)),
          next: next + arg,
        };
      } catch {
        return null;
      }
    }
    case 4: {
      const out: unknown[] = [];
      let cursor = next;
      for (let i = 0; i < arg; i++) {
        const item = readItem(b, cursor);
        if (!item) return null;
        out.push(item.value);
        cursor = item.next;
      }
      return { value: out, next: cursor };
    }
    case 5: {
      const out = new Map<unknown, unknown>();
      let cursor = next;
      for (let i = 0; i < arg; i++) {
        const k = readItem(b, cursor);
        if (!k) return null;
        const v = readItem(b, k.next);
        if (!v) return null;
        // A DUPLICATE KEY IS A REJECTION, for the same reason §10.4 rejects one in clientDataJSON:
        // two decoders can disagree about which copy wins, and the bytes are then ambiguous.
        if (out.has(k.value)) return null;
        out.set(k.value, v.value);
        cursor = v.next;
      }
      return { value: out, next: cursor };
    }
    default:
      return null;              // 6 (tags) and 7 (simple/float) are refused, not skipped
  }
}
