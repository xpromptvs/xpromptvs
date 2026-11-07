import XCTest
@testable import RdevHostKit
import RdevCore

final class E2EDirectoryWatcherTests: XCTestCase {
    /// A watcher pointed at a port nothing listens on must report DOWN (not crash, not spin) and,
    /// after three attempts that never opened, STOP as unavailable — the path a proxy that strips
    /// upgrades takes.
    func testAnUnreachableWatchGivesUpAsUnavailable() {
        let stopped = expectation(description: "stopped")
        let creds = E2EDirectoryWatch.Credentials(bundle: [1], rootID: [UInt8](repeating: 1, count: 32),
                                                  signingPrivateKey: [UInt8](repeating: 7, count: 32),
                                                  ownDeviceID: "me")
        let watcher = E2EDirectoryWatcher(
            url: URL(string: "ws://127.0.0.1:9/directory/x/watch")!, credentials: creds,
            onSessions: { _ in XCTFail("no sessions expected") }, onDown: {},
            onStopped: { stop in XCTAssertEqual(stop, .unavailable); stopped.fulfill() },
            backoffMin: 0.05)
        watcher.start()
        wait(for: [stopped], timeout: 10)
        watcher.stop()
    }
}
