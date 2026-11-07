import CoreVideo
import IOSurface
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

final class FakeSimulators: SimulatorDevices, @unchecked Sendable {
    let lock = NSLock()
    var devices: [SimInfo] = []
    var listDelay: TimeInterval = 0
    var boots: [String] = [], shutdowns: [String] = []
    var observer: (@Sendable ([SimInfo]) -> Void)?
    func list(deadline: TimeInterval) -> [SimInfo]? {
        if listDelay > 0 { Thread.sleep(forTimeInterval: listDelay) }   // a WEDGED service ignores every deadline
        return lock.withLock { devices }
    }
    func observe(_ onChange: @escaping @Sendable ([SimInfo]) -> Void) { lock.withLock { observer = onChange } }
    var observing = false
    func setObserving(_ on: Bool) { lock.withLock { observing = on } }
    func boot(_ udid: String, completion: @escaping @Sendable (String?) -> Void) { lock.withLock { boots.append(udid) }; completion(nil) }
    func shutdown(_ udid: String, completion: @escaping @Sendable (String?) -> Void) { lock.withLock { shutdowns.append(udid) }; completion(nil) }
    func attachFramebuffer(_ udid: String, queue: DispatchQueue, surface: @escaping (IOSurface?) -> Void,
                           frame: @escaping () -> Void, properties: @escaping () -> Void) -> SimFramebufferFeed? { nil }
    var hid: (() -> SimHIDSink?)?
    func connectHID(_ udid: String) -> SimHIDSink? { hid?() }
    func change(_ d: [SimInfo]) { let o = lock.withLock { devices = d; return observer }; o?(d) }
}

final class SimManagerSimulatorTests: XCTestCase {
    private static let U = "9B45C574-451C-475D-8498-66BD68AEE17D"
    private let id = "sim:\(U)"
    private var hub: ChannelHub!
    private var sim: SimManager!
    private var fake: FakeSimulators!

    private func info(_ state: SimState) -> SimInfo {
        SimInfo(udid: Self.U, name: "iPhone 18 Pro", os: "iOS 27.0", state: state, w: 402, h: 874, pxW: 1206, pxH: 2622)
    }

    override func setUp() {
        fake = FakeSimulators()
        hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: NullVideo(),
                         terminalPauseHold: .milliseconds(50), mediaPauseHold: .milliseconds(50))
        sim = SimManager(makeEncoder: { _, _, _, _ in NullVideo() }, channelHub: hub,
                         defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                         bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000,
                         graceSeconds: 60, simulators: fake)
        sim.attachesCaptureForTests = false
        hub.simDelegate = sim
        hub.isVideoSubscribed = { true }
    }

    override func tearDown() { hub?.simDelegate = nil; hub = nil; sim = nil; fake = nil }

    /// REVIEW FOCUS 2. A CoreSimulatorService that never answers costs the palette its simulators, never its windows:
    /// SimManager holds its OWN deadline, whatever the catalog does.
    func testAHungCatalogListsWindowsWithinTheDeadline() async {
        fake.listDelay = 10
        let t0 = Date()
        let r = await sim.listSimulators()
        XCTAssertNil(r)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3.0)
    }

    func testOpeningAShutDownSimulatorBootsIt() {
        fake.change([info(.shutdown)])
        XCTAssertTrue(sim.openWindow(sourceID: id, requestedBy: "a"))
        XCTAssertEqual(fake.lock.withLock { fake.boots }, [Self.U])
    }

    func testOpeningABootedSimulatorBootsNothing() {
        fake.change([info(.booted)])
        XCTAssertTrue(sim.openWindow(sourceID: id, requestedBy: "a"))
        XCTAssertEqual(fake.lock.withLock { fake.boots }, [])
    }

    func testAShutDownSimulatorKeepsItsTabAndSaysSo() throws {
        fake.change([info(.booted)])
        _ = sim.openWindow(sourceID: id, requestedBy: "a")
        fake.change([info(.shutdown)])
        let s = try XCTUnwrap(sim.simulatorStatuses().first { $0.id == id })
        XCTAssertFalse(s.live)
        XCTAssertEqual(s.simState, .shutdown)
        XCTAssertTrue(sim.subscribedSourceIDs().contains(id) || sim.sessionContainsForTests(id), "the tab stays")
    }

    func testADeletedSimulatorLeavesTheSession() {
        sim.deletionConfirmDelay = 0.1
        fake.change([info(.booted)])
        _ = sim.openWindow(sourceID: id, requestedBy: "a")
        fake.change([])                                   // the device was deleted — confirmed by the next listing
        let deadline = Date().addingTimeInterval(2)
        while sim.sessionContainsForTests(id) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(sim.sessionContainsForTests(id))
    }

    /// A simulator cannot be resized; the request is ANSWERED with the size it is, so the client snaps back.
    func testASizeRequestIsAnsweredWithTheSimulatorsSize() throws {
        fake.change([info(.booted)])
        _ = sim.openWindow(sourceID: id, requestedBy: "a")
        let s = try XCTUnwrap(sim.simulatorSizeStatus(sourceID: id))
        XCTAssertEqual(s.w, 402); XCTAssertEqual(s.h, 874)
    }

    func testTheNewStreamsDefaultsFitTheEncoder() {
        fake.change([info(.booted)])
        _ = sim.openWindow(sourceID: id, requestedBy: "a")
        sim.reconcile(driverPrefs: ClientPrefs())
        // 2622 px tall exceeds libaom's 2160: the starting scale fits it, as a display's does.
        XCTAssertEqual(sim.streamScaleForTests(id) ?? 0, 2160.0 / 2622.0, accuracy: 1e-6)
    }

    private static let U2 = "7A8B9C0D-1E2F-4A3B-8C4D-5E6F7A8B9C0D"
    private func twoBooted() -> StatusLog {
        let other = SimInfo(udid: Self.U2, name: "iPad", os: "iOS 27.0", state: .booted, w: 820, h: 1180, pxW: 1640, pxH: 2360)
        fake.change([info(.booted), other])
        _ = sim.openWindow(sourceID: id, requestedBy: "a")
        _ = sim.openWindow(sourceID: "sim:\(Self.U2)", requestedBy: "a")
        let log = StatusLog()
        sim.statusBroadcastForTests = { log.append($0) }
        return log
    }

    /// FINAL REVIEW I1. The client REPLACES its liveness map and its simulator states with every `source-status`, so a
    /// push about ONE source — a window's size, a simulator's first frame — wiped every simulator's `simState` (a
    /// booted simulator's tab then offered only "Boot"). Every push carries every simulator.
    func testASizePushCarriesEverySimulator() throws {
        let log = twoBooted()
        sim.sourceSizeChanged("win:9", size: CGSize(width: 100, height: 50), scale: 2)
        let last = try XCTUnwrap(log.last)
        XCTAssertEqual(last.first { $0.id == "win:9" }?.w, 100)
        XCTAssertEqual(last.first { $0.id == id }?.simState, .booted)
        XCTAssertEqual(last.first { $0.id == "sim:\(Self.U2)" }?.simState, .booted)
    }

    func testASimulatorsSizeReplyCarriesEveryOtherSimulator() throws {
        let log = twoBooted()
        sim.setSourceSize(sourceID: id, w: 1, h: 1, requestedBy: "a")
        let last = try XCTUnwrap(log.last)
        XCTAssertEqual(last.first { $0.id == id }?.w, 402, "the size it is")
        XCTAssertEqual(last.first { $0.id == "sim:\(Self.U2)" }?.simState, .booted)
    }

    /// FINAL REVIEW I6. Nothing of CoreSimulator runs at launch: the catalog is watched only while the session holds a
    /// simulator tab, and the watch stops with the last one.
    func testTheSimulatorsAreWatchedOnlyWhileATabIsOpen() {
        XCTAssertFalse(fake.lock.withLock { fake.observing }, "nothing watches at launch")
        fake.change([info(.booted)])
        _ = sim.openWindow(sourceID: id, requestedBy: "a")
        XCTAssertTrue(fake.lock.withLock { fake.observing })
        sim.closeWindow(sourceID: id, requestedBy: "a")
        XCTAssertFalse(fake.lock.withLock { fake.observing }, "the watch stops with the last simulator tab")
    }

    /// FINAL REVIEW M2 (re-graded Important). A device missing from ONE listing — CoreSimulatorService restarting, the
    /// standard cure for a wedge — is not a deletion: it is confirmed by a second listing before its tab goes.
    func testOneListingsAbsenceIsConfirmedBeforeATabGoes() {
        sim.deletionConfirmDelay = 0.1
        fake.change([info(.booted)])
        _ = sim.openWindow(sourceID: id, requestedBy: "a")
        fake.change([])                                       // gone from one listing…
        XCTAssertTrue(sim.sessionContainsForTests(id), "not deleted on one listing's word")
        fake.lock.withLock { fake.devices = [info(.booted)] }  // …and back by the confirming one
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(sim.sessionContainsForTests(id), "a device that came back keeps its tab")
        fake.change([])
        let deadline = Date().addingTimeInterval(2)
        while sim.sessionContainsForTests(id) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(sim.sessionContainsForTests(id), "confirmed gone: the tab leaves")
    }

    func testBootAndShutDownGoThroughTheCatalog() {
        fake.change([info(.shutdown)])
        sim.simAction(sourceID: id, action: .boot, requestedBy: "a")
        sim.simAction(sourceID: id, action: .shutdown, requestedBy: "a")
        XCTAssertEqual(fake.lock.withLock { fake.boots }, [Self.U])
        XCTAssertEqual(fake.lock.withLock { fake.shutdowns }, [Self.U])
    }

    func testARotationGoesThroughDevicectl() {
        let calls = CallLog()
        sim.simulatorControl = SimulatorControl(run: { args, _, _ in calls.append(args); return (0, Data()) })
        sim.simAction(sourceID: id, action: .rotateLeft, requestedBy: "a")
        let deadline = Date().addingTimeInterval(2)
        while calls.all.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(calls.all.first, ["devicectl", "device", "orientation", "rotate", "--device", Self.U, "left"])
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock(); private var v: [[String]] = []
    func append(_ a: [String]) { lock.withLock { v.append(a) } }
    var all: [[String]] { lock.withLock { v } }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock(); private var v: [[SourceStatus]] = []
    func append(_ s: [SourceStatus]) { lock.withLock { v.append(s) } }
    var last: [SourceStatus]? { lock.withLock { v.last } }
}
