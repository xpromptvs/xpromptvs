import XCTest
@testable import RdevCore
@testable import RdevHostKit

/// **§12.2's transient retry, which this host did not have.**
///
/// The spec's table is explicit: a transient failure — "timeout, connection refused, DNS or TLS
/// failure, `5xx`, `429`, `404` (a deployment may be in progress), and any reply that did not
/// arrive" — retries **"automatic, idempotent, across restarts"**. The browser does exactly that
/// (`registerWithDirectory`, guarded on the stored status and retried on every dashboard visit).
/// The Mac registered ONCE after enrolling, returned `.unconfirmed` on failure, and nothing drained
/// it — so a Mac enrolled while the Worker was unreachable stayed unpublished for the life of the
/// installation, and a browser discovering its passkey got `404` forever.
///
/// That is what makes a legitimate identity look stranded, which is why a `404` from the credential
/// index may never be read as evidence that a passkey is unused (`docs/e2e.md`).
final class E2ERegistrationRetryTests: XCTestCase {

    private struct Malformed: Error {}

    private struct Device: Decodable { let bundle: String }
    private struct Fixture: Decodable {
        let rp_id: String, allowed_origins: [String]
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

    /// Records every action and every body, and can be made to fail — which is the whole subject
    /// here, since a registration that SUCCEEDS leaves nothing to retry.
    private final class Directory: E2EDirectoryClient.Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        private var bodies: [String: [Data]] = [:]
        /// Fails everything while true. The Worker being unreachable, in one switch.
        var offline = false

        var actions: [String] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }
        func count(_ action: String) -> Int { actions.filter { $0 == action }.count }
        func bodies(of action: String) -> [Data] {
            lock.lock(); defer { lock.unlock() }
            return bodies[action] ?? []
        }

        func send(_ request: URLRequest) async -> (Data, Int)? {
            let action = request.url!.lastPathComponent
            lock.lock()
            seen.append(action)
            if let body = request.httpBody { bodies[action, default: []].append(body) }
            let down = offline
            lock.unlock()
            if down { return nil }                       // a reply that did not arrive
            if action == "challenge" {
                return (Data("{\"challenge\":\"\(String(repeating: "A", count: 43))\"}".utf8), 200)
            }
            return (Data("{\"status\":\"registered\"}".utf8), 200)
        }
    }


    /// Seeded so the installation is the fixture's device H, which is what makes H's bundle a valid
    /// return for it.
    private func identity() throws -> E2EHostIdentity {
        var draw = 0
        let seeded: (Int) -> [UInt8] = { count in
            draw += 1
            switch draw {
            case 1: return Array(repeating: 0x11, count: count)
            case 2: return Array(repeating: 0x2A, count: count)
            default: return Array(repeating: 0xE0, count: count)
            }
        }
        guard case .success(let origin) = E2EOrigin.resolve(fx.allowed_origins[0]) else {
            throw E2EOrigin.Failure.malformed
        }
        return E2EHostIdentity(
            origin: origin,
            manager: E2EIdentityManager(installations: InstallationStore.Memory(),
                                        trust: InstallationStore.Memory(), randomBytes: seeded))
    }

    /// §12.2's idempotence is on `(root_id, operation_id)`, so a retry MUST carry the operation the
    /// grant was issued under. This is where the expected value comes from.
    private func leafOperation() throws -> [UInt8] {
        guard case .success(let b) = E2ECertificate.parseBundle(hex(fx.devices["H"]!.bundle)),
              let grant = E2EIdentity.parseGrant(b.certificates[0].grant)
        else { throw Malformed() }
        return grant.operationID
    }

    /// An identity with a COMMITTED chain, enrolled while the directory was unreachable — which is
    /// exactly the state §12.2 says must heal itself.
    private func enrolledDuringAnOutage(_ directory: Directory) async throws -> E2EHostIdentity {
        let identity = try identity()
        directory.offline = true
        guard case .success(let loaded) = identity.load(),
              case .success = identity.manager.acceptEnrollmentReturn(
                  bundle: hex(fx.devices["H"]!.bundle), pendingOperationID: try leafOperation(),
                  loaded: loaded, policy: identity.policy, newRoot: .discovered)
        else { throw Malformed() }
        // The enrollment itself must have survived the outage — §12.2 is explicit that publication
        // cannot fail one, and the retry only matters because of that.
        _ = await identity.registerGrant(operationID: try leafOperation(), transport: directory)
        return identity
    }

    // MARK: -

    func testAnOutageAtEnrollmentLeavesTheRegistrationUnconfirmed() async throws {
        let directory = Directory()
        let identity = try await enrolledDuringAnOutage(directory)
        guard case .success(let loaded) = identity.manager.load() else { return XCTFail("load") }
        XCTAssertEqual(loaded.record.publicationStatus, .unconfirmed)
        XCTAssertNotNil(loaded.record.bundle, "the enrollment survived the outage, as §12.2 requires")
    }

    /// **THE FIX.** §12.2: transient failures retry "automatic, idempotent, across restarts".
    func testAnUnconfirmedRegistrationIsRetriedAndReachesConfirmed() async throws {
        let directory = Directory()
        let identity = try await enrolledDuringAnOutage(directory)
        directory.offline = false

        let status = await identity.retryRegistration(transport: directory)
        XCTAssertEqual(status, .confirmed)
        guard case .success(let loaded) = identity.manager.load() else { return XCTFail("load") }
        XCTAssertEqual(loaded.record.publicationStatus, .confirmed)
    }

    /// **IDEMPOTENT, which means the ORIGINAL operation id.** §12.2 keys idempotence on
    /// `(root_id, operation_id)`: reusing the one the grant was issued under makes a retry free,
    /// while a fresh id would open a second operation for the same grant.
    func testTheRetryCarriesTheGRANTSOwnOperationId() async throws {
        let directory = Directory()
        let identity = try await enrolledDuringAnOutage(directory)
        directory.offline = false

        _ = await identity.retryRegistration(transport: directory)
        let sent = directory.bodies(of: "register")
        XCTAssertEqual(sent.count, 1, "one registration attempt")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent[0]) as? [String: Any])
        let operation = try XCTUnwrap(body["operation_id"] as? String)
        XCTAssertEqual(operation, base64urlEncode(Data(try leafOperation())),
                       "a retry must reuse the grant's own operation id, not mint a new one")
    }

    /// `confirmed` is terminal (§12.2), so a retry there is pure noise against the Worker.
    func testAConfirmedRegistrationIsNotRetried() async throws {
        let directory = Directory()
        let identity = try await enrolledDuringAnOutage(directory)
        directory.offline = false
        _ = await identity.retryRegistration(transport: directory)
        let after = directory.count("register")

        _ = await identity.retryRegistration(transport: directory)
        XCTAssertEqual(directory.count("register"), after,
                       "confirmed is terminal — nothing should be sent")
    }

    /// **§12.2 separates `rejected` from `unconfirmed` by RETRY POLICY, not by meaning.** A refusal
    /// is permanent and needs a person; retrying it forever would hammer the Worker and hide the
    /// one status a person is required to be shown.
    func testARejectedRegistrationIsNotRetriedAutomatically() async throws {
        let directory = Directory()
        let identity = try await enrolledDuringAnOutage(directory)
        guard case .success(let loaded) = identity.manager.load() else { return XCTFail("load") }
        _ = identity.manager.recordPublicationStatus(.rejected, reporterHoldsPublicationJob: true,
                                                    in: loaded.record)
        directory.offline = false
        let before = directory.count("register")

        let status = await identity.retryRegistration(transport: directory)
        XCTAssertNil(status, "a rejected registration is not an automatic retry")
        XCTAssertEqual(directory.count("register"), before)
    }

    /// Nothing committed is no publication job, and must not be one request either.
    func testAnUnenrolledMacRetriesNothing() throws {
        let directory = Directory()
        let identity = try identity()
        let expectation = XCTestExpectation(description: "retry returns")
        Task {
            let status = await identity.retryRegistration(transport: directory)
            XCTAssertNil(status)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(directory.actions, [], "an unenrolled Mac sends nothing")
    }
}
