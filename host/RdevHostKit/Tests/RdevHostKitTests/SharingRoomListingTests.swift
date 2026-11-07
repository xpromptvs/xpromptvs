import XCTest
import RdevCore
@testable import RdevHostKit

/// **A MAC THAT ENROLS WHILE SHARING IS LISTED THEN** (`SharingRoom.publishIfReady`, 2026-10-07): the Mac mini had
/// shared since launch with no identity, was added by code, could reach the laptop — and the laptop's list never
/// showed it, because the listing started only at Share. A room that is sharing starts it on the move to ready.
final class SharingRoomListingTests: XCTestCase {
    /// The directory: every request answered 200 — what a publication needs.
    private final class Directory: E2EDirectoryClient.Transport, @unchecked Sendable {
        func send(_ request: URLRequest) async -> (Data, Int)? {
            if request.url!.path.hasSuffix("/challenge") {
                return (Data(#"{"challenge":"\#(String(repeating: "A", count: 43))"}"#.utf8), 200)
            }
            return (Data(#"{"status":"published"}"#.utf8), 200)
        }
    }

    func testARoomSharingBeforeItsMacEnrolledIsListedOnceItHas() async throws {
        guard case .success(let origin) = E2EOrigin.resolve(E2EPasskeyCeremonyTests.origin) else { return XCTFail("origin") }
        let identity = E2EHostIdentity(origin: origin,
                                       manager: E2EIdentityManager(installations: InstallationStore.Memory(),
                                                                   trust: InstallationStore.Memory()),
                                       pendingRoot: MemoryRecord())
        let worker = E2EPasskeyCeremonyTests.Worker()
        let service = E2EIdentityService(e2e: .success(identity), directory: worker)
        let pasteDir = FileManager.default.temporaryDirectory.appendingPathComponent("listing-\(UUID().uuidString)")
        var config = HostConfig.from(environment: [:])
        config.pasteDirectory = pasteDir.path
        let session = HostSession(config: config)
        defer { session.end(); try? FileManager.default.removeItem(at: pasteDir) }
        let publisher = E2ESessionPublisher(intervalSeconds: 3600, transport: Directory())
        let room = SharingRoom(session: session, config: config, code: "c", token: "t", e2e: service, publisher: publisher)

        room.publishIfReady()
        XCTAssertFalse(publisher.state().publishing, "not sharing: nothing to list")
        room.markSharingForTests()
        room.publishIfReady()
        XCTAssertFalse(publisher.state().publishing, "sharing, but no identity to be listed under")

        let passkey = E2EPasskeyCeremonyTests.SoftwarePasskey()
        worker.index = .root(passkey.root)
        guard case .success = await identity.signIn(authenticator: passkey, transport: worker) else { return XCTFail("sign in") }
        service.invalidateStatus()
        room.publishIfReady()
        XCTAssertTrue(publisher.state().publishing, "enrolled while sharing: listed now, not at the next Share")

        room.stop()
        room.publishIfReady()
        XCTAssertFalse(publisher.state().publishing, "a stopped room lists nothing")
    }
    func testMediaResumeAlreadyDispatchedCannotResurrectStoppedRoom() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stop-race-\(UUID().uuidString)")
        var config = HostConfig.from(environment: [:]); config.pasteDirectory = dir.path
        let session = HostSession(config: config)
        defer { session.end(); try? FileManager.default.removeItem(at: dir) }
        let room = SharingRoom(session: session, config: config, code: "c", token: "t", e2e: E2EIdentityService(e2e: .failure(.storageUnavailable)))
        let generation = Data(repeating: 7, count: 16)
        _ = session.peerHub.prepareFast("a", generation: generation)
        session.peerHub.clientJoined("a", claim: true)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = expectation(description: "dispatched resume finished")
        room.beforeFastMediaResumeForTests = { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        let message = try JSONSerialization.data(withJSONObject: ["t": "fast-media-rebuild", "generation": base64urlEncode(generation), "mode": "rebuild"])
        DispatchQueue.global().async { room.deliverSignallingForTests(message, from: "a"); done.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        room.stop()
        release.signal()
        wait(for: [done], timeout: 5)
        XCTAssertNil(session.channelHub.currentDriver(), "a command admitted before Stop must not create a new driver afterwards")
    }

}
