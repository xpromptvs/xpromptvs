import { describe, expect, it } from "vitest";
import fixture from "../fixtures/e2e-session.json";
import { parseBundle } from "../src/e2e-certificate";
import {
  grantCommitment, parseGrant, parseRoot, root as rootDescriptor, rootId as hashRoot,
} from "../src/e2e-identity";
import { verifyDiscoveredRoot } from "../src/e2e-verify";
import { discoveryAssertionOptions, rootDiscoveryPreimage } from "../src/webauthn";

/**
 * §10.1's usernameless discovery: adopting a root descriptor that arrived from the Control Plane,
 * on the strength of a WebAuthn assertion and locally-configured policy.
 *
 * **DRIVEN BY A REAL ASSERTION, from `scripts/e2e_sigs.py`.** The evidence is device H's root-issued
 * grant out of `protocol/fixtures/e2e-session.json`, with that grant's §10.4 COMMITMENT as the
 * pre-image — which is exactly the shape a discovery assertion has (a pre-image the caller holds,
 * hashed into the challenge), so the ECDSA path under test is the one a browser will run and not a
 * signature this suite produced for itself.
 *
 * The commitment rather than the grant because that is what a root passkey now signs; and since the
 * ONE ceremony that signs it is also the one that discovers the credential, this borrowed assertion
 * is the literal shape signing in produces. Freshness is the CALLER's: `verifyDiscoveredRoot` verifies the evidence
 * for material its caller already holds, and the label in `rootDiscoveryPreimage` is what stops that
 * material being mistakable for a grant.
 */
const fx = fixture as unknown as {
  rp_id: string; allowed_origins: string[]; root: string;
  devices: Record<string, { bundle: string }>;
};

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const POLICY = { rpId: fx.rp_id, allowedOrigins: fx.allowed_origins };
const ROOT = hex(fx.root);

const certificate = (() => {
  const parsed = parseBundle(hex(fx.devices.H!.bundle));
  if (!parsed.ok) throw new Error("fixture bundle H does not parse");
  return parsed.bundle.certificates[0]!;
})();
const ASSERTION = certificate.evidence;
// §10.4's commitment — derived through the same function the verifier uses, so this test cannot
// drift from the projection the fixture's assertion was actually signed over.
const PREIMAGE = (() => {
  const g = parseGrant(certificate.grant);
  const commitment = g && grantCommitment(g, hashRoot(hex(fx.root)));
  if (!commitment) throw new Error("fixture grant H has no commitment");
  return commitment;
})();

/// The fixture root's own credential id and public key, read back out of the descriptor rather than
/// sliced at literal offsets, so a substituted descriptor changes exactly one field at a time and a
/// layout change is a parse failure instead of a test that silently stops testing anything.
const PARSED = parseRoot(ROOT)!;
const CREDENTIAL = PARSED.credentialId;
const PUBLIC_KEY = PARSED.publicKey;

describe("rootDiscoveryPreimage", () => {
  it("carries its own label, so the material is not a grant", () => {
    const p = rootDiscoveryPreimage(new Uint8Array(32).fill(3))!;
    expect(new TextDecoder().decode(p.slice(2, 2 + 25))).toBe("rdev-e2e/root-discovery/v");
    expect(p.length).toBe(2 + 26 + 32);
  });

  it("refuses randomness that is not 32 bytes", () => {
    expect(rootDiscoveryPreimage(new Uint8Array(31))).toBeNull();
    expect(rootDiscoveryPreimage(new Uint8Array(33))).toBeNull();
  });

  it("is fresh material, not a constant", () => {
    const a = rootDiscoveryPreimage(new Uint8Array(32).fill(1))!;
    const b = rootDiscoveryPreimage(new Uint8Array(32).fill(2))!;
    expect([...a]).not.toEqual([...b]);
  });
});

describe("discoveryAssertionOptions", () => {
  it("asks for any discoverable credential, user-verified", () => {
    const o = discoveryAssertionOptions({ rpId: "rdev.example", challenge: new Uint8Array(32) });
    expect(o.rpId).toBe("rdev.example");
    expect(o.userVerification).toBe("required");
    // PRESENT AND EMPTY. An omitted list is equivalent in the specification and has been read as
    // "no credential permitted" in the field.
    expect(o.allowCredentials).toEqual([]);
    expect("allowCredentials" in o).toBe(true);
  });
});

describe("verifyDiscoveredRoot", () => {
  it("adopts the descriptor the assertion actually belongs to", () => {
    const r = verifyDiscoveredRoot({ root: ROOT, assertion: ASSERTION, preimage: PREIMAGE,
                                     policy: POLICY });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect([...r.rootId]).toEqual([...hashRoot(ROOT)]);
    expect(r.root.rpId).toBe(fx.rp_id);
  });

  // **THE CHECK `verifyBundle` DOES NOT NEED AND THIS ONE CANNOT DO WITHOUT.** Every other field of
  // the descriptor is pinned by the assertion; `rp_id` is pinned only against policy, because
  // `verifyAssertion` hashes the POLICY's rpId rather than the descriptor's. Without it a Worker
  // could return the real credential and the real key under a different relying party, and the
  // browser would adopt a root id no other device in the identity shares — a denial of service
  // wearing the clothes of a successful setup.
  it("refuses a descriptor whose relying party is not this deployment's", () => {
    const substituted = rootDescriptor("evil.example", CREDENTIAL, PUBLIC_KEY)!;
    const r = verifyDiscoveredRoot({ root: substituted, assertion: ASSERTION, preimage: PREIMAGE,
                                     policy: POLICY });
    expect(r).toEqual({ ok: false, failure: "root-rpid" });
    // And the substitution really would have produced a different identity.
    expect([...hashRoot(substituted)]).not.toEqual([...hashRoot(ROOT)]);
  });

  it("refuses a descriptor naming a credential the authenticator did not return", () => {
    const other = new Uint8Array(CREDENTIAL.length).fill(0xaa);
    const substituted = rootDescriptor(fx.rp_id, other, PUBLIC_KEY)!;
    expect(verifyDiscoveredRoot({ root: substituted, assertion: ASSERTION, preimage: PREIMAGE,
                                  policy: POLICY }))
      .toEqual({ ok: false, failure: "credential-mismatch" });
  });

  it("refuses a substituted public key", () => {
    const other = new Uint8Array(PUBLIC_KEY);
    other[1] = other[1]! ^ 0x01;
    const substituted = rootDescriptor(fx.rp_id, CREDENTIAL, other)!;
    expect(verifyDiscoveredRoot({ root: substituted, assertion: ASSERTION, preimage: PREIMAGE,
                                  policy: POLICY }))
      .toEqual({ ok: false, failure: "signature" });
  });

  it("refuses evidence for a different pre-image", () => {
    const other = rootDiscoveryPreimage(new Uint8Array(32).fill(7))!;
    expect(verifyDiscoveredRoot({ root: ROOT, assertion: ASSERTION, preimage: other,
                                  policy: POLICY }))
      .toEqual({ ok: false, failure: "clientdata-challenge" });
  });

  it("refuses an origin this deployment does not accept", () => {
    expect(verifyDiscoveredRoot({ root: ROOT, assertion: ASSERTION, preimage: PREIMAGE,
                                  policy: { rpId: fx.rp_id, allowedOrigins: ["https://elsewhere"] } }))
      .toEqual({ ok: false, failure: "clientdata-origin" });
  });

  it("refuses bytes that are not a descriptor or not an assertion", () => {
    expect(verifyDiscoveredRoot({ root: new Uint8Array(4), assertion: ASSERTION,
                                  preimage: PREIMAGE, policy: POLICY }))
      .toEqual({ ok: false, failure: "malformed" });
    expect(verifyDiscoveredRoot({ root: ROOT, assertion: new Uint8Array(4),
                                  preimage: PREIMAGE, policy: POLICY }))
      .toEqual({ ok: false, failure: "malformed" });
  });
});
