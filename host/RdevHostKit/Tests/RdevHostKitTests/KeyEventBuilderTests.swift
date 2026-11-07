import CoreGraphics
import XCTest
import RdevCore
@testable import RdevHostKit

/// Same standing as ScrollEventBuilderTests: constructing a CGEvent is ungated, so the exact fields
/// rdev puts on the HID stream are assertable with no window and no Accessibility grant.
final class KeyEventBuilderTests: XCTestCase {
    private func unicodeString(of e: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }

    func testAKeyDownCarriesItsKeycodeAndFlags() throws {
        let action = KeyAction.key(keyCode: 8, flags: .maskCommand, unicode: nil, autorepeat: false)
        let e = try XCTUnwrap(WindowInputInjector.makeKeyEvent(action: action, down: true, source: nil))
        XCTAssertEqual(e.getIntegerValueField(.keyboardEventKeycode), 8)
        XCTAssertTrue(e.flags.contains(.maskCommand))
        XCTAssertEqual(e.type, .keyDown)
    }

    func testAKeyUpIsAKeyUp() throws {
        let action = KeyAction.key(keyCode: 8, flags: [], unicode: nil, autorepeat: false)
        let e = try XCTUnwrap(WindowInputInjector.makeKeyEvent(action: action, down: false, source: nil))
        XCTAssertEqual(e.type, .keyUp)
    }

    /// The client's character replaces whatever the host's own layout would have produced.
    func testTheUnicodeOverrideReachesTheEvent() throws {
        let action = KeyAction.key(keyCode: 0, flags: [], unicode: "é", autorepeat: false)
        let e = try XCTUnwrap(WindowInputInjector.makeKeyEvent(action: action, down: true, source: nil))
        XCTAssertEqual(unicodeString(of: e), "é")
    }

    /// A chord must NOT carry one, or the app receives a character where it expects Command-C.
    ///
    /// Asserted by COMPARISON against the same keycode WITH an override, not by pinning a literal
    /// character: what an un-overridden keycode 8 produces is whatever the HOST's layout says, so a
    /// literal "c" here would fail on a Dvorak machine and would be testing the test runner's
    /// keyboard rather than this code.
    func testNoOverrideLeavesTheHostLayoutInCharge() throws {
        let chord = try XCTUnwrap(WindowInputInjector.makeKeyEvent(
            action: .key(keyCode: 8, flags: .maskCommand, unicode: nil, autorepeat: false),
            down: true, source: nil))
        let overridden = try XCTUnwrap(WindowInputInjector.makeKeyEvent(
            action: .key(keyCode: 8, flags: [], unicode: "☃", autorepeat: false),
            down: true, source: nil))
        XCTAssertEqual(unicodeString(of: overridden), "☃")
        XCTAssertNotEqual(unicodeString(of: chord), "☃")
    }

    func testAutorepeatIsSetOnTheEvent() throws {
        let action = KeyAction.key(keyCode: 0, flags: [], unicode: "a", autorepeat: true)
        let e = try XCTUnwrap(WindowInputInjector.makeKeyEvent(action: action, down: true, source: nil))
        XCTAssertEqual(e.getIntegerValueField(.keyboardEventAutorepeat), 1)
    }

    /// A modifier is a flagsChanged, not a keyDown — apps that react to a bare ⇧ watch for exactly
    /// that type.
    func testAModifierBecomesAFlagsChangedEvent() throws {
        let action = KeyAction.flagsChanged(keyCode: 56, flags: .maskShift)
        let e = try XCTUnwrap(WindowInputInjector.makeKeyEvent(action: action, down: true, source: nil))
        XCTAssertEqual(e.type, .flagsChanged)
        XCTAssertEqual(e.getIntegerValueField(.keyboardEventKeycode), 56)
        XCTAssertTrue(e.flags.contains(.maskShift))
    }

    func testADropBuildsNoEvent() {
        XCTAssertNil(WindowInputInjector.makeKeyEvent(action: .drop(reason: "dead key"),
                                                      down: true, source: nil))
    }
}
