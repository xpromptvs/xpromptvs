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

/// Every session call the hub makes, in order. Windows never "open" (false), so the hub adds no track
/// to a never-connected peer.
private final class SessionSpy: SimControlDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _reconciles: [ClientPrefs] = []
    private var _intents: [String] = []
    private var _gone = 0
    private var _settings: [String] = []
    /// What `subscribedSourceIDs` answers — the windows the session streams. Set before use.
    var streamedForTests: [String] = []
    var reconciles: [ClientPrefs] { lock.withLock { _reconciles } }
    var intents: [String] { lock.withLock { _intents } }
    var gone: Int { lock.withLock { _gone } }
    /// The echoed connection settings and the reconciles, in ORDER: "recovery <bp|nil>",
    /// "playout <min|nil> <max|nil>", "reconcile".
    var settings: [String] { lock.withLock { _settings } }
    private func note(_ s: String) { lock.withLock { _intents.append(s) } }

    private var _presentations: [String] = []
    var presentations: [String] { lock.withLock { _presentations } }
    var nativeReconcile: (() -> Void)?
    var remoteReconcile: (() -> Void)?
    func reconcileNative() { nativeReconcile?(); lock.withLock { _presentations.append("native") } }
    func reconcile(driverPrefs: ClientPrefs) {
        remoteReconcile?(); lock.withLock { _presentations.append("remote") }
        lock.withLock { _reconciles.append(driverPrefs); _settings.append("reconcile") }
    }
    func onClientGone() { lock.withLock { _gone += 1 } }
    func onClientBack() {}
    func openWindow(sourceID: String, requestedBy clientId: String) -> Bool { note("open \(sourceID)"); return false }
    func closeWindow(sourceID: String, land: Bool, requestedBy clientId: String) { note("close \(sourceID)\(land ? " land" : "")") }
    func minimizeWindow(sourceID: String, land: Bool, requestedBy clientId: String) { note("minimize \(sourceID)\(land ? " land" : "")") }
    func restoreWindow(sourceID: String, requestedBy clientId: String) -> Bool { note("restore \(sourceID)"); return false }
    func setWindowPosition(sourceID: String, x: Double, y: Double, requestedBy clientId: String) {
        note("position \(sourceID) \(Int(x)) \(Int(y))")
    }
    func setView(surface: SessionSurface?, fullscreen: String??, requestedBy clientId: String) {
        note("view \(surface?.rawValue ?? "-")")
    }
    func moveTab(_ tab: String, before: String?) -> [String]? { note("move \(tab) \(before ?? "end")"); return nil }
    func renameWindow(sourceID: String, name: String, requestedBy clientId: String) { note("name \(sourceID) \(name)") }
    func syncTerminalTabs(_ ids: [String]) {}

    func listSources(forClient clientId: String) {}
    func requestThumbs(forClient clientId: String) {}
    func applyRecoveryPolicy(mediaBitrateBps: UInt32, budgetBps: UInt32) -> Bool { false }
    func ensureEncoder(sourceID: String, codec: NegotiatedCodec) {}
    func setSourceView(sourceID: String, scale: Double?, crop: CropRect?, requestedBy clientId: String) {}
    func resetViewerDerived() {}
    func codecPrefForSource(_ sourceID: String) -> CodecPref { .auto }
    func setRecoveryOverride(bp: Int?) { lock.withLock { _settings.append("recovery \(bp.map(String.init) ?? "nil")") } }
    func setPlayoutDelay(minMs: Int?, maxMs: Int?) {
        lock.withLock { _settings.append("playout \(minMs.map(String.init) ?? "nil") \(maxMs.map(String.init) ?? "nil")") }
    }
    func focusSource(sourceID: String, requestedBy clientId: String) {}
    func pasteTarget(sourceID: String) -> InputInjector? { nil }
    func setSourceAudio(sourceID: String, enabled: Bool, requestedBy clientId: String) {}
    func setSourceSize(sourceID: String, w: Int, h: Int, requestedBy clientId: String) {}
    func simAction(sourceID: String, action: SimAction, requestedBy clientId: String) {}
    func announceCurtainChange() {}
    func sendViewSet(toClient clientId: String) {}
    var offerPayloads: [Data] = []
    func offerStatePayloads() -> [Data] { offerPayloads }
    func sendSourceStatus(toClient clientId: String) {}
    func subscribedSourceIDs() -> [String] { streamedForTests }
    var encoderLookup: (() -> VideoEncoding?)?
    func encoderForSource(_ id: String) -> VideoEncoding? { encoderLookup?() }
    func audioEncoderForSource(_ id: String) -> AudioEncoding? { nil }
    func setHidden(_ hidden: Bool) {}
    func reconcileAudio() {}
    func endSession() {}
}

/// The hub's side of the session state (docs/superpowers/specs/2026-09-29-host-session-state-design.md):
/// a driver is reconciled only once its `client-hello` has arrived; its preferences travel in it and in
/// `set-prefs`; a claim reconciles for the NEW driver's; the layout intents are the driver's alone; and
/// only the driver leaving — with nobody to take over — ends the streams. Real ChannelHub and PeerHub
/// entry points with real, never-connected PionPeers.
final class ChannelHubSessionTests: XCTestCase {
    private var peers: [PionPeer] = []
    private var hub: ChannelHub!
    private var pool: TerminalManager!

    func testOverlappingReconcilesFinishWithTheCurrentDriversPresentation() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = SocketConnection(clientId: "sock:a", socket: MemorySocket(), presentation: .nativeSimulators)
        let b = SocketConnection(clientId: "sock:b", socket: MemorySocket(), presentation: .streamedSources)
        let blocked = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let remote = DispatchSemaphore(value: 0), both = DispatchGroup()
        spy.nativeReconcile = { blocked.signal(); _ = resume.wait(timeout: .now() + 3) }
        spy.remoteReconcile = { remote.signal() }
        hub.register(clientId: a.clientId, peer: a, claim: true)
        both.enter()
        DispatchQueue.global().async { [self] in hub.receive(.clientHello(prefs: .default, delivery: .rtp), from: a); both.leave() }
        XCTAssertEqual(blocked.wait(timeout: .now() + 2), .success)
        hub.register(clientId: b.clientId, peer: b, claim: true)
        both.enter()
        DispatchQueue.global().async { [self] in hub.receive(.clientHello(prefs: .default, delivery: .rtp), from: b); both.leave() }
        _ = remote.wait(timeout: .now() + 0.2) // old implementation can overtake A; serialized B waits for it
        resume.signal()
        XCTAssertEqual(both.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(spy.presentations.last, "remote")
    }

    override func setUp() {
        pool = TerminalManager(cols: 80, rows: 24)
        hub = ChannelHub(terminals: pool, injector: nil, encoder: NullVideo(),
                         terminalPauseHold: .milliseconds(50), mediaPauseHold: .milliseconds(50))
        // REAL `videoSlots` entries through the product's own add/remove paths, without the bridge: a
        // never-connected PionPeer cannot negotiate a track (`fakeTrackSlotsForTests`). Even slots, no audio.
        let slots = NSLock()
        var next: Int32 = 0
        hub.fakeTrackSlotsForTests = { _, _ in
            slots.lock(); defer { slots.unlock() }
            let v = next; next += 2
            return (v, -1)
        }
    }

    override func tearDown() {
        hub.simDelegate = nil
        hub.trackEventHookForTests = nil
        for p in peers { p.close() }
        peers = []
    }

    /// Every track event from here on, as `"<add|remove> <client> <source>"`; `take()` returns and clears.
    private final class TrackEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func record(_ e: String, _ c: String, _ s: String) { lock.lock(); seen.append("\(e) \(c) \(s)"); lock.unlock() }
        func take() -> [String] { lock.lock(); defer { seen = []; lock.unlock() }; return seen }
    }
    private func watchTracks() -> TrackEvents {
        let t = TrackEvents()
        hub.trackEventHookForTests = { e, c, s in t.record(e, c, s) }
        return t
    }

    private func peer(_ id: String) -> PionPeer {
        let p = PionPeer(clientId: id, turn: nil)
        peers.append(p)
        return p
    }

    private func send(_ p: PionPeer, _ json: String) {
        hub.pionPeer(p, didReceive: wrapMessage(Data(json.utf8)), on: .control)
    }

    // MARK: the hello

    func testADriversVideoWaitsForItsHello() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = peer("a")
        hub.register(clientId: "a", peer: a)                     // the first client drives
        hub.pionPeer(a, stateDidChange: 3)                       // connected — but no hello yet
        XCTAssertEqual(spy.reconciles.count, 0, "nothing is reconciled before the hello")
        send(a, #"{"t":"client-hello","prefs":{"fps":30}}"#)
        XCTAssertEqual(spy.reconciles.map(\.fps), [30], "the hello reconciles, with its preferences")
    }

    func testFastHelloWaitsForMediaAndRetiredPeerCannotReconcile() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let c = FastClientConnection(clientId: "fast", generation: Data(repeating: 7, count: 16), onOpen: { _ in }, onMessage: { _, _ in }, onFailure: { XCTFail($0) })
        defer { c.close() }
        let a = peer("fast"), b = peer("fast")
        c.attachMediaPeer(a); hub.register(clientId: c.clientId, peer: c, claim: true)
        hub.receive(.clientHello(prefs: .default, delivery: .rtp), from: c)
        XCTAssertTrue(spy.reconciles.isEmpty)
        let connected = expectation(description: "current media connected")
        c.onMediaState = { [self] p, state in hub.pionPeer(p, stateDidChange: state); connected.fulfill() }
        c.attachMediaPeer(b)
        c.pionPeer(a, stateDidChange: 3)
        XCTAssertFalse(c.mediaReady)
        c.pionPeer(b, stateDidChange: 3)
        wait(for: [connected], timeout: 2)
        XCTAssertTrue(c.mediaReady)
        XCTAssertEqual(spy.reconciles.count, 1)
    }

    // MARK: the offer's state (docs/sources-and-focus.md, "The offer carries the tab bar")

    /// What a FRESH offer carries, in the order a control open sends it: whether THIS client drives (a passive one
    /// is drawn no terminal tab), the pool's `term-list`, then the session's windows (`offerStatePayloads`).
    func testTheOffersStateSaysWhoDrivesThenCarriesTheTabsAndTheWindows() {
        let spy = SessionSpy(); hub.simDelegate = spy
        spy.offerPayloads = [Data(#"{"t":"view-set","windows":[]}"#.utf8)]
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b, claim: true)            // connecting: it takes control
        func objects(_ d: [Data]) -> [[String: Any]] { d.map { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:] } }
        let forB = objects(hub.offerState(forClient: "b")), forA = objects(hub.offerState(forClient: "a"))
        XCTAssertEqual(forB.map { $0["t"] as? String }, ["control-state", "term-list", "view-set"])
        XCTAssertEqual(forB[0]["active"] as? Bool, true, "the connecting client drives")
        XCTAssertEqual(forA[0]["active"] as? Bool, false, "the one it replaced does not")
        XCTAssertEqual(forB[0]["clients"] as? Int, 2)
        let (tabs, activeId) = pool.descriptors()
        XCTAssertEqual(forB[1] as NSDictionary, objects([termListJSON(tabs: tabs, activeId: activeId)])[0] as NSDictionary,
                       "the pool's own list")
    }

    /// THE JOIN GRID AND THE OFFER'S SCREEN: the grid a client said as it joined is its `resize` — the DRIVER's alone
    /// — and the screen a fresh offer carries is the active tab's at that grid, for the driver only.
    func testTheJoinGridIsTheDriversResizeAndTheOffersScreenIsTheDriversAtIt() throws {
        _ = try XCTUnwrap(pool.openDetachedForTests(cols: 80, rows: 24))
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)                         // the first client drives
        hub.register(clientId: "b", peer: b)                         // a reconnect: passive
        func screen(_ id: String) throws -> [String: Any]? {
            let got = expectation(description: "the screen for \(id)")
            let box = NSMutableArray()
            hub.offerScreen(forClient: id, within: 2_000_000_000) { data in
                if let data, let o = try? JSONSerialization.jsonObject(with: data) { box.add(o) }
                got.fulfill()
            }
            wait(for: [got], timeout: 5)
            return box.firstObject as? [String: Any]
        }
        hub.applyJoinGrid(TermGridSize(cols: 50, rows: 10), clientId: "b")
        let before = try XCTUnwrap(try screen("a"))
        XCTAssertEqual([before["cols"] as? Int, before["rows"] as? Int], [80, 24], "a passive client's grid changes nothing")
        hub.applyJoinGrid(TermGridSize(cols: 100, rows: 30), clientId: "a")
        let after = try XCTUnwrap(try screen("a"))
        XCTAssertEqual(after["t"] as? String, "term-screen")
        XCTAssertEqual(after["id"] as? String, pool.descriptors().activeId?.wire)
        XCTAssertEqual([after["cols"] as? Int, after["rows"] as? Int], [100, 30], "the driver's grid, applied before the screen")
        XCTAssertNil(try screen("b"), "a passive client is drawn no terminal")
    }

    /// The headless host (no session state) has no windows to describe: the tabs alone.
    func testTheHeadlessHostsOfferCarriesTheTabsAlone() {
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        let types = hub.offerState(forClient: "a").map { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["t"] as? String }
        XCTAssertEqual(types, ["control-state", "term-list"])
    }

    // MARK: the join intent (docs/sources-and-focus.md, "The join intent")

    /// A client CONNECTING takes control, decided here: the driver it replaces goes passive, exactly as on
    /// "Move here", and the newcomer's hello reconciles under ITS preferences.
    func testAConnectingClientTakesControl() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        send(a, #"{"t":"client-hello","prefs":{"fps":30}}"#)
        hub.register(clientId: "b", peer: b, claim: true)
        send(b, #"{"t":"client-hello","prefs":{"fps":24}}"#)
        XCTAssertEqual(spy.reconciles.map(\.fps), [30, 24], "the newcomer drives")
        send(a, #"{"t":"set-prefs","prefs":{"fps":15}}"#)
        XCTAssertEqual(spy.reconciles.map(\.fps), [30, 24], "the one it replaced is passive")
    }

    /// A RECONNECT — no claim — keeps its place: another client driving stays the driver.
    func testAReconnectingClientDoesNotTakeControl() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        send(a, #"{"t":"client-hello","prefs":{"fps":30}}"#)
        hub.register(clientId: "b", peer: b)
        send(b, #"{"t":"client-hello","prefs":{"fps":24}}"#)
        XCTAssertEqual(spy.reconciles.map(\.fps), [30])
    }

    /// A client connecting over a connection the host still HELD (a resume of its id: a reload the relay
    /// had not yet reaped) claims on the connection it already has — the same path as "Move here".
    func testAConnectingResumeClaimsItsHeldConnection() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)                     // passive
        send(a, #"{"t":"client-hello","prefs":{"fps":30}}"#)
        send(b, #"{"t":"client-hello","prefs":{"fps":24}}"#)
        hub.claim(clientId: "b")
        XCTAssertEqual(spy.reconciles.map(\.fps), [30, 24])
    }

    func testAPassiveClientsHelloIsKeptForItsClaim() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)                     // passive
        send(a, #"{"t":"client-hello","prefs":{"fps":30}}"#)
        send(b, #"{"t":"client-hello","prefs":{"fps":24}}"#)
        XCTAssertEqual(spy.reconciles.map(\.fps), [30], "a passive client's hello reconciles nothing")
        send(b, #"{"t":"claim-control"}"#)
        XCTAssertEqual(spy.reconciles.map(\.fps), [30, 24], "the claim reconciles for the NEW driver's preferences")
    }

    /// A CLAIMED OR PROMOTED DRIVER STARTS UNDER ITS OWN CONNECTION SETTINGS (final review, 2026-09-29).
    /// A passive client's forced FEC and playout request are refused as it sends them — it does not
    /// drive — so the host KEEPS them and applies them when it becomes the driver, BEFORE its tracks.
    /// Before, "Move here" started video with no playout window on that peer (27 → 57 ms g2g on
    /// Chromium, AGENTS.md) and `view-set` went on echoing the previous driver's values.
    func testDefaultAndSmoothPlayoutFloors() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        send(a, #"{"t":"client-hello","prefs":{}}"#)
        XCTAssertTrue(spy.settings.contains("playout 20 nil"))
        send(a, #"{"t":"set-playout-delay","minMs":100}"#)
        XCTAssertEqual(spy.settings.last, "playout 100 nil")
        send(a, #"{"t":"set-playout-delay","minMs":20}"#)
        XCTAssertEqual(spy.settings.last, "playout 20 nil")
        send(b, #"{"t":"client-hello","prefs":{}}"#)
        let before = spy.settings.count
        send(b, #"{"t":"claim-control"}"#)
        XCTAssertEqual(Array(spy.settings.dropFirst(before)), ["recovery nil", "playout 20 nil", "reconcile"])
    }

    func testAClaimAppliesTheClaimersConnectionSettingsBeforeItsTracks() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)                      // passive
        send(a, #"{"t":"client-hello","prefs":{}}"#)
        send(a, #"{"t":"set-recovery","overrideBp":2500}"#)
        send(b, #"{"t":"set-playout-delay","minMs":10,"maxMs":10}"#)
        send(b, #"{"t":"client-hello","prefs":{}}"#)
        XCTAssertFalse(spy.settings.contains("playout 10 10"), "a passive client's settings are not applied")
        let before = spy.settings.count
        send(b, #"{"t":"claim-control"}"#)
        // b's playout window, and NO forced FEC — b never asked for one, so the echo stops showing a's —
        // both before b's reconcile adds a track.
        XCTAssertEqual(Array(spy.settings.dropFirst(before)), ["recovery nil", "playout 10 10", "reconcile"])
    }

    func testSetPrefsFromTheDriverReconcilesAndFromAPassiveClientDoesNot() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        send(a, #"{"t":"client-hello","prefs":{}}"#)
        send(b, #"{"t":"client-hello","prefs":{}}"#)
        send(b, #"{"t":"set-prefs","prefs":{"fps":15}}"#)
        send(a, #"{"t":"set-prefs","prefs":{"fps":45}}"#)
        XCTAssertEqual(spy.reconciles.map(\.fps), [nil, 45])
        send(b, #"{"t":"claim-control"}"#)
        XCTAssertEqual(spy.reconciles.last?.fps, 15, "the passive client's change was kept for its claim")
    }

    /// A hello still draining from a connection a rebuild retired says nothing about the new one.
    func testAHelloFromARetiredConnectionIsDropped() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a1 = peer("a"), a2 = peer("a")
        hub.register(clientId: "a", peer: a1)
        hub.rebindPeer(clientId: "a", peer: a2)
        send(a1, #"{"t":"client-hello","prefs":{"fps":10}}"#)
        XCTAssertEqual(spy.reconciles.count, 0)
        send(a2, #"{"t":"client-hello","prefs":{"fps":20}}"#)
        XCTAssertEqual(spy.reconciles.map(\.fps), [20])
    }

    /// The hello states the CONNECTION's transport (amendment 1): a `?dc=1` driver's reconciled
    /// windows are routed over the DataChannel — or a window restored for it would come back on RTP.
    func testTheHellosTransportRoutesTheReconciledWindows() {
        let spy = SessionSpy(); hub.simDelegate = spy
        hub.isVideoSubscribed = { true }                         // the product path
        spy.streamedForTests = ["win:1", "win:2"]
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        send(a, #"{"t":"client-hello","prefs":{},"delivery":"dc"}"#)
        XCTAssertEqual(hub.videoDeliveryRequestForTests("win:1"), .dc)
        XCTAssertEqual(hub.videoDeliveryRequestForTests("win:2"), .dc)
    }

    /// `reattach-source` (amendment 2) re-adds THIS driver's track for a STREAMED window — the WebCodecs
    /// stall recovery, which used to unsubscribe and resubscribe and would now close and reopen the
    /// window. It changes no state. A passive client's, and one naming a window that is not streamed,
    /// do nothing.
    func testReattachSourceReaddsOnlyTheDriversTrackForAStreamedWindow() {
        let spy = SessionSpy(); hub.simDelegate = spy
        hub.isVideoSubscribed = { true }
        spy.streamedForTests = ["win:1"]
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        send(a, #"{"t":"client-hello","prefs":{}}"#)
        let before = spy.reconciles.count
        let tracks = watchTracks()
        send(b, #"{"t":"reattach-source","source":"win:1"}"#)   // passive: refused
        send(a, #"{"t":"reattach-source","source":"win:2"}"#)   // not streamed: nothing to re-add
        send(a, #"{"t":"reattach-source","source":"win:1"}"#)
        XCTAssertEqual(tracks.take(), ["remove a win:1", "add a win:1"])
        XCTAssertEqual(spy.intents, [], "no state change")
        XCTAssertEqual(spy.reconciles.count, before, "and no reconcile")
    }

    func testStreamRemovalWaitsForLiveReferenceReconfiguration() {
        let spy = SessionSpy(); hub.simDelegate = spy
        hub.isVideoSubscribed = { true }; spy.streamedForTests = ["win:1"]
        let encoder = NullVideo()
        spy.encoderLookup = { encoder }
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        send(a, #"{"t":"client-hello","prefs":{}}"#)
        hub.encoderReady(sourceID: "win:1")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let removed = DispatchSemaphore(value: 0)
        spy.encoderLookup = { entered.signal(); _ = release.wait(timeout: .now() + 5); return encoder }
        hub.trackEventHookForTests = { event, _, _ in if event == "remove" { removed.signal() } }
        let refreshed = expectation(description: "refresh finished")
        DispatchQueue.global().async { [self] in
            send(a, #"{"t":"set-prefs","prefs":{"av1ReferenceRecovery":true}}"#)
            refreshed.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let retired = expectation(description: "retirement finished")
        DispatchQueue.global().async { [self] in
            send(a, #"{"t":"unsubscribe","source":"win:1"}"#)
            retired.fulfill()
        }
        XCTAssertEqual(removed.wait(timeout: .now() + 0.15), .timedOut,
                       "removal must not retire a slot while its live refresh is configuring")
        release.signal(); release.signal()
        wait(for: [refreshed, retired], timeout: 5)
        spy.encoderLookup = nil
    }

    // MARK: the layout intents

    func testTheLayoutIntentsAreTheDriversAlone() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        for p in [b, a] {                                        // the passive client first: refused
            send(p, #"{"t":"minimize-window","source":"win:1"}"#)
            send(p, #"{"t":"restore-window","source":"win:1"}"#)
            send(p, #"{"t":"set-window-position","source":"win:1","x":10,"y":20}"#)
            send(p, #"{"t":"set-view","surface":"windows"}"#)
        }
        XCTAssertEqual(spy.intents, ["minimize win:1", "restore win:1", "position win:1 10 20", "view windows"])
    }

    // MARK: only the driver's departure ends the streams

    private func realSim(grace: Int) -> SimManager {
        let sim = SimManager(makeEncoder: { _, _, _, _ in NullVideo() }, channelHub: hub,
                             defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                             bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000,
                             graceSeconds: grace)
        sim.attachesCaptureForTests = false
        hub.simDelegate = sim
        hub.isVideoSubscribed = { true }
        return sim
    }

    /// THE DEFECT found while mapping (2026-09-29): `PeerHub.clientLeft` armed SimManager's GLOBAL
    /// teardown for EVERY departing peer, so a PASSIVE tab closing ended the CURRENT driver's streams
    /// ~10 s later, with no view-set to say so. Red on the code before this task.
    func testAPassiveClientLeavingKeepsTheDriversStreams() {
        let sim = realSim(grace: 0)
        let peerHub = PeerHub(channelHub: hub)
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)                     // the driver
        hub.register(clientId: "b", peer: b)                     // passive
        send(a, #"{"t":"client-hello","prefs":{}}"#)
        XCTAssertTrue(sim.openWindow(sourceID: "dsp:987654", requestedBy: "a"))
        XCTAssertEqual(sim.subscribedSourceIDs(), ["dsp:987654"], "precondition: the driver's window streams")
        peerHub.clientLeft("b")
        Thread.sleep(forTimeInterval: 0.3)                       // well past a zero-second grace
        XCTAssertEqual(sim.subscribedSourceIDs(), ["dsp:987654"], "a passive client leaving must not end the driver's streams")
    }

    func testTheDriverLeavingWithSomeoneToTakeOverEndsNothing() {
        let sim = realSim(grace: 0)
        let peerHub = PeerHub(channelHub: hub)
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        send(a, #"{"t":"client-hello","prefs":{}}"#)
        send(b, #"{"t":"client-hello","prefs":{}}"#)
        sim.openWindow(sourceID: "dsp:987654", requestedBy: "a")
        peerHub.clientLeft("a")                                  // b is the only one left: promoted
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(sim.subscribedSourceIDs(), ["dsp:987654"], "the promoted driver is reconciled; nothing is torn down")
    }

    func testTheLastDriverLeavingEndsTheStreamsAndKeepsTheSession() {
        let sim = realSim(grace: 0)
        let peerHub = PeerHub(channelHub: hub)
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        send(a, #"{"t":"client-hello","prefs":{}}"#)
        sim.openWindow(sourceID: "dsp:987654", requestedBy: "a")
        peerHub.clientLeft("a")
        let deadline = Date().addingTimeInterval(5)
        while !sim.subscribedSourceIDs().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(sim.subscribedSourceIDs(), [], "nobody drives: the streams stop after the grace")
        let vs = (try? JSONSerialization.jsonObject(with: sim.viewSetPayload(forClient: "x"))) as? [String: Any]
        XCTAssertEqual((vs?["windows"] as? [[String: Any]])?.map { $0["source"] as? String }, ["dsp:987654"],
                       "and the session is kept for whoever connects next")
    }

    // MARK: the reconcile is idempotent; a codec change renegotiates once

    private func stateVersion(_ sim: SimManager) -> Int {
        let vs = (try? JSONSerialization.jsonObject(with: sim.viewSetPayload(forClient: "x"))) as? [String: Any]
        return (vs?["version"] as? NSNumber)?.intValue ?? -1
    }

    /// A SECOND `client-hello` on the driver's SAME connection — its control channel re-stating, or a
    /// duplicate — reconciles to what is already there: no second track for any window, no re-add, and
    /// no change to the session state.
    func testASecondHelloOnTheSameConnectionAddsNoTrackAndChangesNoState() {
        let sim = realSim(grace: 60)
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        send(a, #"{"t":"client-hello","prefs":{"fps":30}}"#)
        let tracks = watchTracks()
        send(a, #"{"t":"subscribe","source":"dsp:987654"}"#)
        XCTAssertEqual(tracks.take(), ["add a dsp:987654"], "precondition: the window's one track")
        XCTAssertEqual(sim.fullPrefsForTests("dsp:987654")?.fps, 30, "precondition: the hello reconciled")
        let version = stateVersion(sim)
        send(a, #"{"t":"client-hello","prefs":{"fps":30}}"#)
        XCTAssertEqual(tracks.take(), [], "no second track, and no remove-and-add")
        XCTAssertEqual(stateVersion(sim), version, "and the state did not change")
        XCTAssertEqual(sim.subscribedSourceIDs(), ["dsp:987654"])
    }

    /// A `set-prefs` that moves only the CODEC renegotiates each streamed window's track EXACTLY ONCE —
    /// removed and added again with a fresh SSRC (`setCodec`), never `ReplaceTrack`, which the receiver
    /// discards — and a `set-prefs` that changes nothing renegotiates none.
    func testACodecOnlyChangeReaddsEachTrackOnceAndANoOpReaddsNone() {
        let sim = realSim(grace: 60)
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        send(a, #"{"t":"client-hello","prefs":{"fps":30}}"#)
        send(a, #"{"t":"subscribe","source":"dsp:987654"}"#)
        send(a, #"{"t":"subscribe","source":"dsp:987655"}"#)
        XCTAssertEqual(sim.subscribedSourceIDs(), ["dsp:987654", "dsp:987655"], "precondition")
        let tracks = watchTracks()
        send(a, #"{"t":"set-prefs","prefs":{"fps":30,"codec":"h265"}}"#)
        let changed = tracks.take()
        for src in ["dsp:987654", "dsp:987655"] {
            XCTAssertEqual(changed.filter { $0.hasSuffix(" \(src)") }, ["remove a \(src)", "add a \(src)"],
                           "\(src): removed, then added once")
        }
        XCTAssertEqual(changed.count, 4, "\(changed)")
        XCTAssertEqual(sim.codecPrefForSource("dsp:987654"), .h265)
        send(a, #"{"t":"set-prefs","prefs":{"fps":30,"codec":"h265"}}"#)
        XCTAssertEqual(tracks.take(), [], "a set-prefs that changes nothing renegotiates nothing")
    }

    // MARK: who drives, said last (docs/sources-and-focus.md, "The last control-state a client gets is the truth")

    /// Every `control-state` `c` was sent, in order: its `active`.
    private func states(_ c: WindowlessConnection) -> [Bool] {
        c.controlMessages.compactMap { json in
            json.contains(#""t":"control-state""#) ? json.contains(#""active":true"#) : nil
        }
    }

    /// Arms `afterControlStateReadForTests` ONCE: the first control-state to read who drives stops there until the
    /// returned `release` is signalled (or 300 ms pass — a send that must wait for it cannot signal it). `read` is
    /// signalled when it stopped.
    private func holdFirstControlStateRead() -> (read: DispatchSemaphore, release: DispatchSemaphore) {
        let read = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let once = NSLock(); var armed = true
        hub.afterControlStateReadForTests = {
            once.lock(); let mine = armed; armed = false; once.unlock()
            guard mine else { return }
            read.signal()
            _ = release.wait(timeout: .now() + .milliseconds(300))
        }
        return (read, release)
    }

    private func onAnotherThread(_ body: @escaping () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { body(); done.signal() }
        return done
    }

    /// TWO CLAIMS AT ONCE: each `control-state` was read under the lock and sent outside it, so the claim that read
    /// FIRST could send LAST — the page it named believing it drives while the host had given control to the other
    /// (the wire, the keys and every snapshot going there): a frozen terminal with no "Move here" to tap. The phone's
    /// claim arrives on pion's thread, "This Mac"'s on the socket queue; nothing ordered them.
    func testTwoClaimsAtOnceLeaveEveryClientToldWhoDrivesLast() {
        let a = WindowlessConnection("sock:a"), b = WindowlessConnection("sock:b")
        hub.register(clientId: a.clientId, peer: a)                  // the first client drives
        hub.register(clientId: b.clientId, peer: b)                  // a reconnect: passive
        hub.connection(a, didOpen: .control); hub.connection(b, didOpen: .control)
        let hold = holdFirstControlStateRead()
        let first = onAnotherThread { self.send(b, #"{"t":"claim-control"}"#) }     // B drives; its broadcast stops after reading
        XCTAssertEqual(hold.read.wait(timeout: .now() + 5), .success)
        let second = onAnotherThread { self.send(a, #"{"t":"claim-control"}"#); hold.release.signal() }   // A drives
        XCTAssertEqual(first.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(second.wait(timeout: .now() + 5), .success)
        hub.afterControlStateReadForTests = nil
        XCTAssertEqual(states(a).last, true, "A claimed last and drives — the last word it got must say so: \(states(a))")
        XCTAssertEqual(states(b).last, false, "B does not drive — the last word it got must say so: \(states(b))")
    }

    /// The same race at a CONTROL OPEN: the page's own control-state (read as it opened) against the claim the page
    /// sends the moment its channel opens (`SessionControl.reclaim`) — a stale "passive" sent last left the driver
    /// behind the claim overlay.
    func testAClaimRacingItsOwnControlOpenLeavesTheClientToldItDrives() {
        let a = WindowlessConnection("sock:a"), b = WindowlessConnection("sock:b")
        hub.register(clientId: a.clientId, peer: a)                  // the first client drives
        hub.connection(a, didOpen: .control)
        hub.register(clientId: b.clientId, peer: b)                  // a reconnect: passive
        let hold = holdFirstControlStateRead()
        let opened = onAnotherThread { self.hub.connection(b, didOpen: .control) }   // reads "passive", stops
        XCTAssertEqual(hold.read.wait(timeout: .now() + 5), .success)
        let claimed = onAnotherThread { self.send(b, #"{"t":"claim-control"}"#); hold.release.signal() }
        XCTAssertEqual(opened.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(claimed.wait(timeout: .now() + 5), .success)
        hub.afterControlStateReadForTests = nil
        XCTAssertEqual(states(b).last, true, "B claimed and drives — the last word it got must say so: \(states(b))")
        XCTAssertEqual(states(a).last, false, "A does not drive: \(states(a))")
    }

    // MARK: window-less clients (docs/sources-and-focus.md, "Window-less clients")

    private func send(_ c: ClientConnection, _ json: String) {
        hub.connection(c, didReceive: wrapMessage(Data(json.utf8)), on: .control)
    }

    /// A window-less client's window intents reach NOTHING — not the session, not a track, not a
    /// connection setting — even as the driver. (NO `curtain` row: the hub calls the real
    /// CurtainController, and a mutation run of this test would black this machine's screen.)
    func testAWindowlessDriversWindowIntentsReachNothing() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let tracks = watchTracks()
        let w = WindowlessConnection("sock:w")
        hub.register(clientId: w.clientId, peer: w)                  // the first client drives
        hub.connection(w, didOpen: .control)
        for json in [#"{"t":"subscribe","source":"win:1"}"#, #"{"t":"unsubscribe","source":"win:1"}"#,
                     #"{"t":"minimize-window","source":"win:1"}"#, #"{"t":"restore-window","source":"win:1"}"#,
                     #"{"t":"set-window-position","source":"win:1","x":10,"y":20}"#,
                     #"{"t":"set-view","surface":"windows"}"#,
                     #"{"t":"set-recovery","overrideBp":500}"#, #"{"t":"set-playout-delay","minMs":10}"#] {
            send(w, json)
        }
        XCTAssertEqual(spy.intents, [], "a window-less client's window intents must reach nothing")
        XCTAssertEqual(spy.settings, [], "nor its media settings")
        XCTAssertEqual(tracks.take(), [])
        XCTAssertTrue(w.controlMessages.contains { $0.contains(#""t":"control-state","active":true"#) },
                      "it still drives: \(w.controlMessages)")
    }

    /// The BAR is the one window-shaped thing a window-less client may arrange: its `move-tab` and
    /// `rename-tab` are PERMITTED (`WindowlessPolicy`) and reach the session as the driver's — while every
    /// window intent beside them (the test above) reaches nothing.
    func testAWindowlessDriversBarIntentsReachTheSession() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let w = WindowlessConnection("sock:w")
        hub.register(clientId: w.clientId, peer: w)                  // the first client drives
        hub.connection(w, didOpen: .control)
        send(w, #"{"t":"move-tab","tab":"win:1","before":null}"#)
        send(w, #"{"t":"rename-tab","tab":"win:1","name":"mail"}"#)
        XCTAssertEqual(spy.intents, ["move win:1 end", "name win:1 mail"])
    }

    /// A window-less client TAKING CONTROL stops the captures as a leaving driver does — the state is
    /// kept — applies no connection settings and is never reconciled; a windowed client claiming back is
    /// reconciled again.
    func testAWindowlessDriverStopsTheCapturesAndAWindowedClaimerGetsThemBack() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        send(a, #"{"t":"client-hello","prefs":{"fps":30}}"#)
        XCTAssertEqual(spy.reconciles.count, 1)
        let settingsBefore = spy.settings.count
        let w = WindowlessConnection("sock:w")
        hub.register(clientId: w.clientId, peer: w, claim: true)     // a connect takes control
        send(w, #"{"t":"client-hello","prefs":{"fps":24}}"#)
        XCTAssertEqual(spy.gone, 1, "the captures stop, as when a driver leaves")
        XCTAssertEqual(spy.reconciles.count, 1, "a window-less driver is never reconciled")
        XCTAssertEqual(spy.settings.count, settingsBefore, "and applies no connection settings")
        send(a, #"{"t":"claim-control"}"#)
        XCTAssertEqual(spy.reconciles.map(\.fps), [30, 30], "the windowed claimer is reconciled again")
    }
    func testNativeSocketCanChangeSimulatorTabsButNeverMacWindows() {
        let spy = SessionSpy(); hub.simDelegate = spy
        let clients = SocketClients(hub: hub)
        let socket = MemorySocket()
        clients.accept(socket, presentation: .nativeSimulators)
        socket.hello("native")
        let sim = "sim:9B45C574-451C-475D-8498-66BD68AEE17D"
        socket.sends(.control, "{\"t\":\"subscribe\",\"source\":\"\(sim)\"}")
        socket.sends(.control, #"{"t":"subscribe","source":"win:1"}"#)
        clients.drainForTests()
        XCTAssertEqual(spy.intents, ["open \(sim)"])
        let replacement = MemorySocket()
        clients.accept(replacement)
        replacement.hello("native")
        replacement.sends(.control, "{\"t\":\"subscribe\",\"source\":\"\(sim)\"}")
        clients.drainForTests()
        XCTAssertEqual(spy.intents, ["open \(sim)"], "replacement does not inherit native privilege")
        clients.closeAll(reason: "test complete"); clients.drainForTests()
    }

}
