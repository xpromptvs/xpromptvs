import XCTest
@testable import RdevCore

final class CursorOverlayStateTests: XCTestCase {
    func testNoMarkerBeforeAnyInput() {
        XCTAssertNil(CursorOverlayState().marker(forSource: nil))
    }

    func testHoverSetsPositionUnpressed() {
        let s = CursorOverlayState()
        s.hover(x: 0.25, y: 0.5)
        XCTAssertEqual(s.marker(forSource: nil), CursorMarkerState(x: 0.25, y: 0.5, pressed: false))
    }

    func testTouchDownPresses() {
        let s = CursorOverlayState()
        s.touch(phase: "down", x: 0.1, y: 0.2)
        XCTAssertEqual(s.marker(forSource: nil), CursorMarkerState(x: 0.1, y: 0.2, pressed: true))
    }

    func testTouchMoveKeepsPressed() {
        let s = CursorOverlayState()
        s.touch(phase: "down", x: 0.1, y: 0.2)
        s.touch(phase: "move", x: 0.3, y: 0.4)
        XCTAssertEqual(s.marker(forSource: nil), CursorMarkerState(x: 0.3, y: 0.4, pressed: true))
    }

    func testTouchUpReleasesAndKEEPSThePosition() {
        // The whole reason the rectangle now survives mouse-up. The deleted version returned nil
        // unless pressed, so it vanished on release.
        let s = CursorOverlayState()
        s.touch(phase: "down", x: 0.1, y: 0.2)
        s.touch(phase: "up", x: 0.7, y: 0.8)
        XCTAssertEqual(s.marker(forSource: nil), CursorMarkerState(x: 0.7, y: 0.8, pressed: false))
    }

    func testHoverAfterReleaseStillTracks() {
        let s = CursorOverlayState()
        s.touch(phase: "up", x: 0.7, y: 0.8)
        s.hover(x: 0.9, y: 0.1)
        XCTAssertEqual(s.marker(forSource: nil), CursorMarkerState(x: 0.9, y: 0.1, pressed: false))
    }

    func testFocusedSourceIsAnswered() {
        let s = CursorOverlayState()
        s.setFocused("win:1")
        s.hover(x: 0.5, y: 0.5)
        XCTAssertNotNil(s.marker(forSource: "win:1"))
    }

    func testUnfocusedSourceGetsNil() {
        // Input only reaches the focused source, so the same normalized position on another
        // subscribed window would point at nothing.
        let s = CursorOverlayState()
        s.setFocused("win:1")
        s.hover(x: 0.5, y: 0.5)
        XCTAssertNil(s.marker(forSource: "win:2"))
    }

    func testClearingFocusHidesTheMarker() {
        let s = CursorOverlayState()
        s.setFocused("win:1")
        s.hover(x: 0.5, y: 0.5)
        s.setFocused(nil)
        XCTAssertNil(s.marker(forSource: "win:1"))
    }

    func testNilSourceIsAlwaysAnswered() {
        // The test-pattern path runs without SimManager: one source, no viewSet, no focus. This is
        // what lets the headless gate see the rectangle at all.
        let s = CursorOverlayState()
        s.setFocused("win:1")
        s.hover(x: 0.5, y: 0.5)
        XCTAssertNotNil(s.marker(forSource: nil))
    }
}
