import XCTest
@testable import RdevCore

/// The one place that answers "who is this device, and what should it do next?" from durable state.
///
/// Everything under it is separately tested; what is tested HERE is the relationship between the two
/// records — which is exactly what a caller consulting them separately would have to re-derive.
final class E2EIdentityManagerTests: XCTestCase {

    private struct Device: Decodable { let device_id: String, bundle: String, descriptor: String }
    private struct Fixture: Decodable {
        let rp_id: String, allowed_origins: [String], root: String, root_id: String
        let devices: [String: Device]
    }
    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-session.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()
    private var fx: Fixture { Self.fx }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }
    private var policy: E2EVerify.Policy {
        .init(rpID: fx.rp_id, allowedOrigins: fx.allowed_origins)
    }

    private func manager(_ installations: InstallationStore.Backend,
                         _ trust: InstallationStore.Backend) -> E2EIdentityManager {
        E2EIdentityManager(installations: installations, trust: trust)
    }

    // MARK: - the states

    func testAFreshDeviceIsUnenrolledAndHasKeys() throws {
        let keys = InstallationStore.Memory()
        let trust = InstallationStore.Memory()
        guard case .success(let loaded) = manager(keys, trust).load() else {
            return XCTFail("load")
        }
        XCTAssertEqual(loaded.state, .unenrolled)
        XCTAssertNotNil(keys.stored, "the keys were created and written")
        XCTAssertNil(loaded.record.root)
        // A descriptor NAMES its root, so there is no such thing as one before a root is adopted.
        XCTAssertNil(loaded.deviceDescriptor)
        XCTAssertNil(loaded.trustedRootID)
    }

    func testASecondLoadKeepsTheSameKeys() throws {
        let keys = InstallationStore.Memory()
        let trust = InstallationStore.Memory()
        guard case .success(let first) = manager(keys, trust).load(),
              case .success(let second) = manager(keys, trust).load() else { return XCTFail("load") }
        XCTAssertEqual(first.installation, second.installation)
        XCTAssertEqual(keys.writes, 1, "a second load must not rewrite the installation")
    }

    /// **THE DISTINCTION THAT MATTERS.** A trust record that is absent is a device that has never
    /// enrolled; one that is present and unreadable is a device whose identity is in trouble. Only
    /// the first may quietly start a ceremony.
    func testAnUnreadableTrustRecordBlocksRatherThanLookingUnenrolled() throws {
        let keys = InstallationStore.Memory()
        let trust = InstallationStore.Memory(Array("not a trust record".utf8))
        guard case .success(let loaded) = manager(keys, trust).load() else { return XCTFail("load") }
        XCTAssertEqual(loaded.state, .blocked(.unreadableTrust))
        XCTAssertEqual(trust.writes, 0, "nothing may be written over it")
    }

    func testAnUnreadableInstallationIsAFailureNotAState() {
        let keys = InstallationStore.Memory(Array("not an installation".utf8))
        guard case .failure(let f) = manager(keys, InstallationStore.Memory()).load() else {
            return XCTFail("must fail")
        }
        XCTAssertEqual(f, .unreadableInstallation)
    }

    func testAFailedInstallationWriteIsAFailure() {
        guard case .failure(let f) = manager(InstallationStore.ReadOnly(),
                                             InstallationStore.Memory()).load() else {
            return XCTFail("must fail")
        }
        XCTAssertEqual(f, .writeFailed)
    }

    // MARK: - adopting a root

    func testARootIsAdoptedOnceAndNeverReplaced() throws {
        let keys = InstallationStore.Memory()
        let trust = InstallationStore.Memory()
        let m = manager(keys, trust)
        guard case .success(let loaded) = m.load() else { return XCTFail("load") }

        guard case .success(let withRoot) = m.adoptRoot(hex(fx.root), into: loaded.record) else {
            return XCTFail("adopt")
        }
        XCTAssertEqual(withRoot.root, hex(fx.root))
        XCTAssertNotNil(trust.stored, "the record was persisted, not just returned")

        // The same root again is idempotent; a different one is refused.
        guard case .success = m.adoptRoot(hex(fx.root), into: withRoot) else {
            return XCTFail("idempotent")
        }
        var other = hex(fx.root)
        other[other.count - 1] ^= 0x01
        guard case .failure = m.adoptRoot(other, into: withRoot) else {
            return XCTFail("a second root must be refused")
        }
    }

    func testAdoptingARootMakesTheDescriptorExist() throws {
        let keys = InstallationStore.Memory()
        let trust = InstallationStore.Memory()
        let m = manager(keys, trust)
        guard case .success(let before) = m.load() else { return XCTFail("load") }
        XCTAssertNil(before.deviceDescriptor)

        _ = m.adoptRoot(hex(fx.root), into: before.record)
        guard case .success(let after) = m.load() else { return XCTFail("reload") }
        let descriptor = try XCTUnwrap(after.deviceDescriptor)
        XCTAssertEqual(after.trustedRootID, hex(fx.root_id))
        // It is THIS device's descriptor under THAT root.
        XCTAssertEqual(descriptor,
                       after.installation.keys.descriptor(rootID: hex(fx.root_id)))
    }

    // MARK: - committing a chain

    /// **A bundle that verifies for someone else is a grant this device cannot use.** Persisting one
    /// would leave a host presenting a chain whose keys it does not hold — which fails at the first
    /// `client-confirm`, a long way from the cause.
    func testACommitMustDescribeThisDevice() throws {
        let keys = InstallationStore.Memory()
        let trust = InstallationStore.Memory()
        let m = manager(keys, trust)
        guard case .success(let fresh) = m.load() else { return XCTFail("load") }
        _ = m.adoptRoot(hex(fx.root), into: fresh.record)
        guard case .success(let loaded) = m.load() else { return XCTFail("reload") }

        // H's bundle is valid and describes H, which is not us.
        guard case .failure(let f) = m.commit(bundle: hex(fx.devices["H"]!.bundle),
                                              status: .confirmed, into: loaded,
                                              policy: policy) else {
            return XCTFail("someone else's chain must be refused")
        }
        XCTAssertEqual(f, .chainMismatch)
        XCTAssertNil(loaded.record.bundle)
    }

    func testACommitWithoutARootIsRefused() throws {
        let m = manager(InstallationStore.Memory(), InstallationStore.Memory())
        guard case .success(let loaded) = m.load() else { return XCTFail("load") }
        guard case .failure(let f) = m.commit(bundle: hex(fx.devices["H"]!.bundle),
                                              status: .confirmed, into: loaded,
                                              policy: policy) else { return XCTFail("no root") }
        XCTAssertEqual(f, .noRoot)
    }

    func testAnUnverifiableBundleIsRefused() throws {
        let keys = InstallationStore.Memory()
        let trust = InstallationStore.Memory()
        let m = manager(keys, trust)
        guard case .success(let fresh) = m.load() else { return XCTFail("load") }
        _ = m.adoptRoot(hex(fx.root), into: fresh.record)
        guard case .success(let loaded) = m.load() else { return XCTFail("reload") }

        var corrupt = hex(fx.devices["H"]!.bundle)
        corrupt[corrupt.count - 1] ^= 0x01
        guard case .failure(let f) = m.commit(bundle: corrupt, status: .confirmed,
                                              into: loaded, policy: policy) else {
            return XCTFail("must refuse")
        }
        XCTAssertEqual(f, .chainMismatch)
    }

    // MARK: - revocation and reset

    func testARevocationIsPersistedBeforeItIsActedOn() throws {
        let trust = InstallationStore.Memory()
        let m = manager(InstallationStore.Memory(), trust)
        guard case .success(let loaded) = m.load() else { return XCTFail("load") }
        let target = hex(fx.devices["C"]!.device_id)

        guard case .success(let after) = m.revoke(deviceID: target, in: loaded.record) else {
            return XCTFail("revoke")
        }
        XCTAssertTrue(after.revokedDeviceIDs.contains(target))
        // §12.2: "persist before acknowledgement" — the caller gets the record back only once the
        // durable write succeeded.
        let stored = try XCTUnwrap(trust.stored.flatMap(E2ETrustStore.decode))
        XCTAssertTrue(stored.revokedDeviceIDs.contains(target))
    }

    func testAFailedWriteYieldsNothingToActOn() {
        // §12.3: "unsuccessful durable write grants no authority."
        let m = manager(InstallationStore.Memory(), InstallationStore.ReadOnly())
        guard case .success(let loaded) = m.load() else { return XCTFail("load") }
        guard case .failure(let f) = m.revoke(deviceID: Array(repeating: 1, count: 32),
                                              in: loaded.record) else { return XCTFail("must fail") }
        XCTAssertEqual(f, .writeFailed)
    }

    /// A reset is a change of IDENTITY, not of device: the keys survive it. Destroying them is a
    /// separate operation, and a caller that wants both calls both.
    func testResetDiscardsTrustAndKeepsTheKeys() throws {
        let keys = InstallationStore.Memory()
        let trust = InstallationStore.Memory()
        let m = manager(keys, trust)
        guard case .success(let fresh) = m.load() else { return XCTFail("load") }
        _ = m.adoptRoot(hex(fx.root), into: fresh.record)
        let installation = fresh.installation

        guard case .success(let after) = m.resetTrust() else { return XCTFail("reset") }
        XCTAssertNil(after.root)
        guard case .success(let reloaded) = m.load() else { return XCTFail("reload") }
        XCTAssertEqual(reloaded.installation, installation, "the device is the same device")
        XCTAssertEqual(reloaded.state, .unenrolled)
    }

    // MARK: - accepting an enrollment return

    /// The manager's installation is SEEDED with the fixture's H keys, so the device it describes is
    /// H — and H's bundle is therefore a valid return for it. Asserted rather than assumed below,
    /// because the whole test rests on it.
    private func seededManager(_ trust: InstallationStore.Backend)
        -> (E2EIdentityManager, InstallationStore.Memory) {
        let keys = InstallationStore.Memory()
        var draw = 0
        let seeded: (Int) -> [UInt8] = { count in
            draw += 1
            switch draw {
            case 1: return Array(repeating: 0x11, count: count)   // H's signing key
            case 2: return Array(repeating: 0x2A, count: count)   // H's noise key
            default: return Array(repeating: 0xE0, count: count)  // a rendezvous seed
            }
        }
        return (E2EIdentityManager(installations: keys, trust: trust, randomBytes: seeded), keys)
    }

    private func hOperationID() throws -> [UInt8] {
        guard case .success(let bundle) = E2ECertificate.parseBundle(hex(fx.devices["H"]!.bundle)),
              let grant = E2EIdentity.parseGrant(bundle.certificates[0].grant)
        else { throw E2EIdentityManager.Failure.chainMismatch }
        return grant.operationID
    }

    func testTheSeedGivesUsTheFixturesDevice() throws {
        let (m, _) = seededManager(InstallationStore.Memory())
        guard case .success(let loaded) = m.load() else { return XCTFail("load") }
        XCTAssertEqual(loaded.installation.keys.descriptor(rootID: hex(fx.root_id)),
                       hex(fx.devices["H"]!.descriptor),
                       "the seeded installation must BE H, or every test below proves nothing")
    }

    /// **§10.1'S OBLIGATION, MADE STRUCTURAL.** A device with no trusted root cannot tell a legitimate
    /// one from a substituted one, so it adopts one only when the caller names how a person chose it
    /// (`NewRoot`). Here that is a parameter: without it, nothing is adopted.
    func testAFirstRootIsNotAdoptedWithoutSayingHowAPersonChoseIt() throws {
        let trust = InstallationStore.Memory()
        let (m, _) = seededManager(trust)
        guard case .success(let loaded) = m.load() else { return XCTFail("load") }

        guard case .failure(let f) = m.acceptEnrollmentReturn(
            bundle: hex(fx.devices["H"]!.bundle), pendingOperationID: try hOperationID(),
            loaded: loaded, policy: policy, newRoot: nil) else {
            return XCTFail("a first root nobody chose must be refused")
        }
        XCTAssertEqual(f, .rootNotConfirmed)
        XCTAssertEqual(trust.writes, 0, "and nothing may be persisted")
    }

    func testAChosenFirstRootIsAdoptedAndTheChainCommitted() throws {
        let trust = InstallationStore.Memory()
        let (m, _) = seededManager(trust)
        guard case .success(let loaded) = m.load() else { return XCTFail("load") }

        guard case .success(let out) = m.acceptEnrollmentReturn(
            bundle: hex(fx.devices["H"]!.bundle), pendingOperationID: try hOperationID(),
            loaded: loaded, policy: policy, newRoot: .discovered) else {
            return XCTFail("accept")
        }
        XCTAssertEqual(out.acceptance, .adoptedNewRoot(rootID: hex(fx.root_id)))
        XCTAssertEqual(out.record.bundle, hex(fx.devices["H"]!.bundle))
        // §12.2: a native return comes from a ceremony this device drove, so nothing has been
        // published yet — `unconfirmed` is the truth until a publication says otherwise.
        XCTAssertEqual(out.record.publicationStatus, .unconfirmed)

        guard case .success(let reloaded) = m.load() else { return XCTFail("reload") }
        XCTAssertEqual(reloaded.state, .ready(cleanupPending: false))
    }

    /// A return under the root already trusted needs no confirmation: nothing is being decided.
    func testASubsequentReturnNeedsNoConfirmation() throws {
        let trust = InstallationStore.Memory()
        let (m, _) = seededManager(trust)
        guard case .success(let first) = m.load() else { return XCTFail("load") }
        _ = m.acceptEnrollmentReturn(bundle: hex(fx.devices["H"]!.bundle),
                                     pendingOperationID: try hOperationID(), loaded: first,
                                     policy: policy, newRoot: .discovered)

        guard case .success(let loaded) = m.load() else { return XCTFail("reload") }
        guard case .success(let out) = m.acceptEnrollmentReturn(
            bundle: hex(fx.devices["H"]!.bundle), pendingOperationID: try hOperationID(),
            loaded: loaded, policy: policy, newRoot: nil) else {
            return XCTFail("a return under the trusted root needs no confirmation")
        }
        XCTAssertEqual(out.acceptance, .verified)
    }

    /// §10.4's bindings still apply, confirmation or not.
    func testAReturnForAnotherOperationIsRefusedEvenWhenConfirmed() throws {
        let (m, _) = seededManager(InstallationStore.Memory())
        guard case .success(let loaded) = m.load() else { return XCTFail("load") }
        guard case .failure(let f) = m.acceptEnrollmentReturn(
            bundle: hex(fx.devices["H"]!.bundle),
            pendingOperationID: Array(repeating: 0xEE, count: 32),
            loaded: loaded, policy: policy, newRoot: .discovered) else {
            return XCTFail("must refuse")
        }
        XCTAssertEqual(f, .returnRejected)
    }

    func testAReturnForAnotherDeviceIsRefused() throws {
        // C's bundle is valid and describes C. This device is H.
        let (m, _) = seededManager(InstallationStore.Memory())
        guard case .success(let loaded) = m.load() else { return XCTFail("load") }
        guard case .failure(let f) = m.acceptEnrollmentReturn(
            bundle: hex(fx.devices["C"]!.bundle), pendingOperationID: nil,
            loaded: loaded, policy: policy, newRoot: .discovered) else {
            return XCTFail("must refuse")
        }
        XCTAssertEqual(f, .returnRejected)
    }

    func testNothingPendingIsRefused() throws {
        // §10.4 binds the return to a PENDING operation; an unsolicited one is not a slow answer.
        let (m, _) = seededManager(InstallationStore.Memory())
        guard case .success(let loaded) = m.load() else { return XCTFail("load") }
        guard case .failure(let f) = m.acceptEnrollmentReturn(
            bundle: hex(fx.devices["H"]!.bundle), pendingOperationID: nil,
            loaded: loaded, policy: policy, newRoot: .discovered) else {
            return XCTFail("must refuse")
        }
        XCTAssertEqual(f, .returnRejected)
    }

    // MARK: - §12.4, end to end

    func testAPendingOperationResumesRatherThanStartingAFreshCeremony() throws {
        let trust = InstallationStore.Memory()
        let m = manager(InstallationStore.Memory(), trust)
        let pending = try XCTUnwrap(E2ETrustStore.PendingOperation(
            operationID: Array(repeating: 0xB0, count: 32),
            responderDeviceID: hex(fx.devices["H"]!.device_id),
            route: RendezvousRoute(rcode: "x0WuwKuk",
                                   rtoken: "f67e21bd-9c7d-4a3b-8f21-0d4e6a1b2c3d")))
        var record = E2ETrustStore.Record(root: hex(fx.root))
        record.pending = pending
        _ = trust.write(try XCTUnwrap(E2ETrustStore.encode(record)))

        guard case .success(let loaded) = m.load() else { return XCTFail("load") }
        // Starting a fresh ceremony here would reserve a SECOND window for one enrollment.
        XCTAssertEqual(loaded.state, .resumable(pending))
    }

    // MARK: - logging out

    /// **Logging out deletes the KEYS as well as the trust record**, which is what separates it from
    /// §10.1's local reset. Keeping the keys would leave one Noise static certified under two roots
    /// — a stable correlator any peer on either side can see (`docs/e2e.md`).
    func testForgetDeletesTheKeysAndTheTrustRecord() throws {
        let installations = InstallationStore.Memory()
        let trust = InstallationStore.Memory()
        let m = manager(installations, trust)
        guard case .success = m.load() else { return XCTFail("load") }
        _ = trust.write(try XCTUnwrap(E2ETrustStore.encode(
            E2ETrustStore.Record(root: hex(fx.root), bundle: [1, 2, 3],
                                 publicationStatus: .confirmed))))
        XCTAssertNotNil(installations.stored)
        XCTAssertNotNil(trust.stored)

        XCTAssertTrue(m.forget())
        XCTAssertNil(installations.stored, "the keys survived a logout")
        XCTAssertNil(trust.stored, "the trust record survived a logout")

        // Afterwards it is a device that has NEVER enrolled, not one that is blocked — so the way
        // back is the ordinary ceremony rather than a state a person has to be rescued from.
        guard case .success(let after) = m.load() else { return XCTFail("reload") }
        XCTAssertEqual(after.state, .unenrolled)
    }

    /// **KEYS FIRST, AND NOTHING AT ALL IF THEY SURVIVE.** The two orders fail differently and only
    /// one failure is safe: keys gone with the record left is §12.4's `keys-lost`, which nothing can
    /// use, while the record gone with the keys left is a device still holding the material a person
    /// believes they deleted — and looking unenrolled while it does.
    func testForgetThatCannotDeleteTheKeysChangesNothing() throws {
        let trust = InstallationStore.Memory()
        let encoded = try XCTUnwrap(E2ETrustStore.encode(
            E2ETrustStore.Record(root: hex(fx.root), bundle: [1, 2, 3],
                                 publicationStatus: .confirmed)))
        _ = trust.write(encoded)
        let m = manager(InstallationStore.ReadOnly([1, 2, 3]), trust)

        XCTAssertFalse(m.forget())
        XCTAssertEqual(trust.stored, encoded, "the trust record went while the keys stayed")
    }

    /// The safe half-failure, asserted so the order is not free to flip: the keys are gone, the
    /// caller is told it did not finish, and what is left cannot be used by anything.
    func testForgetThatLosesOnlyTheRecordStillTookTheKeys() {
        let installations = InstallationStore.Memory([1, 2, 3])
        let m = manager(installations, InstallationStore.ReadOnly([4, 5, 6]))

        XCTAssertFalse(m.forget())
        XCTAssertNil(installations.stored)
    }

    func testACommittedChainWithCleanupOutstandingIsStillReady() throws {
        let trust = InstallationStore.Memory()
        let m = manager(InstallationStore.Memory(), trust)
        var record = E2ETrustStore.Record(root: hex(fx.root), bundle: [1, 2, 3],
                                          publicationStatus: .unconfirmed)
        record.pending = try XCTUnwrap(E2ETrustStore.PendingOperation(
            operationID: Array(repeating: 1, count: 32),
            responderDeviceID: Array(repeating: 2, count: 32),
            route: RendezvousRoute(rcode: "AAAAAAAA",
                                   rtoken: "00000000-0000-4000-8000-000000000000")))
        _ = trust.write(try XCTUnwrap(E2ETrustStore.encode(record)))

        guard case .success(let loaded) = m.load() else { return XCTFail("load") }
        XCTAssertEqual(loaded.state, .ready(cleanupPending: true))
    }
}
