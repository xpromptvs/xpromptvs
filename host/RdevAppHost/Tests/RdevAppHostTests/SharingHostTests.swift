import Foundation
import RdevHostKit
import XCTest
@testable import RdevAppHost

/// **THE APP'S SESSION OUTLIVES SHARING** (docs/desktop-app.md, "The local window"): the local window's
/// socket lives through Stop Sharing, and only the session's END — a quit — closes it.
final class SharingHostTests: XCTestCase {
    private final class Probe: MessageSocket, @unchecked Sendable {
        private let lock = NSLock()
        private var why: String?
        var reason: String? { lock.withLock { why } }
        func start(onFrame: @escaping (Data) -> Void, onClose: @escaping () -> Void) {}
        func send(_ frame: Data) {}
        func close(reason: String) { lock.withLock { if why == nil { why = reason } } }
    }

    func testTheLocalWindowsSocketLivesUntilTheSessionEnds() {
        let host = SharingHost()
        // Never the app's own folder: a session EMPTIES its paste folder at launch.
        let pastes = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-pastes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pastes) }
        host.beginSession(pasteDirectory: pastes)
        let socket = Probe()
        host.acceptLocal(socket)
        host.stop()
        XCTAssertNil(socket.reason, "Stop Sharing closed the local window's socket")
        host.endSession()
        XCTAssertEqual(socket.reason, "the session ended")
        let late = Probe()
        host.acceptLocal(late)
        XCTAssertEqual(late.reason, "no session", "a quitting app admits nobody")
        XCTAssertEqual(host.tabCount, 0)
    }
}
