import CoreVideo
import XCTest
import RdevCore
@testable import RdevHostKit

private final class RouteVideo: VideoEncoding, @unchecked Sendable {
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
private final class RouteClient: ClientConnection {
    let clientId: String
    let lock = NSLock()
    private var replies: [[String: Any]] = []
    init(_ id: String) { clientId = id }
    var presentation: ClientPresentation { .streamedSources }
    var mediaPeer: PionPeer? { nil }
    func send(_ ch: PionChannel, _ bytes: Data) {
        guard ch == .control, let data = unwrapMessage(bytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.withLock { replies.append(object) }
    }
    func reply(_ type: String, request: String? = nil) -> [String: Any]? {
        lock.withLock { replies.last { ($0["t"] as? String) == type && (request == nil || ($0["request"] as? String) == request) } }
    }
}
private final class RouteInjector: InputInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [InputPostFence] = []
    private var events: [SourceInputEvent] = []
    private var _posts = 0
    private var _legacyKeys = 0
    private var _releases = 0
    private var neutral: [InputPostFence] = []
    var onRaise: (() -> Void)?
    var onDrain: ((@escaping () -> Void) -> Void)?
    var frontmost = true
    func inject(touchNormalizedX: Double, y: Double, phase: String, button: MouseButton) {}
    func submitScoped(_ event: SourceInputEvent, postFence: @escaping InputPostFence) { lock.withLock { queued.append(postFence); events.append(event) } }
    func key(down: Bool, code: String, key: String, repeat: Bool, mods: InputModifiers) { lock.withLock { _legacyKeys += 1 } }
    var legacyKeys: Int { lock.withLock { _legacyKeys } }
    var releases: Int { lock.withLock { _releases } }
    func releaseKeys() { lock.withLock { _releases += 1 } }
    func releaseAfterOwnershipChange(postFence: @escaping InputPostFence) { lock.withLock { neutral.append(postFence) } }
    var neutralCount: Int { lock.withLock { neutral.count } }
    func fireNeutral(_ index: Int) -> Bool {
        guard let fence = lock.withLock({ neutral.indices.contains(index) ? neutral[index] : nil }) else { return true }
        return fence { self.releaseKeys() }
    }
    func raise() { onRaise?() }
    func awaitFrontmost() -> Bool { frontmost }
    func drainForFocusChange(_ completion: @escaping () -> Void) {
        if let onDrain { onDrain(completion) } else { completion() }
    }
    var count: Int { lock.withLock { queued.count } }
    func event(_ index: Int) -> SourceInputEvent? { lock.withLock { events.indices.contains(index) ? events[index] : nil } }
    var posts: Int { lock.withLock { _posts } }
    func fire(_ index: Int) -> Bool {
        let fence = lock.withLock { queued[index] }
        return fence { lock.withLock { _posts += 1 } }
    }
}

final class SourceInputRoutingTests: XCTestCase {
    private var hub: ChannelHub!
    private var sim: SimManager!
    private var client: RouteClient!
    private var a: RouteInjector!, b: RouteInjector!
    override func setUp() {
        hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: RouteVideo())
        sim = SimManager(makeEncoder: { _, _, _, _ in RouteVideo() }, channelHub: hub,
            defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000), bitrateCap: 8_000_000,
            throttleFps: 1, throttleBitrateBps: 100_000, graceSeconds: 60)
        sim.attachesCaptureForTests = false
        sim.windowOwnerPID = { _ in 4242 }; sim.existingWindowIDs = { [] }
        hub.simDelegate = sim; hub.isVideoSubscribed = { true }
        client = RouteClient("source-driver"); hub.register(clientId: client.clientId, peer: client, claim: true)
        _ = sim.openWindow(sourceID: "win:11", requestedBy: client.clientId)
        _ = sim.openWindow(sourceID: "win:12", requestedBy: client.clientId)
        a = RouteInjector(); b = RouteInjector()
        sim.setInjectorForTests("win:11", a); sim.setInjectorForTests("win:12", b)
    }
    override func tearDown() { hub.simDelegate = nil; sim = nil; hub = nil; client = nil }
    private func announce() { hub.receive(.sourceInput(.capabilities), from: client) }
    private func request(_ source: String?, _ nonce: String) { hub.receive(.sourceInput(.focus(source: source, request: nonce)), from: client) }
    private func awaitReply(_ nonce: String) -> [String: Any]? {
        let end = Date().addingTimeInterval(2)
        while client.reply("source-focus", request: nonce) == nil && Date() < end { Thread.sleep(forTimeInterval: 0.005) }
        return client.reply("source-focus", request: nonce)
    }
    private func activate(_ source: String, _ nonce: String) throws -> String {
        request(source, nonce)
        return try XCTUnwrap(awaitReply(nonce)?["lease"] as? String)
    }
    private func input(_ source: String, _ lease: String, from sender: RouteClient? = nil) {
        hub.receive(.sourceInput(.input(source: source, lease: lease, event: .winKey(down: true, code: "KeyA", key: "a", repeat: false, mods: .none))), from: sender ?? client)
    }

    func testScopedPointerPreservesCursorObservationAndTimestampAcknowledgments() throws {
        announce(); let lease = try activate("win:11", "pointer-observation")
        let hover = SourceInputEvent.hover(x: 0.13, y: 0.29)
        hub.receive(.sourceInput(.input(source: "win:11", lease: "stale", event: hover)), from: client)
        XCTAssertEqual(a.count, 0)
        hub.receive(.sourceInput(.input(source: "win:11", lease: lease, event: hover)), from: client)
        XCTAssertEqual(CursorOverlayState.shared.marker(forSource: nil), CursorMarkerState(x: 0.13, y: 0.29, pressed: false))
        let touch = SourceInputEvent.touch(x: 0.31, y: 0.47, phase: "down", button: .left, ts: 12345)
        hub.receive(.sourceInput(.input(source: "win:11", lease: lease, event: touch)), from: client)
        XCTAssertEqual(CursorOverlayState.shared.marker(forSource: nil), CursorMarkerState(x: 0.31, y: 0.47, pressed: true))
        XCTAssertEqual(client.reply("inputAck")?["ts"] as? Int, 12345)
        XCTAssertNotNil(client.reply("inputAck")?["injectedAtEpochMs"] as? Int)
        let polled = expectation(description: "accepted hover arms cursor polling")
        DispatchQueue.main.async { [self] in
            XCTAssertTrue(hub.cursorPollingForTests)
            polled.fulfill()
        }
        wait(for: [polled], timeout: 2)
    }

    func testExplicitCapabilityAndCommittedLeaseAreRequired() throws {
        input("win:11", "made-up"); request("win:11", "no-capability")
        XCTAssertEqual(a.count, 0)
        XCTAssertNil(client.reply("source-focus", request: "no-capability")?["lease"])
        announce()
        XCTAssertEqual(client.reply("source-input-capabilities")?["v"] as? Int, 1)
        XCTAssertEqual(client.reply("source-input-capabilities")?["scrollGestures"] as? [String], ["window", "display"])
        let lease = try activate("win:11", "ready")
        input("win:12", lease); input("win:11", "wrong")
        XCTAssertEqual(a.count, 0); XCTAssertEqual(b.count, 0)
        input("win:11", lease)
        XCTAssertEqual(a.count, 1); XCTAssertTrue(a.fire(0))
    }

    func testQueuedLeaseCannotReviveAfterSourceABA() throws {
        announce()
        let old = try activate("win:11", "a1")
        input("win:11", old)
        _ = try activate("win:12", "b2")
        let next = try activate("win:11", "a3")
        XCTAssertNotEqual(old, next)
        XCTAssertFalse(a.fire(0))
        input("win:11", old); XCTAssertEqual(a.count, 1)
        input("win:11", next); XCTAssertTrue(a.fire(1))
        XCTAssertEqual(a.posts, 1)
    }

    func testNewIntentRevokesOldLeaseBeforeTheNewAXRaiseCompletes() throws {
        announce()
        let old = try activate("win:11", "a")
        input("win:11", old)
        let raised = expectation(description: "B raise blocked"), resume = DispatchSemaphore(value: 0)
        b.onRaise = { raised.fulfill(); _ = resume.wait(timeout: .now() + 3) }
        request("win:12", "b")
        wait(for: [raised], timeout: 2)
        XCTAssertNil(client.reply("source-focus", request: "b")?["lease"])
        XCTAssertFalse(a.fire(0), "revocation must precede a potentially blocking AX call")
        resume.signal()
        XCTAssertNotNil(awaitReply("b")?["lease"])
    }

    func testSameIDReadmissionCannotUseOrPostThePreviousLease() throws {
        announce()
        let old = try activate("win:11", "old")
        input("win:11", old)
        let retired = client!
        client = RouteClient(retired.clientId)
        hub.register(clientId: client.clientId, peer: client, claim: true)
        XCTAssertFalse(a.fire(0))
        hub.receive(.winKey(down: true, code: "KeyA", key: "a", repeat: false, mods: .none), from: retired)
        XCTAssertEqual(a.legacyKeys, 0, "a replaced native admission cannot bypass its stale lease using legacy input")
        input("win:11", old, from: retired); input("win:11", old)
        XCTAssertEqual(a.count, 1)
        request("win:11", "without-new-capability")
        XCTAssertNil(client.reply("source-focus", request: "without-new-capability")?["lease"])
        announce()
        let next = try activate("win:11", "new")
        input("win:11", next); XCTAssertTrue(a.fire(1))
    }

    func testTerminalFocusRevokesSourceInputUntilFreshActivation() throws {
        announce()
        let old = try activate("win:11", "source")
        input("win:11", old)
        request(nil, "terminal")
        XCTAssertNotNil(awaitReply("terminal"))
        XCTAssertFalse(a.fire(0))
        XCTAssertEqual(sim.focusedSourceID, "win:11", "terminal activation must preserve source membership/focus state")
        let next = try activate("win:11", "back")
        XCTAssertNotEqual(old, next)
        input("win:11", next); XCTAssertTrue(a.fire(1))
    }

    func testBrowserDriverRestoresInputAfterPreviousNativeOwnersTerminalFocus() throws {
        announce()
        _ = try activate("win:11", "source")
        request(nil, "terminal")
        XCTAssertNotNil(awaitReply("terminal"))
        let browser = RouteClient("browser-driver")
        hub.register(clientId: browser.clientId, peer: browser, claim: true)
        hub.receive(.clientHello(prefs: .default, delivery: .rtp), from: browser)
        let end = Date().addingTimeInterval(1)
        while a.legacyKeys == 0 && Date() < end {
            hub.receive(.winKey(down: true, code: "KeyA", key: "a", repeat: false, mods: .none), from: browser)
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertGreaterThan(a.legacyKeys, 0, "terminal input focus belongs to the old native admission, not the host session")
    }

    func testFailedNativeRaiseCannotAcknowledgeInputReadiness() {
        announce(); a.frontmost = false
        request("win:11", "not-front")
        let reply = awaitReply("not-front")
        XCTAssertNotNil(reply)
        XCTAssertNil(reply?["lease"])
        XCTAssertEqual(reply?["error"] as? String, "focus-unavailable")
    }

    func testNativeReactivationWaitsForSameInjectorNeutralDrainBeforeAcknowledging() throws {
        announce()
        let old = try activate("win:11", "first")
        input("win:11", old)
        let draining = expectation(description: "same source drain began")
        let lock = NSLock(); var complete: (() -> Void)?
        a.onDrain = { callback in lock.withLock { complete = callback }; draining.fulfill() }
        request("win:11", "second")
        wait(for: [draining], timeout: 2)
        XCTAssertNil(client.reply("source-focus", request: "second")?["lease"])
        XCTAssertFalse(a.fire(0))
        lock.withLock { complete }?()
        XCTAssertNotNil(awaitReply("second")?["lease"])
    }

    func testOldDriversDepartureCannotDrainTheNewScopedDriversKeys() throws {
        announce(); _ = try activate("win:11", "old")
        let previous = client!
        client = RouteClient("next-driver")
        hub.register(clientId: client.clientId, peer: client, claim: true)
        announce(); let lease = try activate("win:11", "new")
        input("win:11", lease); XCTAssertTrue(a.fire(0))
        let releases = a.releases
        hub.unregister(clientId: previous.clientId)
        XCTAssertEqual(a.releases, releases, "new route already drained its predecessor before readiness")
    }

    func testLateOldDeactivationEffectCannotDrainTheNewScopedDriversKeys() throws {
        announce(); _ = try activate("win:11", "old")
        let previous = client!
        client = RouteClient("next-driver")
        hub.register(clientId: client.clientId, peer: client, claim: true)
        announce(); let lease = try activate("win:11", "new")
        input("win:11", lease); XCTAssertTrue(a.fire(0))
        let releases = a.releases
        hub.apply(ActiveClientEffects(activate: nil, deactivate: previous.clientId, broadcastState: false))
        XCTAssertEqual(a.releases, releases, "a delayed outgoing effect must not target freshly admitted input")
    }

    func testAnOldOwnershipReleaseDelayedUntilAfterFreshInputIsRejectedAtPost() throws {
        announce(); _ = try activate("win:11", "old")
        client = RouteClient("next-driver")
        hub.register(clientId: client.clientId, peer: client, claim: true)
        XCTAssertEqual(a.neutralCount, 1, "ownership release must carry a final-post fence too")
        announce(); let lease = try activate("win:11", "new")
        input("win:11", lease); XCTAssertTrue(a.fire(0))
        let releases = a.releases
        XCTAssertFalse(a.fireNeutral(0), "a pre-queue ownership check cannot protect newly held keys")
        XCTAssertEqual(a.releases, releases)
    }

    func testUnavailableDestinationReleasesOldHeldInputWithoutDrainingAFutureActivation() throws {
        announce(); let old = try activate("win:11", "old")
        input("win:11", old)
        request("win:999", "unavailable")
        XCTAssertEqual(awaitReply("unavailable")?["error"] as? String, "source-unavailable")
        XCTAssertFalse(a.fire(0))
        XCTAssertEqual(a.event(1), .winKeysRelease, "failed activation must not leave the old press held")
        if a.count > 1 {
            XCTAssertTrue(a.fire(1))
            _ = try activate("win:11", "fresh")
            XCTAssertFalse(a.fire(1), "a delayed failed-focus release must not drain newly held input")
        }
    }

    func testBlockedRealSimulatorHIDCannotPostOldTouchAfterSourceABA() throws {
        let sink = RouteHIDSink(), connectBegan = expectation(description: "HID connect began")
        let resume = DispatchSemaphore(value: 0)
        let real = SimulatorInputInjector(udid: "fixture", connect: {
            connectBegan.fulfill(); _ = resume.wait(timeout: .now() + 3); return sink
        }, display: SimDisplayState(), control: SimulatorControl(run: { _, _, _ in (0, Data()) }),
        nativePointW: 402, nativePointH: 874, nowMs: { 0 })
        // The fixture's source has no capture/catalog. Use the REAL simulator queue/sink behind it.
        sim.setInjectorForTests("win:11", real)
        announce(); let old = try activate("win:11", "a1")
        hub.receive(.sourceInput(.input(source: "win:11", lease: old,
            event: .simTouch(phase: "down", points: [SimPoint(x: 0.5, y: 0.5)]))), from: client)
        wait(for: [connectBegan], timeout: 2)
        request("win:12", "b2"); request("win:11", "a3")
        XCTAssertNil(client.reply("source-focus", request: "a3")?["lease"])
        resume.signal()
        let fresh = try XCTUnwrap(awaitReply("a3")?["lease"] as? String)
        real.drainForTests()
        XCTAssertTrue(sink.events.isEmpty, "neither a stale press nor an up for an unposted press may reach HID")
        hub.receive(.sourceInput(.input(source: "win:11", lease: fresh,
            event: .simTouch(phase: "down", points: [SimPoint(x: 0.25, y: 0.75)]))), from: client)
        real.drainForTests()
        XCTAssertEqual(sink.events, [.start([SimPoint(x: 0.25, y: 0.75)])])
    }

    func testClosedMinimizedAndParkedApplicationSourcesCannotGetALease() {
        announce()
        sim.minimizeWindow(sourceID: "win:11", land: false, requestedBy: client.clientId)
        for (index, source) in ["win:11", "win:999", "apps:" + UUID().uuidString].enumerated() {
            let nonce = "invalid-\(index)"; request(source, nonce)
            let reply = awaitReply(nonce)
            XCTAssertNotNil(reply)
            XCTAssertNil(reply?["lease"])
            XCTAssertEqual(reply?["error"] as? String, "source-unavailable")
        }
    }
}

private final class RouteHIDSink: SimHIDSink, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SimTouchEvent] = []
    var events: [SimTouchEvent] { lock.withLock { values } }
    var invalidated: Bool { false }
    func touch(_ event: SimTouchEvent) { lock.withLock { values.append(event) } }
    func key(_ usage: UInt32, down: Bool) {}
    func button(_ button: SimButton, down: Bool) {}
}
