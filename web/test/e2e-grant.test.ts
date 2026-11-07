import { describe, expect, test } from "vitest";
import fixture from "../../protocol/fixtures/e2e-identity.json";
import { IssuerKind, grantCommitmentPreimage, type Binding } from "@rdev/protocol";
import { issueDirectGrant, type DirectGrantRequest } from "../src/lib/e2e-grant";
import type { CeremonyConfig, CeremonyResult } from "../src/client/webauthn-ceremony";

/**
 * **§12.1's direct grant, and the two things about it that are now parameters.**
 *
 * Both were hardcoded while §12.1 was the only issuer: capabilities `7`, and a LOCAL binding because
 * a passkey ceremony has no Noise transcript to name. Adopt-by-code issues the same grant at
 * capability `2` inside a live handshake, so what this file measures is that a caller's choice
 * reaches the bytes the passkey signs — not merely the object handed in.
 *
 * **It measures the CHALLENGE, which is the whole point.** §10.4's challenge is
 * `H(grant_commitment)`, so if a parameter were dropped the challenge would differ and a grant would
 * be signed that says something the caller did not ask for. The implementation builds that
 * commitment by parsing its own grant back and projecting it; this test builds it from the parts,
 * through `grantCommitmentPreimage`. Two different constructions have to agree, which is stronger
 * than either checked against itself.
 *
 * The stub assertion is not a real one, so `verifyBundle` — the last step, and a real check — fails
 * with `unverified`. That is asserted rather than worked around: it proves everything up to the
 * signature ran, and the guard is still in place for the callers that pass a real authenticator.
 */

interface Case { name: string; kind: string; encoded?: string; id?: string;
                 root_public_key?: string; credential_id?: string;
                 signing_public_key?: string; noise_public_key?: string; }

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const caseNamed = (name: string): Case =>
  (fixture.cases as Case[]).find((c) => c.name === name)!;

const ROOT_CASE = caseNamed("root");
const DEVICE_CASE = caseNamed("device");
const OPERATION = new Uint8Array(32).fill(0xb0);
/** Deterministic, because the binding's randomness is the one value a test must pin. */
const fill = (b: number) => (n: number) => new Uint8Array(n).fill(b);

const REMOTE: Binding = {
  kind: "remote",
  handshakeHash: new Uint8Array(32).fill(0xd0),
  responderDeviceId: new Uint8Array(32).fill(0xd1),
};

function request (): DirectGrantRequest {
  return {
    config: { rpId: "rdev.example", rpName: "Xpromptvs" } as CeremonyConfig,
    origin: "https://rdev.example",
    root: hex(ROOT_CASE.encoded!),
    credentialId: hex(ROOT_CASE.credential_id!),
    device: hex(DEVICE_CASE.encoded!),
    operationId: OPERATION,
  };
}

/** What §10.4 says the passkey must be asked to sign, built from the parts. */
async function expectedChallenge (capabilities: number, binding: Binding): Promise<Uint8Array> {
  const preimage = grantCommitmentPreimage({
    operationId: OPERATION, issuerKind: IssuerKind.Root,
    signingPublicKey: hex(DEVICE_CASE.signing_public_key!),
    noisePublicKey: hex(DEVICE_CASE.noise_public_key!),
    capabilities, binding,
  })!;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", preimage as BufferSource));
}

/** Captures what the ceremony was asked to sign. Returns a stub, so `verifyBundle` still refuses. */
function capturing () {
  const seen: { challenge?: Uint8Array } = {};
  const assert = async (_c: CeremonyConfig, _id: Uint8Array, challenge: Uint8Array)
    : Promise<CeremonyResult<Uint8Array>> => {
    seen.challenge = challenge;
    return { ok: true, value: new Uint8Array(64).fill(9) };
  };
  return { seen, assert: assert as never };
}

describe("issueDirectGrant", () => {
  test("defaults to capability 7 and a fresh LOCAL binding", async () => {
    const { seen, assert } = capturing();
    const res = await issueDirectGrant(request(), assert, fill(0xaa));

    expect(seen.challenge).toEqual(await expectedChallenge(
      7, { kind: "local", randomness: new Uint8Array(32).fill(0xaa) }));
    // The stub is not an assertion, so the real verification at the end still refuses it.
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.failure.kind).toBe("unverified");
  });

  test("signs the capability it is given", async () => {
    const { seen, assert } = capturing();
    await issueDirectGrant({ ...request(), capabilities: 2 }, assert, fill(0xaa));
    expect(seen.challenge).toEqual(await expectedChallenge(
      2, { kind: "local", randomness: new Uint8Array(32).fill(0xaa) }));
  });

  test("signs the REMOTE binding it is given, verbatim", async () => {
    const { seen, assert } = capturing();
    await issueDirectGrant({ ...request(), capabilities: 2, binding: REMOTE }, assert, fill(0xaa));
    expect(seen.challenge).toEqual(await expectedChallenge(2, REMOTE));
  });

  // A capability the caller chose and a binding it did not would be the quietest way to get this
  // wrong: the grant would be for the right device, inside the right handshake, and say so nowhere.
  test("capability and binding travel together, not one or the other", async () => {
    const { seen, assert } = capturing();
    await issueDirectGrant({ ...request(), capabilities: 2, binding: REMOTE }, assert, fill(0xaa));
    expect(seen.challenge).not.toEqual(await expectedChallenge(7, REMOTE));
    expect(seen.challenge).not.toEqual(await expectedChallenge(
      2, { kind: "local", randomness: new Uint8Array(32).fill(0xaa) }));
  });
});
