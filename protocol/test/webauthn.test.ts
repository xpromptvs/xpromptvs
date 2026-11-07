import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  COSE_ES256, decodeCbor, parseAttestedCredential, rootAssertionOptions, rootCheckChallenge,
  rootCheckPreimage, rootCreationOptions,
  discoveryAssertionOptions,
} from "../src/webauthn";
import { parseBundle } from "../src/e2e-certificate";
import { parseRoot } from "../src/e2e-identity";

// §10.1's registration ceremony, against vectors a THIRD implementation produced
// (`scripts/gen_webauthn_fixture.py`).
//
// **THE VECTORS ARE SYNTHETIC.** They pin the PARSING of CBOR and COSE; they do not establish that
// any real authenticator emits bytes of this shape. That needs a passkey and a person, and nothing
// here stands in for it — see `docs/e2e.md`.
interface Case {
  name: string; expect: "ok" | "refuse"; attestation_object: string;
  credential_id?: string; public_key?: string; flags?: number;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/webauthn.json", import.meta.url)), "utf8")) as {
    rp_id: string; cases: Case[];
    root_check: Array<{ name: string; root_id: string; random: string; challenge: string }>;
  };
const certificates = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-certificate.json", import.meta.url)), "utf8")) as {
    verify: Array<{ name: string; bundle: string }>;
  };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const toHex = (u: Uint8Array): string => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");

describe("parsing a registration", () => {
  for (const c of fx.cases) {
    test(`${c.name} → ${c.expect}`, () => {
      const parsed = parseAttestedCredential(hex(c.attestation_object));
      if (c.expect === "refuse") {
        expect(parsed).toBeNull();
        return;
      }
      expect(parsed).not.toBeNull();
      expect(toHex(parsed!.credentialId)).toBe(c.credential_id);
      expect(toHex(parsed!.publicKey)).toBe(c.public_key);
      expect(parsed!.flags).toBe(c.flags);
      // The 65-byte uncompressed SEC1 point §10.1 stores in the root descriptor.
      expect(parsed!.publicKey.length).toBe(65);
      expect(parsed!.publicKey[0]).toBe(0x04);
    });
  }

  test("the fixture carries refusals, not only successes", () => {
    // A parser that returned null for everything would pass every refusal; a fixture with no
    // successes would let it. Both arms have to be populated for either to mean anything.
    expect(fx.cases.filter((c) => c.expect === "ok").length).toBeGreaterThan(0);
    expect(fx.cases.filter((c) => c.expect === "refuse").length).toBeGreaterThan(5);
  });
});

// THE LOOP CLOSES HERE. The key extracted from a registration is the key that verifies assertions
// made by that credential — so "a credential was created" and "an assertion by it verifies" are the
// same key, checked against two fixtures generated independently of each other.
test("the registered key is the root key that verifies assertions", () => {
  const registered = parseAttestedCredential(
    hex(fx.cases.find((c) => c.expect === "ok")!.attestation_object))!;
  const bundle = parseBundle(hex(certificates.verify.find((v) => v.name === "direct")!.bundle));
  expect(bundle.ok).toBe(true);
  if (!bundle.ok) return;
  const root = parseRoot(bundle.bundle.root)!;
  expect(toHex(root.publicKey)).toBe(toHex(registered.publicKey));
  expect(toHex(root.credentialId)).toBe(toHex(registered.credentialId));
});

describe("§10.1's bootstrap challenge", () => {
  for (const c of fx.root_check) {
    test(c.name, () => {
      expect(toHex(rootCheckChallenge(hex(c.root_id), hex(c.random))!)).toBe(c.challenge);
    });
  }

  test("its own label separates it from a grant and a revocation", () => {
    // All three are WebAuthn assertions over a 32-byte challenge; only the label keeps a root-check
    // assertion — which §10.1 says "is not an enrollment grant" — from being replayable as one.
    const rootId = new Uint8Array(32).fill(7);
    const random = new Uint8Array(32).fill(9);
    const challenge = rootCheckChallenge(rootId, random)!;
    // Changing either input changes it, so it binds both.
    expect(toHex(rootCheckChallenge(new Uint8Array(32).fill(8), random)!)).not.toBe(toHex(challenge));
    expect(toHex(rootCheckChallenge(rootId, new Uint8Array(32).fill(10))!))
      .not.toBe(toHex(challenge));
  });

  test("wrong widths are refused rather than padded", () => {
    expect(rootCheckChallenge(new Uint8Array(31), new Uint8Array(32))).toBeNull();
    expect(rootCheckChallenge(new Uint8Array(32), new Uint8Array(31))).toBeNull();
  });
});

describe("what we ask the authenticator for", () => {
  const creation = rootCreationOptions({
    rpId: "rdev.example", rpName: "Xpromptvs", userId: new Uint8Array(16),
    userName: "root", challenge: new Uint8Array(32),
  });

  test("ES256 only, discoverable, user-verified, no attestation", () => {
    // §10.1: "a discoverable ES256 credential". §10.4: 'Require userVerification: "required"'.
    expect(creation.pubKeyCredParams).toEqual([{ type: "public-key", alg: COSE_ES256 }]);
    expect(creation.authenticatorSelection?.residentKey).toBe("required");
    expect(creation.authenticatorSelection?.userVerification).toBe("required");
    // §10.1 asks for a credential, not a claim about the hardware holding it.
    expect(creation.attestation).toBe("none");
  });

  // **This test used to require NO extensions at all**, reasoning that asking for one "would make a
  // ceremony fail on authenticators that do not support it". That is true of `required` and false
  // of `preferred`, which is the whole difference: §10.1 says no extension is REQUIRED, not that
  // none may be asked for. The concern it was protecting is what this asserts now.
  test("no extension is ever REQUIRED, and no PRF is asked for at all", () => {
    const ext = creation.extensions as Record<string, { support?: string }> | undefined;
    // largeBlob may be requested — at `preferred`, which an authenticator without it simply
    // declines, leaving a perfectly good root.
    expect(ext?.largeBlob?.support).toBe("preferred");
    for (const value of Object.values(ext ?? {})) {
      expect(value?.support).not.toBe("required");
    }
    // §4 rejected PRF outright: the missing field is a VERIFICATION KEY, not an identifier, and
    // credential_id is already a stable id on every assertion.
    expect(ext?.prf).toBeUndefined();
  });

  test("an assertion is restricted to exactly one credential", () => {
    // §10.1: "Restrict the request to that candidate's credential ID via `allowCredentials`."
    const credentialId = new Uint8Array([1, 2, 3, 4]);
    const options = rootAssertionOptions({
      rpId: "rdev.example", credentialId, challenge: new Uint8Array(32),
    });
    expect(options.allowCredentials).toHaveLength(1);
    expect(new Uint8Array(options.allowCredentials![0]!.id as ArrayBuffer)).toEqual(credentialId);
    expect(options.userVerification).toBe("required");
    expect(options.rpId).toBe("rdev.example");
  });
});

describe("the CBOR subset", () => {
  test("decodes what WebAuthn uses", () => {
    expect(decodeCbor(new Uint8Array([0x00]))!.value).toBe(0);
    expect(decodeCbor(new Uint8Array([0x17]))!.value).toBe(23);
    expect(decodeCbor(new Uint8Array([0x18, 0x64]))!.value).toBe(100);
    expect(decodeCbor(new Uint8Array([0x19, 0x01, 0x00]))!.value).toBe(256);
    expect(decodeCbor(new Uint8Array([0x20]))!.value).toBe(-1);
    expect(decodeCbor(new Uint8Array([0x38, 0x63]))!.value).toBe(-100);
    expect(decodeCbor(new Uint8Array([0x42, 1, 2]))!.value).toEqual(new Uint8Array([1, 2]));
    expect(decodeCbor(new Uint8Array([0x63, 0x61, 0x62, 0x63]))!.value).toBe("abc");
    expect(decodeCbor(new Uint8Array([0x82, 0x01, 0x02]))!.value).toEqual([1, 2]);
    const map = decodeCbor(new Uint8Array([0xa1, 0x01, 0x02]))!.value as Map<unknown, unknown>;
    expect(map.get(1)).toBe(2);
  });

  test("refuses what it was never asked to understand", () => {
    // Tags, floats, indefinite lengths and 64-bit arguments are REFUSED rather than skipped: none
    // appears in an attestation object, and tolerating them means interpreting bytes an
    // authenticator — or something pretending to be one — chose.
    expect(decodeCbor(new Uint8Array([0xc0, 0x00]))).toBeNull();          // tag
    expect(decodeCbor(new Uint8Array([0xf5]))).toBeNull();                // true
    expect(decodeCbor(new Uint8Array([0xbf, 0xff]))).toBeNull();          // indefinite map
    expect(decodeCbor(new Uint8Array([0x1b, 0, 0, 0, 0, 0, 0, 0, 1]))).toBeNull(); // 64-bit
    expect(decodeCbor(new Uint8Array([0x42, 1]))).toBeNull();             // truncated byte string
    expect(decodeCbor(new Uint8Array([]))).toBeNull();
  });

  test("refuses a duplicate map key", () => {
    // Two decoders can disagree about which copy wins, so the bytes are ambiguous — the same rule
    // §10.4 applies to clientDataJSON.
    expect(decodeCbor(new Uint8Array([0xa2, 0x01, 0x02, 0x01, 0x03]))).toBeNull();
  });

  test("refuses invalid UTF-8 in a text string rather than replacing it", () => {
    expect(decodeCbor(new Uint8Array([0x62, 0xff, 0xfe]))).toBeNull();
  });
});

describe("the root-check pre-image", () => {
  const rootId = new Uint8Array(32).fill(0x11);
  const random = new Uint8Array(32).fill(0x22);

  // `verifyAssertion` takes the PRE-IMAGE and hashes it itself, which is why the discovery helper
  // returns one. Splitting this the same way is what lets §10.1's local root check be verified by
  // the very same verifier a DISCOVERED root goes through, rather than by a second path.
  test("the challenge is the hash of the pre-image", async () => {
    const preimage = rootCheckPreimage(rootId, random)!;
    const challenge = rootCheckChallenge(rootId, random)!;
    const digest = new Uint8Array(
      await crypto.subtle.digest("SHA-256", preimage as BufferSource));
    expect([...challenge]).toEqual([...digest]);
  });

  // §10.1 SPECIFIES these bytes. Refactoring the helper must not move them.
  test("the challenge bytes are unchanged by the split", () => {
    const challenge = rootCheckChallenge(rootId, random);
    expect(challenge).not.toBeNull();
    expect(challenge!.length).toBe(32);
    // The label is what stops a root check being replayed as a grant or a revocation, so it has to
    // be IN the pre-image rather than merely implied by the caller.
    const preimage = rootCheckPreimage(rootId, random)!;
    expect(new TextDecoder().decode(preimage.slice(2, 2 + 22)))
      .toBe("rdev-e2e/root-check/v1");
  });

  test("both refuse a wrong-sized root id or randomness", () => {
    expect(rootCheckPreimage(new Uint8Array(31), random)).toBeNull();
    expect(rootCheckPreimage(rootId, new Uint8Array(16))).toBeNull();
    expect(rootCheckChallenge(new Uint8Array(31), random)).toBeNull();
  });
});

describe("the large blob the authenticator may carry", () => {
  // §4: `"preferred"`, NEVER `"required"`. Required fails CREATION outright on an authenticator
  // without largeBlob — which would make signing up impossible on hardware perfectly able to hold
  // the root. §10.1 is explicit that no extension is required.
  test("creation asks for a blob without demanding one", () => {
    const options = rootCreationOptions({
      rpId: "example.com", rpName: "Xpromptvs", userId: new Uint8Array(16),
      userName: "example.com", challenge: new Uint8Array(32),
    });
    const ext = options.extensions as { largeBlob?: { support?: string } } | undefined;
    expect(ext?.largeBlob?.support).toBe("preferred");
    expect(ext?.largeBlob?.support).not.toBe("required");
  });

  // A WRITE requires `allowCredentials` to name exactly one credential — with `[]` the platform
  // answers NotSupportedError. Measured against a Chromium virtual authenticator 2026-09-14, and
  // the reason the write rides the grant assertion rather than the discovery one.
  test("an assertion carrying a blob still names exactly one credential", () => {
    const options = rootAssertionOptions({
      rpId: "example.com", credentialId: new Uint8Array(20).fill(1),
      challenge: new Uint8Array(32), writeBlob: new Uint8Array(115).fill(2),
    });
    expect(options.allowCredentials).toHaveLength(1);
    const ext = options.extensions as { largeBlob?: { write?: ArrayBufferView } } | undefined;
    expect(ext?.largeBlob?.write?.byteLength).toBe(115);
  });

  test("and an assertion with no blob asks for no extension at all", () => {
    const options = rootAssertionOptions({
      rpId: "example.com", credentialId: new Uint8Array(20).fill(1),
      challenge: new Uint8Array(32),
    });
    expect((options.extensions as { largeBlob?: unknown } | undefined)?.largeBlob).toBeUndefined();
  });

  // A READ works discoverably, which is what lets discovery ask without naming anything.
  test("discovery asks for the blob and still names no credential", () => {
    const options = discoveryAssertionOptions({
      rpId: "example.com", challenge: new Uint8Array(32),
    });
    expect(options.allowCredentials).toEqual([]);
    expect((options.extensions as { largeBlob?: { read?: boolean } })?.largeBlob?.read).toBe(true);
  });
});
