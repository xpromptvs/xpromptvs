import XCTest
@testable import ShellstormCore

/// The Dock's bell (docs/desktop-app.md, "The bell"): each client window's count of terminal tabs with an
/// unseen bell, summed.
final class BellBadgeTests: XCTestCase {
    func testTheBadgeIsTheSumOfEveryWindowsCount() {
        var b = BellBadge()
        XCTAssertNil(b.label, "no bell, no badge")
        _ = b.set(2, for: 1)
        _ = b.set(1, for: 7)
        XCTAssertEqual(b.total, 3)
        XCTAssertEqual(b.label, "3")
        _ = b.set(0, for: 1)
        XCTAssertEqual(b.label, "1")
        _ = b.set(0, for: 7)
        XCTAssertNil(b.label)
    }

    /// Attention is for NEWS: a window's count GROWING is a tab newly unseen. The same count again, or one going
    /// down (a tab looked at, or closed), is not.
    func testOnlyAGrowingCountAsksForAttention() {
        var b = BellBadge()
        XCTAssertTrue(b.set(1, for: 1))
        XCTAssertFalse(b.set(1, for: 1))
        XCTAssertTrue(b.set(2, for: 1))
        XCTAssertFalse(b.set(1, for: 1))
        XCTAssertTrue(b.set(1, for: 2), "another window's first bell is news even with the total already up")
        XCTAssertFalse(b.set(0, for: 2))
    }

    /// A window that closes, reloads or whose page dies takes its share with it.
    func testAWindowThatGoesTakesItsShare() {
        var b = BellBadge()
        _ = b.set(2, for: 1)
        _ = b.set(1, for: 2)
        b.remove(1)
        XCTAssertEqual(b.total, 1)
        XCTAssertEqual(b.count(for: 1), 0)
        XCTAssertTrue(b.set(1, for: 1), "after it went, its next bell is news again")
    }

    func testABigCountStaysReadable() {
        var b = BellBadge()
        _ = b.set(BellBadge.maxCount, for: 1)
        _ = b.set(5, for: 2)
        XCTAssertEqual(b.label, "99+")
    }

    func testTheWindowTitleCarriesTheBellWhileRinging() {
        XCTAssertEqual(BellBadge.title("This Mac", ringing: true), "🔔 This Mac")
        XCTAssertEqual(BellBadge.title("This Mac", ringing: false), "This Mac")
    }
}
