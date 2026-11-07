import CoreVideo
import XCTest
import RdevCore
@testable import RdevHostKit

private final class NullVideoEncoder: VideoEncoding, @unchecked Sendable {
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

/// A value behind a lock, for what a test's closures record from other queues.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

/// A Dock the test writes: application path → badge label, the Dock's pid, and how a read fails.
private final class FakeDock: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String: DockLabel] = [:]
    private var pid: Int32 = 500
    private var empty = false
    private var hidden: Set<String> = []
    private(set) var reads = 0
    func set(_ path: String, _ label: String?) { lock.withLock { labels[path] = label.map { .badge($0) } ?? DockLabel.none } }
    func fail(_ path: String) { lock.withLock { labels[path] = .unreadable } }
    func relaunch(empty e: Bool) { lock.withLock { pid += 1; empty = e } }
    func settle() { lock.withLock { empty = false } }
    /// `path` missing from the readings (its subrole or bundle read failed) until `show`.
    func hide(_ path: String) { lock.withLock { _ = hidden.insert(path) } }
    func show(_ path: String) { lock.withLock { _ = hidden.remove(path) } }
    func read() -> DockReading? {
        lock.withLock {
            reads += 1
            let items = empty ? [] : labels.filter { !hidden.contains($0.key) }
                .map { DockItemReading(path: $0.key, bundleID: nil, label: $0.value) }
            return DockReading(dock: pid, items: items)
        }
    }
}

/// A WINDOW TAB'S BELL — the host's half (docs/window-capture-and-input.md, "A window's bell"): the Dock's
/// badges read while the session has windows and a driver, a RISE rung for every window of its application,
/// and sent to the DRIVER alone as a `window-bell`.
final class DockBadgeWatchTests: XCTestCase {
    private let terminal = "/Applications/Utilities/Terminal.app"
    private let telegram = "/Applications/Telegram.app"

    private func watch(_ dock: FakeDock, rung: @escaping ([String]) -> Void) -> DockBadgeWatch {
        let w = DockBadgeWatch(intervalMs: 3_600_000)              // ticks only when the test says
        w.read = { dock.read() }
        w.appOf = { [terminal, telegram] pid in (pid == 100 ? terminal : pid == 200 ? telegram : nil, nil) }
        w.onRing = rung
        return w
    }

    func testTheFirstReadingIsTheBaselineAndARiseRingsTheApplicationsWindows() {
        let dock = FakeDock()
        dock.set(terminal, nil); dock.set(telegram, "..21")
        let lock = NSLock(); var rung: [[String]] = []
        let w = watch(dock) { g in lock.withLock { rung.append(g) } }
        w.setTargets([.init(source: "win:1", pid: 100), .init(source: "win:2", pid: 200), .init(source: "win:3", pid: 100)])
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [], "Telegram's 21 was already showing: not news")
        dock.set(terminal, "1")
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [["win:1", "win:3"]], "Terminal badged: both its windows")
        dock.set(telegram, "..20")
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }.count, 1, "a count going down rings nothing")
        dock.set(telegram, "..22")
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }.last, ["win:2"])
    }

    func testNoWindowsStopsThePollAndARestartIsABaselineAgain() {
        let dock = FakeDock()
        dock.set(terminal, nil)
        let lock = NSLock(); var rung: [[String]] = []
        let w = watch(dock) { g in lock.withLock { rung.append(g) } }
        w.setTargets([.init(source: "win:1", pid: 100)])
        w.pollForTests()
        XCTAssertTrue(w.isWatchingForTests)
        w.setTargets([])
        XCTAssertFalse(w.isWatchingForTests, "nothing to watch: no poll")
        let reads = dock.reads
        w.pollForTests()
        XCTAssertEqual(dock.reads, reads, "a stopped watch reads no Dock")
        dock.set(terminal, "3")                                  // rose while nobody watched
        w.setTargets([.init(source: "win:1", pid: 100)])
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [], "what showed when the watch started is the baseline")
        dock.set(terminal, "4")
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [["win:1"]])
    }

    func testAnUnreadableDockChangesNothing() {
        let dock = FakeDock()
        dock.set(terminal, "1")
        let lock = NSLock(); var rung: [[String]] = []
        let w = watch(dock) { g in lock.withLock { rung.append(g) } }
        var readable = true
        w.read = { readable ? dock.read() : nil }
        w.setTargets([.init(source: "win:1", pid: 100)])
        w.pollForTests()
        readable = false                                          // Accessibility revoked, no Dock process
        w.pollForTests()
        readable = true
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [], "an unread tick is no reading: 1 → (nothing) → 1 is no change")
    }

    /// REVIEW F1, the shapes the REAL reader returns. A failed badge read (`.cannotComplete`, a timeout) is
    /// UNREADABLE, not "no badge"; the next good read of the same label used to be a rise.
    func testAFailedBadgeReadIsNoChange() {
        let dock = FakeDock()
        dock.set(terminal, "..21")
        let lock = NSLock(); var rung: [[String]] = []
        let w = watch(dock) { g in lock.withLock { rung.append(g) } }
        w.setTargets([.init(source: "win:1", pid: 100)])
        w.pollForTests()
        dock.fail(terminal)
        w.pollForTests()
        dock.set(terminal, "..21")
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [], "21 → (unreadable) → 21 marks nothing")
        dock.set(terminal, "..22")
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [["win:1"]])
    }

    /// REVIEW F1: `killall Dock`. The new Dock reads EMPTY at first, then lists its items before their badges;
    /// nothing rings until it has settled, and a real rise after that does.
    func testADockRelaunchRingsNothingWhileItSettles() {
        let dock = FakeDock()
        dock.set(terminal, "5")
        let lock = NSLock(); var rung: [[String]] = []
        let w = watch(dock) { g in lock.withLock { rung.append(g) } }
        w.setTargets([.init(source: "win:1", pid: 100)])
        w.pollForTests()
        dock.relaunch(empty: true)
        w.pollForTests()                                          // an empty reading: nothing changes
        dock.settle()
        dock.set(terminal, nil)
        w.pollForTests()                                          // its items, before their badges
        dock.set(terminal, "5")
        w.pollForTests()                                          // the badge, a tick later
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [], "a relaunched Dock's badges arriving are not news")
        dock.set(terminal, "6")
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [["win:1"]])
    }

    /// An item missing from ONE reading (a partial read) keeps its baseline.
    func testAPartialReadingKeepsTheMissingItemsBaseline() {
        let dock = FakeDock()
        dock.set(terminal, "3"); dock.set(telegram, nil)
        let lock = NSLock(); var rung: [[String]] = []
        let w = watch(dock) { g in lock.withLock { rung.append(g) } }
        w.setTargets([.init(source: "win:1", pid: 100)])
        w.pollForTests()
        dock.hide(terminal)
        w.pollForTests()
        dock.show(terminal)
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [], "3 → (missing) → 3 is no change")
        dock.hide(terminal)
        w.pollForTests()
        dock.show(terminal); dock.set(terminal, "4")
        w.pollForTests()
        XCTAssertEqual(lock.withLock { rung }, [["win:1"]], "3 → (missing) → 4 is a rise")
    }

    // MARK: - the reader's mapping (review F1)

    func testOnlyNoValueMeansNoBadgeEveryOtherFailureIsUnreadable() {
        XCTAssertEqual(DockBadgeReader.label(.success, "3" as NSString), .badge("3"))
        XCTAssertEqual(DockBadgeReader.label(.success, "..21" as NSString), .badge("..21"))
        XCTAssertEqual(DockBadgeReader.label(.success, "  " as NSString), DockLabel.none, "a blank label is no badge")
        XCTAssertEqual(DockBadgeReader.label(.noValue, nil), DockLabel.none)
        XCTAssertEqual(DockBadgeReader.label(.attributeUnsupported, nil), DockLabel.none)
        for e: AXError in [.cannotComplete, .invalidUIElement, .failure, .apiDisabled, .notImplemented, .illegalArgument] {
            XCTAssertEqual(DockBadgeReader.label(e, nil), .unreadable, "\(e.rawValue)")
        }
        XCTAssertEqual(DockBadgeReader.label(.success, NSNumber(value: 3)), .unreadable, "not a string: unreadable")
        XCTAssertEqual(DockBadgeReader.label(.success, nil), .unreadable)
    }

    func testAReadingKeepsApplicationItemsWithABundleAndMapsTheirBadges() {
        let url = URL(fileURLWithPath: "/Applications/Utilities/Terminal.app/")
        let raw = [
            DockBadgeReader.RawItem(subrole: "AXApplicationDockItem", url: url, labelError: .success, label: "1" as NSString),
            DockBadgeReader.RawItem(subrole: "AXApplicationDockItem", url: URL(fileURLWithPath: "/Applications/Telegram.app"),
                                    labelError: .cannotComplete, label: nil),
            DockBadgeReader.RawItem(subrole: "AXApplicationDockItem", url: nil, labelError: .noValue, label: nil),  // bundle unread
            DockBadgeReader.RawItem(subrole: nil, url: url, labelError: .noValue, label: nil),                      // subrole unread
            DockBadgeReader.RawItem(subrole: "AXFolderDockItem", url: URL(fileURLWithPath: "/Users/x/Downloads"),
                                    labelError: .success, label: "4" as NSString),
            DockBadgeReader.RawItem(subrole: "AXSeparatorDockItem", url: nil, labelError: .noValue, label: nil),
        ]
        let r = DockBadgeReader.reading(dock: 77, raw: raw, bundleID: { $0.lastPathComponent })
        XCTAssertEqual(r.dock, 77)
        XCTAssertEqual(r.items, [
            DockItemReading(path: "/Applications/Utilities/Terminal.app", bundleID: "Terminal.app", label: .badge("1")),
            DockItemReading(path: "/Applications/Telegram.app", bundleID: "Telegram.app", label: .unreadable),
        ])
    }

    // MARK: - through SimManager and the hub

    private var hub: ChannelHub!
    private var sim: SimManager!
    /// Every one-copy owner lookup the bell watch's refresh made, by the ids it asked for.
    private let bulkLookups = Locked<[Set<CGWindowID>]>([])
    /// The watch has its targets: the refresh is queued off the broadcasting thread.
    private var watching: Bool { sim.flushBellRefreshForTests(); return sim.dockBadges.isWatchingForTests }

    override func tearDown() {
        hub?.simDelegate = nil
        hub = nil; sim = nil
    }

    private func session(dock: FakeDock) {
        hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: NullVideoEncoder(),
                         terminalPauseHold: .milliseconds(50), mediaPauseHold: .milliseconds(50))
        sim = SimManager(makeEncoder: { _, _, _, _ in NullVideoEncoder() }, channelHub: hub,
                         defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                         bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000, graceSeconds: 60)
        sim.attachesCaptureForTests = false
        sim.windowOwnerPID = { $0 == 12 ? 200 : 100 }           // win:12 is Telegram's, every other Terminal's
        sim.windowOwnerPIDs = { [weak self] ids in
            self?.bulkLookups.withLock { $0.append(ids) }
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == 12 ? 200 : 100) })
        }
        sim.existingWindowIDs = { [] }
        sim.dockBadges = watch(dock) { _ in }                     // SimManager wires its own `onRing`
        hub.simDelegate = sim
        hub.isVideoSubscribed = { true }
    }

    private func bells(_ c: WindowlessConnection) -> [[String]] {
        c.controlMessages.compactMap { m -> [String]? in
            guard let o = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any],
                  o["t"] as? String == "window-bell" else { return nil }
            return o["sources"] as? [String]
        }
    }

    func testARiseReachesTheDriverAsAWindowBellNamingEveryWindowOfThatApplicationMinimizedToo() {
        let dock = FakeDock()
        dock.set(terminal, nil); dock.set(telegram, nil)
        session(dock: dock)
        let driver = WindowlessConnection("sock:d"), passive = WindowlessConnection("sock:p")
        hub.register(clientId: driver.clientId, peer: driver)                 // the first client drives
        hub.connection(driver, didOpen: .control)
        hub.register(clientId: passive.clientId, peer: passive)
        hub.connection(passive, didOpen: .control)
        sim.openWindow(sourceID: "win:11", requestedBy: driver.clientId)
        sim.openWindow(sourceID: "win:12", requestedBy: driver.clientId)
        sim.openWindow(sourceID: "win:13", requestedBy: driver.clientId)
        sim.minimizeWindow(sourceID: "win:13", requestedBy: driver.clientId)
        sim.flushBellRefreshForTests()
        sim.dockBadges.pollForTests()                                         // the baseline, read at the start
        XCTAssertTrue(watching, "a driver and windows: the Dock is watched")
        dock.set(terminal, "1")
        sim.dockBadges.pollForTests()
        XCTAssertEqual(bells(driver), [["win:11", "win:13"]], "Terminal's windows, the parked one included")
        XCTAssertEqual(bells(passive), [], "the driver's alone")
        dock.set(telegram, "2")
        sim.dockBadges.pollForTests()
        XCTAssertEqual(bells(driver).last, ["win:12"])
    }

    /// REVIEW F5: the refresh looks owners up ONCE, only for windows with no stream (a minimized one), and a tab
    /// drag — `windows` reordered, the same set — looks nothing up at all.
    func testTheRefreshLooksOwnersUpOnceAndNeverForADrag() {
        session(dock: FakeDock())
        // Each refresh waited for: one queued by the first open could otherwise run between the second window
        // entering the state and its stream being built, and look that one up — correct, and not this test.
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        sim.flushBellRefreshForTests()
        sim.openWindow(sourceID: "win:12", requestedBy: "a")
        sim.flushBellRefreshForTests()
        XCTAssertEqual(bulkLookups.withLock { $0 }, [], "streamed windows: their streams know their owners")
        sim.openWindow(sourceID: "win:13", requestedBy: "a")
        sim.flushBellRefreshForTests()
        sim.minimizeWindow(sourceID: "win:13", requestedBy: "a")
        sim.flushBellRefreshForTests()
        XCTAssertEqual(bulkLookups.withLock { $0 }, [], "parking changes no window: its owner is the one already watched")
        sim.stopStreamsKeepingSession()                                       // nobody drives: the watch stops
        sim.flushBellRefreshForTests()
        sim.reconcile(driverPrefs: .default)                                  // a driver again: the targets anew
        sim.flushBellRefreshForTests()
        XCTAssertEqual(bulkLookups.withLock { $0 }, [[13]], "only the parked window — it has no stream — in ONE lookup")
        let lookups = bulkLookups.withLock { $0.count }
        XCTAssertNotNil(sim.moveTab("win:13", before: "win:11"))
        sim.flushBellRefreshForTests()
        XCTAssertEqual(bulkLookups.withLock { $0.count }, lookups, "a drag changes no window: nothing looked up")
    }

    func testNoWindowOrNoDriverNoWatch() {
        let dock = FakeDock()
        session(dock: dock)
        XCTAssertFalse(watching, "nothing open")
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        XCTAssertTrue(watching)
        sim.closeWindow(sourceID: "win:11", requestedBy: "a")
        XCTAssertFalse(watching, "the last window went")
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        XCTAssertTrue(watching)
        sim.stopStreamsKeepingSession()                                       // Stop Sharing: no driver drives
        XCTAssertFalse(watching, "the windows stay in the state, but nobody drives")
        sim.reconcile(driverPrefs: .default)                                  // a driver again
        XCTAssertTrue(watching)
        sim.endSession()
        XCTAssertFalse(watching)
    }
}
