import CoreVideo
import XCTest
import RdevCore
@testable import RdevHostKit

private final class NullVideo: VideoEncoding, @unchecked Sendable {
    var codec: NegotiatedCodec { .av1 }
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64) {}
    func addSink(_ s: any VideoTrackSink) {}
    func removeSink(_ s: any VideoTrackSink) {}
    func removeAllSinks() {}
    func requestKeyframe() {}
    func setFps(_ v: Int) {}
    func setBitrate(_ v: Int) {}
    func setCrop(_ v: CropRect) {}
    func invalidate() {}
}

/// The host's session STATE in SimManager (docs/superpowers/specs/2026-09-29-host-session-state-design.md):
/// windows opened, minimized, closed and positioned; a stream exactly for each streamed window while a
/// driver is reconciled; the driver's preferences resolving every stream; a grace teardown that stops
/// the streams and KEEPS the state. Real SimManager + ChannelHub; no ScreenCaptureKit
/// (`attachesCaptureForTests`), window owners faked (`windowOwnerPID` — a made-up window id has no
/// owner, and an unknown owner FAILS CLOSED as the host's own).
final class SimManagerSessionTests: XCTestCase {
    private var hub: ChannelHub!
    private var sim: SimManager!

    private func make(grace: Int = 60) {
        hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: NullVideo(),
                         terminalPauseHold: .milliseconds(50), mediaPauseHold: .milliseconds(50))
        sim = SimManager(makeEncoder: { _, _, _, _ in NullVideo() }, channelHub: hub,
                         defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                         bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000,
                         graceSeconds: grace)
        sim.attachesCaptureForTests = false
        sim.windowOwnerPID = { _ in 4242 }            // some application that is not this process
        sim.existingWindowIDs = { [] }                // no window exists unless a test says so
        hub.simDelegate = sim
        hub.isVideoSubscribed = { true }              // the product path, not the headless one
    }

    func testRestoredAgentTabsReachEveryClientsStateWithoutRuntimeStatus() throws {
        make()
        var old=SessionState();_=old.openAgent("one",title:"Build",cwd:"/project")
        _=old.setAgentStatus("one","active")
        sim.restoreAgentTabs(SavedAgentTabs(state:old,terminalIDs:[]),terminalIDs:[:])
        for client in ["a","new-client"] {
            let data=try XCTUnwrap(try JSONSerialization.jsonObject(with:sim.viewSetPayload(forClient:client)) as? [String:Any])
            XCTAssertEqual((data["agents"] as? [[String:Any]])?.first?["id"] as? String,"one")
            XCTAssertEqual(data["selectedAgent"] as? String,"one")
            XCTAssertEqual((data["view"] as? [String:Any])?["surface"] as? String,"agents")
            XCTAssertNil((data["agents"] as? [[String:Any]])?.first?["status"])
        }
    }

    override func tearDown() {
        hub?.simDelegate = nil
        hub = nil; sim = nil
    }

    private func viewSet() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: sim.viewSetPayload(forClient: "a"))) as? [String: Any] ?? [:]
    }
    private func windows() -> [[String: Any]] { viewSet()["windows"] as? [[String: Any]] ?? [] }
    private func sources() -> [String?] { windows().map { $0["source"] as? String } }
    private func minimized() -> [Bool?] { windows().map { $0["minimized"] as? Bool } }
    private func version() -> Int { (viewSet()["version"] as? NSNumber)?.intValue ?? -1 }
    private func waitUntil(_ what: String, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !cond() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(cond(), what)
    }

    func testBlockedOldRaiseFinishesBeforeAnyNewerSourceRaise() {
        make()
        let a = BlockingFocusInjector(), b = BlockingFocusInjector()
        let aBegan = expectation(description: "A AX began")
        let unblock = DispatchSemaphore(value: 0), bBegan = DispatchSemaphore(value: 0)
        a.onFirstRaise = { aBegan.fulfill(); _ = unblock.wait(timeout: .now() + 3) }
        b.onFirstRaise = { bBegan.signal() }
        _ = sim.openWindow(sourceID: "win:11", requestedBy: "a")
        _ = sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.setInjectorForTests("win:11", a)
        sim.setInjectorForTests("win:12", b)
        sim.focusSource(sourceID: "win:11", requestedBy: "a")
        wait(for: [aBegan], timeout: 3)
        sim.focusSource(sourceID: "win:12", requestedBy: "a")
        let early = bBegan.wait(timeout: .now() + 0.15)
        unblock.signal()
        XCTAssertEqual(early, .timedOut, "concurrent AX raises let a blocked old activation steal focus after the new one")
        if early == .timedOut { XCTAssertEqual(bBegan.wait(timeout: .now() + 3), .success) }
    }

    func testOpeningAWindowPutsItInTheStateAndStreamsIt() {
        make()
        XCTAssertTrue(sim.openWindow(sourceID: "win:11", requestedBy: "a"))
        XCTAssertEqual(sources(), ["win:11"])
        XCTAssertEqual(minimized(), [false])
        XCTAssertEqual(viewSet()["focused"] as? String, "win:11")
        XCTAssertEqual(sim.subscribedSourceIDs(), ["win:11"])
    }

    func testClosingAgentOntoWindowRoutesFocusToThatWindow() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        let target = BlockingFocusInjector()
        let raised = expectation(description: "landing window raised")
        target.onFirstRaise = { raised.fulfill() }
        sim.setInjectorForTests("win:11", target)
        sim.agentTab(action: "open-tab", thread: "one", title: "Build", cwd: "")
        _ = sim.moveTab("agent:one", before: "win:12")
        sim.agentTab(action: "close-tab", thread: "one", title: "", cwd: "")
        XCTAssertEqual(viewSet()["focused"] as? String, "win:11")
        wait(for: [raised], timeout: 1)
    }

    /// WHAT AN OFFER CARRIES OF THE WINDOWS (docs/sources-and-focus.md, "The offer carries the tab bar"): the
    /// session state as a `view-set` — its windows, focus, view, the bar's order — with NO live echo (it is built on
    /// pion's dispatcher, which must not reach the bridge), then a `source-list` naming ONLY the session's windows,
    /// as the last listing named them. A window the last listing did not name is simply absent from it.
    func testTheOffersWindowsAreTheStateWithNoEchoAndTheListedNamesOfItsWindows() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.openWindow(sourceID: "win:13", requestedBy: "a")
        sim.minimizeWindow(sourceID: "win:12", requestedBy: "a")
        sim.rememberListing([
            Source(id: "win:11", kind: "window", name: "Safari — Docs", inputCapable: true, running: true, w: 800, h: 600),
            Source(id: "win:12", kind: "window", name: "Mail", inputCapable: true, running: true),
            Source(id: "win:99", kind: "window", name: "Not in the session", inputCapable: true, running: true),
        ])
        let payloads = sim.offerStatePayloads().map { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:] }
        XCTAssertEqual(payloads.map { $0["t"] as? String }, ["view-set", "source-list"])
        let vs = payloads[0], live = viewSet()
        for key in ["windows", "tabOrder", "view", "focused", "version"] {
            XCTAssertEqual(vs[key] as? NSObject, live[key] as? NSObject, "the state's \(key), as the control channel carries it")
        }
        XCTAssertEqual((vs["subs"] as? [Any])?.count, 0, "no live echo")
        XCTAssertFalse((live["subs"] as? [Any] ?? []).isEmpty, "(the control channel's has one)")
        for key in ["activeRecovery", "recoveryOverrideBp", "playoutDelayMinMs", "playoutDelayMaxMs", "curtainUp"] {
            XCTAssertNil(vs[key], "\(key) is the bridge's or the curtain's: absent means unknown")
        }
        let named = (payloads[1]["sources"] as? [[String: Any]] ?? []).map { "\($0["id"] ?? "") \($0["name"] ?? "")" }
        XCTAssertEqual(named, ["win:11 Safari — Docs", "win:12 Mail"], "the session's windows only, as listed")
    }

    func testAnOfferOfASessionWithNoWindowsCarriesItsStateAndNoNames() {
        make()
        sim.rememberListing([Source(id: "win:99", kind: "window", name: "Mail", inputCapable: true, running: true)])
        let types = sim.offerStatePayloads().map { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["t"] as? String }
        XCTAssertEqual(types, ["view-set"])
    }

    func testTheHostsOwnWindowIsRefusedAndNeverEntersTheState() {
        make()
        sim.windowOwnerPID = { _ in ProcessInfo.processInfo.processIdentifier }
        XCTAssertFalse(sim.openWindow(sourceID: "win:12", requestedBy: "a"))
        XCTAssertEqual(sources(), [])
        XCTAssertEqual(sim.subscribedSourceIDs(), [])
    }

    func testWorkspaceAutoBitrateFollowsFixedEncodedPanelsAndHonorsManualBudget() throws {
        make()
        let connection = WorkspaceTestConnection()
        hub.register(clientId: connection.clientId, peer: connection)
        sim.workspaceConnectionCapability(true, clientID: connection.clientId, connectionID: ObjectIdentifier(connection))
        hub.receive(.clientHello(prefs: .default, delivery: .rtp, av1ReferenceAck: nil), from: connection)
        let id = "apps:" + UUID().uuidString
        sim.workspaceDisplayForTests = { $0 == id ? 999 : nil }
        XCTAssertTrue(sim.openWindow(sourceID: id, requestedBy: connection.clientId))
        let expected = resolutionBitrateBps(pixelW: 3840, pixelH: 800, fps: 60,
                                          floorBps: 2_000_000, capBps: 8_000_000)
        XCTAssertEqual(try XCTUnwrap(sim.fullPrefsForTests(id)).bitrateBps, expected,
                       "one encoded frame carries RGB, alpha and hit panels, not the flat unknown-size fallback")
        sim.reconcile(driverPrefs: ClientPrefs(fps: 30, scale: .fixed(0.25)))
        let fixed = try XCTUnwrap(sim.fullPrefsForTests(id))
        XCTAssertEqual(fixed.scale, 1)
        XCTAssertEqual(fixed.bitrateBps, resolutionBitrateBps(pixelW: 3840, pixelH: 800, fps: 30,
                        floorBps: 2_000_000, capBps: 8_000_000),
                       "ordinary resolution preferences cannot shrink the budget of a fixed-size workspace")
        sim.reconcile(driverPrefs: ClientPrefs(fps: 60, scale: .fixed(0.25), bitrateBps: 3_000_000))
        XCTAssertEqual(try XCTUnwrap(sim.fullPrefsForTests(id)).bitrateBps, 3_000_000,
                       "an explicit client budget still wins")
    }

    func testUnsupportedWorkspaceCodecPausesInputAndMediaUntilFreshCapability() {
        make()
        let connection = WorkspaceTestConnection()
        hub.register(clientId: connection.clientId, peer: connection)
        sim.workspaceConnectionCapability(true, clientID: connection.clientId, connectionID: ObjectIdentifier(connection))
        let id = "apps:" + UUID().uuidString
        sim.workspaceDisplayForTests = { $0 == id ? 999 : nil }
        sim.installStreamForTests(sourceID: id, target: .workspace(999), ownerPID: nil, audioEncoder: WorkspaceNullAudio())
        let injector = WorkspaceReleaseSpy()
        sim.setInjectorForTests(id, injector); hub.setInjector(injector)
        sim.ensureEncoder(sourceID: id, codec: .h264)
        XCTAssertEqual(injector.releases, 1, "a picture the receiver cannot decode must not retain live input")
        XCTAssertFalse(sim.subscribedSourceIDs().contains(id))
        XCTAssertTrue(sim.sessionContainsForTests(id), "unsupported codec retains application placement and tab")
        sim.reconcile(driverPrefs: .default)
        XCTAssertFalse(sim.subscribedSourceIDs().contains(id), "ordinary reconciliation cannot resurrect refused media")
        sim.workspaceConnectionCapability(true, clientID: connection.clientId, connectionID: ObjectIdentifier(connection))
        XCTAssertTrue(sim.subscribedSourceIDs().contains(id), "fresh capability is the explicit retry boundary")
    }

    func testWorkspaceCapabilityRecordDoesNotRetainADeadConnection() throws {
        var connection: WorkspaceTestConnection? = WorkspaceTestConnection()
        weak var observed = connection
        let record = WorkspaceConnectionCapability(try XCTUnwrap(connection))
        XCTAssertTrue(record.matches(try XCTUnwrap(connection)))
        connection = nil
        XCTAssertNil(observed, "capability records cannot extend a connection lifetime")
        XCTAssertNil(record.peer, "the authorization vanishes when its connection deallocates")
        XCTAssertFalse(record.matches(WorkspaceTestConnection()), "same client ID is not the same live connection")
    }

    func testCapableWorkspaceHandoffRetiresInputAndFencesBlockedWorkAcrossReturn() throws {
        make()
        let a = WorkspaceTestConnection("capable-a"), b = WorkspaceTestConnection("capable-b")
        hub.register(clientId: a.clientId, peer: a)
        hub.register(clientId: b.clientId, peer: b)
        for connection in [a,b] {
            sim.workspaceConnectionCapability(true, clientID: connection.clientId, connectionID: ObjectIdentifier(connection))
            hub.receive(.clientHello(prefs: .default, delivery: .rtp, av1ReferenceAck: nil), from: connection)
        }
        let id = "apps:" + UUID().uuidString
        sim.workspaceDisplayForTests = { $0 == id ? 999 : nil }
        sim.installStreamForTests(sourceID: id, target: .workspace(999), ownerPID: nil, audioEncoder: WorkspaceNullAudio())
        let retired = WorkspaceReleaseSpy()
        sim.setInjectorForTests(id, retired); hub.setInjector(retired)
        let oldOwnership = WorkspaceInputOwnership(epoch: hub.currentDriverEpoch(), current: { [hub] in hub?.currentDriverEpoch() })
        let queue = DispatchQueue(label: "workspace.blocked.old-input")
        let unblock = DispatchSemaphore(value: 0), completed = expectation(description: "old native queue drained")
        let posted = WorkspacePostedCounter()
        queue.async {
            unblock.wait()
            let lease = WorkspaceInputLease()
            lease.perform(whileReady: { oldOwnership.isCurrent }) { posted.increment() }
            completed.fulfill()
        }
        hub.receive(.claimControl(grid: nil), from: b)
        XCTAssertNil(sim.injectorForTests(id), "capable-to-capable handoff must retire the old injector too")
        XCTAssertFalse(oldOwnership.isCurrent)
        hub.receive(.claimControl(grid: nil), from: a)
        XCTAssertFalse(oldOwnership.isCurrent, "A→B→A never revives A's old input generation")
        let newOwnership = WorkspaceInputOwnership(epoch: hub.currentDriverEpoch(), current: { [hub] in hub?.currentDriverEpoch() })
        XCTAssertTrue(newOwnership.isCurrent)
        unblock.signal(); wait(for: [completed], timeout: 2)
        XCTAssertEqual(posted.value, 0, "blocked old down/key/drag cannot post under the new owner")
        XCTAssertFalse(hub.performInput(ifCurrentEpoch: oldOwnership.epoch) { posted.increment() })
        XCTAssertTrue(hub.performInput(ifCurrentEpoch: newOwnership.epoch) { posted.increment() })
        XCTAssertEqual(posted.value, 1)
    }

    func testSameIDDriverAdmissionRetiresThePreviousOwnershipEpoch() {
        make()
        let first = WorkspaceTestConnection(), replacement = WorkspaceTestConnection()
        hub.register(clientId: first.clientId, peer: first)
        let ownership = WorkspaceInputOwnership(epoch: hub.currentDriverEpoch(), current: { [hub] in hub?.currentDriverEpoch() })
        hub.register(clientId: replacement.clientId, peer: replacement)
        XCTAssertFalse(ownership.isCurrent, "same-ID admission replacement is a new input owner")
        XCTAssertFalse(hub.performInput(ifCurrentEpoch: ownership.epoch) { XCTFail("retired admission posted") })
    }

    func testWorkspaceCapabilityDoesNotSurviveSameIDConnectionReplacement() throws {
        make()
        let first = WorkspaceTestConnection(), second = WorkspaceTestConnection()
        hub.register(clientId: "workspace-client", peer: first)
        sim.workspaceConnectionCapability(true, clientID: first.clientId, connectionID: ObjectIdentifier(first))
        let id = "apps:" + UUID().uuidString
        sim.workspaceDisplayForTests = { $0 == id ? 999 : nil }
        sim.installStreamForTests(sourceID: id, target: .workspace(999), ownerPID: nil, audioEncoder: WorkspaceNullAudio())
        sim.reconcile(driverPrefs: .default)
        XCTAssertTrue(sim.subscribedSourceIDs().contains(id))
        hub.rebindPeer(clientId: first.clientId, peer: second)
        hub.receive(try XCTUnwrap(parseInbound(Data(#"{"t":"client-hello","prefs":{}}"#.utf8))), from: second)
        XCTAssertFalse(sim.subscribedSourceIDs().contains(id), "legacy replacement never declared packed support")
        XCTAssertTrue(sim.sessionContainsForTests(id))
        hub.receive(try XCTUnwrap(parseInbound(Data(#"{"t":"apps-capabilities","packedV1":true}"#.utf8))), from: second)
        XCTAssertTrue(sim.subscribedSourceIDs().contains(id), "explicit capability from replacement restores media")
        sim.workspaceConnectionCapability(true, clientID: first.clientId, connectionID: ObjectIdentifier(first))
        sim.reconcile(driverPrefs: .default)
        XCTAssertTrue(sim.subscribedSourceIDs().contains(id), "late retired-connection announcement cannot overwrite current capability")
    }

    func testRevocationDuringPreparationCannotInstallWorkspaceStream() {
        make()
        let connection = WorkspaceTestConnection()
        hub.register(clientId: connection.clientId, peer: connection)
        let id = "apps:" + UUID().uuidString
        sim.workspaceDisplayForTests = { $0 == id ? 999 : nil }
        sim.installStreamForTests(sourceID: id, target: .workspace(999), ownerPID: nil, audioEncoder: WorkspaceNullAudio())
        sim.workspaceCapability(false, clientID: connection.clientId)
        XCTAssertFalse(sim.subscribedSourceIDs().contains(id))
        sim.beforeStreamInstallForTests = { [unowned self] in
            self.sim.beforeStreamInstallForTests = nil
            self.sim.workspaceCapability(false, clientID: connection.clientId)
        }
        sim.workspaceCapability(true, clientID: connection.clientId)
        XCTAssertFalse(sim.subscribedSourceIDs().contains(id), "old prepared work cannot undo a newer revoke")
        XCTAssertTrue(sim.sessionContainsForTests(id))
    }

    func testCapabilityRevocationDetachesFocusedWorkspaceInputButKeepsItsTab() {
        make()
        let id = "apps:" + UUID().uuidString
        let injector = WorkspaceReleaseSpy()
        sim.installStreamForTests(sourceID: id, target: .workspace(999), ownerPID: nil,
                                  audioEncoder: WorkspaceNullAudio())
        sim.setInjectorForTests(id, injector)
        hub.setInjector(injector)
        sim.workspaceCapability(false, clientID: "a")
        XCTAssertEqual(injector.releases, 1, "revocation detaches and drains the old focused injector")
        XCTAssertTrue(sim.sessionContainsForTests(id), "capability loss parks presentation, not membership")
        XCTAssertFalse(sim.subscribedSourceIDs().contains(id))
        hub.setInjector(nil)
        XCTAssertEqual(injector.releases, 1, "the old injector is no longer routed")
    }

    func testMinimizingKeepsTheWindowButStopsItsStream() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.minimizeWindow(sourceID: "win:12", requestedBy: "a")
        XCTAssertEqual(sources(), ["win:11", "win:12"])
        XCTAssertEqual(minimized(), [false, true])
        XCTAssertEqual(sim.subscribedSourceIDs(), ["win:11"], "a minimized window streams nothing")
        XCTAssertEqual(viewSet()["focused"] as? String, "win:11", "focus falls back to the open window")
        XCTAssertTrue(sim.restoreWindow(sourceID: "win:12", requestedBy: "a"))
        XCTAssertEqual(minimized(), [false, false])
        XCTAssertEqual(sim.subscribedSourceIDs(), ["win:11", "win:12"])
        XCTAssertEqual(viewSet()["focused"] as? String, "win:12", "restoring focuses it")
    }

    /// §4.2: a paste goes to a window that is FOCUSED first — even a focused one is re-announced as
    /// nothing, but an unfocused one becomes the view-set's focus — and only an open window with an
    /// injector is a target.
    func testPasteTargetFocusesTheWindowAndReturnsItsInjector() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        let inj = LoggingInjector()
        sim.setInjectorForTests("win:11", inj)
        XCTAssertEqual(viewSet()["focused"] as? String, "win:12")
        XCTAssertTrue(sim.pasteTarget(sourceID: "win:11") === inj)
        XCTAssertEqual(viewSet()["focused"] as? String, "win:11")
        XCTAssertTrue(sim.pasteTarget(sourceID: "win:11") === inj, "an already-focused window is still a target")
    }

    func testPasteTargetIsNilForMinimizedUnknownAndInjectorless() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.setInjectorForTests("win:11", LoggingInjector())
        sim.setInjectorForTests("win:12", LoggingInjector())
        sim.minimizeWindow(sourceID: "win:12", requestedBy: "a")
        XCTAssertNil(sim.pasteTarget(sourceID: "win:12"), "minimized")
        XCTAssertNil(sim.pasteTarget(sourceID: "win:99"), "unknown")
        sim.setInjectorForTests("win:11", nil)
        XCTAssertNil(sim.pasteTarget(sourceID: "win:11"), "a window still booting has no injector")
    }

    func testClosingAWindowRemovesItFromTheState() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.closeWindow(sourceID: "win:12", requestedBy: "a")
        XCTAssertEqual(sources(), ["win:11"])
        XCTAssertEqual(sim.subscribedSourceIDs(), ["win:11"])
        XCTAssertEqual(viewSet()["focused"] as? String, "win:11")
    }

    func testPositionAndViewAreStateAndMoveTheVersion() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        let before = version()
        sim.setWindowPosition(sourceID: "win:11", x: 120, y: 64, requestedBy: "a")
        sim.setView(surface: .windows, fullscreen: .some("win:11"), requestedBy: "a")
        XCTAssertEqual((windows().first?["x"] as? NSNumber)?.doubleValue, 120)
        XCTAssertEqual((windows().first?["y"] as? NSNumber)?.doubleValue, 64)
        let view = viewSet()["view"] as? [String: Any]
        XCTAssertEqual(view?["surface"] as? String, "windows")
        XCTAssertEqual(view?["fullscreen"] as? String, "win:11")
        XCTAssertGreaterThan(version(), before)
    }

    /// THE POINT OF THE FEATURE: a driver leaving for good stops the capture after the grace, and the
    /// session it left survives for whoever connects next.
    func testTheGraceTeardownStopsTheStreamsAndKeepsTheState() {
        make(grace: 0)
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.minimizeWindow(sourceID: "win:12", requestedBy: "a")
        sim.setWindowPosition(sourceID: "win:11", x: 10, y: 20, requestedBy: "a")
        sim.onClientGone()
        waitUntil("the streams stopped") { self.sim.subscribedSourceIDs().isEmpty }
        XCTAssertEqual(sources(), ["win:11", "win:12"], "THE STATE IS KEPT")
        XCTAssertEqual(minimized(), [false, true])
        XCTAssertEqual((windows().first?["x"] as? NSNumber)?.doubleValue, 10)
        XCTAssertEqual(viewSet()["focused"] as? String, "win:11")
    }

    func testANewDriverIsReconciledBackToTheState() {
        make(grace: 0)
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.minimizeWindow(sourceID: "win:12", requestedBy: "a")
        sim.onClientGone()
        waitUntil("the streams stopped") { self.sim.subscribedSourceIDs().isEmpty }
        sim.reconcile(driverPrefs: ClientPrefs(fps: 30, bitrateBps: 3_000_000))
        XCTAssertEqual(sim.subscribedSourceIDs(), ["win:11"], "exactly the streamed windows — not the minimized one")
        XCTAssertEqual(sim.fullPrefsForTests("win:11")?.fps, 30)
        XCTAssertEqual(sim.fullPrefsForTests("win:11")?.bitrateBps, 3_000_000)
    }

    /// A layout intent, or a listing, arriving with nobody driving must not resurrect capture.
    func testNothingIsBuiltWithoutADriver() {
        make(grace: 0)
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.onClientGone()
        waitUntil("the streams stopped") { self.sim.subscribedSourceIDs().isEmpty }
        sim.setWindowPosition(sourceID: "win:11", x: 1, y: 2, requestedBy: "a")
        sim.setView(surface: .windows, fullscreen: nil, requestedBy: "a")
        sim.retainListed(sourceIDs: ["win:11"])
        XCTAssertEqual(sim.subscribedSourceIDs(), [])
    }

    func testTheDriversPreferencesResolveEveryStream() {
        make()
        sim.reconcile(driverPrefs: ClientPrefs(fps: 24, scale: .auto, codec: .h265))
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.setSourceView(sourceID: "win:12", scale: 0.5, crop: nil, requestedBy: "a")
        XCTAssertEqual(sim.fullPrefsForTests("win:11")?.fps, 24)
        XCTAssertEqual(sim.fullPrefsForTests("win:12")?.fps, 24, "ONE preference for every window")
        XCTAssertEqual(sim.fullPrefsForTests("win:11")?.scale, 1, "Auto, no ceiling reported yet: the default")
        XCTAssertEqual(sim.fullPrefsForTests("win:12")?.scale, 0.5, "Auto: the ceiling this window's page reported")
        XCTAssertEqual(sim.codecPrefForSource("win:11"), .h265)
        sim.reconcile(driverPrefs: ClientPrefs(fps: 60, scale: .fixed(0.25)))
        XCTAssertEqual(sim.fullPrefsForTests("win:12")?.scale, 0.25, "a FIXED resolution wins over the page's ceiling")
        XCTAssertEqual(sim.codecPrefForSource("win:11"), .auto, "another driver's codec takes over")
    }

    /// A change of driver forgets every window's Auto ceiling AND crop (contract amendment 3): both are
    /// what the OUTGOING viewer's page derived from its own boxes; the incoming one re-derives them.
    func testAChangeOfViewerForgetsTheAutoCeilingAndTheCrop() {
        make()
        sim.reconcile(driverPrefs: .default)
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        let corner = CropRect(x: 0, y: 0, w: 0.5, h: 0.5)
        sim.setSourceView(sourceID: "win:11", scale: 0.4, crop: corner, requestedBy: "a")
        XCTAssertEqual(sim.fullPrefsForTests("win:11")?.scale, 0.4, "precondition: the page's ceiling")
        XCTAssertEqual(sim.fullPrefsForTests("win:11")?.crop, corner, "precondition: the page's crop")
        sim.resetViewerDerived()
        sim.reconcile(driverPrefs: .default)
        XCTAssertEqual(sim.fullPrefsForTests("win:11")?.scale, 1, "the incoming viewer starts from the default")
        XCTAssertEqual(sim.fullPrefsForTests("win:11")?.crop, .full)
    }

    /// `subs` echoes each stream's RESOLVED prefs — never the throttled rate an unfocused window
    /// actually runs at (contract amendment 3): the titlebar shows the preference, not the throttle.
    func testSubsEchoTheResolvedPrefsNotTheThrottle() {
        make()
        sim.reconcile(driverPrefs: ClientPrefs(fps: 50))
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")        // win:11 is now unfocused (throttled)
        let subs = viewSet()["subs"] as? [[String: Any]] ?? []
        XCTAssertEqual(subs.map { ($0["fps"] as? NSNumber)?.intValue }, [50, 50])
    }

    func testAWindowGoneFromTheListingLeavesTheStateButADisplayDoesNot() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.minimizeWindow(sourceID: "win:12", requestedBy: "a")
        sim.openWindow(sourceID: "dsp:987654", requestedBy: "a")
        // win:12's app quit; the display is not listed either — as a SLEEPING display is not.
        sim.retainListed(sourceIDs: ["win:11"])
        XCTAssertEqual(sources(), ["win:11", "dsp:987654"])
        XCTAssertFalse(sim.subscribedSourceIDs().contains("win:12"))
    }

    /// NOT LISTED IS NOT GONE. The listing carries on-screen windows plus minimized ones, so a window
    /// whose app is HIDDEN (⌘H), on another Space, behind a full-screen app, under 64 pt or with an empty
    /// title is absent from it while its app runs — and any client's control open lists. Only a window
    /// the window server no longer has leaves the state (final review, 2026-09-29).
    func testAWindowMissingFromTheListingButStillExistingStays() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.minimizeWindow(sourceID: "win:12", requestedBy: "a")
        sim.existingWindowIDs = { [11, 12] }
        let before = version()
        sim.retainListed(sourceIDs: [])               // e.g. the app was hidden with ⌘H
        XCTAssertEqual(sources(), ["win:11", "win:12"], "a hidden app's windows stay")
        XCTAssertEqual(version(), before, "and the state did not change at all")
        XCTAssertEqual(sim.subscribedSourceIDs(), ["win:11"])
        // PAIRED: the same listing once win:12's window is really gone drops it, and only it — so the
        // assertions above are about existence, not about a listing that can no longer prune.
        sim.existingWindowIDs = { [11] }
        sim.retainListed(sourceIDs: [])
        XCTAssertEqual(sources(), ["win:11"])
    }

    /// A listing WITHOUT Screen Recording is EMPTY — the permission missing, not every window gone — and
    /// must prune NOTHING: a revoked grant or a first-run prompt would otherwise wipe the session.
    func testAnUnauthorizedListingPrunesNothing() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.minimizeWindow(sourceID: "win:12", requestedBy: "a")
        let before = version()
        sim.applyListing(sourceIDs: [], authorized: false)
        XCTAssertEqual(sources(), ["win:11", "win:12"], "every window survives, the minimized one too")
        XCTAssertEqual(minimized(), [false, true])
        XCTAssertEqual(version(), before, "and the state did not change at all")
        XCTAssertEqual(sim.subscribedSourceIDs(), ["win:11"])
        // THE NEGATIVE CONTROL: the same empty listing, AUTHORIZED, does prune — so the assertions
        // above are about the permission and not about a listing that could never prune.
        sim.applyListing(sourceIDs: [], authorized: true)
        XCTAssertEqual(sources(), [])
    }

    func testEndingTheSessionForgetsItAndStopsEverything() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.endSession()
        XCTAssertEqual(sim.subscribedSourceIDs(), [])
        XCTAssertEqual(sources(), [], "Stop Sharing ENDS the session; the next Share starts empty")
    }

    // MARK: the bar (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §1 and §3)

    private func tabOrder() -> [String] { viewSet()["tabOrder"] as? [String] ?? [] }

    /// `moveTab` answers the NEW ORDER when it changed — the hub arranges the pool from it — and nil for a
    /// refusal or a move to where the tab already is, with no version moved. A moved window streams in its
    /// new place: `windows`, and so `subscribedSourceIDs`, follow the bar.
    func testMoveTabAnswersTheNewOrderOnlyWhenItChanged() {
        make()
        sim.syncTerminalTabs(["pty:1"])
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        XCTAssertEqual(tabOrder(), ["pty:1", "win:11", "win:12"])
        XCTAssertEqual(sim.moveTab("win:12", before: "pty:1"), ["win:12", "pty:1", "win:11"])
        XCTAssertEqual(tabOrder(), ["win:12", "pty:1", "win:11"])
        XCTAssertEqual(sources(), ["win:12", "win:11"], "windows follow the bar")
        XCTAssertEqual(sim.subscribedSourceIDs(), ["win:12", "win:11"])
        let v = version()
        XCTAssertNil(sim.moveTab("win:12", before: "pty:1"), "already there")
        XCTAssertNil(sim.moveTab("win:99", before: nil), "not in the bar")
        XCTAssertNil(sim.moveTab("pty:1", before: "pty:1"), "before itself")
        XCTAssertEqual(version(), v)
    }

    /// A window's name is session state: it rides `view-set` while set, clears with "", outlives a
    /// minimize, and an unknown window or a refused name moves nothing.
    func testRenamingAWindowIsSessionState() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.renameWindow(sourceID: "win:11", name: "mail", requestedBy: "a")
        XCTAssertEqual(windows().first?["name"] as? String, "mail")
        sim.minimizeWindow(sourceID: "win:11", requestedBy: "a")
        XCTAssertEqual(windows().first?["name"] as? String, "mail", "kept while minimized")
        let v = version()
        sim.renameWindow(sourceID: "win:11", name: "mail", requestedBy: "a")
        sim.renameWindow(sourceID: "win:99", name: "x", requestedBy: "a")
        sim.renameWindow(sourceID: "win:11", name: "a\u{7}b", requestedBy: "a")
        XCTAssertEqual(version(), v, "no change, an unknown window, a refused name: nothing moved")
        sim.renameWindow(sourceID: "win:11", name: "", requestedBy: "a")
        XCTAssertNil(windows().first?["name"], "\"\" clears")
        XCTAssertEqual(version(), v + 1)
    }

    /// The terminal half of the bar is whatever the pool last said — new tabs placed beside their
    /// siblings, gone ones dropped — and the same set again (a title change) moves no version.
    func testTheTerminalHalfIsThePoolsLastSet() {
        make()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.syncTerminalTabs(["pty:1", "tmux:$2"])
        XCTAssertEqual(tabOrder(), ["pty:1", "tmux:$2", "win:11"])
        let v = version()
        sim.syncTerminalTabs(["pty:1", "tmux:$2"])
        XCTAssertEqual(version(), v, "the same set: no change")
        sim.syncTerminalTabs(["tmux:$2"])
        XCTAssertEqual(tabOrder(), ["tmux:$2", "win:11"])
        XCTAssertEqual(version(), v + 1)
    }
}

private final class WorkspaceReleaseSpy: InputInjector {
    var releases = 0
    func inject(touchNormalizedX: Double, y: Double, phase: String, button: MouseButton) {}
    func releaseKeys() { releases += 1 }
}
private final class WorkspaceNullAudio: AudioEncoding {
    func encode(_ frame: AudioFraming.Frame) {}
    func addSink(_ sink: any AudioTrackSink) {}
    func removeSink(_ sink: any AudioTrackSink) {}
    func removeAllSinks() {}
    func setBitrate(_ value: Int) {}
    func invalidate() {}
}

private final class WorkspaceTestConnection: ClientConnection {
    let clientId: String
    init(_ clientId: String = "workspace-client") { self.clientId = clientId }
    var presentation: ClientPresentation { .streamedSources }
    var mediaPeer: PionPeer? { nil }
    func send(_ channel: PionChannel, _ data: Data) {}
}

private final class WorkspacePostedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class BlockingFocusInjector: InputInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    var onFirstRaise: (() -> Void)?
    func inject(touchNormalizedX x: Double, y: Double, phase: String, button: MouseButton) {}
    func raise() {
        let shouldRun = lock.withLock { () -> Bool in guard first else { return false }; first = false; return true }
        if shouldRun { onFirstRaise?() }
    }
}
