import XCTest
@testable import RdevCore
@testable import RdevHostKit

/// **§12.2's session discovery, as the Mac runs it** — the signed replacement for
/// `PUT /account/sessions` and its bearer token
/// (`docs/superpowers/specs/2026-09-13-passkey-only-identity.md`).
///
/// The publisher itself is a heartbeat and a state; what is worth asserting here is the part the old
/// implementation got wrong, which was never the HTTP: it reported one boolean and an error string,
/// so "not sharing", "no identity" and "failing for hours" were one silence, and a Mac could drop
/// out of its owner's device list while the window claimed it was listed.
final class E2ESessionPublisherTests: XCTestCase {

    private struct Malformed: Error {}

    private struct Device: Decodable { let bundle: String }
    private struct Fixture: Decodable {
        let rp_id: String, allowed_origins: [String], root_id: String
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
    /// The directory side: records every request, answers from a settable script, and can be HELD
    /// OPEN mid-request — which is the only way a beat that lands after `stop` is observable.
    private final class Directory: E2EDirectoryClient.Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var answer: (Data, Int)? = (Data("{\"status\":\"published\"}".utf8), 200)
        /// Blocks the FIRST `publish` until `release()` is called. Only the first: the withdrawal
        /// that follows a `stop` must not be held too, or the test would deadlock on its own gate.
        private var gate: CheckedContinuation<Void, Never>?
        private var holdFirstPublish = false
        private var held = false

        func holdTheFirstPublish() { lock.lock(); holdFirstPublish = true; lock.unlock() }

        func release() {
            lock.lock()
            let waiting = gate
            gate = nil
            holdFirstPublish = false
            lock.unlock()
            waiting?.resume()
        }

        var actions: [String] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }
        func count(_ action: String) -> Int { actions.filter { $0 == action }.count }

        func send(_ request: URLRequest) async -> (Data, Int)? {
            let action = request.url!.lastPathComponent
            lock.lock()
            seen.append(action)
            let hold = action == "publish" && holdFirstPublish && !held
            if hold { held = true }
            lock.unlock()

            if hold {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    let alreadyReleased = !holdFirstPublish
                    if !alreadyReleased { gate = c }
                    lock.unlock()
                    if alreadyReleased { c.resume() }
                }
            }
            if action == "challenge" {
                return (try! JSONSerialization.data(withJSONObject: [
                    "challenge": base64urlEncode(Data(Array(repeating: 0x5C, count: 32))),
                    "expires_in": 120,
                ]), 200)
            }
            return answer
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

    private func hOperation() throws -> [UInt8] {
        guard case .success(let b) = E2ECertificate.parseBundle(hex(fx.devices["H"]!.bundle)),
              let grant = E2EIdentity.parseGrant(b.certificates[0].grant)
        else { throw Malformed() }
        return grant.operationID
    }

    /// An identity with a COMMITTED chain — the only kind that can sign a directory request.
    private func enrolled() async throws -> E2EHostIdentity {
        let identity = try identity()
        guard case .success(let loaded) = identity.load(),
              case .success = identity.manager.acceptEnrollmentReturn(
                  bundle: hex(fx.devices["H"]!.bundle), pendingOperationID: try hOperation(),
                  loaded: loaded, policy: identity.policy, newRoot: .discovered)
        else { throw Malformed() }
        return identity
    }

    private var session: E2EDirectory.Session {
        .init(code: "AbCd1234", token: "fa9c2f01-7a5b-4c33-9f6d-0b1e2d3c4a5b", label: "studio mac")
    }

    // MARK: - the state a person reads

    func testAnIdleMacIsNotPublishing() {
        let publisher = E2ESessionPublisher(transport: Directory())
        XCTAssertEqual(publisher.state(), .init(publishing: false, status: nil))
    }

    /// The happy path, end to end through the client: a challenge, then `publish` under this root,
    /// and a state a person can read.
    func testPublishingReachesConfirmedAndNamesTheRoom() async throws {
        let identity = try await enrolled()
        let directory = Directory()
        let publisher = E2ESessionPublisher(intervalSeconds: 60, transport: directory)

        publisher.start(identity: identity, session: session)
        await waitUntil({ publisher.state().status == .confirmed }, "the first beat to land")
        XCTAssertTrue(publisher.state().publishing)
        XCTAssertEqual(directory.actions.prefix(2).map { $0 }, ["challenge", "publish"])
    }

    /// **THE FIRST BEAT HAS NOT COME BACK YET IS A THIRD ANSWER.** Collapsing it into either of the
    /// other two is how the old implementation came to claim a listing it did not have.
    func testPublishingStartsPendingRatherThanClaimingSuccess() async throws {
        let identity = try await enrolled()
        let publisher = E2ESessionPublisher(intervalSeconds: 60, transport: Directory())
        publisher.start(identity: identity, session: session)
        // Read SYNCHRONOUSLY, before the task can have completed a round trip.
        let immediately = publisher.state()
        XCTAssertTrue(immediately.publishing)
        XCTAssertNil(immediately.status, "nothing has been reported yet")
    }

    /// §12.2's transient/terminal split reaches the state unchanged, and neither can fail sharing.
    func testASilentWorkerIsUnconfirmedAndKeepsTrying() async throws {
        let identity = try await enrolled()
        let directory = Directory()
        directory.answer = nil
        let publisher = E2ESessionPublisher(intervalSeconds: 0.05, transport: directory)

        publisher.start(identity: identity, session: session)
        await waitUntil({ publisher.state().status == .unconfirmed }, "an unconfirmed beat")
        // The loop keeps running, because retrying is the only thing that re-lists this Mac when
        // the network returns.
        await waitUntil({ directory.count("publish") >= 2 }, "a second attempt")
        XCTAssertTrue(publisher.state().publishing)
    }

    func testARefusalIsRejectedRatherThanRetriedSilently() async throws {
        let identity = try await enrolled()
        let directory = Directory()
        directory.answer = (Data("{}".utf8), 422)
        let publisher = E2ESessionPublisher(intervalSeconds: 60, transport: directory)

        publisher.start(identity: identity, session: session)
        await waitUntil({ publisher.state().status == .rejected }, "a rejection")
    }

    /// The heartbeat, which is what keeps the 90 s TTL from reaping a Mac that is still sharing.
    func testItKeepsAnnouncing() async throws {
        let identity = try await enrolled()
        let directory = Directory()
        let publisher = E2ESessionPublisher(intervalSeconds: 0.05, transport: directory)

        publisher.start(identity: identity, session: session)
        await waitUntil({ directory.count("publish") >= 3 }, "three beats")
        publisher.stop(identity: identity)
    }

    /// Stopping withdraws the room. **Fire and forget** — the 90 s TTL reaps it anyway, and quitting
    /// must not wait on a network round trip — so the state goes quiet immediately and the request
    /// follows.
    func testStoppingGoesQuietAtOnceAndWithdrawsTheRoom() async throws {
        let identity = try await enrolled()
        let directory = Directory()
        let publisher = E2ESessionPublisher(intervalSeconds: 60, transport: directory)

        publisher.start(identity: identity, session: session)
        await waitUntil({ publisher.state().status == .confirmed }, "the first beat to land")

        publisher.stop(identity: identity)
        XCTAssertEqual(publisher.state(), .init(publishing: false, status: nil),
                       "the state is quiet before the withdrawal has been answered")
        await waitUntil({ directory.count("unpublish") == 1 }, "the withdrawal")
    }

    /// **A beat that lands after `stop` must not resurrect the listing.** The room has been
    /// withdrawn; a late answer describes a request about a session that no longer exists, and
    /// recording it would leave the app claiming a listing for a session nobody can join.
    ///
    /// The transport is HELD OPEN across the `stop`, which is what makes the race deterministic —
    /// without that the beat always finishes first and the guard is never reached.
    func testALateBeatDoesNotResurrectTheState() async throws {
        let identity = try await enrolled()
        let directory = Directory()
        directory.holdTheFirstPublish()
        let publisher = E2ESessionPublisher(intervalSeconds: 60, transport: directory)

        publisher.start(identity: identity, session: session)
        await waitUntil({ directory.count("publish") == 1 }, "a beat to be in flight")
        publisher.stop(identity: identity)
        XCTAssertEqual(publisher.state(), .init(publishing: false, status: nil))

        directory.release()
        // Long enough for the released beat to have run all the way through `record`.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(publisher.state(), .init(publishing: false, status: nil),
                       "a beat answered after the withdrawal must record nothing")
    }

    /// A Mac with nothing committed has no identity to be listed under. It is not a failure and it
    /// is not something a retry fixes — and no request is made at all, because there is nothing to
    /// sign with.
    func testAnUnenrolledMacPublishesNothing() async throws {
        let identity = try identity()
        let directory = Directory()
        let publisher = E2ESessionPublisher(intervalSeconds: 60, transport: directory)

        publisher.start(identity: identity, session: session)
        await waitUntil({ publisher.state().status != nil }, "the first beat to resolve")
        XCTAssertEqual(publisher.state().status, .unconfirmed)
        XCTAssertTrue(directory.actions.isEmpty, "nothing reached the Control Plane")
        publisher.stop(identity: identity)
    }
}
