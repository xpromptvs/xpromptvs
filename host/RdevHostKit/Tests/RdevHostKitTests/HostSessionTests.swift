import XCTest
import RdevCore
@testable import RdevHostKit

/// **THE SESSION OUTLIVES SHARING** (docs/sources-and-focus.md, "The session's lifetime"): Stop Sharing
/// closes the door — every relay client leaves — and leaves the tabs and the socket clients alone; only
/// the session's END (a quit) closes the shells.
final class HostSessionTests: XCTestCase {
    private var session: HostSession!
    private var room: SharingRoom!
    /// Never the process's own Caches folder: a session EMPTIES its paste folder at launch.
    private var pasteDir: URL!

    private func config(pasteDirectory: URL) -> HostConfig {
        var c = HostConfig.from(environment: [:])
        c.pasteDirectory = pasteDirectory.path
        return c
    }

    override func setUp() {
        pasteDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-pastes-\(UUID().uuidString)")
        session = HostSession(config: config(pasteDirectory: pasteDir))
        // Never started: no relay socket, no listing. `stop()` still runs every step of Stop Sharing.
        room = SharingRoom(session: session, config: HostConfig.from(environment: [:]), code: "c", token: "t",
                           e2e: E2EIdentityService(e2e: .failure(.storageUnavailable)))
    }

    override func tearDown() {
        session.end()
        session.sockets.drainForTests()
        try? FileManager.default.removeItem(at: pasteDir)
    }

    /// **THE PASTE FOLDER** (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §6) is the config's,
    /// emptied at LAUNCH — a run that ended cleanly left nothing, so anything there is a crash's — and at the
    /// session's END, a quit.
    func testThePasteFolderIsEmptiedAtLaunchAndAtTheEnd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("session-pastes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("left by a crash".utf8).write(to: dir.appendingPathComponent("old.png"))
        let s = HostSession(config: config(pasteDirectory: dir))
        XCTAssertEqual(s.pasteStore.directory.path, dir.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        let f = try s.pasteStore.open(name: "a.png", type: "image/png")
        try f.append(Data([1])); _ = try s.pasteStore.commit(f)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
        s.end()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    /// A socket client with a shell open, as the app's local window leaves it.
    private func localWindowWithAShell() async -> MemorySocket {
        let s = MemorySocket()
        session.accept(s)
        s.hello("tab-1")
        s.sends(.control, #"{"t":"term-mode","mode":"raw"}"#)
        s.sends(.control, #"{"t":"open-terminal"}"#)
        session.sockets.drainForTests()
        let session = self.session!
        await waitUntil({ session.tabCount == 1 }, "the shell to open")
        return s
    }

    /// **A WINDOW-LESS CLIENT GETS THE BAR** (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md):
    /// the app's local window is a control client like any other, so the session's `view-set` — its
    /// `tabOrder` — reaches it, and its `move-tab` and `rename-tab` (permitted to a window-less client)
    /// arrange the bar and name a tab.
    func testAWindowlessClientGetsTheBarAndArrangesIt() async {
        let s = await localWindowWithAShell()
        s.sends(.control, #"{"t":"open-terminal"}"#)
        session.sockets.drainForTests()
        let lastTabOrder: @Sendable () -> [String]? = {
            for json in s.controlMessages.reversed() {
                guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      o["t"] as? String == "view-set" else { continue }
                return o["tabOrder"] as? [String]
            }
            return nil
        }
        await waitUntil({ lastTabOrder() == ["pty:1", "pty:2"] }, "the bar to reach the window-less client")
        s.sends(.control, #"{"t":"move-tab","tab":"pty:2","before":"pty:1"}"#)
        s.sends(.control, #"{"t":"rename-tab","tab":"pty:1","name":"build"}"#)
        session.sockets.drainForTests()
        await waitUntil({ lastTabOrder() == ["pty:2", "pty:1"] }, "its move to reorder the bar")
        await waitUntil({ s.controlMessages.contains { $0.contains(#""t":"term-list""#) && $0.contains(#""name":"build""#) } },
                        "its rename to reach the term-list")
    }

    func testStoppingSharingKeepsTheTabsAndTheSocketClient() async {
        let s = await localWindowWithAShell()
        room.stop()
        session.sockets.drainForTests()
        XCTAssertNil(s.closedReason, "Stop Sharing closed the local window's socket")
        XCTAssertEqual(session.tabCount, 1, "Stop Sharing closed a tab")
        XCTAssertTrue(session.channelHub.controlClientIDs().contains("sock:tab-1"))
    }

    /// **STOP SHARING STOPS THE CAPTURES NOW, AND KEEPS THE STATE.** The relay driver's departure arms
    /// SimManager's grace (10 s by default); no driver can return after Stop, so waiting it out left SCK
    /// capturing and encoding for nobody.
    func testStoppingSharingStopsEveryCaptureAtOnceAndKeepsTheWindows() throws {
        let sim = try XCTUnwrap(session.simManager)
        sim.attachesCaptureForTests = false
        sim.windowOwnerPID = { _ in 4242 }
        sim.existingWindowIDs = { [] }
        session.channelHub.isVideoSubscribed = { true }
        XCTAssertTrue(sim.openWindow(sourceID: "win:11", requestedBy: "a"))
        XCTAssertEqual(sim.subscribedSourceIDs(), ["win:11"], "precondition: the window streams")
        sim.onClientGone()   // the grace a departing relay driver arms
        room.stop()
        XCTAssertEqual(sim.subscribedSourceIDs(), [], "Stop Sharing left a capture running")
        let payload = sim.viewSetPayload(forClient: "a")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let windows = json["windows"] as? [[String: Any]] ?? []
        XCTAssertEqual(windows.compactMap { $0["source"] as? String }, ["win:11"], "the state is the session's")
    }

    func testEndingTheSessionClosesTheShellsAndTheSockets() async {
        let s = await localWindowWithAShell()
        session.end()
        session.sockets.drainForTests()
        XCTAssertEqual(s.closedReason, "the session ended")
        XCTAssertEqual(session.tabCount, 0, "every shell is killed")
        let late = MemorySocket()
        session.accept(late)
        XCTAssertEqual(late.closedReason, "the session ended", "an ended session admits nobody")
    }

    func testAColdHostRegistersAClientSuspendedBeforeItsFirstHandshake() {
        let id = "cold-resume"
        session.peerHub.suspend(id)
        _ = session.peerHub.prepareFast(id, generation: Data(repeating: 4, count: 16))
        session.peerHub.resume(id, mode: .rebuild, claim: true)
        XCTAssertTrue(session.channelHub.isActiveClient(id), "a rebuilt media peer must also be registered for control")
    }

    /// Every relay client LEAVES at Stop Sharing — one held in its grace window too, now rather than
    /// 180 s later — so a socket client left behind is promoted to drive.
    func testStoppingSharingMakesEveryRelayClientLeave() async {
        let s = await localWindowWithAShell()
        let relay = WindowlessConnection("relay-1")
        session.channelHub.register(clientId: "relay-1", peer: relay, claim: true)
        session.peerHub.suspend("relay-1")
        XCTAssertEqual(s.controlState?.active, false, "precondition: the relay client drives")
        room.stop()
        session.sockets.drainForTests()
        await waitUntil({ s.controlState?.active == true }, "the socket client to be promoted")
        XCTAssertEqual(s.controlState?.clients, 1)
    }

    /// **THE DRIVER LEAVES LAST**: `ActiveClientTracker` promotes only when ONE client remains as the
    /// driver goes, and set order is random — so with several passive relay clients an order-dependent
    /// Stop left the local window passive in a driverless session.
    func testStoppingSharingPromotesTheSocketClientWhateverTheOrder() async {
        let s = await localWindowWithAShell()
        for i in 0..<6 {   // relay-0 drives (claims); the other five are passive
            let id = "relay-\(i)"
            session.channelHub.register(clientId: id, peer: WindowlessConnection(id), claim: i == 0)
            session.peerHub.suspend(id)
        }
        XCTAssertEqual(s.controlState?.active, false, "precondition: a relay client drives")
        room.stop()
        session.sockets.drainForTests()
        await waitUntil({ s.controlState?.active == true }, "the socket client to be promoted")
        XCTAssertEqual(s.controlState?.clients, 1)
    }

    /// **A RELAY PEER NEVER SPEAKS FOR A SOCKET CLIENT**: a `peer-left` naming `sock:tab-1` would
    /// otherwise reach `PeerHub.clientLeft` and unregister the Mac's own window.
    func testRelayTrafficNamingASocketClientIsIgnored() async {
        let s = await localWindowWithAShell()
        room.handle(.peerLeft("sock:tab-1"))
        room.handle(.peerSuspended("sock:tab-1"))
        XCTAssertTrue(session.channelHub.controlClientIDs().contains("sock:tab-1"),
                      "a relay peer-left unregistered the local window")
        XCTAssertNil(s.closedReason)
    }
}
