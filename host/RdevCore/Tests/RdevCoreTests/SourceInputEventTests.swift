import XCTest
@testable import RdevCore

final class SourceInputEventTests: XCTestCase {
    func testNativeScrollGestureRequiresCanonicalBoundariesAndFiniteVelocity() {
        let end: [String: Any] = ["t": "scroll-gesture", "phase": "end", "x": 0.25, "y": 0.5, "vx": 300, "vy": -500]
        XCTAssertNotNil(SourceInputEvent.parse(end), "Explicit release must survive the source lease")
        for field in ["x", "y", "vx", "vy"] {
            var bad = end; bad[field] = Double.infinity
            XCTAssertNil(SourceInputEvent.parse(bad), field)
            bad[field] = true; XCTAssertNil(SourceInputEvent.parse(bad), field)
        }
        var bad = end; bad["phase"] = "changed"; XCTAssertNil(SourceInputEvent.parse(bad))
        bad = end; bad["vx"] = 1_000_001; XCTAssertNil(SourceInputEvent.parse(bad))
        XCTAssertNotNil(SourceInputEvent.parse(["t":"scroll-gesture","phase":"begin","x":0.5,"y":0.5]))
        XCTAssertNotNil(SourceInputEvent.parse(["t":"scroll-gesture","phase":"cancel","x":0.5,"y":0.5]))
    }
    func testLocalNativeGestureRequiresASimulatorTarget() {
        let sim = "sim:00000000-0000-0000-0000-000000000001"
        XCTAssertTrue(NativeSimulatorPolicy.permits(.scrollGesture(x: 0.5, y: 0.5, phase: .end, vx: 0, vy: 500, mods: .none), focusedSource: sim))
        XCTAssertFalse(NativeSimulatorPolicy.permits(.scrollGesture(x: 0.5, y: 0.5, phase: .end, vx: 0, vy: 500, mods: .none), focusedSource: "win:1"))
    }
    func testDecodesOnlySourceInputAndPreservesItsExistingWireMeaning() {
        XCTAssertEqual(SourceInputEvent.parse(["t": "touch", "x": 0.25, "y": 0.75, "phase": "down"])?.message,
                       .touch(x: 0.25, y: 0.75, phase: "down", button: .left, ts: nil))
        XCTAssertEqual(SourceInputEvent.parse(["t": "hover", "x": 0.4, "y": 0.6])?.message, .hover(x: 0.4, y: 0.6))
        XCTAssertEqual(SourceInputEvent.parse(["t": "win-key", "down": true, "code": "KeyA", "key": "a"])?.message,
                       .winKey(down: true, code: "KeyA", key: "a", repeat: false, mods: InputModifiers(raw: 0)))
        XCTAssertEqual(SourceInputEvent.parse(["t": "win-keys-release"])?.message, .winKeysRelease)
    }

    func testRejectsControlTerminalAndNestedInputEnvelopes() {
        for type in ["key", "focus-source", "source-input", "source-focus", "client-hello", "subscribe", "curtain", "kill-tmux", "apps-add", "paste-begin", "sim-action", "future-input"] {
            XCTAssertNil(SourceInputEvent.parse(["t": type, "source": "win:1", "event": ["t": "win-keys-release"]]), type)
        }
        XCTAssertNil(SourceInputEvent(.focusSource(source: "win:1")))
        XCTAssertNil(SourceInputEvent(.killTmux(session: "$1")))
    }

    func testRequiresFiniteNormalizedPointerCoordinatesAndCanonicalPhases() {
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(SourceInputEvent.parse(["t": "hover", "x": bad, "y": 0.5]))
            XCTAssertNil(SourceInputEvent.parse(["t": "touch", "x": 0.5, "y": bad, "phase": "up"]))
        }
        XCTAssertNil(SourceInputEvent.parse(["t": "touch", "y": 0.5, "phase": "down"]))
        XCTAssertNil(SourceInputEvent.parse(["t": "hover", "x": true, "y": 0.5]))
        XCTAssertNil(SourceInputEvent.parse(["t": "touch", "x": 0.5, "y": 0.5, "phase": "cancel"]))
        XCTAssertEqual(SourceInputEvent.parse(["t": "hover", "x": 2, "y": -1])?.message, .hover(x: 1, y: 0))
    }

    func testScrollKeepsUnitsAndZeroVelocityFlingStillStops() {
        XCTAssertEqual(SourceInputEvent.parse(["t": "scroll", "x": 0.25, "y": 0.5, "dx": 2, "dy": -3, "unit": "px"])?.message,
                       .scroll(x: 0.25, y: 0.5, dx: 2, dy: -3, unit: .pixel, mods: InputModifiers(raw: 0)))
        XCTAssertEqual(SourceInputEvent.parse(["t": "scroll-fling", "x": 0.25, "y": 0.5])?.message,
                       .scrollFling(x: 0.25, y: 0.5, vx: 0, vy: 0, mods: InputModifiers(raw: 0)))
        XCTAssertNil(SourceInputEvent.parse(["t": "scroll", "x": 0.5, "y": 0.5, "dx": Double.nan]))
        XCTAssertEqual(SourceInputEvent.parse(["t": "scroll-fling", "x": 0.5, "y": 0.5, "vx": Double.infinity])?.message,
                       .scrollFling(x: 0.5, y: 0.5, vx: 0, vy: 0, mods: InputModifiers(raw: 0)))
    }

    func testSimulatorGesturesRetainTheirPointLimitAndRotationInputShape() {
        XCTAssertEqual(SourceInputEvent.parse(["t": "sim-touch", "phase": "move", "points": [["x": 0.2, "y": 0.3], ["x": 0.8, "y": 0.7]]])?.message,
                       .simTouch(phase: "move", points: [SimPoint(x: 0.2, y: 0.3), SimPoint(x: 0.8, y: 0.7)]))
        XCTAssertNil(SourceInputEvent.parse(["t": "sim-touch", "phase": "down", "points": Array(repeating: ["x": 0.2, "y": 0.3], count: 3)]))
        XCTAssertNil(SourceInputEvent.parse(["t": "sim-touch", "phase": "move", "points": [["x": Double.infinity, "y": 0.3]]]))
    }

    func testTextAndKeyBoundsAreBytesRatherThanUnicodeCharacterCounts() {
        let allowed = String(repeating: "é", count: 2048)
        XCTAssertEqual(SourceInputEvent.parse(["t": "sim-text", "text": allowed])?.message, .simText(allowed))
        XCTAssertNil(SourceInputEvent.parse(["t": "sim-text", "text": allowed + "é"]))
        XCTAssertNil(SourceInputEvent.parse(["t": "win-key", "down": true, "code": String(repeating: "A", count: 65)]))
        XCTAssertNil(SourceInputEvent.parse(["t": "win-key", "down": true, "code": "KeyA", "key": String(repeating: "x", count: 4097)]))
        XCTAssertNil(SourceInputEvent.parse(["t": "win-key", "code": "KeyA"]))
    }
}
