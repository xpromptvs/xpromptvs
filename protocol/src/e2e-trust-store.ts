/// §10.2's durable trust state: "Store the trusted root, own grant chain, revocation tombstones,
/// pending operations, and committed registration records durably."
///
/// Mirror of `RdevCore.E2ETrustStore` (Swift).
///
/// Separate from the installation record on purpose. **The keys and the trust are different things
/// with different lifetimes**: §10.2 binds the keys and the rendezvous seed together because
/// "reinstallation generates both anew", while the root, the chain and the tombstones are learned
/// afterwards and survive everything except a reinstall. Keeping them apart means losing trust state
/// cannot cost the device its identity, and rotating keys cannot silently keep a chain that no
/// longer describes it.
///
/// **LOCAL ONLY.** No peer parses these bytes.
import { rootId as hashRoot } from "./e2e-identity";
import { mergePublicationStatus as mergeStatus, type NextAction } from "./e2e-directory";
import { E2E_ID_LENGTH, E2EReader, PublicationStatus, bytesEqual, lengthPrefixed } from "./e2e-wire";
import type { RendezvousRoute } from "./rendezvous-seed";

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);
const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

const RECORD_LABEL = "rdev-e2e/trust/v1";
/// No status stored. Outside `PublicationStatus`'s range on purpose — §7 rejects an unsupported
/// enum value, so "absent" must not be spelled as one of the three that mean something.
export const TRUST_STATUS_ABSENT = 0xff;

/// §12.3: "persist trusted root + issuer ID + durable route + pending request" — everything a
/// `resume` needs to find the same responder and finish the same operation.
export interface PendingOperation {
  operationId: Uint8Array;
  responderDeviceId: Uint8Array;
  route: RendezvousRoute;
}

export interface TrustRecord {
  /** The §10.1 root descriptor this device trusts. **Null means no identity yet.** */
  root: Uint8Array | null;
  /** This device's own §10.4 bundle. */
  bundle: Uint8Array | null;
  /** §12.2's status for the grant in `bundle`. Meaningless without one. */
  publicationStatus: PublicationStatus | null;
  /** §10.5 tombstones, applied to BOTH peers' chains before activation, and irreversible. */
  revokedDeviceIds: Uint8Array[];
  /** An enrollment that was started and has not committed — what makes `resume` possible. */
  pending: PendingOperation | null;
}

export const emptyTrustRecord = (): TrustRecord =>
  ({ root: null, bundle: null, publicationStatus: null, revokedDeviceIds: [], pending: null });

/// §12.4's table, answered from what is actually stored rather than from a flag someone set.
///
/// **`hasKeys` is a separate argument because it lives in a separate record.** A device whose
/// installation is gone has lost its identity whatever its trust state says, and §10.2 gives that
/// exactly one answer: "generating new keys and enrolling again".
/// **Named differently from `e2e-directory`'s `nextAction` because TypeScript has no namespaces.**
/// The Swift side reaches both as `E2EDirectory.nextAction` and `E2ETrustStore.nextAction` and can
/// keep one name; here the two would collide in the package's surface. Same rule, two spellings, and
/// this comment is the only place that is visible.
export function nextActionForRecord (record: TrustRecord, hasKeys: boolean): NextAction {
  if (!hasKeys) return { action: "generate-new-keys-and-enroll" };
  if (record.bundle) {
    // §12.4 distinguishes "committed chain, cleanup pending" from "committed and clean", and a
    // pending operation beside a committed chain is exactly that cleanup.
    return { action: "auth", repeatCleanup: record.pending !== null };
  }
  if (record.pending) return { action: "resume" };
  return { action: "fresh-enrollment" };
}

// --------------------------------------------------------------------------------- encoding

export function encodeTrustRecord (record: TrustRecord): Uint8Array | null {
  const root = lengthPrefixed(record.root ?? new Uint8Array(0));
  const bundle = lengthPrefixed(record.bundle ?? new Uint8Array(0));
  if (!root || !bundle) return null;

  const parts: Uint8Array[] = [lengthPrefixed(utf8(RECORD_LABEL))!, root, bundle];
  parts.push(new Uint8Array([record.publicationStatus ?? TRUST_STATUS_ABSENT]));

  if (record.pending) {
    const p = record.pending;
    if (p.operationId.length !== E2E_ID_LENGTH) return null;
    if (p.responderDeviceId.length !== E2E_ID_LENGTH) return null;
    const rcode = lengthPrefixed(utf8(p.route.rcode));
    const rtoken = lengthPrefixed(utf8(p.route.rtoken));
    if (!rcode || !rtoken) return null;
    parts.push(new Uint8Array([1]), p.operationId, p.responderDeviceId, rcode, rtoken);
  } else {
    parts.push(new Uint8Array([0]));
  }

  // Sorted and de-duplicated, so the same set always encodes to the same bytes. A record that
  // re-serialised differently every time would make "did anything change?" unanswerable by
  // comparison, which is the cheapest check a caller has before a durable write.
  const seen = new Map<string, Uint8Array>();
  for (const id of record.revokedDeviceIds) {
    if (id.length !== E2E_ID_LENGTH) return null;
    seen.set([...id].map((b) => b.toString(16).padStart(2, "0")).join(""), id);
  }
  const tombstones = [...seen.keys()].sort().map((k) => seen.get(k)!);
  if (tombstones.length > 0xffff) return null;
  parts.push(new Uint8Array([tombstones.length >> 8, tombstones.length & 0xff]), ...tombstones);
  return concat(...parts);
}

export function decodeTrustRecord (bytes: Uint8Array): TrustRecord | null {
  const r = new E2EReader(bytes);
  if (!r.expectLabel(RECORD_LABEL)) return null;
  const root = r.lengthPrefixed();
  const bundle = r.lengthPrefixed();
  const rawStatus = r.takeByte();
  if (!root || !bundle || rawStatus === null) return null;

  let publicationStatus: PublicationStatus | null = null;
  if (rawStatus !== TRUST_STATUS_ABSENT) {
    if (!(rawStatus in PublicationStatus)) return null;   // §7: unsupported values are rejections
    publicationStatus = rawStatus as PublicationStatus;
  }

  const hasPending = r.takeByte();
  let pending: PendingOperation | null = null;
  if (hasPending === 1) {
    const operationId = r.take(E2E_ID_LENGTH);
    const responderDeviceId = r.take(E2E_ID_LENGTH);
    const rcode = r.lengthPrefixed();
    const rtoken = r.lengthPrefixed();
    if (!operationId || !responderDeviceId || !rcode || !rtoken) return null;
    const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });
    try {
      pending = { operationId, responderDeviceId,
                  route: { rcode: decoder.decode(rcode), rtoken: decoder.decode(rtoken) } };
    } catch {
      return null;
    }
  } else if (hasPending !== 0) {
    return null;
  }

  const high = r.takeByte();
  const low = r.takeByte();
  if (high === null || low === null) return null;
  const revokedDeviceIds: Uint8Array[] = [];
  for (let i = 0; i < ((high << 8) | low); i++) {
    const id = r.take(E2E_ID_LENGTH);
    if (!id) return null;
    revokedDeviceIds.push(id);
  }
  if (!r.atEnd) return null;

  return {
    root: root.length > 0 ? root : null,
    bundle: bundle.length > 0 ? bundle : null,
    publicationStatus, revokedDeviceIds, pending,
  };
}

// ------------------------------------------------------- the transitions that are rules

export type TrustFailure =
  /** §10.1: "An incoming chain is never allowed to replace an already trusted root." */
  | "root-already-trusted"
  /** A chain was offered for a root this device does not trust. */
  | "root-mismatch"
  | "no-root";

export type TrustResult =
  | { ok: true; record: TrustRecord }
  | { ok: false; failure: TrustFailure };

/// Adopt a root. **Only from nothing.** §10.1: "Switching identity requires an explicit local
/// reset/re-registration; possession of a new passkey cannot remotely replace a Host's existing
/// root." Replacing one is `resetTrust`, which discards everything and says so.
export function adoptRoot (record: TrustRecord, root: Uint8Array): TrustResult {
  if (record.root) {
    return bytesEqual(record.root, root)
      ? { ok: true, record }
      : { ok: false, failure: "root-already-trusted" };
  }
  return { ok: true, record: { ...record, root } };
}

/// Record this device's own committed chain, with the status §11.2 delivered beside it.
export function commitOwnChain (record: TrustRecord, bundle: Uint8Array,
                                status: PublicationStatus, rootId: Uint8Array): TrustResult {
  if (!record.root) return { ok: false, failure: "no-root" };
  if (!bytesEqual(hashRoot(record.root), rootId)) return { ok: false, failure: "root-mismatch" };
  // §12.3: "persist committed chain; erase pairing secret and PENDING-ONLY state." Keeping the
  // pending operation would make §12.4 answer `resume` forever, against a ceremony that finished.
  return { ok: true, record: { ...record, bundle, publicationStatus: status, pending: null } };
}

/// §12.2's monotonic merge, applied to what is stored.
/// Named `...ForRecord` for the same reason as `nextActionForRecord` above.
export function mergePublicationStatusForRecord (record: TrustRecord, reported: PublicationStatus,
                                                 reporterHoldsPublicationJob: boolean): TrustRecord {
  return {
    ...record,
    publicationStatus: mergeStatus(record.publicationStatus, reported,
                                   reporterHoldsPublicationJob),
  };
}

/// §10.5: an irreversible tombstone. Nothing here removes one.
export function revokeDevice (record: TrustRecord, deviceId: Uint8Array): TrustRecord {
  if (deviceId.length !== E2E_ID_LENGTH) return record;
  if (record.revokedDeviceIds.some((id) => bytesEqual(id, deviceId))) return record;
  return { ...record, revokedDeviceIds: [...record.revokedDeviceIds, deviceId] };
}

/// §10.1's "explicit local reset/re-registration". **Everything goes**, because a root is the anchor
/// for all of it: a chain under the old root, a pending operation against the old Issuer, and
/// tombstones naming devices of an identity this one no longer has.
///
/// Tombstones going is worth stating rather than assuming: they are irreversible WITHIN an identity
/// (§10.5), and this is the operation that ends the identity.
export const resetTrust = (): TrustRecord => emptyTrustRecord();
