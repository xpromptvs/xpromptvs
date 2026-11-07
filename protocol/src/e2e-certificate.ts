/// The §10.4 evidence encodings — the WebAuthn assertion, the certificate that pairs a grant with
/// the evidence authorising it, and the bundle that carries a whole chain.
///
/// ```
/// assertion   = LP(credential_id) || LP(clientDataJSON) || LP(authenticatorData) || LP(signature)
/// certificate = LP(grant) || LP(evidence)     evidence = assertion | raw Ed25519 signature
/// bundle      = LP(root) || U8(count) || LP(certificate_1) [|| LP(certificate_2)]
/// ```
///
/// Mirror of `RdevCore.E2ECertificate` (Swift), held to `protocol/fixtures/e2e-certificate.json`.
///
/// **WHICH EVIDENCE FORM APPLIES IS DECIDED BY THE GRANT, NEVER BY PROBING THE BYTES.** The two
/// forms are not disjoint: the fixture carries a CRAFTED 64-byte value — the width of a raw Ed25519
/// signature — that parses cleanly as an assertion. A verifier that tries one form and falls back
/// to the other therefore lets the party supplying the evidence choose which check it faces, so
/// `issuer_kind` picks and a mismatch is a rejection rather than a second attempt. The hazard is
/// deliberate construction, not coincidence — a real signature colliding with the assertion grammar
/// is ~1e-14, and 0 of 2,000,000 random ones did.
///
/// PURE. Nothing here verifies a signature; that is `e2e-verify.ts`, which needs key material and a
/// deployment policy. This layer decides only what the bytes mean.
import { E2EReader, lengthPrefixed } from "./e2e-wire";

const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

/// A parsed WebAuthn assertion. `clientDataJSON` is kept as the ORIGINAL OCTETS: §10.4 says "Do not
/// reserialize `clientDataJSON`", because the signature is over exactly those bytes and any round
/// trip through a JSON encoder is free to change them.
export interface ParsedAssertion {
  credentialId: Uint8Array;
  clientDataJSON: Uint8Array;
  authenticatorData: Uint8Array;
  signature: Uint8Array;
}

/// A grant and the evidence authorising it, still undivided: `evidence` is whatever the certificate
/// carried, and the caller decides how to read it from the grant's issuer kind.
export interface ParsedCertificate {
  grant: Uint8Array;
  evidence: Uint8Array;
}

export interface ParsedBundle {
  root: Uint8Array;
  certificates: ParsedCertificate[];
}

/// `count-invalid` is separated from `malformed` because it is the one framing error a peer can make
/// that says something specific — it declared a chain length this protocol does not have.
export type BundleParseFailure = "malformed" | "count-invalid";

export function assertion (credentialId: Uint8Array, clientDataJSON: Uint8Array,
                           authenticatorData: Uint8Array, signature: Uint8Array): Uint8Array | null {
  const c = lengthPrefixed(credentialId);
  const d = lengthPrefixed(clientDataJSON);
  const a = lengthPrefixed(authenticatorData);
  const s = lengthPrefixed(signature);
  return c && d && a && s ? concat(c, d, a, s) : null;
}

export function parseAssertion (bytes: Uint8Array): ParsedAssertion | null {
  const r = new E2EReader(bytes);
  const credentialId = r.lengthPrefixed();
  const clientDataJSON = r.lengthPrefixed();
  const authenticatorData = r.lengthPrefixed();
  const signature = r.lengthPrefixed();
  // §7: trailing bytes are a rejection.
  if (!credentialId || !clientDataJSON || !authenticatorData || !signature || !r.atEnd) return null;
  return { credentialId, clientDataJSON, authenticatorData, signature };
}

export function certificate (grant: Uint8Array, evidence: Uint8Array): Uint8Array | null {
  const g = lengthPrefixed(grant);
  const e = lengthPrefixed(evidence);
  return g && e ? concat(g, e) : null;
}

export function parseCertificate (bytes: Uint8Array): ParsedCertificate | null {
  const r = new E2EReader(bytes);
  const grant = r.lengthPrefixed();
  const evidence = r.lengthPrefixed();
  if (!grant || !evidence || !r.atEnd) return null;
  return { grant, evidence };
}

/// `bundle = LP(root) || U8(count) || LP(certificate_1) [|| LP(certificate_2)]`, root-to-leaf.
/// Refuses to encode a chain length §10.3 does not permit, rather than leaving it to a verifier.
export function bundle (root: Uint8Array, certificates: Uint8Array[]): Uint8Array | null {
  if (certificates.length !== 1 && certificates.length !== 2) return null;
  const r = lengthPrefixed(root);
  if (!r) return null;
  const parts = [r, new Uint8Array([certificates.length])];
  for (const c of certificates) {
    const lp = lengthPrefixed(c);
    if (!lp) return null;
    parts.push(lp);
  }
  return concat(...parts);
}

export function parseBundle (bytes: Uint8Array):
  { ok: true; bundle: ParsedBundle } | { ok: false; failure: BundleParseFailure } {
  const r = new E2EReader(bytes);
  const root = r.lengthPrefixed();
  const count = r.takeByte();
  if (!root || count === null) return { ok: false, failure: "malformed" };
  // Checked at the declared length, BEFORE reading that many certificates: "No chain has more than
  // two grants" (§10.3), so a bundle claiming 255 costs one comparison.
  if (count !== 1 && count !== 2) return { ok: false, failure: "count-invalid" };

  const certificates: ParsedCertificate[] = [];
  for (let i = 0; i < count; i++) {
    const raw = r.lengthPrefixed();
    const c = raw && parseCertificate(raw);
    if (!c) return { ok: false, failure: "malformed" };
    certificates.push(c);
  }
  if (!r.atEnd) return { ok: false, failure: "malformed" };
  return { ok: true, bundle: { root, certificates } };
}
