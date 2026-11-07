import XCTest
@testable import RdevCore

/// §10.2's durable trust state, and the transitions that are rules rather than assignments.
final class E2ETrustStoreTests: XCTestCase {

    private func id(_ n: UInt8) -> [UInt8] { Array(repeating: n, count: 32) }
    private let route = RendezvousRoute(rcode: "x0WuwKuk",
                                        rtoken: "f67e21bd-9c7d-4a3b-8f21-0d4e6a1b2c3d")

    private func root(_ n: UInt8 = 1) -> [UInt8] {
        E2EIdentity.root(rpID: "rdev.example", credentialID: [n],
                         rootPublicKey: [0x04] + Array(repeating: n, count: 64))!
    }

    private func pending(_ n: UInt8 = 0xB0) -> E2ETrustStore.PendingOperation {
        E2ETrustStore.PendingOperation(operationID: id(n), responderDeviceID: id(0xC0),
                                       route: route)!
    }

    // MARK: - encoding

    func testAnEmptyRecordRoundTrips() throws {
        let empty = E2ETrustStore.Record()
        let encoded = try XCTUnwrap(E2ETrustStore.encode(empty))
        XCTAssertEqual(E2ETrustStore.decode(encoded), empty)
        // Nil is not an empty array: a record with no root must decode back to NO root, not to a
        // zero-length descriptor that would then fail every comparison for a confusing reason.
        XCTAssertNil(E2ETrustStore.decode(encoded)?.root)
        XCTAssertNil(E2ETrustStore.decode(encoded)?.publicationStatus)
    }

    func testAFullRecordRoundTrips() throws {
        let record = E2ETrustStore.Record(
            root: root(), bundle: [1, 2, 3], publicationStatus: .rejected,
            revokedDeviceIDs: [id(9), id(8)], pending: pending())
        let encoded = try XCTUnwrap(E2ETrustStore.encode(record))
        XCTAssertEqual(E2ETrustStore.decode(encoded), record)
    }

    /// The same set must always encode to the same bytes, or "did anything change?" stops being
    /// answerable by comparison — the cheapest check a caller has before a durable write.
    func testTheEncodingIsStableAcrossSetOrdering() throws {
        let a = E2ETrustStore.Record(revokedDeviceIDs: [id(1), id(2), id(3)])
        let b = E2ETrustStore.Record(revokedDeviceIDs: [id(3), id(1), id(2)])
        XCTAssertEqual(try XCTUnwrap(E2ETrustStore.encode(a)),
                       try XCTUnwrap(E2ETrustStore.encode(b)))
    }

    func testARecordThatIsNotOneIsRefused() throws {
        let good = try XCTUnwrap(E2ETrustStore.encode(
            E2ETrustStore.Record(root: root(), bundle: [1], publicationStatus: .confirmed)))
        XCTAssertNotNil(E2ETrustStore.decode(good))
        XCTAssertNil(E2ETrustStore.decode(good + [0]))
        XCTAssertNil(E2ETrustStore.decode(Array(good.dropLast())))
        XCTAssertNil(E2ETrustStore.decode([]))
        var wrongLabel = good
        wrongLabel[2] = UInt8(ascii: "X")
        XCTAssertNil(E2ETrustStore.decode(wrongLabel))
    }

    /// §7: an unsupported enum value is a REJECTION, never partially interpreted. "Absent" is 0xFF
    /// precisely so it cannot be confused with one of the three that mean something.
    ///
    /// The status byte is located by REBUILDING the record with a different status and finding the
    /// single byte that moved. The first version of this test indexed `count - 3` by hand and hit
    /// the PENDING FLAG instead — it passed, for the wrong reason, against a record whose status it
    /// never touched.
    func testAnUnknownPublicationStatusIsRefused() throws {
        let confirmed = try XCTUnwrap(E2ETrustStore.encode(
            E2ETrustStore.Record(root: root(), publicationStatus: .confirmed)))
        let rejected = try XCTUnwrap(E2ETrustStore.encode(
            E2ETrustStore.Record(root: root(), publicationStatus: .rejected)))
        XCTAssertEqual(confirmed.count, rejected.count)
        let differing = zip(confirmed, rejected).enumerated().filter { $0.element.0 != $0.element.1 }
        XCTAssertEqual(differing.count, 1, "exactly one byte encodes the status")
        let statusIndex = try XCTUnwrap(differing.first).offset
        XCTAssertEqual(confirmed[statusIndex], E2EWire.PublicationStatus.confirmed.rawValue)

        for raw: UInt8 in [3, 4, 0xFE] {
            var mutated = confirmed
            mutated[statusIndex] = raw
            XCTAssertNil(E2ETrustStore.decode(mutated), "status \(raw)")
        }
        var absent = confirmed
        absent[statusIndex] = E2ETrustStore.statusAbsent
        XCTAssertNotNil(E2ETrustStore.decode(absent))
        XCTAssertNil(E2ETrustStore.decode(absent)?.publicationStatus)
    }

    /// And the pending flag, which the test above used to hit by accident: anything but 0 or 1 is a
    /// rejection rather than "probably no pending operation".
    func testAnUnknownPendingFlagIsRefused() throws {
        let without = try XCTUnwrap(E2ETrustStore.encode(E2ETrustStore.Record(root: root())))
        let with = try XCTUnwrap(E2ETrustStore.encode(
            E2ETrustStore.Record(root: root(), pending: pending())))
        let flagIndex = try XCTUnwrap(zip(without, with).enumerated()
            .first { $0.element.0 != $0.element.1 }).offset
        XCTAssertEqual(without[flagIndex], 0)
        for raw: UInt8 in [2, 3, 0xFF] {
            var mutated = without
            mutated[flagIndex] = raw
            XCTAssertNil(E2ETrustStore.decode(mutated), "pending flag \(raw)")
        }
    }

    // MARK: - §10.1: a trusted root is never replaced

    func testARootIsAdoptedOnlyFromNothing() throws {
        var record = E2ETrustStore.Record()
        guard case .success(let adopted) = E2ETrustStore.adoptRoot(record, root: root(1)) else {
            return XCTFail("adopt")
        }
        XCTAssertEqual(adopted.root, root(1))

        // The same root again is idempotent; a different one is refused.
        guard case .success = E2ETrustStore.adoptRoot(adopted, root: root(1)) else {
            return XCTFail("idempotent")
        }
        guard case .failure(let f) = E2ETrustStore.adoptRoot(adopted, root: root(2)) else {
            return XCTFail("a second root must be refused")
        }
        XCTAssertEqual(f, .rootAlreadyTrusted)
        record = adopted
        XCTAssertEqual(record.root, root(1), "and the stored one is untouched")
    }

    /// §10.1's "explicit local reset/re-registration" — the only way out, and it takes everything.
    func testResetDiscardsEverythingIncludingTombstones() {
        let full = E2ETrustStore.Record(root: root(), bundle: [1], publicationStatus: .confirmed,
                                        revokedDeviceIDs: [id(9)], pending: pending())
        let after = E2ETrustStore.reset()
        XCTAssertNotEqual(after, full)
        XCTAssertNil(after.root)
        XCTAssertNil(after.bundle)
        XCTAssertNil(after.pending)
        // Tombstones are irreversible WITHIN an identity; this is the operation that ends one.
        XCTAssertTrue(after.revokedDeviceIDs.isEmpty)
    }

    // MARK: - committing a chain

    func testCommittingAChainRequiresTheMatchingRoot() throws {
        let trusted = root(1)
        var record = E2ETrustStore.Record(root: trusted)
        guard case .failure(let mismatch) = E2ETrustStore.commitOwnChain(
            record, bundle: [1], status: .confirmed,
            rootID: E2EIdentity.rootID(root(2))) else { return XCTFail("mismatch") }
        XCTAssertEqual(mismatch, .rootMismatch)

        guard case .failure(let none) = E2ETrustStore.commitOwnChain(
            E2ETrustStore.Record(), bundle: [1], status: .confirmed,
            rootID: E2EIdentity.rootID(trusted)) else { return XCTFail("no root") }
        XCTAssertEqual(none, .noRoot)

        guard case .success(let ok) = E2ETrustStore.commitOwnChain(
            record, bundle: [1, 2], status: .unconfirmed,
            rootID: E2EIdentity.rootID(trusted)) else { return XCTFail("commit") }
        XCTAssertEqual(ok.bundle, [1, 2])
        XCTAssertEqual(ok.publicationStatus, .unconfirmed)
        record = ok
    }

    /// §12.3: "persist committed chain; erase pairing secret and PENDING-ONLY state." Keeping the
    /// pending operation would make §12.4 answer `resume` forever, against a ceremony that finished.
    func testCommittingClearsThePendingOperation() throws {
        let record = E2ETrustStore.Record(root: root(), pending: pending())
        guard case .success(let after) = E2ETrustStore.commitOwnChain(
            record, bundle: [1], status: .confirmed,
            rootID: E2EIdentity.rootID(root())) else { return XCTFail("commit") }
        XCTAssertNil(after.pending)
    }

    // MARK: - §12.2's monotonic status, and §10.5's tombstones

    func testStatusIsMonotonicTowardConfirmed() {
        var record = E2ETrustStore.Record(root: root(), bundle: [1], publicationStatus: .confirmed)
        record = E2ETrustStore.mergePublicationStatus(record, reported: .unconfirmed,
                                                      reporterHoldsPublicationJob: true)
        XCTAssertEqual(record.publicationStatus, .confirmed)

        var other = E2ETrustStore.Record(root: root(), bundle: [1], publicationStatus: .rejected)
        // A responder holding no job is informational only — otherwise every connection to an
        // unrelated Host would erase what the issuing endpoint reported.
        other = E2ETrustStore.mergePublicationStatus(other, reported: .unconfirmed,
                                                     reporterHoldsPublicationJob: false)
        XCTAssertEqual(other.publicationStatus, .rejected)
    }

    func testRevocationIsIrreversibleAndWidthChecked() {
        var record = E2ETrustStore.Record()
        record = E2ETrustStore.revoke(record, deviceID: id(7))
        record = E2ETrustStore.revoke(record, deviceID: id(7))
        XCTAssertEqual(record.revokedDeviceIDs, [id(7)])
        // Nothing in this type removes one.
        record = E2ETrustStore.revoke(record, deviceID: id(8))
        XCTAssertEqual(record.revokedDeviceIDs.count, 2)
        // A wrong-width id is ignored rather than stored as a tombstone that can never match.
        record = E2ETrustStore.revoke(record, deviceID: [1, 2, 3])
        XCTAssertEqual(record.revokedDeviceIDs.count, 2)
    }

    // MARK: - §12.4, answered from what is stored

    func testTheResumeTableIsAnsweredFromTheRecord() {
        let empty = E2ETrustStore.Record()
        XCTAssertEqual(E2ETrustStore.nextAction(empty, hasKeys: true), .freshEnrollment)
        XCTAssertEqual(E2ETrustStore.nextAction(empty, hasKeys: false), .generateNewKeysAndEnroll)

        let pendingOnly = E2ETrustStore.Record(root: root(), pending: pending())
        XCTAssertEqual(E2ETrustStore.nextAction(pendingOnly, hasKeys: true), .resume)

        let clean = E2ETrustStore.Record(root: root(), bundle: [1], publicationStatus: .confirmed)
        XCTAssertEqual(E2ETrustStore.nextAction(clean, hasKeys: true), .auth(repeatCleanup: false))

        let dirty = E2ETrustStore.Record(root: root(), bundle: [1], publicationStatus: .confirmed,
                                         pending: pending())
        XCTAssertEqual(E2ETrustStore.nextAction(dirty, hasKeys: true), .auth(repeatCleanup: true))
    }

    /// §10.2: "Private-key loss means generating new keys and enrolling again." A device with a
    /// perfectly good chain and no keys has lost its identity, whatever the trust record says — so
    /// the keys are a separate argument, from a separate record.
    func testLosingTheKeysOverridesEverythingElse() {
        let complete = E2ETrustStore.Record(root: root(), bundle: [1], publicationStatus: .confirmed)
        XCTAssertEqual(E2ETrustStore.nextAction(complete, hasKeys: false),
                       .generateNewKeysAndEnroll)
    }
}
