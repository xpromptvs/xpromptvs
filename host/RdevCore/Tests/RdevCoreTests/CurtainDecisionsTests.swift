import XCTest
@testable import RdevCore

/// The curtain's two decisions, pure (docs/curtain.md): what its event tap does with an event, and which
/// displays a tick must (re)black. The controller itself blacks the real screen and suppresses real input,
/// so nothing automated raises it; these are what can be pinned.
final class CurtainDecisionsTests: XCTestCase {

    private func verdict(marked: Bool = false, keyDown: Bool = true, keycode: Int64 = curtainPanicKeycode,
                         control: Bool = true, option: Bool = true, command: Bool = true) -> CurtainTapVerdict {
        curtainTapVerdict(marked: marked, keyDown: keyDown, keycode: keycode, control: control, option: option, command: command)
    }

    /// ⌃⌥⌘U on the Mac's OWN keyboard is the panic unlock.
    func testThePanicComboOnTheMacsOwnKeyboardLowers() {
        XCTAssertEqual(verdict(), .lower)
    }

    /// The SAME combo from rdev's own input — the driver typing it, or a modifier stuck on the host plus a
    /// `u` — is just a key for the focused app. The driver lowers the curtain with its toggle.
    func testTheComboFromRdevsOwnInputPassesAndLowersNothing() {
        XCTAssertEqual(verdict(marked: true), .pass)
    }

    /// Anything else from the Mac's own keyboard or trackpad is swallowed — the combo short of a
    /// modifier, its key-up, another key, a mouse event.
    func testEverythingElseLocalIsSwallowed() {
        XCTAssertEqual(verdict(control: false), .drop)
        XCTAssertEqual(verdict(option: false), .drop)
        XCTAssertEqual(verdict(command: false), .drop)
        XCTAssertEqual(verdict(keyDown: false), .drop)
        XCTAssertEqual(verdict(keycode: 0), .drop)
        XCTAssertEqual(verdict(keyDown: false, keycode: -1, control: false, option: false, command: false), .drop)
    }

    func testRdevsOwnInputAlwaysPasses() {
        XCTAssertEqual(verdict(marked: true, keyDown: false, keycode: -1, control: false, option: false, command: false), .pass)
        XCTAssertEqual(verdict(marked: true, keycode: 0, control: false), .pass)
    }

    // MARK: which displays to (re)black

    /// A display the curtain has not blacked — it woke, or was attached, mid-curtain.
    func testANewlyActiveDisplayIsBlacked() {
        XCTAssertEqual(curtainDisplaysToBlack(active: [1, 2], blacked: [1], isBlack: { _ in true }), [2])
    }

    /// A display the curtain DID black whose gamma is no longer black — macOS or another app restored
    /// its colour while the curtain stayed up. Until 2026-09-30 only a change in the SET of displays was
    /// noticed, so such a screen stayed lit with local input still dead.
    func testABlackedDisplayWhoseGammaWasResetIsBlackedAgain() {
        XCTAssertEqual(curtainDisplaysToBlack(active: [1, 2], blacked: [1, 2], isBlack: { $0 != 2 }), [2])
    }

    func testNothingToDoWhenEveryActiveDisplayIsStillBlack() {
        XCTAssertEqual(curtainDisplaysToBlack(active: [1, 2], blacked: [1, 2], isBlack: { _ in true }), [])
    }

    /// A display that went away (slept, detached) needs nothing — it is blacked when it comes back.
    func testADisplayThatWentAwayNeedsNothing() {
        XCTAssertEqual(curtainDisplaysToBlack(active: [1], blacked: [1, 2], isBlack: { _ in true }), [])
    }
}
