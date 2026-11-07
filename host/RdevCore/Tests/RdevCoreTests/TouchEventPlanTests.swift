import XCTest
@testable import RdevCore

final class TouchEventPlanTests: XCTestCase {
    func testWireButtonDefaultsToLeft() {
        // ABSENT MEANS LEFT — the same rule ScrollUnit.init(wire:) follows. A client that predates
        // the field sends left clicks, and reading them as anything else would make every tap on an
        // older client do the wrong thing.
        XCTAssertEqual(MouseButton(wire: nil), .left)
        XCTAssertEqual(MouseButton(wire: "left"), .left)
        XCTAssertEqual(MouseButton(wire: "right"), .right)
        // A version skew must degrade to the ordinary button, never refuse: a refused touch is a
        // click that silently does nothing, with a correct-looking log line beside it.
        XCTAssertEqual(MouseButton(wire: "middle"), .left)
        XCTAssertEqual(MouseButton(wire: ""), .left)
    }

    func testEveryPhaseAndButtonCombination() {
        XCTAssertEqual(touchEventPlan(phase: "down", button: .left),
                       TouchEventPlan(kind: .down, button: .left))
        XCTAssertEqual(touchEventPlan(phase: "move", button: .left),
                       TouchEventPlan(kind: .dragged, button: .left))
        XCTAssertEqual(touchEventPlan(phase: "up", button: .left),
                       TouchEventPlan(kind: .up, button: .left))
        XCTAssertEqual(touchEventPlan(phase: "down", button: .right),
                       TouchEventPlan(kind: .down, button: .right))
        XCTAssertEqual(touchEventPlan(phase: "move", button: .right),
                       TouchEventPlan(kind: .dragged, button: .right))
        XCTAssertEqual(touchEventPlan(phase: "up", button: .right),
                       TouchEventPlan(kind: .up, button: .right))
    }

    func testAnUnrecognisedPhaseIsADrag() {
        // PRE-EXISTING BEHAVIOUR, DELIBERATELY KEPT. WindowInputInjector fell through to
        // .leftMouseDragged for anything that was not "down" or "up", and AGENTS.md records the
        // trap: a drag with no button held registers as NOTHING while the host logs perfectly
        // correct coordinates, which reads as a coordinate bug and is not one. Keeping it in one
        // tested place is better than re-deriving it at the call site.
        XCTAssertEqual(touchEventPlan(phase: "began", button: .left),
                       TouchEventPlan(kind: .dragged, button: .left))
        XCTAssertEqual(touchEventPlan(phase: "", button: .right),
                       TouchEventPlan(kind: .dragged, button: .right))
    }

    func testTouchMessageParsesTheButtonAndDefaultsIt() {
        let withButton = #"{"t":"touch","x":0.5,"y":0.25,"phase":"down","button":"right"}"#
        XCTAssertEqual(parseInbound(Data(withButton.utf8)),
                       .touch(x: 0.5, y: 0.25, phase: "down", button: .right, ts: nil))
        let without = #"{"t":"touch","x":0.5,"y":0.25,"phase":"down"}"#
        XCTAssertEqual(parseInbound(Data(without.utf8)),
                       .touch(x: 0.5, y: 0.25, phase: "down", button: .left, ts: nil))
    }

    // MARK: a drop's carry

    /// THE DRIVER'S OWN POINTER STAYS OUT OF A DROP'S CARRY. A real drop (`HostDrop`) holds the Mac's left button
    /// from its own press to its mouse-up, ~0.65 s, carrying the real cursor to the point; a tap of the driver's
    /// posted meanwhile would end that drag at the TAP's point — possibly in another window. While a drop
    /// carries, nothing of the driver's posts.
    func testNothingPostsWhileADropCarries() {
        var gate = DropCarryGate()
        XCTAssertEqual([MouseEventKind.down, .dragged, .up].map { gate.admits($0, carrying: false) }, [true, true, true])
        XCTAssertEqual([MouseEventKind.down, .dragged, .up].map { gate.admits($0, carrying: true) }, [false, false, false])
        XCTAssertTrue(gate.admits(.down, carrying: false), "the next press after the carry posts")
    }

    /// A PRESS THAT BEGAN DURING THE CARRY IS DROPPED WHOLE — its drags and its up too, even once the carry is
    /// over: an up for a down nobody posted would reach the app under it as a click it never began.
    func testAPressThatBeganDuringTheCarryIsDroppedWhole() {
        var gate = DropCarryGate()
        XCTAssertFalse(gate.admits(.down, carrying: true))
        XCTAssertFalse(gate.admits(.dragged, carrying: false), "the carry ended; the press it began in did not")
        XCTAssertFalse(gate.admits(.up, carrying: false))
        XCTAssertEqual([MouseEventKind.down, .dragged, .up].map { gate.admits($0, carrying: false) }, [true, true, true],
                       "its up ended it: the next press is the driver's again")
    }

    /// A pointer motion with no press — a hover, a scroll, a glide's step — is simply not posted while a drop carries.
    func testMotionWithNoPressWaitsOutTheCarry() {
        XCTAssertTrue(DropCarryGate.admitsMotion(carrying: false))
        XCTAssertFalse(DropCarryGate.admitsMotion(carrying: true))
    }
}
