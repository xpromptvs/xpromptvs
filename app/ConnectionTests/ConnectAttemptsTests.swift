import ShellstormCore
import XCTest

// Compile the production attempt coordinator against window spies. A show is the native
// makeKeyAndOrderFront/activate boundary; no network or desktop focus is needed to exercise it.
@MainActor
final class ClientWindow {
    var pageGone = false
    var onClosed: (() -> Void)?
    var onGone: (() -> Void)?
    var onLoadFailed: ((ConnectFailure) -> Void)?
    var onConnectionState: ((String, String?) -> Void)?
    private(set) var shows = 0
    func show() { shows += 1 }
    func close() { onClosed?() }
}

@MainActor
final class AppWindows {
    var local: ClientWindow?
    var clients: [ClientWindow] = []
    func openClient(pairing: String?, showWhenReady: Bool, motion: Motion?) -> ClientWindow {
        let client = ClientWindow()
        clients.append(client)
        if showWhenReady { client.show() }
        return client
    }
    func openLocal(showWhenReady: Bool, motion: Motion?) -> ClientWindow {
        let client = openClient(pairing: nil, showWhenReady: showWhenReady, motion: motion)
        local = client
        return client
    }
}

final class ConnectAttemptsTests: XCTestCase {
    @MainActor
    private func checkReveal(initial: String) async throws {
        let windows = AppWindows()
        var closed: [String] = []
        var settlements = 0
        let attempts = ConnectAttempts(windows: windows, notifyClosed: { closed.append($0) })
        attempts.onSettled = { settlements += 1 }
        let task = Task {
            try await attempts.connect(requestId: "remote", motion: nil, pairing: { nil })
        }
        for _ in 0..<1000 {
            if !windows.clients.isEmpty { break }
            await Task.yield()
        }
        let remote = try XCTUnwrap(windows.clients.first)
        XCTAssertEqual(remote.shows, 0, "The pending window stays hidden")
        remote.onConnectionState?(initial, "offline")
        do {
            try await task.value
            XCTAssertEqual(initial, "connected")
        } catch {
            XCTAssertEqual(initial, "error")
        }
        XCTAssertEqual(remote.shows, 1, "The initial result reveals the window")
        XCTAssertEqual(attempts.pendingCount, 0)

        // The user can now be working in This Mac or have minimized the remote window.
        // Background recovery and errors must never ask AppKit to reveal it again.
        for state in ["reconnecting", "connected", "connected", "error"] {
            remote.onConnectionState?(state, "offline")
            XCTAssertEqual(remote.shows, 1, "A settled attempt must not reveal on \(state)")
        }
        remote.onLoadFailed?(.load(domain: "test", code: 1, description: nil))
        XCTAssertEqual(remote.shows, 1, "A later navigation failure must not reveal either")
        XCTAssertEqual(settlements, 1)
        remote.close()
        XCTAssertEqual(closed, ["remote"], "Keep the dashboard's close notification attached")
        XCTAssertEqual(settlements, 1)
    }

    @MainActor
    func testConnectedWindowDoesNotRevealAgain() async throws {
        try await checkReveal(initial: "connected")
    }

    @MainActor
    func testInitiallyFailedWindowDoesNotRevealAgain() async throws {
        try await checkReveal(initial: "error")
    }
}
