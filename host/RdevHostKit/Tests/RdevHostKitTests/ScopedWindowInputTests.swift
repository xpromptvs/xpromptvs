import CoreGraphics
import XCTest
import RdevCore
@testable import RdevHostKit

final class ScopedWindowInputTests: XCTestCase {
    func testNativeContactCanRestLongerThanTheLegacyQuietTimerWithoutReleasing() {
        var phases: [Int64] = []
        let inj = WindowInputInjector(testBounds: CGRect(x: 0, y: 0, width: 800, height: 600), post: { e in
            if e.type == .scrollWheel { phases.append(e.getIntegerValueField(.scrollWheelEventScrollPhase)) }
        })
        let fence: InputPostFence = { $0(); return true }
        inj.submitScoped(.scrollGesture(x: 0.5, y: 0.5, phase: .begin, vx: 0, vy: 0, mods: .none), postFence: fence)
        inj.submitScoped(.scroll(x: 0.5, y: 0.5, dx: 0, dy: 10, unit: .pixel, mods: .none), postFence: fence)
        let rested = expectation(description: "contact rests beyond legacy timeout")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.13) { inj.enqueueForTests { rested.fulfill() } }
        wait(for: [rested], timeout: 1)
        XCTAssertEqual(phases, [1], "A pause while fingers remain down is not a release")
        inj.submitScoped(.scroll(x: 0.5, y: 0.5, dx: 0, dy: 10, unit: .pixel, mods: .none), postFence: fence)
        inj.submitScoped(.scrollGesture(x: 0.5, y: 0.5, phase: .end, vx: 0, vy: 0, mods: .none), postFence: fence)
        let ended = expectation(description: "explicit release")
        inj.enqueueForTests { ended.fulfill() }; wait(for: [ended], timeout: 1)
        XCTAssertEqual(phases, [1, 2, 4])
    }
    func testNativeReleaseClosesTheGestureBeforeHostMomentumStarts() {
        var phases: [(Int64, Int64)] = []
        let began = expectation(description: "host momentum")
        let inj = WindowInputInjector(testBounds: CGRect(x: 0, y: 0, width: 800, height: 600), post: { e in
            guard e.type == .scrollWheel else { return }
            let direct = e.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = e.getIntegerValueField(CGEventField(rawValue: 123)!)
            phases.append((direct, momentum))
            if momentum == 1 { began.fulfill() }
        })
        inj.submitScoped(.scroll(x: 0.5, y: 0.5, dx: 0, dy: 12, unit: .pixel, mods: .none), postFence: { $0(); return true })
        inj.submitScoped(.scrollGesture(x: 0.5, y: 0.5, phase: .end, vx: 0, vy: 500, mods: .none), postFence: { $0(); return true })
        wait(for: [began], timeout: 1)
        let drained = expectation(description: "stop")
        inj.drainForFocusChange { drained.fulfill() }; wait(for: [drained], timeout: 1)
        XCTAssertEqual(phases.first?.0, 1)
        guard let end = phases.firstIndex(where: { $0.0 == 4 }), let momentum = phases.firstIndex(where: { $0.1 == 1 }) else { return XCTFail("Missing direct end or host momentum begin") }
        XCTAssertLessThan(end, momentum)
        XCTAssertTrue(phases.allSatisfy { $0.0 == 0 || $0.1 == 0 })
    }

    func testNativeCancelClosesDirectScrollWithoutStartingMomentum() {
        var phases: [(Int64, Int64)] = []
        let inj = WindowInputInjector(testBounds: CGRect(x: 0, y: 0, width: 800, height: 600), post: { e in
            if e.type == .scrollWheel { phases.append((e.getIntegerValueField(.scrollWheelEventScrollPhase), e.getIntegerValueField(CGEventField(rawValue: 123)!))) }
        })
        inj.submitScoped(.scroll(x: 0.5, y: 0.5, dx: 0, dy: 12, unit: .pixel, mods: .none), postFence: { $0(); return true })
        inj.submitScoped(.scrollGesture(x: 0.5, y: 0.5, phase: .cancel, vx: 0, vy: 500, mods: .none), postFence: { $0(); return true })
        let done = expectation(description: "cancel processed")
        inj.enqueueForTests { done.fulfill() }; wait(for: [done], timeout: 1)
        XCTAssertEqual(phases.map { $0.0 }, [1, 4])
        XCTAssertTrue(phases.allSatisfy { $0.1 == 0 })
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var valid = true
        var events: [CGEventType] = []
        func fence(_ post: () -> Void) -> Bool {
            lock.withLock { guard valid else { return false }; post(); return true }
        }
    }
    func testQueuedOldInputCannotPostAfterLeaseRevocation() {
        let state = State(), gate = DispatchSemaphore(value: 0)
        let inj = WindowInputInjector(testBounds: CGRect(x: 0, y: 0, width: 800, height: 600), post: { state.events.append($0.type) })
        inj.enqueueForTests { gate.wait() }
        inj.submitScoped(.hover(x: 0.5, y: 0.5), postFence: state.fence)
        inj.submitScoped(.winKey(down: true, code: "KeyA", key: "a", repeat: false, mods: .none), postFence: state.fence)
        state.lock.withLock { state.valid = false }
        let drained = expectation(description: "neutral drain")
        inj.drainForFocusChange { drained.fulfill() }
        gate.signal()
        wait(for: [drained], timeout: 3)
        XCTAssertTrue(state.events.isEmpty)
    }

    func testNeutralModifiersAndPointerReleaseFinishBeforeFocusDrainCompletes() {
        let state = State()
        let inj = WindowInputInjector(testBounds: CGRect(x: 0, y: 0, width: 800, height: 600), post: { state.events.append($0.type) })
        inj.submitScoped(.winKey(down: true, code: "ShiftLeft", key: "Shift", repeat: false, mods: InputModifiers(raw: InputModifiers.shiftBit)), postFence: state.fence)
        inj.submitScoped(.touch(x: 0.5, y: 0.5, phase: "down", button: .left, ts: nil), postFence: state.fence)
        let accepted = expectation(description: "accepted down")
        inj.enqueueForTests { accepted.fulfill() }
        wait(for: [accepted], timeout: 3)
        XCTAssertEqual(state.events, [.flagsChanged, .leftMouseDown])
        state.lock.withLock { state.valid = false }
        let drained = expectation(description: "all releases before completion")
        inj.drainForFocusChange { drained.fulfill() }
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(state.events, [.flagsChanged, .leftMouseDown, .flagsChanged, .leftMouseUp])
    }

    func testInterruptedReleaseRetainsUnpostedKeyUpsForNeutralDrain() {
        let state = State()
        var ups: [Int64] = []
        let inj = WindowInputInjector(testBounds: CGRect(x: 0, y: 0, width: 800, height: 600), post: { event in
            state.events.append(event.type)
            if event.type == .keyUp {
                ups.append(event.getIntegerValueField(.keyboardEventKeycode))
                if ups.count == 1 { state.valid = false } // Callback runs inside the stand-in fence lock.
            }
        })
        for code in ["KeyA", "KeyB"] {
            inj.submitScoped(.winKey(down: true, code: code, key: code == "KeyA" ? "a" : "b", repeat: false, mods: .none), postFence: state.fence)
        }
        inj.submitScoped(.winKeysRelease, postFence: state.fence)
        let drained = expectation(description: "remaining neutral releases")
        inj.drainForFocusChange { drained.fulfill() }
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(Set(ups), Set([Int64(0), Int64(11)]))
        XCTAssertEqual(ups.count, 2)
    }

    func testInterruptedModifierReleaseRetainsUnpostedMouseUpForNeutralDrain() {
        let state = State()
        var flagChanges = 0
        let inj = WindowInputInjector(testBounds: CGRect(x: 0, y: 0, width: 800, height: 600), post: { event in
            state.events.append(event.type)
            if event.type == .flagsChanged {
                flagChanges += 1
                if flagChanges == 2 { state.valid = false }
            }
        })
        inj.submitScoped(.winKey(down: true, code: "ShiftLeft", key: "Shift", repeat: false, mods: InputModifiers(raw: InputModifiers.shiftBit)), postFence: state.fence)
        inj.submitScoped(.touch(x: 0.5, y: 0.5, phase: "down", button: .left, ts: nil), postFence: state.fence)
        inj.submitScoped(.winKeysRelease, postFence: state.fence)
        let drained = expectation(description: "remaining pointer release")
        inj.drainForFocusChange { drained.fulfill() }
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(state.events, [.flagsChanged, .leftMouseDown, .flagsChanged, .leftMouseUp])
    }

    func testAnUnpairedDragDoesNotInventANeutralMouseUp() {
        let state = State()
        let inj = WindowInputInjector(testBounds: CGRect(x: 0, y: 0, width: 800, height: 600), post: { state.events.append($0.type) })
        inj.submitScoped(.touch(x: 0.5, y: 0.5, phase: "move", button: .left, ts: nil), postFence: state.fence)
        let drained = expectation(description: "no press owed")
        inj.drainForFocusChange { drained.fulfill() }
        wait(for: [drained], timeout: 3)
        XCTAssertFalse(state.events.contains(.leftMouseUp))
    }

    func testQuietScrollTimerRetainsTheLeaseOfItsOriginatingGesture() {
        let state = State()
        let inj = WindowInputInjector(testBounds: CGRect(x: 0, y: 0, width: 800, height: 600), post: { state.events.append($0.type) })
        inj.submitScoped(.scroll(x: 0.5, y: 0.5, dx: 0, dy: 10, unit: .pixel, mods: .none), postFence: state.fence)
        let accepted = expectation(description: "scroll queued")
        inj.enqueueForTests { accepted.fulfill() }
        wait(for: [accepted], timeout: 3)
        let count = state.events.count
        XCTAssertGreaterThan(count, 0)
        state.lock.withLock { state.valid = false }
        let expired = expectation(description: "quiet timer expired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { inj.enqueueForTests { expired.fulfill() } }
        wait(for: [expired], timeout: 3)
        XCTAssertEqual(state.events.count, count, "timer must not escape its captured fence")
    }
}
