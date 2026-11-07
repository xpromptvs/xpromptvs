import CoreGraphics
import XCTest
import RdevCore
@testable import RdevHostKit

/// Building a `CGEvent` needs no permission — only POSTING one is gated by Accessibility. That is
/// what lets the exact bytes rdev puts on the HID stream be asserted here, with no window, no TCC
/// grant and no GUI session. What this cannot see is whether the event reaches an app; that is
/// `scripts/gate-window-input.sh`.
final class ScrollEventBuilderTests: XCTestCase {
    func testPixelScrollIsContinuousAndCarriesItsPhase() throws {
        let e = try XCTUnwrap(WindowInputInjector.makeScrollEvent(
            source: nil, unit: .pixel, dx: 0, dy: -12, phase: .began, flags: []))
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        // MEASURED, and the field is not the obvious one: under `.pixel` units DeltaAxis1 holds the
        // LINE-EQUIVALENT (it reads -1 for a 12px delta) and the pixels live in PointDeltaAxis1. An
        // assertion on DeltaAxis1 here would be comparing a rounded approximation and would go green
        // for any delta inside the same line bucket.
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -12)
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventScrollPhase), 1)   // kCGScrollPhaseBegan
    }

    func testChangedAndEndedUseTheirOwnPhaseCodes() throws {
        let changed = try XCTUnwrap(WindowInputInjector.makeScrollEvent(
            source: nil, unit: .pixel, dx: 0, dy: -1, phase: .changed, flags: []))
        XCTAssertEqual(changed.getIntegerValueField(.scrollWheelEventScrollPhase), 2)
        let ended = try XCTUnwrap(WindowInputInjector.makeScrollEvent(
            source: nil, unit: .pixel, dx: 0, dy: 0, phase: .ended, flags: []))
        XCTAssertEqual(ended.getIntegerValueField(.scrollWheelEventScrollPhase), 4)
    }

    /// A notched wheel must stay notched: line units, and NO phase (a real wheel gesture has none,
    /// and claiming one would tell AppKit to rubber-band a discrete notch).
    func testLineScrollIsNeitherContinuousNorPhased() throws {
        let e = try XCTUnwrap(WindowInputInjector.makeScrollEvent(
            source: nil, unit: .line, dx: 0, dy: 3, phase: nil, flags: []))
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventIsContinuous), 0)
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventDeltaAxis1), 3)
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
    }

    /// ⌥-scroll and ⌘-scroll-to-zoom are the whole reason `mods` rides the wire.
    func testModifierFlagsReachTheEvent() throws {
        let e = try XCTUnwrap(WindowInputInjector.makeScrollEvent(
            source: nil, unit: .pixel, dx: 0, dy: -3, phase: .changed,
            flags: InputModifiers(raw: InputModifiers.optionBit).cgFlags))
        XCTAssertTrue(e.flags.contains(.maskAlternate))
    }

    /// THE TWO PHASE FIELDS ARE SEPARATE, and a finger-driven event must leave the momentum one at
    /// `kCGMomentumScrollPhaseNone`. An app reads the pair to tell a drag from a coast; writing both
    /// would describe an event that no real trackpad ever produces.
    func testAFingerDrivenEventCarriesNoMomentumPhase() throws {
        let e = try XCTUnwrap(WindowInputInjector.makeScrollEvent(
            source: nil, unit: .pixel, dx: 0, dy: -12, phase: .changed, flags: []))
        XCTAssertEqual(e.getIntegerValueField(CGEventField(rawValue: 123)!), 0)
    }

    /// ...and a momentum step is the mirror image: the momentum phase set, the gesture phase left at
    /// zero, so the app knows the fingers are gone. The raw 123 is `kCGScrollWheelEventMomentumPhase`,
    /// which CoreGraphics does not expose as a Swift constant.
    func testAMomentumStepCarriesItsPhaseAndNoGesturePhase() throws {
        for (phase, code) in [(MomentumPhase.begin, 1), (.continuing, 2), (.end, 3)] {
            let e = try XCTUnwrap(WindowInputInjector.makeScrollEvent(
                source: nil, unit: .pixel, dx: 0, dy: -6, phase: nil, momentum: phase, flags: []))
            XCTAssertEqual(e.getIntegerValueField(CGEventField(rawValue: 123)!), Int64(code))
            XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
            XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
            XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -6)
        }
    }

    /// A LINE event takes neither field. Momentum is a continuous-scroll concept; a notched wheel
    /// that claimed to be coasting would ask AppKit to rubber-band a discrete notch.
    func testALineEventTakesNoMomentumPhaseEither() throws {
        let e = try XCTUnwrap(WindowInputInjector.makeScrollEvent(
            source: nil, unit: .line, dx: 0, dy: 3, phase: nil, momentum: .begin, flags: []))
        XCTAssertEqual(e.getIntegerValueField(CGEventField(rawValue: 123)!), 0)
    }

    /// wheel1 is VERTICAL and wheel2 is HORIZONTAL. The negation of the browser's sign happens in
    /// the caller, not here — this asserts only that the axes do not swap.
    func testAxesDoNotSwap() throws {
        let e = try XCTUnwrap(WindowInputInjector.makeScrollEvent(
            source: nil, unit: .pixel, dx: 7, dy: -9, phase: .changed, flags: []))
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -9)
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 7)
    }
}
