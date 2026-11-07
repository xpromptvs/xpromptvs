import {
  DIRECTORY_CHALLENGE_LENGTH, PUBLISH_DEADLINE_SECONDS, directoryRequestBody,
  rootId as hashRoot, signEd25519, type DirectoryAction, type DirectorySession,
} from "@rdev/protocol";
import { base64urlDecode, base64urlEncode } from "./base64url";
import { workerFetch } from "./worker-fetch";

/**
 * **§12.2's directory, from the browser — the signed replacement for the account listing.**
 *
 * A browser that holds a chain under a root can ask which Macs in that identity are sharing right
 * now. The authorisation is the one `register` already used: a one-use 32-byte Worker challenge, a
 * request body signed by this device's own key, and a chain the Worker verifies under the root in
 * the route. There is no bearer token, and the Worker learns a root id rather than a person.
 * `docs/superpowers/specs/2026-09-13-passkey-only-identity.md`.
 *
 * **`list` IS SIGNED, and that is not symmetry for its own sake.** Every row carries a room `code`
 * and `token` — what a peer needs to reach the signalling room at all — so an unauthenticated
 * listing would hand every live room to anyone who learned a root id. §11's gate would still refuse
 * them, but "the gate holds" is not a reason to publish the door.
 *
 * **A LISTING IS A HINT.** §4 puts the Worker inside the adversary model and §12.2 is explicit that
 * absence from the directory is never revocation. A row is an invitation to try a room; §11 decides
 * whether anything is behind it, so the worst a hostile listing costs is a failed connection.
 */
export interface DirectoryIdentity {
  /** The §10.1 root descriptor this device trusts. */
  root: Uint8Array;
  /** This device's own §10.4 bundle — the chain the Worker verifies. */
  bundle: Uint8Array;
  signingPrivateKey: Uint8Array;
}

/**
 * **Put this device's own grant in the directory — which is what makes its root DISCOVERABLE.**
 *
 * The Worker indexes `credential_id -> root descriptor` when a `DirectoryDO` first learns its root,
 * and it learns it from a `register` or a `publish`. Only the Mac ever did either, so a browser that
 * created an identity and enrolled was invisible to discovery from any OTHER browser: the same
 * passkey, offered by the same authenticator, answered "no identity is registered for that passkey
 * yet" — measured 2026-09-14, and the reason this exists.
 *
 * **BEST EFFORT, BOUNDED, AND NEVER A PRECONDITION** (§12.2). A failed registration costs discovery
 * from a second browser; it costs this browser nothing, so it must never fail an enrollment.
 *
 * `operationId` is the LEAF GRANT'S OWN, not a fresh one: §12.2 makes registration idempotent on
 * `(root_id, operation_id)`, so re-sending the same grant under the same id returns the stored
 * record instead of a conflict — which is what lets a browser enrolled before this existed heal
 * itself by simply trying again.
 */
export async function registerDirectoryGrant (
  base: string, identity: DirectoryIdentity, operationId: Uint8Array,
  fetcher: typeof fetch = workerFetch(),
): Promise<boolean> {
  const rootId = hashRoot(identity.root);
  const at = `${base}/directory/${base64urlEncode(rootId)}`;

  const challenge = await post(fetcher, `${at}/challenge`);
  const encoded = typeof challenge?.challenge === "string" ? challenge.challenge : null;
  const challengeBytes = encoded === null ? null : base64urlDecode(encoded);
  if (!challengeBytes || challengeBytes.length !== DIRECTORY_CHALLENGE_LENGTH) return false;

  const fields = signDirectoryRequest("register", challengeBytes, identity, operationId,
                                      identity.bundle);
  if (!fields) return false;

  const answer = await post(fetcher, `${at}/register`, { ...fields, challenge: encoded as string });
  return answer?.status === "registered";
}

/** Null on ANY unhappy answer, because a caller can do exactly one thing with all of them. */
export async function listDirectorySessions(
  base: string, identity: DirectoryIdentity,
  fetcher: typeof fetch = workerFetch(),
  random: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n)),
): Promise<DirectorySession[] | null> {
  const rootId = hashRoot(identity.root);
  const at = `${base}/directory/${base64urlEncode(rootId)}`;

  const challenge = await post(fetcher, `${at}/challenge`);
  const encoded = typeof challenge?.challenge === "string" ? challenge.challenge : null;
  const challengeBytes = encoded === null ? null : base64urlDecode(encoded);
  if (!challengeBytes || challengeBytes.length !== DIRECTORY_CHALLENGE_LENGTH) return null;

  // `list` signs an EMPTY payload: there is nothing to describe, and the one-use challenge is what
  // makes the request fresh.
  const fields = signDirectoryRequest("list", challengeBytes, identity, random(32),
                                      new Uint8Array(0));
  if (!fields) return null;

  const answer = await post(fetcher, `${at}/list`, { ...fields, challenge: encoded as string });
  return parseSessionRows(answer?.sessions);
}

/// §12.2's signed request fields, for ANY action. `register`, `list` and `subscribe`
/// (`directory-watch.ts`) all build theirs here, so they can never sign differently.
export function signDirectoryRequest (
  action: DirectoryAction, challenge: Uint8Array, identity: DirectoryIdentity,
  operationId: Uint8Array, payload: Uint8Array,
): { bundle: string; operation_id: string; signature: string } | null {
  const body = directoryRequestBody(action, challenge, hashRoot(identity.root), operationId, payload);
  if (!body) return null;
  return {
    bundle: base64urlEncode(identity.bundle),
    operation_id: base64urlEncode(operationId),
    signature: base64urlEncode(signEd25519(body, identity.signingPrivateKey)),
  };
}

/// Every field checked, and a row missing one is DROPPED rather than defaulted: a session with no
/// token is a door with no key, and showing it offers a name behind nothing that can connect.
/// Null when `v` is not an array at all — the listing did not answer.
export function parseSessionRows (v: unknown): DirectorySession[] | null {
  if (!Array.isArray(v)) return null;
  return v.flatMap((row) => {
    if (!row || typeof row !== "object") return [];
    const r = row as Record<string, unknown>;
    if (typeof r.code !== "string" || r.code === "") return [];
    if (typeof r.token !== "string" || r.token === "") return [];
    if (typeof r.label !== "string" || typeof r.device_id !== "string") return [];
    return [{ code: r.code, token: r.token, label: r.label, device_id: r.device_id }];
  });
}

/**
 * **BOUNDED, for the reason §12.2 gives about publication**: a request that is neither answered nor
 * refused has not failed, and without a deadline a silent Worker holds a person in front of a
 * spinner for as long as it likes.
 */
async function post(fetcher: typeof fetch, url: string,
                    body?: Record<string, string>): Promise<Record<string, unknown> | null> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), PUBLISH_DEADLINE_SECONDS * 1000);
  try {
    const res = await fetcher(url, {
      method: "POST", signal: abort.signal,
      ...(body ? { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {}),
    });
    if (!res.ok) return null;
    return await res.json() as Record<string, unknown>;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}
