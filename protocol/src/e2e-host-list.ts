/// Turning a Control Plane's list of live hosts into something a person may be shown.
///
/// **THE LIST IS EVIDENCE OF NOTHING.** §4 puts the Control Plane inside the adversary model and
/// §9.2 is explicit that "addresses and room tokens confer no E2E authority" — so every field here
/// arrives from M and every one of them is a claim. This turns those claims into three answers a
/// caller can act on: which rows can be connected to at all, which names are vouched for, and which
/// are merely asserted.
///
/// **IT DECIDES NOTHING ABOUT ACCESS.** A row surviving this is a row worth offering; whether the
/// peer at the other end is who it claims is settled by the handshake (§11.1's expected-peer check)
/// and by §13. What this exists to stop is narrower and entirely about the human: being shown a
/// name that the directory chose.
import { verifyDeviceLabel, type DeviceLabelFailure } from "./e2e-device-label";
import { parseBundle } from "./e2e-certificate";
import { parseRoot, rootId as hashRoot } from "./e2e-identity";
import type { E2EPolicy } from "./e2e-verify";

/// The shape the account layer publishes, named structurally so this package does not depend on the
/// control plane's types. Every field is optional except the routing, because a deployment without
/// E2E identity publishes none of them.
export interface ListedHost {
  name: string;
  code: string;
  token: string;
  e2eDeviceId?: string;
  label?: string;
  labelSignature?: string;
  labelSignerBundle?: string;
}

export type NameSource =
  /** The name came from a label this endpoint verified against its own trusted root. */
  | "verified"
  /**
   * The name came from the directory and nothing vouches for it. **A caller MUST mark it** — §10.1's
   * residual is about exactly this: a name "the same adversary chose".
   */
  | "unverified";

export interface ReviewedHost {
  code: string;
  token: string;
  /** The name to show. */
  displayName: string;
  nameSource: NameSource;
  /** Present only when the row carries a usable `e2eDeviceId`. */
  deviceId: Uint8Array | null;
  /**
   * **A row with no device id cannot be selected.** §11.1 requires that "a selected Host's
   * `device_id` must also match the selection", and a selection with nothing to match is not one —
   * so a caller that offered this row could never make the check that makes the offer safe.
   */
  connectable: boolean;
  /** Why the label was not used, when it was not. Null when there was no label to reject. */
  labelFailure: DeviceLabelFailure | null;
  /**
   * The directory's own `name` field disagreed with the verified label.
   *
   * Not a refusal — the verified name simply wins — but it is the directory caught saying something
   * a signature contradicts, and a caller with somewhere to put that should say so.
   */
  nameContested: boolean;
}

export interface ReviewOptions {
  trustedRootId: Uint8Array;
  policy: E2EPolicy;
  revokedDeviceIds?: readonly Uint8Array[];
}

const fromB64u = (value: string | undefined): Uint8Array | null => {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const bin = atob(value.replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
};

/// Review one row.
export function reviewHost (host: ListedHost, opts: ReviewOptions): ReviewedHost {
  const deviceId = fromB64u(host.e2eDeviceId);
  const base: ReviewedHost = {
    code: host.code,
    token: host.token,
    displayName: host.name,
    nameSource: "unverified",
    deviceId: deviceId !== null && deviceId.length === 32 ? deviceId : null,
    connectable: deviceId !== null && deviceId.length === 32,
    labelFailure: null,
    nameContested: false,
  };
  if (!base.deviceId) return base;

  const body = fromB64u(host.label);
  const signature = fromB64u(host.labelSignature);
  const signerBundle = fromB64u(host.labelSignerBundle);
  // A partial label is no label. Three fields that only mean anything together, so a row carrying
  // two of them is a row whose name is unvouched-for — not one to half-believe.
  if (!body || !signature || !signerBundle) return base;

  const verified = verifyDeviceLabel({
    body, signature, signerBundle,
    expectedDeviceId: base.deviceId,
    trustedRootId: opts.trustedRootId,
    policy: opts.policy,
    revokedDeviceIds: opts.revokedDeviceIds ?? [],
  });
  if (!verified.ok) return { ...base, labelFailure: verified.failure };

  return {
    ...base,
    displayName: verified.label.name,
    nameSource: "verified",
    // The verified name WINS; this records that the directory said otherwise.
    nameContested: verified.label.name !== host.name,
  };
}

/// Review a whole listing, preserving order.
///
/// **Nothing is dropped.** A caller that only wanted connectable rows could filter, but a row
/// silently missing from a list is indistinguishable from a device that is not running — and §12.2
/// is emphatic that absence must never be read as a verdict. Rows come back marked, not removed.
export const reviewHosts = (hosts: readonly ListedHost[], opts: ReviewOptions): ReviewedHost[] =>
  hosts.map((h) => reviewHost(h, opts));

/**
 * The distinct identities a listing OFFERS to join, for a device that holds none yet.
 *
 * **A LISTING IS NOT AUTHORITY, AND THIS DOES NOT PRETEND OTHERWISE.** Every byte here comes from a
 * Control Plane §4 places inside the adversary model, so these are candidates a person is asked
 * about — §10.1's "MUST name the identity being adopted before the device commits to it".
 *
 * What makes that ask safe rather than merely honest is what happens NEXT: joining means asserting
 * the root's passkey, on this origin. A substituted root is one of two things. Either its credential
 * is not registered here — and the ceremony simply fails, because the browser cannot produce an
 * assertion for a credential it does not have — or it IS registered here, on this origin, by this
 * person, in which case it is their own. **The worst a hostile listing can do is offer the wrong one
 * of a person's own identities**, which is why naming it still matters and why nothing else does.
 *
 * Ordered by how many rows presented each root, descending, then by first appearance — so the
 * identity most of a person's Macs agree on is the one offered first. Ties keep listing order rather
 * than sorting by id, because a stable order a person can recognise beats a canonical one.
 */
export interface RootCandidate {
  /** The root descriptor, exactly as it appeared. Parse-checked, verified by nothing. */
  root: Uint8Array;
  rootId: Uint8Array;
  /** How many listed rows presented this identity. */
  presentedBy: number;
}

export function rootCandidates (hosts: readonly ListedHost[]): RootCandidate[] {
  const seen = new Map<string, { candidate: RootCandidate; order: number }>();
  for (const [index, host] of hosts.entries()) {
    const bundleBytes = fromB64u(host.labelSignerBundle);
    if (!bundleBytes) continue;
    const parsed = parseBundle(bundleBytes);
    if (!parsed.ok) continue;
    // Parsed, not verified: a root descriptor that does not decode cannot be named to anybody, and
    // one that does is still only a candidate.
    if (!parseRoot(parsed.bundle.root)) continue;
    const id = hashRoot(parsed.bundle.root);
    const key = [...id].map((b) => b.toString(16).padStart(2, "0")).join("");
    const existing = seen.get(key);
    if (existing) {
      existing.candidate.presentedBy++;
      continue;
    }
    seen.set(key, {
      candidate: { root: parsed.bundle.root, rootId: id, presentedBy: 1 },
      order: index,
    });
  }
  return [...seen.values()]
    .sort((a, b) => b.candidate.presentedBy - a.candidate.presentedBy || a.order - b.order)
    .map((e) => e.candidate);
}
