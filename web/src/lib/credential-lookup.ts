import { base64urlDecode, base64urlEncode } from "./base64url";
import { workerFetch } from "./worker-fetch";

/**
 * **The one thing a discovery assertion cannot tell you: the root's public key.**
 *
 * §10.1's descriptor is `rp_id || credential_id || root_public_key`, and WebAuthn hands the key back
 * only at creation. A browser that has never held this identity therefore knows the credential id
 * and nothing else, so it asks the Control Plane what descriptor is registered under it.
 *
 * **THE ANSWER IS A HINT.** §4 puts the Worker inside the adversary model and this endpoint is no
 * exception: it may lie, it may say nothing, and it is under no obligation to be consistent.
 * `verifyDiscoveredRoot` is what makes the hint usable — the returned descriptor must name the
 * credential the authenticator just returned, carry the relying party this deployment is configured
 * for, and hold the public key the assertion verifies under. A caller that adopts what comes back
 * here without that check has trusted the Worker with the identity, which is the one thing the whole
 * protocol is built not to do.
 *
 * For the TRUST decision every unhappy answer is one — nothing registered, a refusal, a timeout,
 * junk: only `found` leads anywhere, and telling the rest apart there would tempt someone into
 * treating "the Worker said no" as evidence about the identity. §12.2 already says it is not:
 * "absence from the directory MUST NOT be read as revocation." (The Mac's native ceremony asks the
 * same route the same way, `E2ECredentialLookup`.)
 */
export const CREDENTIAL_LOOKUP_DEADLINE_MS = 5_000;

/**
 * **`absent` is told apart from `unknown` for ONE purpose**, never for the trust decision (above).
 *
 * It is for something much weaker — whether to OFFER a person the option of deleting a passkey
 * nothing appears to be using. **It is not evidence and not a verdict**: it decides whether to raise
 * the subject or stay quiet, and the person decides the rest, because they know things this code
 * cannot (whether they ever set up a Mac). A Worker that never replied has told us nothing, and
 * inviting somebody to destroy a credential on the strength of a timeout would be inviting it on the
 * strength of their Wi-Fi.
 *
 * `absent` is ONLY `credential-do.ts`'s own `404 { error: "not-found" }` — the one answer in the
 * system that means "I looked, and I hold nothing". A path that misses the route falls through to
 * the ASSETS binding, which 404s with HTML: same status, entirely different meaning.
 */
export type CredentialLookup =
  | { kind: "found"; root: Uint8Array }
  | { kind: "absent" }
  | { kind: "unknown" };

export async function credentialLookupOutcome(
  origin: string, credentialId: Uint8Array,
  fetcher: typeof fetch = workerFetch(),
): Promise<CredentialLookup> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), CREDENTIAL_LOOKUP_DEADLINE_MS);
  try {
    const res = await fetcher(`${origin}/credential/${base64urlEncode(credentialId)}`,
                              { signal: abort.signal });
    const body = await res.json().catch(() => null) as
      { root?: unknown; error?: unknown } | null;
    if (!res.ok) {
      // Both halves required. The status alone is the ASSETS binding's answer too.
      return res.status === 404 && body?.error === "not-found"
        ? { kind: "absent" }
        : { kind: "unknown" };
    }
    if (typeof body?.root !== "string") return { kind: "unknown" };
    const root = base64urlDecode(body.root);
    // A 200 carrying something that is not a descriptor is a Worker behaving oddly, which is not
    // the same as one that looked and found nothing.
    return root ? { kind: "found", root } : { kind: "unknown" };
  } catch {
    return { kind: "unknown" };
  } finally {
    clearTimeout(timer);
  }
}
