import {
  assertion as encodeAssertion, discoveryAssertionOptions, parseAttestedCredential,
  rootAssertionOptions, rootCheckPreimage, rootCreationOptions, root as rootDescriptor,
} from "@rdev/protocol";
import { base64urlEncode } from "../lib/base64url";

/// The four lines that actually talk to `navigator.credentials`, and nothing else.
///
/// **THIS FILE IS THE PART THAT CANNOT BE TESTED HERE**, which is exactly why it is this small.
/// Everything decidable without a browser — building the request, parsing CBOR and COSE, deriving
/// the root descriptor, verifying an assertion — lives in `@rdev/protocol` and is held to fixtures.
/// What remains is the call itself and the shape of what a real authenticator returns, and no
/// fixture can establish that: it needs a passkey and a person. See `docs/e2e.md`.
///
/// Nothing here decides anything. It gathers bytes; §10.1 and §10.4's rules are applied by the
/// verifier, against the same bytes, on whichever side is entitled to decide.

/// Everything §10.1's root descriptor needs, plus the flags the ceremony actually ran under.
export interface RegisteredRoot {
  /// `root = LP("rdev-e2e/root/v1") || LP(rp_id) || LP(credential_id) || root_public_key`
  root: Uint8Array;
  credentialId: Uint8Array;
  publicKey: Uint8Array;
  flags: number;
}

export interface CeremonyConfig {
  rpId: string;
  rpName: string;
}

export type CeremonyFailure =
  /** The browser has no WebAuthn, or it is unavailable in this context (an insecure origin). */
  | "unsupported"
  /**
   * **The prompt closed without a credential, and nothing is wrong.** Cancelled, timed out, or the
   * authenticator held nothing that matched — WebAuthn reports all three as `NotAllowedError` ON
   * PURPOSE, because telling them apart would reveal whether a credential exists for this relying
   * party to a page that has no business knowing. So this is as fine-grained as the platform allows,
   * and a caller must not invent a reason it cannot have.
   *
   * What it IS good for is the only distinction that matters to a person: a dismissal is a decision,
   * so the interface returns to the form rather than reporting a fault (`afterFailure`).
   */
  | "dismissed"
  /**
   * The browser or the authenticator refused, and NAMED the reason — `SecurityError`,
   * `NotSupportedError`, `InvalidStateError`. Something is genuinely wrong and a person needs to
   * see it, which is exactly what `dismissed` must not be turned into.
   */
  | `refused/${string}`
  /** Something came back and it was not what was asked for. */
  | "malformed"
  /** §10.4: user verification is REQUIRED, and `required` at request time is only a request. */
  | "user-verification";

/**
 * Which of the two a thrown ceremony is.
 *
 * **THE CATCH USED TO COLLAPSE BOTH INTO ONE**, citing §14's "errors never offer an automatic
 * 'continue anyway' trust override". That rule was over-applied: it is about never letting a person
 * past a FAILED VERIFICATION, and it says nothing about how to word a prompt somebody dismissed.
 * Telling a dismissal from a refusal bypasses no check — it decides whether the interface shows a
 * fault or simply waits.
 *
 * DUCK-TYPED on `name` rather than `instanceof DOMException`, for the reason `buffer()` below gives:
 * the Web IDL classes are undefined where WebAuthn is not implemented, and a cross-realm exception
 * fails `instanceof` anyway.
 *
 * An error with no name is `refused/unknown`, NOT a dismissal: "something went wrong and I cannot
 * say what" is worth showing, and silently returning to the form would hide a real defect.
 */
function classify (error: unknown): CeremonyFailure {
  const name = typeof (error as { name?: unknown } | null)?.name === "string"
    ? (error as { name: string }).name : "";
  // `AbortError` is an `AbortSignal` this code never passes — a navigation, in practice. `Timeout
  // Error` is rare because WebAuthn folds timeouts into `NotAllowedError`. Neither is a fault, and
  // both leave the form as the right place to be.
  if (name === "NotAllowedError" || name === "AbortError" || name === "TimeoutError") {
    return "dismissed";
  }
  return `refused/${name === "" ? "unknown" : name}`;
}

export type CeremonyResult<T> = { ok: true; value: T } | { ok: false; failure: CeremonyFailure };

const UV_FLAG = 0x04;

/// Pull an `ArrayBuffer` field out of a credential response.
///
/// **DUCK-TYPED, NOT `instanceof AuthenticatorAttestationResponse`.** The deciding reason is that
/// the Web IDL classes are undefined wherever WebAuthn is not implemented, so `instanceof` there is
/// a `ReferenceError` rather than a false — and a capability check that throws is worse than one
/// that answers.
///
/// The secondary reason is cross-realm identity, and it is weaker than an earlier version of this
/// comment claimed: it has bitten this project only in TEST environments (`fake-indexeddb`, and a
/// vitest `TextEncoder`), while `e2e/installation-store-check.mjs` measured real Chromium and WebKit
/// returning same-realm objects. Kept because a field that is there and is bytes is the fact we
/// need, and asking for that costs nothing.
function buffer(source: unknown, field: string): Uint8Array | null {
  if (source === null || typeof source !== "object") return null;
  const value: unknown = (source as Record<string, unknown>)[field];
  if (ArrayBuffer.isView(value)) {
    const view = value as ArrayBufferView;
    return new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
  }
  // NOT `value instanceof ArrayBuffer` — same reason as above, and it bit again here: a buffer
  // produced in another realm (a test helper's `TextEncoder`, an iframe) reports
  // `[object ArrayBuffer]` and fails `instanceof`. The brand check is the one that describes the
  // value rather than where it was made.
  if (Object.prototype.toString.call(value) === "[object ArrayBuffer]") {
    return new Uint8Array(value as ArrayBuffer);
  }
  return null;
}

/// `method` is the one about to be called, not both. The first version always checked `create`,
/// which made `assertRoot` report `unsupported` in any environment providing only `get` — harmless
/// in a browser, where both exist, and exactly wrong in the one place it was observable.
function available(method: "create" | "get"): boolean {
  if (typeof globalThis.PublicKeyCredential === "undefined") return false;
  if (typeof navigator === "undefined") return false;
  const credentials = navigator.credentials as unknown as Record<string, unknown> | undefined;
  return typeof credentials?.[method] === "function";
}

/// §12.1: "The first device creates or authenticates a root passkey." The challenge is not bound to
/// anything: a registration proves possession of nothing yet, and the credential it produces is the
/// trust anchor rather than a statement about one. Randomness keeps the ceremony fresh.
export async function createRoot(config: CeremonyConfig, userName: string,
                                 userId: Uint8Array): Promise<CeremonyResult<RegisteredRoot>> {
  if (!available("create")) return { ok: false, failure: "unsupported" };
  const challenge = new Uint8Array(32);
  crypto.getRandomValues(challenge);

  let credential: Credential | null;
  try {
    credential = await navigator.credentials.create({
      publicKey: rootCreationOptions({
        rpId: config.rpId, rpName: config.rpName, userId, userName, challenge,
      }),
    });
  } catch (error) {
    return { ok: false, failure: classify(error) };
  }
  // A null credential with no throw is not something any browser does; treated as a dismissal
  // because there is nothing to name.
  if (!credential) return { ok: false, failure: "dismissed" };

  const attestationObject = buffer((credential as PublicKeyCredential).response,
                                   "attestationObject");
  if (!attestationObject) return { ok: false, failure: "malformed" };
  const attested = parseAttestedCredential(attestationObject);
  if (!attested) return { ok: false, failure: "malformed" };
  // §10.4 requires user verification, and the request-time `required` is only a request — the flag
  // is the part that can be checked afterwards.
  if ((attested.flags & UV_FLAG) === 0) return { ok: false, failure: "user-verification" };

  const root = rootDescriptor(config.rpId, attested.credentialId, attested.publicKey);
  if (!root) return { ok: false, failure: "malformed" };
  return { ok: true, value: { root, credentialId: attested.credentialId,
                              publicKey: attested.publicKey, flags: attested.flags } };
}

/// A WebAuthn assertion over `challenge`, encoded as §10.4's `assertion`.
///
/// Used for a grant (`challenge = H(grant_commitment)` — §10.4's projection, which names no
/// root), a revocation (`H(revocation)`) and §10.1's local
/// root check — all three are this call with a different challenge, and only their LABEL keeps them
/// apart, which is why the challenge is computed by the caller and never here.
export async function assertRoot(config: CeremonyConfig, credentialId: Uint8Array,
                                 challenge: Uint8Array,
                                 writeBlob?: Uint8Array): Promise<CeremonyResult<Uint8Array>> {
  if (!available("get")) return { ok: false, failure: "unsupported" };

  let credential: Credential | null;
  try {
    credential = await navigator.credentials.get({
      publicKey: rootAssertionOptions({ rpId: config.rpId, credentialId, challenge,
                                        ...(writeBlob ? { writeBlob } : {}) }),
    });
  } catch (error) {
    return { ok: false, failure: classify(error) };
  }
  if (!credential) return { ok: false, failure: "dismissed" };

  const assertion = credential as PublicKeyCredential;
  const clientDataJSON = buffer(assertion.response, "clientDataJSON");
  const authenticatorData = buffer(assertion.response, "authenticatorData");
  const signature = buffer(assertion.response, "signature");
  const returned = buffer(assertion, "rawId");
  if (!clientDataJSON || !authenticatorData || !signature || !returned) {
    return { ok: false, failure: "malformed" };
  }

  // §10.1: "**reject an assertion returning any other credential ID**". `allowCredentials` is a
  // request; an authenticator may answer with a different credential, and accepting one would adopt
  // an identity the caller never selected.
  if (returned.length !== credentialId.length
      || !returned.every((b, i) => b === credentialId[i])) {
    return { ok: false, failure: "malformed" };
  }

  // **`largeBlob.written` IS DELIBERATELY NOT INSPECTED.** §4: the write is best-effort, the same
  // shape as §12.2's publication, which "is best-effort and not a precondition for access". An
  // authenticator that declined the blob has still produced the assertion that was asked for, and
  // failing a grant over a storage hint would trade the thing that matters for the one that does not.
  const encoded = encodeAssertion(returned, clientDataJSON, authenticatorData, signature);
  return encoded ? { ok: true, value: encoded } : { ok: false, failure: "malformed" };
}

/// **Ask the authenticator which roots it holds, and prove one.**
///
/// §10.1's root is a discoverable credential, which is what makes this possible: with an empty
/// `allowCredentials` the browser offers every passkey it has for this relying party — including one
/// on a phone, over the platform's cross-device flow — and the person picks. There is no username,
/// no email and no account, which is the entire replacement for OAuth sign-in
/// (`docs/superpowers/specs/2026-09-13-passkey-only-identity.md`).
///
/// **What comes back is a credential id and a signature, and NOT a public key.** WebAuthn returns
/// one only at creation, so a browser that has never held this identity cannot build the §10.1
/// descriptor from the ceremony alone. The missing field is fetched from the Control Plane and the
/// signature returned here is what pins it — `verifyDiscoveredRoot`, never this function, decides
/// whether the answer may be adopted. **Nothing here decides anything**, exactly as the rest of this
/// file does not.
///
/// **THE PRE-IMAGE IS THE CALLER'S**, and that is what makes signing in one prompt rather than two.
/// A caller that hands in §10.4's grant commitment gets an assertion which is simultaneously the
/// answer to "which passkey?" and the signature its grant is made of. A caller with nothing to sign
/// passes `rootDiscoveryPreimage`'s output and learns only the identity.
///
/// It is returned again alongside the assertion because §17.1 requires the candidate material to be
/// frozen before the ceremony, and handing back the exact bytes the ceremony ran with is the only
/// way to hold a caller to that.
export async function discoverRoot(config: CeremonyConfig, preimage: Uint8Array):
  Promise<CeremonyResult<{ credentialId: Uint8Array; preimage: Uint8Array; assertion: Uint8Array;
                           blob: Uint8Array | null }>> {
  if (!available("get")) return { ok: false, failure: "unsupported" };
  if (preimage.length === 0) return { ok: false, failure: "malformed" };

  const challenge = new Uint8Array(
    await crypto.subtle.digest("SHA-256", preimage as BufferSource));

  let credential: Credential | null;
  try {
    credential = await navigator.credentials.get({
      publicKey: discoveryAssertionOptions({ rpId: config.rpId, challenge }),
    });
  } catch (error) {
    // A dismissed prompt, a timeout, and an authenticator holding no credential for this relying
    // party remain ONE outcome — `NotAllowedError` for all three, by design, so that a page cannot
    // learn whether a credential exists. What IS separable is a named refusal, and `classify` is
    // where that line is drawn.
    return { ok: false, failure: classify(error) };
  }
  if (!credential) return { ok: false, failure: "dismissed" };

  const assertion = credential as PublicKeyCredential;
  const clientDataJSON = buffer(assertion.response, "clientDataJSON");
  const authenticatorData = buffer(assertion.response, "authenticatorData");
  const signature = buffer(assertion.response, "signature");
  const returned = buffer(assertion, "rawId");
  if (!clientDataJSON || !authenticatorData || !signature || !returned) {
    return { ok: false, failure: "malformed" };
  }

  // **NO CREDENTIAL-ID EQUALITY CHECK HERE, AND THAT IS NOT AN OMISSION.** §10.1's "reject an
  // assertion returning any other credential ID" is enforceable only by a caller that NAMED one;
  // this ceremony named none, so whatever the authenticator returned was legitimately offered. The
  // rule reappears one step later, inverted: the descriptor claimed for this credential must contain
  // exactly these bytes, and `verifyDiscoveredRoot` is where that is decided.
  // §4: the descriptor the authenticator may be carrying. A missing extension, an empty answer and
  // a non-buffer are ALL the same thing — no blob — and none of them is a failure: an authenticator
  // without largeBlob answers this assertion exactly as it always did. `buffer()` reads it the same
  // way as every other field here, for the cross-realm reason given above.
  //
  // **Nothing here decides whether it may be believed.** These are bytes anyone holding the
  // credential could have written; `verifyDiscoveredRoot` is what pins them, exactly as it pins the
  // Worker's answer.
  //
  // DUCK-TYPED on the METHOD as well, for `available()`'s reason: a real `PublicKeyCredential`
  // always has `getClientExtensionResults`, but this file's rule is that a capability check must
  // answer rather than throw, and "the method is not there" lands on the same answer every other
  // absence does — no blob.
  const extensions = (assertion as unknown as
    { getClientExtensionResults?: () => { largeBlob?: { blob?: unknown } } });
  const results = typeof extensions.getClientExtensionResults === "function"
    ? extensions.getClientExtensionResults()
    : undefined;
  const blob = results?.largeBlob === undefined ? null : buffer(results.largeBlob, "blob");

  const encoded = encodeAssertion(returned, clientDataJSON, authenticatorData, signature);
  if (!encoded) return { ok: false, failure: "malformed" };
  return { ok: true, value: { credentialId: returned, preimage, assertion: encoded, blob } };
}

/// §10.1's local root check: prove the authenticator still holds a candidate credential, before
/// trusting a root descriptor that came from anywhere but local state.
///
/// **THE CANDIDATE IS FROZEN BEFORE THE CALL** — §10.1 and §17.1 both require it: "freeze the
/// candidate key before the assertion and verify before exposing the proof. Replacing the candidate
/// after signature creation must fail." Here that is structural: the caller passes the exact
/// descriptor it intends to adopt, and this returns the evidence FOR THAT descriptor. Verification
/// is the caller's, against the frozen candidate and nothing else.
export async function rootCheck(config: CeremonyConfig, rootId: Uint8Array,
                                credentialId: Uint8Array):
  Promise<CeremonyResult<{ challenge: Uint8Array; preimage: Uint8Array; assertion: Uint8Array }>> {
  const random = new Uint8Array(32);
  crypto.getRandomValues(random);
  // The PRE-IMAGE is returned beside the challenge because `verifyAssertion` hashes it itself —
  // which is what lets a caller put this through the same `verifyDiscoveredRoot` a discovered root
  // goes through, rather than inventing a second verification path for the local case.
  const preimage = rootCheckPreimage(rootId, random);
  if (!preimage) return { ok: false, failure: "malformed" };
  const challenge = new Uint8Array(
    await crypto.subtle.digest("SHA-256", preimage as BufferSource));

  const assertion = await assertRoot(config, credentialId, challenge);
  if (!assertion.ok) return assertion;
  // §10.1: "do not transmit the assertion or allow replacement of the candidate before
  // verification." Returned to the caller, never sent anywhere by this function.
  return { ok: true, value: { challenge, preimage, assertion: assertion.value } };
}

/// **Tell the credential provider that this relying party does not recognise a credential — which
/// on Apple platforms DELETES IT, silently and permanently.**
///
/// Measured 2026-09-14, Safari 26.6: `undefined` back in 250 ms, no throw, no prompt of any kind,
/// and the passkey gone from iCloud Keychain. **There is no platform safety net**, so the
/// confirmation is the application's and the caller had better be certain. Every grant under a root
/// dies with its credential, because §10.1's public key existed only at creation.
///
/// The ONE caller that can be certain is `discardPendingRoot`: a descriptor this browser created,
/// never committed, and never registered. **A `404` from the credential index is not certainty** —
/// that index is best-effort, so a root in daily use on a Mac answers exactly as a stranded one
/// does, and §12.2's "absence MUST NOT be read as revocation" has teeth here.
///
/// `credentialId` is base64url per the Signal API, not a buffer.
export type SignalOutcome = "signalled" | "unsupported" | `failed/${string}`;

export async function signalUnknownCredential(rpId: string,
                                              credentialId: Uint8Array): Promise<SignalOutcome> {
  if (!canSignalUnknownCredential()) return "unsupported";
  try {
    await (globalThis.PublicKeyCredential as unknown as {
      signalUnknownCredential: (o: { rpId: string; credentialId: string }) => Promise<void>;
    }).signalUnknownCredential({ rpId, credentialId: base64urlEncode(credentialId) });
    return "signalled";
  } catch (error) {
    const name = typeof (error as { name?: unknown } | null)?.name === "string"
      ? (error as { name: string }).name : "unknown";
    return `failed/${name}`;
  }
}

/// Duck-typed for `available()`'s reason: a capability check must answer rather than throw, and the
/// Web IDL classes are undefined wherever WebAuthn is not implemented. Synchronous on purpose — the
/// interface uses it to decide whether to OFFER a destructive button, and a button that appears
/// after a round trip is a button somebody clicks by accident.
export function canSignalUnknownCredential(): boolean {
  if (typeof globalThis.PublicKeyCredential === "undefined") return false;
  return typeof (globalThis.PublicKeyCredential as unknown as Record<string, unknown>)
    .signalUnknownCredential === "function";
}
