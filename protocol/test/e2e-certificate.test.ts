import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { sha256 } from "@noble/hashes/sha2.js";
import {
  assertion, bundle, certificate, parseAssertion, parseBundle, parseCertificate,
} from "../src/e2e-certificate";
import { deviceId, grantCommitment, parseGrant, parseRoot } from "../src/e2e-identity";
import {
  ed25519PublicKey, signEd25519, verifyAssertion, verifyBundle, verifyEd25519,
} from "../src/e2e-verify";

// The §10.4 evidence encodings and the bundle verifier, against vectors a THIRD implementation
// produced (`scripts/gen_e2e_certificate_fixture.py`, whose own signature arithmetic is pinned to
// the published RFC 8032 §7.1 and RFC 6979 A.2.5 answers) and which `E2ECertificateTests.swift`
// asserts too.
interface EncCase {
  name: string; kind: string; encoded?: string;
  credential_id?: string; client_data_json?: string; authenticator_data?: string; signature?: string;
  grant?: string; evidence?: string; real_signature?: string;
  root?: string; certificates?: string[]; note?: string;
}
interface VerifyCase {
  name: string; bundle: string; trusted_root_id: string; rp_id: string; allowed_origins: string[];
  expect: string; leaf_device_id?: string; leaf_capabilities?: number;
  leaf_noise_public_key?: string; revoked_device_ids?: string[]; expected_noise_static?: string;
  note?: string;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-certificate.json", import.meta.url)), "utf8")) as
  { cases: EncCase[]; verify: VerifyCase[] };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const toHex = (u: Uint8Array): string => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");

describe("§10.4 encodings, cross-implementation vectors", () => {
  const kinds = new Set<string>();
  for (const c of fx.cases) {
    test(c.name, () => {
      kinds.add(c.kind);
      switch (c.kind) {
        case "assertion": {
          const encoded = assertion(hex(c.credential_id!), hex(c.client_data_json!),
                                    hex(c.authenticator_data!), hex(c.signature!));
          expect(toHex(encoded!)).toBe(c.encoded);
          const back = parseAssertion(hex(c.encoded!))!;
          expect(toHex(back.credentialId)).toBe(c.credential_id);
          expect(toHex(back.clientDataJSON)).toBe(c.client_data_json);
          expect(toHex(back.authenticatorData)).toBe(c.authenticator_data);
          expect(toHex(back.signature)).toBe(c.signature);
          break;
        }
        case "certificate": {
          expect(toHex(certificate(hex(c.grant!), hex(c.evidence!))!)).toBe(c.encoded);
          const back = parseCertificate(hex(c.encoded!))!;
          expect(toHex(back.grant)).toBe(c.grant);
          expect(toHex(back.evidence)).toBe(c.evidence);
          break;
        }
        case "bundle": {
          const encoded = bundle(hex(c.root!), c.certificates!.map(hex));
          expect(toHex(encoded!)).toBe(c.encoded);
          const back = parseBundle(hex(c.encoded!));
          expect(back.ok).toBe(true);
          if (!back.ok) return;
          expect(toHex(back.bundle.root)).toBe(c.root);
          expect(back.bundle.certificates.map((x) => toHex(certificate(x.grant, x.evidence)!)))
            .toEqual(c.certificates);
          break;
        }
        case "ambiguity": {
          // The two evidence forms are NOT DISJOINT: this crafted 64-byte value — the width of a
          // raw Ed25519 signature — parses cleanly as an assertion, which is the whole reason the
          // form is chosen by the grant's issuer_kind and never by probing the bytes.
          expect(hex(c.evidence!).length).toBe(64);
          expect(parseAssertion(hex(c.evidence!))).not.toBeNull();
          // And the control: a REAL signature does not parse. Without this arm the case above
          // could be read as "signatures collide with assertions", which is false (~1e-14) and
          // would point at the wrong hazard.
          expect(parseAssertion(hex(c.real_signature!))).toBeNull();
          break;
        }
        default:
          throw new Error(`unhandled kind ${c.kind}`);
      }
    });
  }
  test("every kind in the fixture was exercised", () => {
    expect([...kinds].sort()).toEqual(["ambiguity", "assertion", "bundle", "certificate"]);
  });
});

describe("§10.4 bundle verification", () => {
  const seen = new Set<string>();
  for (const c of fx.verify) {
    test(`${c.name} → ${c.expect}`, () => {
      seen.add(c.expect);
      const result = verifyBundle(hex(c.bundle), {
        trustedRootId: hex(c.trusted_root_id),
        policy: { rpId: c.rp_id, allowedOrigins: c.allowed_origins },
        revokedDeviceIds: (c.revoked_device_ids ?? []).map(hex),
        ...(c.expected_noise_static ? { expectedNoiseStatic: hex(c.expected_noise_static) } : {}),
      });
      if (c.expect === "ok") {
        expect(result.ok ? "ok" : result.failure).toBe("ok");
        if (!result.ok) return;
        expect(toHex(deviceId(result.chain.leafDevice.bytes))).toBe(c.leaf_device_id);
        expect(result.chain.leaf.capabilities).toBe(c.leaf_capabilities);
        expect(toHex(result.chain.leafDevice.noisePublicKey)).toBe(c.leaf_noise_public_key);
      } else {
        expect(result.ok ? "ok" : result.failure).toBe(c.expect);
      }
    });
  }
  // A verifier that returned one blanket rejection would pass every negative case. This is what
  // makes the suite discriminate: the fixture reaches twenty distinct outcomes, and each one names
  // the single thing its case mutated.
  test("the fixture reaches every distinct outcome it declares", () => {
    expect(seen.size).toBe(new Set(fx.verify.map((c) => c.expect)).size);
    expect(seen.size).toBeGreaterThanOrEqual(20);
  });
});

describe("Ed25519", () => {
  // RFC 8032 §7.1 TEST 1 — an EXTERNAL answer, not one this repo computed. It also pins the key
  // encoding: a raw 32-byte seed, never a 64-byte libsodium "secret key".
  const seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
  const pub = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
  const sig = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
            + "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";

  test("RFC 8032 TEST 1", () => {
    expect(toHex(ed25519PublicKey(seed))).toBe(pub);
    expect(toHex(signEd25519(new Uint8Array(0), seed))).toBe(sig);
    expect(verifyEd25519(hex(sig), new Uint8Array(0), hex(pub))).toBe(true);
  });

  test("a wrong-width signature is refused without throwing", () => {
    expect(verifyEd25519(hex(sig).slice(0, 63), new Uint8Array(0), hex(pub))).toBe(false);
  });

  test("a malformed public key is refused without throwing", () => {
    expect(verifyEd25519(hex(sig), new Uint8Array(0), new Uint8Array(31))).toBe(false);
  });
});

describe("the evidence form is chosen by the grant, never by probing", () => {
  // The direct case, rewritten so its root-issued grant carries the LEAF's genuine Ed25519
  // signature as evidence. Every byte is authentic; only the form is wrong for the grant.
  const direct = fx.verify.find((c) => c.name === "direct")!;
  const chain = fx.verify.find((c) => c.name === "chain")!;

  test("a root-issued grant is never verified against a raw signature", () => {
    const parsedChain = parseBundle(hex(chain.bundle));
    expect(parsedChain.ok).toBe(true);
    if (!parsedChain.ok) return;
    const leafEvidence = parsedChain.bundle.certificates[1]!.evidence;
    expect(leafEvidence.length).toBe(64);

    const parsedDirect = parseBundle(hex(direct.bundle));
    if (!parsedDirect.ok) return;
    const swapped = bundle(parsedDirect.bundle.root,
                           [certificate(parsedDirect.bundle.certificates[0]!.grant, leafEvidence)!])!;
    const result = verifyBundle(swapped, {
      trustedRootId: hex(direct.trusted_root_id),
      policy: { rpId: direct.rp_id, allowedOrigins: direct.allowed_origins },
    });
    expect(result.ok).toBe(false);
  });
});

// **THE PRE-IMAGE IS §10.4'S COMMITMENT, NOT THE GRANT.** A root passkey signs a projection of the
// grant that names no root, so these hand `verifyAssertion` exactly what `verifyBundle` would:
// `grantCommitment`'s output for the grant, under the root actually trusted.
describe("verifyAssertion in isolation", () => {
  const direct = fx.verify.find((c) => c.name === "direct")!;
  const parsed = parseBundle(hex(direct.bundle));

  const commitmentOf = (grantBytes: Uint8Array, trustedRootId: string): Uint8Array => {
    const g = parseGrant(grantBytes);
    const commitment = g && grantCommitment(g, hex(trustedRootId));
    if (!commitment) throw new Error("a root-issued grant must have a commitment");
    return commitment;
  };

  test("accepts the fixture's own assertion", () => {
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const cert = parsed.bundle.certificates[0]!;
    const root = parseRoot(parsed.bundle.root)!;
    expect(verifyAssertion(parseAssertion(cert.evidence)!,
                           commitmentOf(cert.grant, direct.trusted_root_id), root,
                           { rpId: direct.rp_id, allowedOrigins: direct.allowed_origins }))
      .toBeNull();
  });

  test("the challenge is the hash of THIS commitment, not of any commitment", () => {
    if (!parsed.ok) return;
    const cert = parsed.bundle.certificates[0]!;
    const root = parseRoot(parsed.bundle.root)!;
    // A DIFFERENT root-issued grant under the SAME root — different operation id, device keys,
    // capabilities and binding, so its commitment differs in every field the commitment carries.
    // `chain`'s first certificate would not do: it IS this bundle's grant. Its leaf would not
    // either, being device-issued, which `grantCommitment` refuses outright.
    const otherCase = fx.verify.find((c) => c.name === "forged-root-issued-leaf")!;
    const otherParsed = parseBundle(hex(otherCase.bundle));
    if (!otherParsed.ok) return;
    const otherCommitment = commitmentOf(otherParsed.bundle.certificates[0]!.grant,
                                         otherCase.trusted_root_id);
    const commitment = commitmentOf(cert.grant, direct.trusted_root_id);
    expect(sha256(otherCommitment)).not.toEqual(sha256(commitment));
    expect(verifyAssertion(parseAssertion(cert.evidence)!, otherCommitment, root,
                           { rpId: direct.rp_id, allowedOrigins: direct.allowed_origins }))
      .toBe("clientdata-challenge");
  });

  test("an origin not in the configured set is refused, including a prefix of one", () => {
    if (!parsed.ok) return;
    const cert = parsed.bundle.certificates[0]!;
    const root = parseRoot(parsed.bundle.root)!;
    const commitment = commitmentOf(cert.grant, direct.trusted_root_id);
    for (const origins of [[], ["https://rdev.example.evil.test"], ["https://rdev.exampl"]]) {
      expect(verifyAssertion(parseAssertion(cert.evidence)!, commitment, root,
                             { rpId: direct.rp_id, allowedOrigins: origins }))
        .toBe("clientdata-origin");
    }
  });
});
