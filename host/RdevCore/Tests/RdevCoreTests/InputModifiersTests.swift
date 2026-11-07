import CoreGraphics
import XCTest
@testable import RdevCore

final class InputModifiersTests: XCTestCase {
    func testEachBitMapsToItsCGEventFlag() {
        XCTAssertEqual(InputModifiers(raw: InputModifiers.shiftBit).cgFlags, .maskShift)
        XCTAssertEqual(InputModifiers(raw: InputModifiers.controlBit).cgFlags, .maskControl)
        XCTAssertEqual(InputModifiers(raw: InputModifiers.optionBit).cgFlags, .maskAlternate)
        XCTAssertEqual(InputModifiers(raw: InputModifiers.commandBit).cgFlags, .maskCommand)
        XCTAssertEqual(InputModifiers(raw: InputModifiers.capsLockBit).cgFlags, .maskAlphaShift)
    }

    func testCombinedBitsCombineFlags() {
        let m = InputModifiers(raw: InputModifiers.commandBit | InputModifiers.shiftBit)
        XCTAssertEqual(m.cgFlags, [.maskCommand, .maskShift])
        XCTAssertTrue(m.command)
        XCTAssertTrue(m.shift)
        XCTAssertFalse(m.option)
    }

    func testNoBitsIsEmptyRatherThanADefault() {
        XCTAssertEqual(InputModifiers(raw: 0).cgFlags, [])
        XCTAssertEqual(InputModifiers(raw: 0), InputModifiers.none)
    }

    // A version skew must not smuggle an unknown flag onto every event the host posts.
    func testUnknownBitsAreDropped() {
        XCTAssertEqual(InputModifiers(raw: 1 << 20).raw, 0)
        XCTAssertEqual(InputModifiers(raw: InputModifiers.shiftBit | (1 << 20)).cgFlags, .maskShift)
    }
}
