import XCTest
@testable import RdevCore

/// One delivery's receive state (§3): items in order, each from seq 0, consecutive, never past its size.
final class PasteDeliveryTests: XCTestCase {
    private let two = PasteBegin(id: "p", to: .terminal(.pty(1)),
                                 items: [.file(name: "a", type: "", size: 20_000), .file(name: "b", type: "", size: 5)])

    func testTwoItemsInOrderComplete() {
        var s = PasteDeliveryState(begin: two, now: 0)
        XCTAssertEqual(s.piece(item: 0, seq: 0, count: 16_384, now: 1), .write(item: 0))
        XCTAssertFalse(s.complete())
        XCTAssertEqual(s.piece(item: 0, seq: 1, count: 3_616, now: 2), .write(item: 0))
        XCTAssertEqual(s.piece(item: 1, seq: 0, count: 5, now: 3), .write(item: 1))
        XCTAssertTrue(s.complete())
    }

    func testAGapAnOverrunAndASkippedItemAreMalformed() {
        var gap = PasteDeliveryState(begin: two, now: 0)
        _ = gap.piece(item: 0, seq: 0, count: 100, now: 0)
        XCTAssertEqual(gap.piece(item: 0, seq: 2, count: 100, now: 0), .fail(.malformed))
        var over = PasteDeliveryState(begin: two, now: 0)
        XCTAssertEqual(over.piece(item: 1, seq: 0, count: 5, now: 0), .fail(.malformed))     // item 0 not done
        var past = PasteDeliveryState(begin: two, now: 0)
        _ = past.piece(item: 0, seq: 0, count: 16_384, now: 0)
        XCTAssertEqual(past.piece(item: 0, seq: 1, count: 16_384, now: 0), .fail(.malformed)) // past 20 000
        var ghost = PasteDeliveryState(begin: two, now: 0)
        XCTAssertEqual(ghost.piece(item: 5, seq: 0, count: 1, now: 0), .fail(.malformed))
    }

    func testAShortItemIsNotComplete() {
        var s = PasteDeliveryState(begin: two, now: 0)
        _ = s.piece(item: 0, seq: 0, count: 16_384, now: 0)
        _ = s.piece(item: 0, seq: 1, count: 3_616, now: 0)
        _ = s.piece(item: 1, seq: 0, count: 4, now: 0)
        XCTAssertFalse(s.complete())
    }

    func testThirtySecondsWithoutAPieceIsAStall() {
        var s = PasteDeliveryState(begin: two, now: 100)
        XCTAssertFalse(s.stalled(now: 129.9))
        XCTAssertTrue(s.stalled(now: 130.1))
        _ = s.piece(item: 0, seq: 0, count: 10, now: 125)
        XCTAssertFalse(s.stalled(now: 154.9))
    }
}
