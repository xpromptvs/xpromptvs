import {
  IssuerKind, bundle as encodeBundle, certificate as encodeCertificate,
  grant as encodeGrant, grantCommitment, parseGrant, rootId as hashRoot, verifyBundle,
  type Binding,
} from "@rdev/protocol";
import { assertRoot } from "../client/webauthn-ceremony";
import { policyFor } from "./product-origin";
import type { CeremonyConfig, CeremonyResult } from "../client/webauthn-ceremony";

/**
 * **§12.1's direct passkey grant, in one place.**
 *
 * The browser issues to ITSELF through here, and adopt-by-code issues to a Mac through here; the
 * Mac's own native ceremony mirrors these steps in Swift (`E2EPasskeyGrant`). A second copy of
 * these five steps is how two devices come to hold grants that were built differently.
 *
 * The steps are: build the grant, get an assertion over `H(grant_commitment)`, assemble the bundle,
 * and verify it. **The verification here is for the PERSON**, not for authority: it makes a failure visible to
 * whoever just touched their fingerprint reader instead of appearing as a silent refusal somewhere
 * else a moment later. The verdict that counts is the accepting device's, against state this never
 * sees.
 */

export type GrantFailure =
  /** The grant or the bundle could not be encoded — a programming error, not a runtime condition. */
  | { kind: "malformed" }
  /** The passkey prompt was dismissed, or the authenticator refused. */
  | { kind: "ceremony"; failure: string }
  /** The assembled bundle does not verify. Carries the reason, which is what a person can act on. */
  | { kind: "unverified"; failure: string };

export type GrantResult =
  | { ok: true; bundle: Uint8Array }
  | { ok: false; failure: GrantFailure };

export interface DirectGrantRequest {
  config: CeremonyConfig;
  /** The origin the assertion will be checked against — `location.origin`, never a server's word. */
  origin: string;
  /** The root descriptor this grant is issued under. */
  root: Uint8Array;
  credentialId: Uint8Array;
  /** The §10.2 descriptor being granted. It already names `root`. */
  device: Uint8Array;
  operationId: Uint8Array;
  /**
   * **Set when the caller ALREADY RAN the ceremony** — which signing in does, because the one
   * `get({ allowCredentials: [] })` that discovers the credential is the same one that signs.
   * Running a second ceremony here would be the second prompt this whole design removes.
   *
   * The binding travels with the assertion because the assertion covers it: §10.4's commitment
   * includes `LP(binding)`, so a grant rebuilt here with fresh randomness would not be the grant
   * that was signed. **One object, so the two cannot be supplied separately** — a caller holding an
   * assertion but letting the binding be regenerated would produce a bundle that fails its own
   * verification, for a reason naming neither.
   */
  preAsserted?: {
    binding: Binding;
    assertion: Uint8Array;
  };
  /**
   * §10.3's capability for this grant. **Defaults to `7`**, which is what §12.1's direct enrollment
   * means by "direct". Adopt-by-code passes `2`: a Mac that shares its screen and may do nothing
   * else. Only the four accepted values exist — `encodeGrant` refuses anything else anyway, which is
   * why this is not validated here as well.
   */
  capabilities?: 1 | 2 | 3 | 7;
  /**
   * §10.3's binding. **Defaults to a fresh LOCAL binding**, which is right for a passkey ceremony
   * with no Noise transcript to name. Adopt-by-code passes a REMOTE one: that grant is issued inside
   * a live handshake, and §10.4 has the far side check `h` and the responder's device id against its
   * own view rather than against the message's word.
   *
   * Ignored when `preAsserted` is set, which carries its own binding for the reason stated there —
   * an assertion covers `LP(binding)`, so the two cannot be chosen separately.
   */
  binding?: Binding;
}

/**
 * `assert` is injected so the whole path is testable without an authenticator; production passes
 * `assertRoot`. `random` likewise — the binding's randomness is the one value a test must pin.
 */
export async function issueDirectGrant(
  request: DirectGrantRequest,
  assert: typeof assertRoot = assertRoot,
  random: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n)),
): Promise<GrantResult> {
  const rootId = hashRoot(request.root);

  // **Root-issued always; the other two are the caller's.** §12.1's direct grant is capabilities 7
  // with a LOCAL binding — a passkey ceremony has no Noise transcript to bind to — and those are the
  // DEFAULTS here rather than facts about this function. Adopt-by-code issues capability 2 with a
  // REMOTE binding, inside a live handshake, through this same path: a second copy of these five
  // steps is how two devices come to hold grants that were built differently.
  const binding = request.preAsserted?.binding
    ?? request.binding
    ?? { kind: "local" as const, randomness: random(32) };
  const grantBytes = encodeGrant({
    rootId, operationId: request.operationId, issuerKind: IssuerKind.Root, issuerId: rootId,
    device: request.device, capabilities: request.capabilities ?? 7, binding,
  });
  if (!grantBytes) return { ok: false, failure: { kind: "malformed" } };

  // **THE PASSKEY SIGNS THE COMMITMENT, NOT THE GRANT.** §10.4's challenge is
  // `H(grant_commitment)`, a projection of the grant that names no root — which is what lets a
  // browser that has not yet learned the identity produce this challenge at all.
  //
  // Built by parsing the grant back and projecting it, rather than from the parts to hand: this is
  // the SAME function `verifyBundle` will call with the same trusted root id, so the signer and the
  // verifier cannot drift. A second construction from the same variables would agree today and be
  // free to stop agreeing later.
  const parsedGrant = parseGrant(grantBytes);
  const preimage = parsedGrant && grantCommitment(parsedGrant, rootId);
  if (!preimage) return { ok: false, failure: { kind: "malformed" } };

  let asserted: CeremonyResult<Uint8Array>;
  if (request.preAsserted) {
    // No ceremony, and NO CHALLENGE COMPUTED: the caller already ran one over this exact
    // commitment. `verifyBundle` below is what checks that claim, so a caller that signed something
    // else is refused here rather than trusted.
    asserted = { ok: true, value: request.preAsserted.assertion };
  } else {
    const challenge = new Uint8Array(
      await crypto.subtle.digest("SHA-256", preimage as BufferSource));
    // §4: the descriptor rides the assertion that was going to happen anyway. `request.root` IS the
    // descriptor, so this costs no extra ceremony and no extra prompt.
    asserted = await assert(request.config, request.credentialId, challenge, request.root);
  }
  if (!asserted.ok) return { ok: false, failure: { kind: "ceremony", failure: asserted.failure } };

  const certificate = encodeCertificate(grantBytes, asserted.value);
  const bundle = certificate ? encodeBundle(request.root, [certificate]) : null;
  if (!bundle) return { ok: false, failure: { kind: "malformed" } };

  const check = verifyBundle(bundle, {
    trustedRootId: rootId,
    policy: { rpId: request.config.rpId, allowedOrigins: policyFor(request.origin).allowedOrigins },
  });
  if (!check.ok) return { ok: false, failure: { kind: "unverified", failure: check.failure } };

  return { ok: true, bundle };
}
