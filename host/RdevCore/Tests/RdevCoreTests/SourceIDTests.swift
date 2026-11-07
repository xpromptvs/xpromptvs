import XCTest
@testable import RdevCore

final class SourceIDTests: XCTestCase {
    func testWorkspaceIdentity() {
        let uuid="17D3584C-7E1E-4EE7-A51A-46F10B06B83F"
        XCTAssertEqual(parseSourceID("apps:"+uuid), .workspace(uuid))
        XCTAssertNil(parseSourceID("apps:"))
        XCTAssertNil(parseSourceID("apps:123"))
    }
    func testBuildIDs() {
        XCTAssertEqual(sourceID(simUDID: "ABC-123"), "sim:ABC-123")
        XCTAssertEqual(sourceID(windowID: 42), "win:42")
    }

    func testParseSim() {
        XCTAssertEqual(parseSourceID("sim:ABC-123"), .sim("ABC-123"))
    }

    func testParseWindow() {
        XCTAssertEqual(parseSourceID("win:42"), .window(42))
    }

    func testParseRejectsMalformed() {
        XCTAssertNil(parseSourceID("sim:"))            // empty udid
        XCTAssertNil(parseSourceID("win:"))            // empty id
        XCTAssertNil(parseSourceID("win:notanumber"))  // non-int window id
        XCTAssertNil(parseSourceID("foo"))             // no known prefix
        XCTAssertNil(parseSourceID(""))
    }

    func testRoundTrip() {
        XCTAssertEqual(parseSourceID(sourceID(simUDID: "U1")), .sim("U1"))
        XCTAssertEqual(parseSourceID(sourceID(windowID: 7)), .window(7))
    }

    func testBuildDisplayID() {
        XCTAssertEqual(sourceID(displayID: 1), "dsp:1")
        XCTAssertEqual(sourceID(displayID: 724_042_615), "dsp:724042615")
    }

    func testParseDisplay() {
        XCTAssertEqual(parseSourceID("dsp:1"), .display(1))
    }

    func testParseRejectsMalformedDisplay() {
        XCTAssertNil(parseSourceID("dsp:"))            // empty id
        XCTAssertNil(parseSourceID("dsp:notanumber"))  // non-int display id
    }

    func testDisplayRoundTrip() {
        XCTAssertEqual(parseSourceID(sourceID(displayID: 724_042_615)), .display(724_042_615))
    }

    /// A window id and a display id may share a numeric value — they come from different
    /// namespaces. The PREFIX is the only thing that separates them, so a parse that dropped it
    /// would route a subscribe to the wrong subsystem while every id looked plausible.
    func testSameNumberDiffersByPrefix() {
        XCTAssertEqual(parseSourceID("win:7"), .window(7))
        XCTAssertEqual(parseSourceID("dsp:7"), .display(7))
        XCTAssertNotEqual(parseSourceID("win:7"), parseSourceID("dsp:7"))
    }
}
