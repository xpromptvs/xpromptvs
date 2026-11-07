/// §12.2's directory contract — the bytes a device signs to mutate the directory, what a publication
/// attempt's outcome means, and the rules that stop one peer's ignorance overwriting another's
/// knowledge.
///
/// Mirror of `RdevCore.E2EDirectory` (Swift).
///
/// **PUBLICATION IS BEST-EFFORT WITH A BOUNDED WAIT; IT IS NOT A PRECONDITION FOR ACCESS.** §12.2
/// flags that as "a deliberate policy change from an earlier revision ... and it should be recognised
/// as such rather than read as a cleanup". Cryptographically the old rule added nothing — M can claim
/// any grant is registered or that none is — but it did give the account list the property of being a
/// COMPLETE view of who had access. That completeness is what was traded away, for availability.
///
/// PURE. No HTTP, no storage, no clock: a caller supplies the outcome it observed and this decides
/// what it means, which is the part two implementations must agree on.
import { sha256 } from "@noble/hashes/sha2.js";
import { E2E_ID_LENGTH, E2EReader, PublicationStatus, lengthPrefixed } from "./e2e-wire";

/// §12.2: "a fresh, one-use 32-byte Worker challenge, valid for at most 120 seconds."
export const DIRECTORY_CHALLENGE_LENGTH = 32;
export const DIRECTORY_CHALLENGE_MAX_AGE_SECONDS = 120;

/// §12.2's bounded wait on publication, and on the revocation fetch.
///
/// **BOUNDED IS THE WHOLE POINT, not "failure does not block".** A request that is neither answered
/// nor refused has not failed, and without a deadline it stalls activation for as long as M cares to
/// stay silent — precisely the denial of service that not blocking on failure was meant to avoid.
export const PUBLISH_DEADLINE_SECONDS = 5;
export const REVOKE_DEADLINE_SECONDS = 5;

const DIRECTORY_LABEL = "rdev-e2e/directory/v1";

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);
const lp = (s: string): Uint8Array => lengthPrefixed(utf8(s))!;
const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

/// §12.2 names one — `register`. Root revocation is NOT here: "the WebAuthn-signed
/// revocation itself authorizes an idempotent submission and needs no device authority", so it is
/// not signed with a device key and does not use this body at all.
///
/// **The other three are rdev's, and they are what replaces OAuth accounts.** Session discovery used
/// to hang off a Google identity and a bearer token; it hangs off the root a device already belongs
/// to, authorised exactly the way `register` is — a one-use Worker challenge and a body signed by a
/// device key whose chain verifies under that root. There is no bearer token to steal and the Worker
/// learns a root id rather than a person.
/// `docs/superpowers/specs/2026-09-13-passkey-only-identity.md`.
///
/// **`list` is signed too, and that is not symmetry for its own sake.** A published session carries
/// the room `code` and `token`, which is what a peer needs to reach the signalling room at all — so
/// an unauthenticated listing would hand every live room to anyone who learned a root id. §11 would
/// still refuse them, but "the gate holds" is not a reason to publish the door.
export type DirectoryAction = "register" | "publish" | "unpublish" | "list" | "subscribe";

/// Every action, for a caller that needs to reject an unknown one rather than guess.
export const DIRECTORY_ACTIONS: readonly DirectoryAction[] =
  ["register", "publish", "unpublish", "list", "subscribe"];

export const isDirectoryAction = (v: unknown): v is DirectoryAction =>
  typeof v === "string" && (DIRECTORY_ACTIONS as readonly string[]).includes(v);

/// **A live Host, as the directory carries it.** The `code` and `token` are the existing pairing
/// pair, so everything after selection is the pairing-code path that already exists — which is what
/// keeps `SessionDO` and the signalling wire format out of this entirely.
///
/// `label` is what a person reads. §10.4's SIGNED device labels are the trustworthy version of a
/// name and this is not one: it is a convenience the publishing device asserts about itself, and a
/// directory-supplied name is one "the same adversary chose". Present it as a hint, never as proof.
export interface DirectorySession {
  code: string;
  token: string;
  label: string;
  /// The publishing device, so a listing can say WHICH Mac and a client can pin `expectedResponder`.
  device_id: string;
}

/// The bytes `publish` signs over. Canonical and minimal: a JSON encoder's key order is not a
/// contract, and two implementations that disagree about it produce a signature neither can check.
export function directorySessionPayload (s: DirectorySession): Uint8Array | null {
  const parts = [s.code, s.token, s.label, s.device_id].map((v) => lengthPrefixed(utf8(v)));
  if (parts.some((p) => p === null)) return null;
  return concat(lp("rdev-e2e/directory-session/v1"), ...(parts as Uint8Array[]));
}

/// `LP("rdev-e2e/directory/v1") || LP(action) || challenge || root_id || operation_id || H(payload)`
///
/// The payload is HASHED, not carried: the body is a fixed size whatever the bundle's size (161
/// bytes for `register`), and the Worker compares the hash against the bundle it actually received.
export function directoryRequestBody (action: DirectoryAction, challenge: Uint8Array,
                                      rootId: Uint8Array, operationId: Uint8Array,
                                      payload: Uint8Array): Uint8Array | null {
  if (challenge.length !== DIRECTORY_CHALLENGE_LENGTH) return null;
  if (rootId.length !== E2E_ID_LENGTH || operationId.length !== E2E_ID_LENGTH) return null;
  return concat(lp(DIRECTORY_LABEL), lp(action), challenge, rootId, operationId, sha256(payload));
}

export interface DirectoryRequest {
  action: DirectoryAction;
  challenge: Uint8Array;
  rootId: Uint8Array;
  operationId: Uint8Array;
  payloadHash: Uint8Array;
}

export function parseDirectoryRequestBody (bytes: Uint8Array): DirectoryRequest | null {
  const r = new E2EReader(bytes);
  if (!r.expectLabel(DIRECTORY_LABEL)) return null;
  const actionBytes = r.lengthPrefixed();
  const challenge = r.take(DIRECTORY_CHALLENGE_LENGTH);
  const rootId = r.take(E2E_ID_LENGTH);
  const operationId = r.take(E2E_ID_LENGTH);
  const payloadHash = r.take(E2E_ID_LENGTH);
  if (!actionBytes || !challenge || !rootId || !operationId || !payloadHash || !r.atEnd) return null;
  let action: string;
  try {
    action = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(actionBytes);
  } catch {
    return null;
  }
  // **EVERY action this body is defined for, not only `register`.** An earlier version hardcoded
  // that one, which made the parser and `directoryRequestBody` disagree about the vocabulary: a
  // perfectly well-formed `publish` body round-tripped to null. Nothing depended on it at the time,
  // which is exactly why it survived.
  if (!isDirectoryAction(action)) return null;
  return { action, challenge, rootId, operationId, payloadHash };
}

// ------------------------------------------------------- what a publication attempt meant

/// What the endpoint observed when it tried to publish. Modelled as cases rather than a bare status
/// code because **a 409 means opposite things depending on its content**, and an API taking only a
/// number would make that distinction impossible to state.
export type DirectoryResponse =
  /** The Worker acknowledged the registration. */
  | { kind: "acknowledged" }
  /** Nothing came back: timeout, connection refused, DNS or TLS failure, or the deadline expired. */
  | { kind: "no-reply" }
  /** A `409` under the same operation ID carrying the SAME content — the idempotent success path. */
  | { kind: "conflict-same-content" }
  /** A `409` under the same operation ID carrying DIFFERENT content — terminal. */
  | { kind: "conflict-different-content" }
  /** Any other HTTP status. */
  | { kind: "http"; status: number };

/// §12.2's transient/terminal table. The two categories differ in RETRY POLICY, not in what they
/// prove about the directory.
export function classifyPublication (response: DirectoryResponse): PublicationStatus {
  switch (response.kind) {
    case "acknowledged":
    case "conflict-same-content":
      return PublicationStatus.Confirmed;
    case "no-reply":
      return PublicationStatus.Unconfirmed;
    case "conflict-different-content":
      return PublicationStatus.Rejected;
    case "http": {
      const code = response.status;
      if (code >= 200 && code <= 299) return PublicationStatus.Confirmed;
      // **404 IS TRANSIENT**, which looks wrong and is not: §12.2 lists it explicitly because "a
      // deployment may be in progress". A 404 from a Worker mid-deploy is an outage, not a refusal,
      // and treating it as terminal would pause a job a retry would complete.
      if (code === 404 || code === 429 || (code >= 500 && code <= 599)) {
        return PublicationStatus.Unconfirmed;
      }
      // Everything else is terminal, and the transient set above is EXHAUSTIVE by design. A bare 409
      // lands here on purpose: its content was not compared, so it is not known to be the idempotent
      // path, and guessing "transient" would retry forever against a Worker that keeps saying 409.
      return PublicationStatus.Rejected;
    }
  }
}

/// §12.2's REQUIRED WORDING, quoted exactly. An interface that says "not listed" asserts an absence
/// no endpoint has established: `rejected` describes the latest ATTEMPT, and a perfectly ordinary
/// history is publication succeeding, its acknowledgement being lost, and a later retry being
/// refused. The record exists; only the retry failed.
///
/// Two rules live behind this string and neither is expressible as code:
///
/// - **`rejected` is not a verdict on the device.** M can refuse arbitrarily, and the endpoint's own
///   verification is what authorized the session.
/// - **Absence from the directory is not revocation.** "A failed request, a rejected retry, or an
///   omitted record never establishes absence" — and the tempting call site, "the list came back and
///   my grant is not in it, so I have been removed", is one line of plausible code.
export const PUBLICATION_REJECTED_WORDING =
  "Publication rejected; listing not confirmed. Action required.";

/// §12.2 obliges both the issuing endpoint and the newcomer to "surface anything other than
/// `confirmed`".
export const mustSurface = (status: PublicationStatus): boolean =>
  status !== PublicationStatus.Confirmed;

/// Transient retries "automatic, idempotent, across restarts"; terminal is "paused, pending
/// corrective action".
export const retriesAutomatically = (status: PublicationStatus): boolean =>
  status === PublicationStatus.Unconfirmed;

// -------------------------------------------------------------- §12.2's monotonic status

/// Merge a reported status into the stored one. **Status is stored per `grant_id` and is monotonic
/// toward `confirmed`.**
///
/// `reporterHoldsPublicationJob` is the rule that makes this non-trivial. `publication_status` rides
/// in EVERY `session-start`, including an ordinary `auth` to a Host that never participated in the
/// publication and holds no record of it — and §12.2 says such a Host "reports `unconfirmed`, which
/// is the truth: it does not know". **Without this parameter every connection to an unrelated Host
/// would erase what the issuing endpoint reported.**
export function mergePublicationStatus (stored: PublicationStatus | null,
                                        reported: PublicationStatus,
                                        reporterHoldsPublicationJob: boolean):
  PublicationStatus | null {
  // `confirmed` is terminal. "A later `unconfirmed` from any peer MUST NOT reset it."
  if (stored === PublicationStatus.Confirmed) return PublicationStatus.Confirmed;
  if (!reporterHoldsPublicationJob) return stored;
  return reported;
}

/// §12.2's clearing rule: "A newcomer clears its own flag when it observes its own `grant_id` in the
/// directory; a `confirmed` status is never revisited."
///
/// **AND IT NEVER COMES BACK.** The flag is a user-visibility hint, not a security control — M can
/// claim a grant is listed when it is not — so re-raising the warning because M later omits the
/// record would hand it a nuisance channel and protect nothing.
export const observedOwnGrantInDirectory = (): PublicationStatus => PublicationStatus.Confirmed;

// ----------------------------------------------------------------------------- §12.4 resume

/// The durable state a newcomer can wake up in.
export type DurableState =
  /** Keys only; no request that could commit was ever sent. */
  | "keys-only"
  /** A pending operation and a responder route, but no committed chain. */
  | "pending-operation"
  /** A committed chain, with cleanup still outstanding. */
  | "committed-cleanup-pending"
  | "committed-clean"
  /** §10.2: private-key loss "means generating new keys and enrolling again". */
  | "keys-lost";

export type NextAction =
  | { action: "fresh-enrollment" }
  | { action: "resume" }
  /** `repeatCleanup` carries §12.4's second column for the interrupted row. */
  | { action: "auth"; repeatCleanup: boolean }
  | { action: "generate-new-keys-and-enroll" };

/// §12.4's table, whole. A device that guesses here either strands a committed chain or restarts a
/// ceremony that already reserved a window.
export function nextAction (state: DurableState): NextAction {
  switch (state) {
    case "keys-only": return { action: "fresh-enrollment" };
    case "pending-operation": return { action: "resume" };
    case "committed-cleanup-pending": return { action: "auth", repeatCleanup: true };
    case "committed-clean": return { action: "auth", repeatCleanup: false };
    case "keys-lost": return { action: "generate-new-keys-and-enroll" };
  }
}
