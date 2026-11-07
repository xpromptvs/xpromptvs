import AppKit
import XCTest

final class SimulatorKeyboardTests: XCTestCase {
    @MainActor func testPhysicalKeyIsHeldUntilItsKeyUp() throws {
        _ = NSApplication.shared
        let view = SimulatorMetalView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        defer { view.renderer?.stop() }
        var events: [NSEvent.EventType] = [], commits: [String] = []
        view.event = { events.append($0.type) }; view.insert = { commits.append($0) }
        func key(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.shift], timestamp: 1,
                windowNumber: 0, context: nil, characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        }
        view.keyDown(with: try key(.keyDown))
        XCTAssertEqual(events, [.keyDown], "ordinary typing is physical HID, with no synthesized key-up")
        XCTAssertTrue(commits.isEmpty)
        view.keyUp(with: try key(.keyUp))
        XCTAssertEqual(events, [.keyDown, .keyUp])
    }
    @MainActor func testCompositionCommitRemainsText() {
        let view = SimulatorMetalView(frame: .zero)
        defer { view.renderer?.stop() }
        var commits: [String] = []; view.insert = { commits.append($0) }
        view.setMarkedText("e", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commits, ["é"])
        XCTAssertFalse(view.hasMarkedText())
    }
}
