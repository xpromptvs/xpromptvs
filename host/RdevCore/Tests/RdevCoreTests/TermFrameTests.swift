import XCTest
@testable import RdevCore

final class TermFrameTests: XCTestCase {
    func testOutputRoundTrips() {
        let f = TermFrame(kind: .output, tab: "pty:3", size: nil, payload: [1, 2, 3])
        XCTAssertEqual([UInt8](f.encoded()), [0, 5] + Array("pty:3".utf8) + [1, 2, 3])
        XCTAssertEqual(TermFrame.decode(f.encoded()), f)
    }

    func testSnapshotFramesCarryTheGrid() {
        let f = TermFrame(kind: .snapshotEnd, tab: "tmux:$2", size: TermGridSize(cols: 300, rows: 40), payload: [9])
        XCTAssertEqual([UInt8](f.encoded()), [2, 7] + Array("tmux:$2".utf8) + [0x01, 0x2C, 0x00, 0x28, 9])
        XCTAssertEqual(TermFrame.decode(f.encoded()), f)
        XCTAssertEqual(TermFrame.headerSize(tab: "tmux:$2", kind: .snapshotChunk), 2 + 7 + 4)
    }

    func testMalformedFramesAreRejected() {
        XCTAssertNil(TermFrame.decode(Data()))
        XCTAssertNil(TermFrame.decode(Data([5, 1, 0x61])), "unknown kind")
        XCTAssertNil(TermFrame.decode(Data([4, 1, 0x61])), "a wire start names no tab")
        XCTAssertNil(TermFrame.decode(Data([4, 0, 9])), "a wire start is exactly two bytes")
        XCTAssertNil(TermFrame.decode(Data([0, 9, 0x61])), "tab id runs past the end")
        XCTAssertNil(TermFrame.decode(Data([1, 1, 0x61, 0, 80])), "a snapshot frame without its grid")
        XCTAssertNil(TermFrame.decode(Data([0, 0])), "an empty tab id")
    }

    /// The wire's `cols`/`rows` are `u16be` — a grid bigger than that must be CLAMPED to 65535, not
    /// silently wrapped mod 65536 (a `TermGridSize(cols: 65536, …)` would otherwise become `cols: 0`
    /// on the wire with no signal anywhere that truncation happened).
    func testAnOversizedGridIsClampedNotWrapped() {
        let f = TermFrame(kind: .snapshotEnd, tab: "pty:1", size: TermGridSize(cols: 70_000, rows: 100_000), payload: [])
        XCTAssertEqual(TermFrame.decode(f.encoded())?.size, TermGridSize(cols: 65535, rows: 65535))
    }

    /// The first message of every new wire (ChannelHub's rebind): exactly `[0x04][0x00]`, no tab, no
    /// payload. A client that is resyncing after an undecodable stream drops everything until it.
    func testTheWireStartIsTwoBytesAndNamesNoTab() {
        XCTAssertEqual([UInt8](TermFrame.wireStart.encoded()), [4, 0])
        XCTAssertEqual(TermFrame.decode(Data([4, 0])), TermFrame.wireStart)
        XCTAssertEqual(TermFrame.decode(Data([4, 0]))?.kind, .wireStart)
    }
}
