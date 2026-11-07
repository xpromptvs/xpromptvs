import CoreGraphics
import XCTest
import RdevCore
@testable import RdevHostKit

/// The fields `CGEvent(mouseEventSource:…)` leaves wrong for a posted event — see
/// `WindowInputInjector.makeMouseEvent`. Building needs no permission; whether AppKit reads these
/// fields back verbatim was measured by hand (2026-09-25) and is not something this suite can see.
final class MouseEventBuilderTests: XCTestCase {
    func testClickStateIsWhatTheCounterSays() throws {
        for (type, state) in [(CGEventType.leftMouseDown, 2), (.leftMouseUp, 2), (.leftMouseDragged, 3),
                              (.rightMouseDown, 1), (.rightMouseUp, 1)] {
            let e = try XCTUnwrap(WindowInputInjector.makeMouseEvent(
                source: nil, type: type, at: CGPoint(x: 5, y: 5), from: nil,
                button: type == .rightMouseDown || type == .rightMouseUp ? .right : .left,
                clickState: state, flags: []))
            XCTAssertEqual(e.getIntegerValueField(.mouseEventClickState), Int64(state), "\(type.rawValue)")
        }
    }

    /// The control arm: what the initializer does on its own, and the reason the field is written.
    /// If this ever fails, CoreGraphics has started counting and `ClickCounter` should be revisited.
    func testTheInitializerAloneStampsAnUpZero() throws {
        let up = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                       mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertEqual(up.getIntegerValueField(.mouseEventClickState), 0)
    }

    func testDragAndMoveCarryTheirDeltas() throws {
        for type in [CGEventType.leftMouseDragged, .rightMouseDragged, .mouseMoved] {
            let e = try XCTUnwrap(WindowInputInjector.makeMouseEvent(
                source: nil, type: type, at: CGPoint(x: 110, y: 47), from: CGPoint(x: 100, y: 50),
                button: type == .rightMouseDragged ? .right : .left, clickState: 1, flags: []))
            XCTAssertEqual(e.getIntegerValueField(.mouseEventDeltaX), 10, "\(type.rawValue)")
            XCTAssertEqual(e.getIntegerValueField(.mouseEventDeltaY), -3, "\(type.rawValue)")
        }
    }

    /// No previous point is no delta, and a press or release never carries one.
    func testNoDeltaWithoutAPreviousPointOrOnAPress() throws {
        let first = try XCTUnwrap(WindowInputInjector.makeMouseEvent(
            source: nil, type: .leftMouseDragged, at: CGPoint(x: 110, y: 47), from: nil,
            button: .left, clickState: 1, flags: []))
        XCTAssertEqual(first.getIntegerValueField(.mouseEventDeltaX), 0)
        let down = try XCTUnwrap(WindowInputInjector.makeMouseEvent(
            source: nil, type: .leftMouseDown, at: CGPoint(x: 110, y: 47), from: CGPoint(x: 0, y: 0),
            button: .left, clickState: 1, flags: []))
        XCTAssertEqual(down.getIntegerValueField(.mouseEventDeltaX), 0)
    }
}
