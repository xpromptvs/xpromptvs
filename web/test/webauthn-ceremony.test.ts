import { afterEach, describe, expect, test, vi } from "vitest";
import fixture from "../../protocol/fixtures/webauthn.json";
import { parseRoot, rootDiscoveryPreimage } from "@rdev/protocol";
import { assertRoot, createRoot, discoverRoot, rootCheck } from "../src/client/webauthn-ceremony";

// The DOM glue around `navigator.credentials`, driven by a FAKE AUTHENTICATOR built from the same
// synthetic vectors the protocol suite parses.
//
// **WHAT THIS CANNOT ESTABLISH:** that a real authenticator returns bytes of this shape. The fake
// returns exactly what the fixture says, so a device that behaves differently would break in
// production with every test here green. That gap needs a passkey and a person; see `docs/e2e.md`.
// What these tests DO cover is the part that is ours — request shape, response handling, and the
// two refusals §10.1 and §10.4 require after the ceremony has already succeeded.
interface Case {
  name: string; expect: "ok" | "refuse"; attestation_object: string;
  credential_id?: string; public_key?: string; flags?: number;
}
const fx = fixture as unknown as { rp_id: string; cases: Case[] };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const toHex = (u: Uint8Array): string => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");
const good = fx.cases.find((c) => c.expect === "ok")!;
const config = { rpId: fx.rp_id, rpName: "Xpromptvs" };

const bytes = (u: Uint8Array): ArrayBuffer =>
  u.buffer.slice(u.byteOffset, u.byteOffset + u.byteLength) as ArrayBuffer;

/// What a browser actually throws: a `DOMException` whose NAME carries the meaning. A plain `Error`
/// is named "Error", which is why the fake's old `new Error("NotAllowedError")` never exercised the
/// classification at all — the message is not the name.
const thrown = (kind: boolean | string): DOMException =>
  new DOMException("refused", typeof kind === "string" ? kind : "NotAllowedError");

/// Install a fake `navigator.credentials`. Returns the options the ceremony actually asked for, so
/// a test can assert the REQUEST as well as the response handling.
function fakeAuthenticator(opts: {
  attestationObject?: Uint8Array;
  assertion?: { rawId: Uint8Array; clientDataJSON: Uint8Array; authenticatorData: Uint8Array;
                signature: Uint8Array };
  /** `true` throws WebAuthn's ambiguous `NotAllowedError`; a string throws that DOMException name. */
  reject?: boolean | string;
  absent?: boolean;
} = {}): { asked: Array<Record<string, unknown>> } {
  const asked: Array<Record<string, unknown>> = [];
  if (opts.absent) {
    vi.stubGlobal("PublicKeyCredential", undefined);
    return { asked };
  }
  vi.stubGlobal("PublicKeyCredential", class {});
  vi.stubGlobal("navigator", {
    credentials: {
      // BOTH methods, always. A fake offering only the one under test would hide whether
      // `available` checks the right one — which is exactly the bug it did hide.
      async create(request: { publicKey: Record<string, unknown> }) {
        asked.push(request.publicKey);
        if (opts.reject) throw thrown(opts.reject);
        return {
          response: {
            attestationObject: bytes(opts.attestationObject ?? hex(good.attestation_object)),
          },
        };
      },
      async get(request: { publicKey: Record<string, unknown> }) {
        asked.push(request.publicKey);
        if (opts.reject) throw thrown(opts.reject);
        const a = opts.assertion!;
        return {
          rawId: bytes(a.rawId),
          response: {
            clientDataJSON: bytes(a.clientDataJSON),
            authenticatorData: bytes(a.authenticatorData),
            signature: bytes(a.signature),
          },
        };
      },
    },
  });
  return { asked };
}

afterEach(() => { vi.unstubAllGlobals(); });

describe("creating a root", () => {
  test("produces a §10.1 root descriptor naming the registered credential", async () => {
    fakeAuthenticator();
    const result = await createRoot(config, "isaac", new Uint8Array(16));
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const parsed = parseRoot(result.value.root)!;
    expect(parsed).not.toBeNull();
    expect(parsed.rpId).toBe(fx.rp_id);
    expect(toHex(parsed.credentialId)).toBe(good.credential_id);
    expect(toHex(parsed.publicKey)).toBe(good.public_key);
  });

  test("asks for exactly what §10.1 and §10.4 require", () => {
    const { asked } = fakeAuthenticator();
    return createRoot(config, "isaac", new Uint8Array(16)).then(() => {
      const options = asked[0]! as Record<string, any>;
      expect(options.pubKeyCredParams).toEqual([{ type: "public-key", alg: -7 }]);
      expect(options.authenticatorSelection.residentKey).toBe("required");
      expect(options.authenticatorSelection.userVerification).toBe("required");
      expect(options.attestation).toBe("none");
      expect(new Uint8Array(options.challenge as ArrayBuffer).length).toBe(32);
    });
  });

  test("two ceremonies use different challenges", async () => {
    const { asked } = fakeAuthenticator();
    await createRoot(config, "isaac", new Uint8Array(16));
    await createRoot(config, "isaac", new Uint8Array(16));
    expect(toHex(new Uint8Array(asked[0]!.challenge as ArrayBuffer)))
      .not.toBe(toHex(new Uint8Array(asked[1]!.challenge as ArrayBuffer)));
  });

  // §10.4: "Require `userVerification: \"required\"`" — which is only a REQUEST at ceremony time.
  // The flag is the part that can be checked afterwards, and an authenticator that ignored the
  // request would otherwise hand back a root nobody verified a user for.
  test("a ceremony that did not verify the user is refused after the fact", async () => {
    // The attestation object is perfectly well formed — the PARSER accepts it — and the UV flag is
    // clear. §10.4 requires user verification, and `required` at request time is only a request:
    // an authenticator may ignore it, and the flag is the part that can be checked afterwards.
    const noUv = fx.cases.find((c) => c.name === "registration/no-user-verification")!;
    fakeAuthenticator({ attestationObject: hex(noUv.attestation_object) });
    const result = await createRoot(config, "isaac", new Uint8Array(16));
    expect(result.ok ? "ok" : result.failure).toBe("user-verification");
  });

  test("a response carrying nothing usable is malformed, not a UV failure", async () => {
    // Paired with the case above: two different refusals that must not collapse into one.
    const refused = fx.cases.find((c) => c.name === "refuse/no-attested-credential-data")!;
    fakeAuthenticator({ attestationObject: hex(refused.attestation_object) });
    const result = await createRoot(config, "isaac", new Uint8Array(16));
    expect(result.ok ? "ok" : result.failure).toBe("malformed");
  });

  // **WHAT WEBAUTHN WILL AND WILL NOT TELL US.** `NotAllowedError` is the deliberate catch-all for
  // cancelled, timed out and nothing-matched: a page must not learn whether a credential exists. So
  // this is as fine-grained as the platform allows, and a dismissal is where the interface stops
  // reporting faults and simply waits.
  test("a dismissed prompt is `dismissed`, whatever actually dismissed it", async () => {
    for (const name of ["NotAllowedError", "AbortError", "TimeoutError"]) {
      fakeAuthenticator({ reject: name });
      const result = await createRoot(config, "isaac", new Uint8Array(16));
      expect(result.ok ? "ok" : result.failure, name).toBe("dismissed");
    }
  });

  // A NAMED refusal is a different thing to put in front of a person: something is wrong, and
  // silently returning them to the form would hide it.
  test("a refusal the browser NAMED keeps its name", async () => {
    for (const name of ["SecurityError", "NotSupportedError", "InvalidStateError"]) {
      fakeAuthenticator({ reject: name });
      const result = await createRoot(config, "isaac", new Uint8Array(16));
      expect(result.ok ? "ok" : result.failure, name).toBe(`refused/${name}`);
    }
  });

  // An error with no name is NOT a dismissal: "something went wrong and I cannot say what" is worth
  // showing, and returning to the form would hide a real defect.
  test("an unnameable error is a refusal, not a dismissal", async () => {
    vi.stubGlobal("PublicKeyCredential", class {});
    vi.stubGlobal("navigator", { credentials: { async create() { throw "a string"; },
                                                async get() { throw "a string"; } } });
    const result = await createRoot(config, "isaac", new Uint8Array(16));
    expect(result.ok ? "ok" : result.failure).toBe("refused/unknown");
  });

  test("no WebAuthn at all is reported as unsupported, not declined", async () => {
    fakeAuthenticator({ absent: true });
    const result = await createRoot(config, "isaac", new Uint8Array(16));
    expect(result.ok ? "ok" : result.failure).toBe("unsupported");
  });
});

describe("asserting", () => {
  const credentialId = hex(good.credential_id!);
  const assertion = {
    rawId: credentialId,
    clientDataJSON: new TextEncoder().encode('{"type":"webauthn.get"}'),
    authenticatorData: new Uint8Array(37).fill(3),
    signature: new Uint8Array(70).fill(4),
  };

  test("encodes §10.4's assertion from what came back", async () => {
    fakeAuthenticator({ assertion });
    const result = await assertRoot(config, credentialId, new Uint8Array(32));
    expect(result.ok ? "ok" : result.failure).toBe("ok");
    if (!result.ok) return;
    // LP(credential_id) || LP(clientDataJSON) || LP(authenticatorData) || LP(signature)
    const expected = 2 + credentialId.length + 2 + assertion.clientDataJSON.length
                   + 2 + assertion.authenticatorData.length + 2 + assertion.signature.length;
    expect(result.value.length).toBe(expected);
  });

  test("restricts the request to one credential", async () => {
    const { asked } = fakeAuthenticator({ assertion });
    await assertRoot(config, credentialId, new Uint8Array(32));
    const options = asked[0]! as Record<string, any>;
    expect(options.allowCredentials).toHaveLength(1);
    expect(toHex(new Uint8Array(options.allowCredentials[0].id as ArrayBuffer)))
      .toBe(good.credential_id);
    expect(options.userVerification).toBe("required");
  });

  // §10.1: "**reject an assertion returning any other credential ID**." `allowCredentials` is a
  // request, and an authenticator may answer with something else — accepting it would adopt an
  // identity the caller never selected.
  test("an assertion for a DIFFERENT credential is refused", async () => {
    fakeAuthenticator({ assertion: { ...assertion, rawId: new Uint8Array(16).fill(0xEE) } });
    const result = await assertRoot(config, credentialId, new Uint8Array(32));
    expect(result.ok ? "ok" : result.failure).toBe("malformed");
  });

  // THE REGRESSION GUARD for a bug this suite created and then hid. `available()` originally
  // checked `credentials.create` on every path, so `assertRoot` reported `unsupported` wherever
  // only `get` existed — and the fake above provides both methods, so nothing noticed. A capability
  // check must ask about the capability being used.
  test("asserting needs only `get`, not `create`", async () => {
    vi.stubGlobal("PublicKeyCredential", class {});
    vi.stubGlobal("navigator", {
      credentials: {
        async get() {
          return { rawId: bytes(credentialId), response: {
            clientDataJSON: bytes(assertion.clientDataJSON),
            authenticatorData: bytes(assertion.authenticatorData),
            signature: bytes(assertion.signature),
          } };
        },
      },
    });
    const result = await assertRoot(config, credentialId, new Uint8Array(32));
    expect(result.ok ? "ok" : result.failure).toBe("ok");
  });

  test("a response missing any field is refused rather than partly encoded", async () => {
    fakeAuthenticator({ assertion });
    vi.stubGlobal("navigator", {
      credentials: {
        async create() { return null; },
        async get() {
          return { rawId: bytes(credentialId),
                   response: { clientDataJSON: bytes(new Uint8Array(4)) } };
        },
      },
    });
    const result = await assertRoot(config, credentialId, new Uint8Array(32));
    expect(result.ok ? "ok" : result.failure).toBe("malformed");
  });
});

describe("§10.1's local root check", () => {
  const credentialId = hex(good.credential_id!);

  test("the challenge is bound to the root being adopted", async () => {
    const { asked } = fakeAuthenticator({
      assertion: {
        rawId: credentialId,
        clientDataJSON: new Uint8Array(8), authenticatorData: new Uint8Array(37),
        signature: new Uint8Array(70),
      },
    });
    const rootId = new Uint8Array(32).fill(5);
    const result = await rootCheck(config, rootId, credentialId);
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    // The challenge the authenticator was asked to sign is the one the caller gets back — which is
    // what lets the caller verify against the candidate it FROZE, and nothing else.
    expect(toHex(new Uint8Array(asked[0]!.challenge as ArrayBuffer)))
      .toBe(toHex(result.value.challenge));
    expect(result.value.challenge.length).toBe(32);
  });

  test("two checks of the same root differ", async () => {
    fakeAuthenticator({
      assertion: {
        rawId: credentialId, clientDataJSON: new Uint8Array(8),
        authenticatorData: new Uint8Array(37), signature: new Uint8Array(70),
      },
    });
    const rootId = new Uint8Array(32).fill(5);
    const a = await rootCheck(config, rootId, credentialId);
    const b = await rootCheck(config, rootId, credentialId);
    expect(a.ok && b.ok).toBe(true);
    if (!a.ok || !b.ok) return;
    // Fresh randomness per §10.1, so a captured assertion cannot be replayed as a later check.
    expect(toHex(a.value.challenge)).not.toBe(toHex(b.value.challenge));
  });
});

// §10.1's usernameless discovery. The ceremony that runs BEFORE anything is known: no credential to
// restrict to, no root to bind the challenge to, and nothing decided here at all.
describe("discovering", () => {
  const credentialId = hex(good.credential_id!);
  const assertion = {
    rawId: credentialId,
    clientDataJSON: new TextEncoder().encode('{"type":"webauthn.get"}'),
    authenticatorData: new Uint8Array(37).fill(3),
    signature: new Uint8Array(70).fill(4),
  };

  // **THE PRE-IMAGE IS THE CALLER'S NOW**, which is what lets signing in cost one prompt: a caller
  // that hands in §10.4's grant commitment gets an assertion that is simultaneously the answer to
  // "which passkey?" and the signature its grant is made of. A caller with nothing to sign passes
  // `rootDiscoveryPreimage`'s output and learns only the identity.
  const PREIMAGE = rootDiscoveryPreimage(new Uint8Array(32).fill(0x5A))!;

  test("asks for ANY discoverable credential, user-verified", async () => {
    const { asked } = fakeAuthenticator({ assertion });
    await discoverRoot(config, PREIMAGE);
    const options = asked[0]! as Record<string, any>;
    // Present and EMPTY. An omitted list is equivalent in the specification and has been read in
    // the field as "no credential permitted" rather than "any".
    expect(options.allowCredentials).toEqual([]);
    expect(options.userVerification).toBe("required");
    expect(options.rpId).toBe(fx.rp_id);
  });

  // §17.1 requires the candidate material to be frozen before the assertion, and a caller can only
  // be held to that if it is handed back the bytes the ceremony actually ran with.
  test("hashes the caller's pre-image into the challenge, and hands it back unchanged", async () => {
    const { asked } = fakeAuthenticator({ assertion });
    const result = await discoverRoot(config, PREIMAGE);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const challenge = new Uint8Array((asked[0]! as Record<string, any>).challenge as ArrayBuffer);
    const digest = new Uint8Array(
      await crypto.subtle.digest("SHA-256", PREIMAGE as BufferSource));
    expect(toHex(digest)).toBe(toHex(challenge));
    expect(toHex(result.value.preimage), "the caller's own bytes, not substituted")
      .toBe(toHex(PREIMAGE));
  });

  // **Freshness is the CALLER'S now**, and this is the observable half: two different pre-images
  // must reach the authenticator as two different challenges, or a caller could not make a ceremony
  // fresh even by trying.
  test("a different pre-image is a different challenge", async () => {
    const { asked } = fakeAuthenticator({ assertion });
    const other = rootDiscoveryPreimage(new Uint8Array(32).fill(0xA5))!;
    await discoverRoot(config, PREIMAGE);
    await discoverRoot(config, other);
    const [a, b] = asked.map((o) =>
      toHex(new Uint8Array((o as Record<string, any>).challenge as ArrayBuffer)));
    expect(a).not.toBe(b);
  });

  // Nothing about the pre-image's SHAPE is this function's business: it hashes what it is given.
  // That is the whole reason one caller can pass a discovery label and another a grant commitment.
  test("refuses an empty pre-image, which could only be a caller bug", async () => {
    fakeAuthenticator({ assertion });
    const result = await discoverRoot(config, new Uint8Array(0));
    expect(result.ok ? "ok" : result.failure).toBe("malformed");
  });

  // **The mirror image of `assertRoot`'s refusal, and it must NOT be copied here.** That one rejects
  // a credential the caller did not name; this one named none, so whatever came back was offered
  // legitimately. The rule reappears in `verifyDiscoveredRoot`, against the descriptor.
  test("whatever credential answers is the one reported", async () => {
    const other = new Uint8Array(16).fill(0xEE);
    fakeAuthenticator({ assertion: { ...assertion, rawId: other } });
    const result = await discoverRoot(config, PREIMAGE);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(toHex(result.value.credentialId)).toBe(toHex(other));
  });

  test("a dismissed prompt and an empty authenticator are one outcome", async () => {
    fakeAuthenticator({ assertion, reject: true });
    const result = await discoverRoot(config, PREIMAGE);
    expect(result.ok ? "ok" : result.failure).toBe("dismissed");
  });

  test("no WebAuthn at all is unsupported, not declined", async () => {
    fakeAuthenticator({ absent: true });
    const result = await discoverRoot(config, PREIMAGE);
    expect(result.ok ? "ok" : result.failure).toBe("unsupported");
  });
});
