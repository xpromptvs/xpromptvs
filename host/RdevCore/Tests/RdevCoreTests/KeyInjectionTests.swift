import CoreGraphics
import XCTest
@testable import RdevCore

final class KeyInjectionTests: XCTestCase {
    // MARK: - the table

    func testLettersDigitsAndPunctuationMapToTheirMacKeycodes() {
        XCTAssertEqual(macVirtualKey(forCode: "KeyA"), 0)
        XCTAssertEqual(macVirtualKey(forCode: "KeyC"), 8)
        XCTAssertEqual(macVirtualKey(forCode: "KeyZ"), 6)
        XCTAssertEqual(macVirtualKey(forCode: "Digit1"), 18)
        XCTAssertEqual(macVirtualKey(forCode: "Digit0"), 29)
        XCTAssertEqual(macVirtualKey(forCode: "Backquote"), 50)
        XCTAssertEqual(macVirtualKey(forCode: "BracketLeft"), 33)
    }

    /// The names differ from the mac constants and from each other; these are the ones a wrong guess
    /// silently mistypes. `Enter` is not `Return`, `Backquote` is not `Grave`, `Delete` is FORWARD
    /// delete while `Backspace` is the one above Return.
    func testTheNamesThatDoNotMatchTheMacConstants() {
        XCTAssertEqual(macVirtualKey(forCode: "Enter"), 36)
        XCTAssertEqual(macVirtualKey(forCode: "Backspace"), 51)
        XCTAssertEqual(macVirtualKey(forCode: "Delete"), 117)
        XCTAssertEqual(macVirtualKey(forCode: "Escape"), 53)
        XCTAssertEqual(macVirtualKey(forCode: "Space"), 49)
        XCTAssertEqual(macVirtualKey(forCode: "Tab"), 48)
    }

    func testArrowsFunctionKeysAndNavigationMap() {
        XCTAssertEqual(macVirtualKey(forCode: "ArrowLeft"), 123)
        XCTAssertEqual(macVirtualKey(forCode: "ArrowRight"), 124)
        XCTAssertEqual(macVirtualKey(forCode: "ArrowDown"), 125)
        XCTAssertEqual(macVirtualKey(forCode: "ArrowUp"), 126)
        XCTAssertEqual(macVirtualKey(forCode: "F1"), 122)
        XCTAssertEqual(macVirtualKey(forCode: "F12"), 111)
        XCTAssertEqual(macVirtualKey(forCode: "Home"), 115)
        XCTAssertEqual(macVirtualKey(forCode: "PageDown"), 121)
    }

    func testLeftAndRightModifiersAreDistinctKeys() {
        XCTAssertEqual(macVirtualKey(forCode: "MetaLeft"), 55)
        XCTAssertEqual(macVirtualKey(forCode: "MetaRight"), 54)
        XCTAssertEqual(macVirtualKey(forCode: "ShiftLeft"), 56)
        XCTAssertEqual(macVirtualKey(forCode: "ShiftRight"), 60)
        XCTAssertTrue(isModifierCode("AltLeft"))
        XCTAssertTrue(isModifierCode("CapsLock"))
        XCTAssertFalse(isModifierCode("KeyA"))
    }

    func testAnUnknownCodeHasNoKeycode() {
        XCTAssertNil(macVirtualKey(forCode: "Fn"))
        XCTAssertNil(macVirtualKey(forCode: ""))
    }

    // MARK: - the plan

    /// CLIENT CHARACTER WINS: a printable key with no ⌘ and no ⌃ carries the character the client
    /// actually produced, so a layout mismatch types what the user sees rather than what the host's
    /// layout would have produced from that physical key.
    func testAPrintableKeyCarriesTheClientsCharacter() {
        guard case .key(let kc, _, let unicode, _) =
            planKeyInjection(down: true, code: "KeyA", key: "é", repeat: false, mods: .none)
        else { return XCTFail("expected a key action") }
        XCTAssertEqual(kc, 0)
        XCTAssertEqual(unicode, "é")
    }

    /// ...but a CHORD must not be overridden, or the app receives ⌘ plus a character rather than the
    /// Command-C it dispatches on.
    func testACommandChordIsKeycodeOnly() {
        guard case .key(let kc, let flags, let unicode, _) =
            planKeyInjection(down: true, code: "KeyC", key: "c", repeat: false,
                             mods: InputModifiers(raw: InputModifiers.commandBit))
        else { return XCTFail("expected a key action") }
        XCTAssertEqual(kc, 8)
        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertNil(unicode)
    }

    func testAControlChordIsAlsoKeycodeOnly() {
        guard case .key(_, _, let unicode, _) =
            planKeyInjection(down: true, code: "KeyC", key: "c", repeat: false,
                             mods: InputModifiers(raw: InputModifiers.controlBit))
        else { return XCTFail("expected a key action") }
        XCTAssertNil(unicode)
    }

    /// Shift and Option are NOT chord modifiers for this purpose — they are how the client produced
    /// the character in the first place, so `A` and `≈` must still carry their unicode.
    func testShiftAndOptionKeepTheClientsCharacter() {
        guard case .key(_, let flags, let unicode, _) =
            planKeyInjection(down: true, code: "KeyA", key: "A", repeat: false,
                             mods: InputModifiers(raw: InputModifiers.shiftBit))
        else { return XCTFail("expected a key action") }
        XCTAssertEqual(unicode, "A")
        XCTAssertTrue(flags.contains(.maskShift))
    }

    func testANonPrintableKeyIsKeycodeOnly() {
        guard case .key(let kc, _, let unicode, _) =
            planKeyInjection(down: true, code: "ArrowUp", key: "ArrowUp", repeat: false, mods: .none)
        else { return XCTFail("expected a key action") }
        XCTAssertEqual(kc, 126)
        XCTAssertNil(unicode)   // "ArrowUp" is a NAME, not a character
    }

    func testAModifierKeyBecomesAFlagsChangedEvent() {
        guard case .flagsChanged(let kc, let flags) =
            planKeyInjection(down: true, code: "ShiftLeft", key: "Shift", repeat: false,
                             mods: InputModifiers(raw: InputModifiers.shiftBit))
        else { return XCTFail("expected a flagsChanged action") }
        XCTAssertEqual(kc, 56)
        XCTAssertTrue(flags.contains(.maskShift))
    }

    func testAutorepeatIsCarried() {
        guard case .key(_, _, _, let autorepeat) =
            planKeyInjection(down: true, code: "KeyA", key: "a", repeat: true, mods: .none)
        else { return XCTFail("expected a key action") }
        XCTAssertTrue(autorepeat)
    }

    /// A dead key produces no character of its own; the composed character arrives on the NEXT
    /// keydown. Injecting the literal name "Dead" would type the word.
    func testADeadKeyIsDropped() {
        guard case .drop = planKeyInjection(down: true, code: "KeyE", key: "Dead", repeat: false,
                                            mods: InputModifiers(raw: InputModifiers.optionBit))
        else { return XCTFail("expected a drop") }
    }

    /// An unmapped code with a printable character still types: keycode 0 plus the unicode override.
    /// Documented cost: an app reading raw keycodes sees `a`.
    func testAnUnmappedCodeWithACharacterStillTypesIt() {
        guard case .key(let kc, _, let unicode, _) =
            planKeyInjection(down: true, code: "Unidentified", key: "ß", repeat: false, mods: .none)
        else { return XCTFail("expected a key action") }
        XCTAssertEqual(kc, 0)
        XCTAssertEqual(unicode, "ß")
    }

    func testAnUnmappedCodeWithNoCharacterIsDropped() {
        guard case .drop = planKeyInjection(down: true, code: "Fn", key: "Fn", repeat: false, mods: .none)
        else { return XCTFail("expected a drop") }
    }

    /// The keyUp of a printable key carries the same unicode as its keyDown, so the pair agrees.
    func testKeyUpMirrorsItsKeyDown() {
        guard case .key(let kc, _, let unicode, _) =
            planKeyInjection(down: false, code: "KeyA", key: "a", repeat: false, mods: .none)
        else { return XCTFail("expected a key action") }
        XCTAssertEqual(kc, 0)
        XCTAssertEqual(unicode, "a")
    }
}

final class HeldKeysTests: XCTestCase {
    func testAKeyIsHeldFromItsDownUntilItsUp() {
        var held = HeldKeys()
        held.down(8)
        XCTAssertEqual(held.count, 1)
        held.up(8)
        XCTAssertEqual(held.count, 0)
    }

    func testReleaseAllReportsEveryHeldKeyOnce() {
        var held = HeldKeys()
        held.down(8); held.down(0); held.down(8)
        XCTAssertEqual(held.releaseAll().sorted(), [0, 8])
        XCTAssertEqual(held.count, 0)
    }

    /// THE RULE THIS TYPE EXISTS FOR. macOS does not deliver a keyup for other keys while Command is
    /// held, so the browser never sends one — after a single ⌘C the host would hold `c` forever and
    /// every later keystroke would arrive as a chord. Releasing Command releases everything.
    func testReleasingCommandReleasesEveryHeldKey() {
        var held = HeldKeys()
        held.down(8)   // c, pressed while Command was down
        let orphaned = held.releaseAll()
        XCTAssertEqual(orphaned, [8])
    }

    func testReleaseAllOnAnEmptyLedgerIsEmpty() {
        var held = HeldKeys()
        XCTAssertTrue(held.releaseAll().isEmpty)
    }

    /// A second release must not re-emit keys already released, or the host posts a keyUp for a key
    /// nothing is holding.
    func testReleaseAllIsNotRepeated() {
        var held = HeldKeys()
        held.down(8)
        XCTAssertEqual(held.releaseAll(), [8])
        XCTAssertTrue(held.releaseAll().isEmpty)
    }
}
