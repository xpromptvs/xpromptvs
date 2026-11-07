import XCTest
import RdevCore
@testable import RdevHostKit

final class SimulatorInputInjectorTests: XCTestCase {
    final class Sink: SimHIDSink, @unchecked Sendable {
        enum E: Equatable { case touch(SimTouchEvent), key(UInt32, Bool), button(UInt16, Bool) }
        let lock = NSLock(); var events: [E] = []; var dead = false
        var onKey: (() -> Void)?
        var invalidated: Bool { lock.withLock { dead } }
        func touch(_ e: SimTouchEvent) { lock.withLock { events.append(.touch(e)) } }
        func key(_ u: UInt32, down: Bool) { lock.withLock { events.append(.key(u, down)) }; onKey?() }
        func button(_ b: SimButton, down: Bool) { lock.withLock { events.append(.button(b.usage, down)) } }
        var all: [E] { lock.withLock { events } }
    }
    final class Clock: @unchecked Sendable { let lock = NSLock(); var ms = 0; var now: Int { lock.withLock { ms } } }
    final class Runner: @unchecked Sendable { let lock = NSLock(); var calls: [[String]] = []; var stdin: [Data?] = [] }

    private var sinks: [Sink] = []
    private var connects = 0
    /// When set, what a connect does instead of handing out a fresh sink at once.
    private var connectBehavior: (() -> SimHIDSink?)?
    private let display = SimDisplayState()
    private let clock = Clock()
    private let runner = Runner()

    private func injector() -> SimulatorInputInjector {
        let control = SimulatorControl(run: { [runner] args, stdin, _ in
            runner.lock.withLock { runner.calls.append(args); runner.stdin.append(stdin) }
            return (0, Data())
        })
        return SimulatorInputInjector(udid: "U", connect: { [unowned self] in
            self.connects += 1
            if let b = self.connectBehavior { return b() }
            let s = Sink(); self.sinks.append(s); return s
        }, display: display, control: control, nativePointW: 402, nativePointH: 874, nowMs: { [clock] in clock.now })
    }

    func testOwnershipLostDuringHIDConnectDropsTheWaitingTouch() {
        let sink = Sink(), gate = Clock()
        let inj = SimulatorInputInjector(udid: "U", connect: {
            gate.lock.withLock { gate.ms = 1 }
            return sink
        }, display: SimDisplayState(), control: SimulatorControl(run: { _, _, _ in (0, Data()) }),
        nativePointW: 402, nativePointH: 874, isInputCurrent: { gate.now == 0 })
        inj.simTouch(phase: "down", points: [SimPoint(x: 0.5, y: 0.5)])
        inj.drainForTests()
        XCTAssertTrue(sink.all.isEmpty, "input queued under the previous owner cannot land after connect")
    }

    func testHandoffInterruptsTextBetweenCharacters() {
        let sink = Sink(), gate = Clock()
        sink.onKey = { gate.lock.withLock { gate.ms = 1 } }
        let inj = SimulatorInputInjector(udid: "U", connect: { sink }, display: SimDisplayState(),
            control: SimulatorControl(run: { _, _, _ in (0, Data()) }), nativePointW: 402, nativePointH: 874,
            isInputCurrent: { gate.now == 0 })
        inj.simText("abc")
        inj.drainForTests()
        XCTAssertEqual(sink.all, [.key(4, true), .key(4, false)], "finish the current key but do not type into the next driver's session")
    }

    func testScopedTouchIsRejectedAfterItsHIDConnectOutlivesTheLease() {
        let sink = Sink(), gate = Clock()
        let inj = SimulatorInputInjector(udid: "U", connect: {
            gate.lock.withLock { gate.ms = 1 }
            return sink
        }, display: SimDisplayState(), control: SimulatorControl(run: { _, _, _ in (0, Data()) }),
        nativePointW: 402, nativePointH: 874)
        inj.submitScoped(.simTouch(phase: "down", points: [SimPoint(x: 0.5, y: 0.5)]), postFence: { post in
            gate.lock.withLock { guard gate.ms == 0 else { return false }; post(); return true }
        })
        inj.drainForTests()
        XCTAssertTrue(sink.all.isEmpty, "a lease must be checked after the potentially blocking HID connection")
    }

    func testScopedTextRechecksEveryPostAndDrainsBeforeTheNextFocus() {
        let sink = Sink(), gate = Clock()
        sink.onKey = { gate.lock.withLock { gate.ms = 1 } }
        let inj = SimulatorInputInjector(udid: "U", connect: { sink }, display: SimDisplayState(),
            control: SimulatorControl(run: { _, _, _ in (0, Data()) }), nativePointW: 402, nativePointH: 874)
        // The test's callback changes ownership synchronously from a posted event; do not hold
        // its stand-in lock across the callback. The real hub fence holds its own lock at post.
        inj.submitScoped(.simText("ab"), postFence: { post in
            guard gate.now == 0 else { return false }; post(); return true
        })
        inj.drainForFocusChange {}
        inj.drainForTests()
        XCTAssertEqual(sink.all, [.key(4, true), .key(4, false)], "only the accepted down and its neutral drain may post")
    }

    func testScopedReleaseInterruptedBetweenKeysRetainsTheUnpostedUp() {
        let sink = Sink(), gate = Clock()
        sink.onKey = {
            if case .key(_, false)? = sink.all.last { gate.lock.withLock { gate.ms = 1 } }
        }
        let inj = SimulatorInputInjector(udid: "U", connect: { sink }, display: SimDisplayState(),
            control: SimulatorControl(run: { _, _, _ in (0, Data()) }), nativePointW: 402, nativePointH: 874)
        let fence: InputPostFence = { post in guard gate.now == 0 else { return false }; post(); return true }
        for code in ["KeyA", "KeyB"] {
            inj.submitScoped(.winKey(down: true, code: code, key: code == "KeyA" ? "a" : "b", repeat: false, mods: .none), postFence: fence)
        }
        inj.submitScoped(.winKeysRelease, postFence: fence)
        inj.drainForFocusChange {}
        inj.drainForTests()
        let ups = sink.all.compactMap { event -> UInt32? in if case .key(let usage, false) = event { return usage }; return nil }
        XCTAssertEqual(Set(ups), Set([UInt32(4), UInt32(5)]))
        XCTAssertEqual(ups.count, 2)
    }

    func testScopedReleaseInterruptedBeforeTouchUpRetainsTheGestureForNeutralDrain() {
        let sink = Sink(), gate = Clock()
        sink.onKey = { if case .key(_, false)? = sink.all.last { gate.lock.withLock { gate.ms = 1 } } }
        let inj = SimulatorInputInjector(udid: "U", connect: { sink }, display: SimDisplayState(),
            control: SimulatorControl(run: { _, _, _ in (0, Data()) }), nativePointW: 402, nativePointH: 874)
        let fence: InputPostFence = { post in guard gate.now == 0 else { return false }; post(); return true }
        inj.submitScoped(.winKey(down: true, code: "KeyA", key: "a", repeat: false, mods: .none), postFence: fence)
        inj.submitScoped(.simTouch(phase: "down", points: [SimPoint(x: 0.5, y: 0.5)]), postFence: fence)
        inj.submitScoped(.winKeysRelease, postFence: fence)
        inj.drainForFocusChange {}
        inj.drainForTests()
        XCTAssertEqual(sink.all, [.key(4, true), .touch(.start([SimPoint(x: 0.5, y: 0.5)])),
            .key(4, false), .touch(.end([SimPoint(x: 0.5, y: 0.5)]))])
    }

    func testATapInPortrait() {
        let inj = injector()
        inj.simTouch(phase: "down", points: [SimPoint(x: 0.25, y: 0.75)])
        inj.simTouch(phase: "up", points: [SimPoint(x: 0.25, y: 0.75)])
        inj.drainForTests()
        XCTAssertEqual(sinks.first?.all, [.touch(.start([SimPoint(x: 0.25, y: 0.75)])), .touch(.end([SimPoint(x: 0.25, y: 0.75)]))])
    }

    /// The rotated tap is the MEASURED one: Safari's landscape address field.
    func testATapWhenRotatedIsTurnedToTheNativeFrame() {
        display.rotation = .rot270
        let inj = injector()
        inj.simTouch(phase: "down", points: [SimPoint(x: 0.4, y: 0.09)])
        inj.drainForTests()
        guard case .touch(.start(let p))? = sinks.first?.all.first else { return XCTFail("\(String(describing: sinks.first?.all))") }
        XCTAssertEqual(p[0].x, 0.91, accuracy: 1e-9)
        XCTAssertEqual(p[0].y, 0.4, accuracy: 1e-9)
    }

    func testKeysRepeatsAndRelease() {
        let inj = injector()
        inj.key(down: true, code: "ShiftLeft", key: "Shift", repeat: false, mods: .none)
        inj.key(down: true, code: "KeyA", key: "A", repeat: false, mods: .none)
        inj.key(down: true, code: "KeyA", key: "A", repeat: true, mods: .none)    // iOS repeats a held key itself
        inj.releaseKeys()
        inj.drainForTests()
        let e = sinks.first?.all ?? []
        XCTAssertEqual(Array(e.prefix(2)), [.key(0xE1, true), .key(4, true)])
        XCTAssertEqual(Set(e.dropFirst(2).map { "\($0)" }), Set([Sink.E.key(0xE1, false), .key(4, false)].map { "\($0)" }),
                       "release lifts exactly what is held, once")
    }

    func testCommittedTextTemporarilyLiftsAndRestoresPhysicalModifiers() {
        let inj = injector()
        inj.key(down: true, code: "MetaLeft", key: "", repeat: false, mods: .none)
        inj.simText("a")
        inj.key(down: false, code: "MetaLeft", key: "", repeat: false, mods: .none)
        inj.drainForTests()
        XCTAssertEqual(sinks.first?.all, [.key(0xE3, true), .key(0xE3, false),
            .key(4, true), .key(4, false), .key(0xE3, true), .key(0xE3, false)])
    }

    func testTypeableTextIsTyped() {
        let inj = injector()
        inj.simText("Hi!")
        inj.drainForTests()
        XCTAssertEqual(sinks.first?.all, [
            .key(0xE1, true), .key(11, true), .key(11, false), .key(0xE1, false),   // H
            .key(12, true), .key(12, false),                                       // i
            .key(0xE1, true), .key(30, true), .key(30, false), .key(0xE1, false),   // !
        ])
        XCTAssertTrue(runner.calls.isEmpty, "nothing pasted")
    }

    /// What no key types goes WHOLE through the simulator's pasteboard, then ⌘V (measured to paste it).
    func testOtherTextIsPasted() {
        let inj = injector()
        inj.simText("héllo 😀")
        inj.drainForTests()
        XCTAssertEqual(runner.calls.first, ["devicectl", "device", "pasteboard", "copy", "--device", "U"])
        XCTAssertEqual(runner.stdin.first ?? nil, Data("héllo 😀".utf8))
        XCTAssertEqual(sinks.first?.all, [.key(0xE3, true), .key(0x19, true), .key(0x19, false), .key(0xE3, false)])
    }

    func testAPasteGoesThroughThePasteboardAndTakesNoFiles() {
        let inj = injector()
        XCTAssertEqual(inj.pasteText("x"), true)
        XCTAssertFalse(inj.takesFilePastes)
    }

    /// REVIEW FOCUS 3, end to end: a wheel never taps, and a real scroll is a drag that ends by itself.
    func testAWheelIsADragThatEndsByItself() {
        let inj = injector()
        inj.scroll(normalizedX: 0.5, normalizedY: 0.5, deltaX: 0, deltaY: 3, unit: .pixel, mods: .none)
        inj.drainForTests()
        XCTAssertNil(sinks.first, "under the slop: no press, so no connection was even needed")
        inj.scroll(normalizedX: 0.5, normalizedY: 0.5, deltaX: 0, deltaY: 84.4, unit: .pixel, mods: .none)
        inj.drainForTests()
        XCTAssertEqual(sinks.first?.all.count, 2, "start + move")
        clock.lock.withLock { clock.ms = 500 }
        Thread.sleep(forTimeInterval: SimWheelDrag.idleMs.asSeconds + 0.1)
        inj.drainForTests()
        guard case .touch(.end)? = sinks.first?.all.last else { return XCTFail("\(String(describing: sinks.first?.all))") }
    }

    func testKeyboardToggleSendsConsumerEjectDownAndUp() {
        let inj = injector()
        inj.press(.keyboard)
        inj.drainForTests()
        XCTAssertEqual(sinks.first?.all, [.button(0xB8, true), .button(0xB8, false)])
    }

    func testButtons() {
        let inj = injector()
        inj.press(.home)
        inj.drainForTests()
        XCTAssertEqual(sinks.first?.all, [.button(0x40, true), .button(0x40, false)])
    }

    /// REVIEW FOCUS 5: a reboot invalidates the connection; the next event gets a NEW one — at most once per backoff
    /// — and starts its gesture afresh rather than continuing one the old connection took down with it.
    func testAnInvalidatedConnectionIsReplacedOnTheNextEvent() {
        let inj = injector()
        inj.simTouch(phase: "down", points: [SimPoint(x: 0.1, y: 0.1)])
        inj.drainForTests()
        sinks[0].lock.withLock { sinks[0].dead = true }
        inj.simTouch(phase: "move", points: [SimPoint(x: 0.2, y: 0.2)])
        inj.drainForTests()
        XCTAssertEqual(connects, 1, "inside the backoff: no reconnect yet")
        clock.lock.withLock { clock.ms = SimulatorInputInjector.reconnectBackoffMs + 1 }
        inj.simTouch(phase: "move", points: [SimPoint(x: 0.3, y: 0.3)])
        inj.drainForTests()
        XCTAssertEqual(connects, 2)
        XCTAssertEqual(sinks[1].all, [.touch(.start([SimPoint(x: 0.3, y: 0.3)]))])
    }

    /// FINAL REVIEW I3. A connect that took 3 s and failed must not be retried at once: the backoff counts from the END
    /// of an attempt, or a booting device is reconnected back to back while every tap waits.
    func testTheBackoffCountsFromTheEndOfAnAttempt() {
        connectBehavior = { [clock] in clock.lock.withLock { clock.ms += 3000 }; return nil }
        let inj = injector()
        inj.simTouch(phase: "down", points: [SimPoint(x: 0.1, y: 0.1)])
        inj.drainForTests()
        clock.lock.withLock { clock.ms += 1 }
        inj.simTouch(phase: "up", points: [SimPoint(x: 0.1, y: 0.1)])
        inj.drainForTests()
        XCTAssertEqual(connects, 1, "inside the backoff, counted from the attempt's end")
    }

    /// FINAL REVIEW I3. Taps made while a slow connect ran (a window reading "Booting…") must not all land at once when it
    /// succeeds: input older than `staleMs` is dropped, and a fresh tap after it goes through.
    func testInputQueuedBehindASlowConnectIsDropped() {
        let late = Sink()
        connectBehavior = { [clock] in clock.lock.withLock { clock.ms += 3000 }; return late }
        let inj = injector()
        inj.simTouch(phase: "down", points: [SimPoint(x: 0.1, y: 0.1)])
        inj.simTouch(phase: "up", points: [SimPoint(x: 0.1, y: 0.1)])
        inj.drainForTests()
        XCTAssertEqual(late.all, [], "a tap that waited 3 s for the connect is not replayed")
        inj.simTouch(phase: "down", points: [SimPoint(x: 0.5, y: 0.5)])
        inj.simTouch(phase: "up", points: [SimPoint(x: 0.5, y: 0.5)])
        inj.drainForTests()
        XCTAssertEqual(late.all, [.touch(.start([SimPoint(x: 0.5, y: 0.5)])), .touch(.end([SimPoint(x: 0.5, y: 0.5)]))])
    }

    /// FINAL REVIEW I5. ⌘ SWALLOWS KEYUP — a browser never sends the other key's up while ⌘ is held — so ⌘'s up releases
    /// every key still held, or the A of ⌘A stays down in the simulator.
    func testCommandUpReleasesTheKeysItSwallowed() {
        let inj = injector()
        inj.key(down: true, code: "MetaLeft", key: "Meta", repeat: false, mods: .none)
        inj.key(down: true, code: "KeyA", key: "a", repeat: false, mods: .none)
        inj.key(down: false, code: "MetaLeft", key: "Meta", repeat: false, mods: .none)
        inj.drainForTests()
        XCTAssertEqual(sinks.first?.all, [.key(0xE3, true), .key(4, true), .key(4, false), .key(0xE3, false)])
    }

    /// FINAL REVIEW I9. A text paste into a simulator is capped: past it nothing reaches devicectl.
    func testATextPasteBeyondTheCapFails() {
        let inj = injector()
        XCTAssertEqual(inj.pasteText(String(repeating: "a", count: SimulatorInputInjector.pasteCapBytes + 1)), false)
        XCTAssertTrue(runner.calls.isEmpty)
    }

}

private extension Int { var asSeconds: Double { Double(self) / 1000 } }
