import { describe, expect, test } from "vitest";
import {
  TRUST_STATUS_ABSENT, adoptRoot, commitOwnChain, decodeTrustRecord, emptyTrustRecord,
  encodeTrustRecord, mergePublicationStatusForRecord, nextActionForRecord, resetTrust, revokeDevice,
  type TrustRecord,
} from "../src/e2e-trust-store";
import { root as rootDescriptor, rootId as hashRoot } from "../src/e2e-identity";
import { PublicationStatus } from "../src/e2e-wire";

// §10.2's durable trust state. `E2ETrustStoreTests.swift` asserts the same rules.
const id = (n: number): Uint8Array => new Uint8Array(32).fill(n);
const route = { rcode: "x0WuwKuk", rtoken: "f67e21bd-9c7d-4a3b-8f21-0d4e6a1b2c3d" };
const root = (n = 1): Uint8Array =>
  rootDescriptor("rdev.example", new Uint8Array([n]),
                 new Uint8Array([0x04, ...new Uint8Array(64).fill(n)]))!;
const pending = (n = 0xb0) =>
  ({ operationId: id(n), responderDeviceId: id(0xc0), route });
const toHex = (u: Uint8Array): string => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");

describe("encoding", () => {
  test("an empty record round trips, and null is not an empty array", () => {
    const encoded = encodeTrustRecord(emptyTrustRecord())!;
    const back = decodeTrustRecord(encoded)!;
    expect(back).toEqual(emptyTrustRecord());
    // A record with no root must decode back to NO root, not a zero-length descriptor that would
    // then fail every comparison for a confusing reason.
    expect(back.root).toBeNull();
    expect(back.publicationStatus).toBeNull();
  });

  test("a full record round trips", () => {
    const record: TrustRecord = {
      root: root(), bundle: new Uint8Array([1, 2, 3]),
      publicationStatus: PublicationStatus.Rejected,
      revokedDeviceIds: [id(9), id(8)], pending: pending(),
    };
    const back = decodeTrustRecord(encodeTrustRecord(record)!)!;
    expect(toHex(back.root!)).toBe(toHex(record.root!));
    expect(back.publicationStatus).toBe(PublicationStatus.Rejected);
    expect(back.revokedDeviceIds.map(toHex).sort()).toEqual([id(8), id(9)].map(toHex).sort());
    expect(back.pending!.route).toEqual(route);
  });

  test("the encoding is stable across ordering and duplicates", () => {
    // The same set must always encode to the same bytes, or "did anything change?" stops being
    // answerable by comparison — the cheapest check a caller has before a durable write.
    const a = encodeTrustRecord({ ...emptyTrustRecord(), revokedDeviceIds: [id(1), id(2), id(3)] })!;
    const b = encodeTrustRecord({ ...emptyTrustRecord(), revokedDeviceIds: [id(3), id(1), id(2)] })!;
    const c = encodeTrustRecord({
      ...emptyTrustRecord(), revokedDeviceIds: [id(1), id(2), id(1), id(3)],
    })!;
    expect(toHex(a)).toBe(toHex(b));
    expect(toHex(a)).toBe(toHex(c));
  });

  test("a record that is not one is refused", () => {
    const good = encodeTrustRecord({
      ...emptyTrustRecord(), root: root(), bundle: new Uint8Array([1]),
      publicationStatus: PublicationStatus.Confirmed,
    })!;
    expect(decodeTrustRecord(good)).not.toBeNull();
    expect(decodeTrustRecord(new Uint8Array([...good, 0]))).toBeNull();
    expect(decodeTrustRecord(good.slice(0, -1))).toBeNull();
    expect(decodeTrustRecord(new Uint8Array(0))).toBeNull();
  });

  // The status byte is located by REBUILDING with a different status and finding the one byte that
  // moved. Indexing it by hand hit the PENDING FLAG in the first version of the Swift mirror, and
  // that test passed against a record whose status it never touched.
  test("an unknown publication status is refused, and 0xFF means absent", () => {
    const base = { ...emptyTrustRecord(), root: root() };
    const confirmed = encodeTrustRecord({ ...base, publicationStatus: PublicationStatus.Confirmed })!;
    const rejected = encodeTrustRecord({ ...base, publicationStatus: PublicationStatus.Rejected })!;
    const differing = [...confirmed].map((b, i) => [b, i] as const)
      .filter(([b, i]) => b !== rejected[i]);
    expect(differing).toHaveLength(1);
    const at = differing[0]![1];

    for (const raw of [3, 4, 0xfe]) {
      const mutated = Uint8Array.from(confirmed);
      mutated[at] = raw;
      expect(decodeTrustRecord(mutated), `status ${raw}`).toBeNull();
    }
    const absent = Uint8Array.from(confirmed);
    absent[at] = TRUST_STATUS_ABSENT;
    expect(decodeTrustRecord(absent)).not.toBeNull();
    expect(decodeTrustRecord(absent)!.publicationStatus).toBeNull();
  });

  test("an unknown pending flag is refused", () => {
    const without = encodeTrustRecord({ ...emptyTrustRecord(), root: root() })!;
    const with_ = encodeTrustRecord({ ...emptyTrustRecord(), root: root(), pending: pending() })!;
    const at = [...without].findIndex((b, i) => b !== with_[i]);
    expect(without[at]).toBe(0);
    for (const raw of [2, 3, 0xff]) {
      const mutated = Uint8Array.from(without);
      mutated[at] = raw;
      expect(decodeTrustRecord(mutated), `pending ${raw}`).toBeNull();
    }
  });
});

describe("§10.1: a trusted root is never replaced", () => {
  test("adopted only from nothing; the same one is idempotent", () => {
    const first = adoptRoot(emptyTrustRecord(), root(1));
    expect(first.ok).toBe(true);
    if (!first.ok) return;
    expect(adoptRoot(first.record, root(1)).ok).toBe(true);

    const second = adoptRoot(first.record, root(2));
    expect(second.ok ? "ok" : second.failure).toBe("root-already-trusted");
    expect(toHex(first.record.root!)).toBe(toHex(root(1)));
  });

  test("reset discards everything, tombstones included", () => {
    // Tombstones are irreversible WITHIN an identity; this is the operation that ends one.
    const after = resetTrust();
    expect(after.root).toBeNull();
    expect(after.bundle).toBeNull();
    expect(after.pending).toBeNull();
    expect(after.revokedDeviceIds).toEqual([]);
  });
});

describe("committing a chain", () => {
  test("requires the matching root", () => {
    const record = { ...emptyTrustRecord(), root: root(1) };
    const mismatch = commitOwnChain(record, new Uint8Array([1]), PublicationStatus.Confirmed,
                                    hashRoot(root(2)));
    expect(mismatch.ok ? "ok" : mismatch.failure).toBe("root-mismatch");

    const none = commitOwnChain(emptyTrustRecord(), new Uint8Array([1]),
                                PublicationStatus.Confirmed, hashRoot(root(1)));
    expect(none.ok ? "ok" : none.failure).toBe("no-root");

    const ok = commitOwnChain(record, new Uint8Array([1, 2]), PublicationStatus.Unconfirmed,
                              hashRoot(root(1)));
    expect(ok.ok).toBe(true);
    if (!ok.ok) return;
    expect(ok.record.publicationStatus).toBe(PublicationStatus.Unconfirmed);
  });

  test("clears the pending operation", () => {
    // §12.3: "erase pairing secret and PENDING-ONLY state." Keeping it would make §12.4 answer
    // `resume` forever, against a ceremony that finished.
    const record = { ...emptyTrustRecord(), root: root(), pending: pending() };
    const after = commitOwnChain(record, new Uint8Array([1]), PublicationStatus.Confirmed,
                                 hashRoot(root()));
    expect(after.ok).toBe(true);
    if (!after.ok) return;
    expect(after.record.pending).toBeNull();
  });
});

describe("status and tombstones", () => {
  test("status is monotonic toward confirmed, and an unrelated reporter is informational", () => {
    const confirmed: TrustRecord = {
      ...emptyTrustRecord(), root: root(), bundle: new Uint8Array([1]),
      publicationStatus: PublicationStatus.Confirmed,
    };
    expect(mergePublicationStatusForRecord(confirmed, PublicationStatus.Unconfirmed, true)
      .publicationStatus).toBe(PublicationStatus.Confirmed);

    const rejected: TrustRecord = { ...confirmed, publicationStatus: PublicationStatus.Rejected };
    expect(mergePublicationStatusForRecord(rejected, PublicationStatus.Unconfirmed, false)
      .publicationStatus).toBe(PublicationStatus.Rejected);
  });

  test("a tombstone is irreversible, deduplicated and width-checked", () => {
    let record = revokeDevice(emptyTrustRecord(), id(7));
    record = revokeDevice(record, id(7));
    expect(record.revokedDeviceIds).toHaveLength(1);
    record = revokeDevice(record, id(8));
    expect(record.revokedDeviceIds).toHaveLength(2);
    // A wrong-width id is ignored rather than stored as a tombstone that can never match.
    record = revokeDevice(record, new Uint8Array([1, 2, 3]));
    expect(record.revokedDeviceIds).toHaveLength(2);
  });
});

describe("§12.4, answered from what is stored", () => {
  test("the table", () => {
    expect(nextActionForRecord(emptyTrustRecord(), true)).toEqual({ action: "fresh-enrollment" });
    expect(nextActionForRecord(emptyTrustRecord(), false))
      .toEqual({ action: "generate-new-keys-and-enroll" });
    expect(nextActionForRecord({ ...emptyTrustRecord(), root: root(), pending: pending() }, true))
      .toEqual({ action: "resume" });
    expect(nextActionForRecord(
      { ...emptyTrustRecord(), root: root(), bundle: new Uint8Array([1]) }, true))
      .toEqual({ action: "auth", repeatCleanup: false });
    expect(nextActionForRecord(
      { ...emptyTrustRecord(), root: root(), bundle: new Uint8Array([1]), pending: pending() }, true))
      .toEqual({ action: "auth", repeatCleanup: true });
  });

  test("losing the keys overrides everything else", () => {
    // §10.2: "Private-key loss means generating new keys and enrolling again." A device with a
    // perfectly good chain and no keys has lost its identity, whatever the trust record says.
    const complete = { ...emptyTrustRecord(), root: root(), bundle: new Uint8Array([1]) };
    expect(nextActionForRecord(complete, false)).toEqual({ action: "generate-new-keys-and-enroll" });
  });
});
