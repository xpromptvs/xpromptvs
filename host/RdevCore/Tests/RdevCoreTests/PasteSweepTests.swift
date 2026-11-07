import XCTest
@testable import RdevCore

/// §6's cleanup: older than 24 h goes; then oldest first while over 2 GiB; never the file just saved.
final class PasteSweepTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func f(_ name: String, mb: Int64, hoursAgo: Double) -> PasteFileInfo {
        PasteFileInfo(name: name, bytes: mb * 1_048_576, modified: now.addingTimeInterval(-hoursAgo * 3600))
    }

    func testTheRuleIsTheSpecs() {
        XCTAssertEqual(PasteSweep.maxAge, 86_400)
        XCTAssertEqual(PasteSweep.capBytes, 2_147_483_648)
        XCTAssertEqual(PasteSweep.capBytes, 2 * Int64(PasteLimits.totalMaxBytes), "twice the largest delivery")
    }

    func testOlderThanADayGoesAndYoungerStays() {
        XCTAssertEqual(PasteSweep.victims([f("old", mb: 1, hoursAgo: 24.01), f("new", mb: 1, hoursAgo: 23.9)], now: now, keep: nil), ["old"])
    }

    func testOverTheCapTheOldestGoFirstUntilUnder() {
        let files = [f("c", mb: 800, hoursAgo: 1), f("a", mb: 800, hoursAgo: 3), f("b", mb: 800, hoursAgo: 2)]
        XCTAssertEqual(PasteSweep.victims(files, now: now, keep: nil), ["a"])        // 2400 → 1600 MiB
    }

    func testTheFileJustSavedIsNeverItsOwnSweepsVictim() {
        let files = [f("just", mb: 1800, hoursAgo: 30), f("a", mb: 600, hoursAgo: 2)]
        XCTAssertEqual(PasteSweep.victims(files, now: now, keep: "just"), ["a"])
    }

    /// One largest delivery (1 GiB) beside earlier pastes leaves them: at a 1 GiB budget it swept them all.
    func testOneLargestPasteSweepsNothingEarlier() {
        let files = [f("big", mb: 1024, hoursAgo: 0), f("a", mb: 200, hoursAgo: 1), f("b", mb: 300, hoursAgo: 2)]
        XCTAssertEqual(PasteSweep.victims(files, now: now, keep: "big"), [])
    }

    func testNothingToDo() {
        XCTAssertEqual(PasteSweep.victims([], now: now, keep: nil), [])
        XCTAssertEqual(PasteSweep.victims([f("a", mb: 1, hoursAgo: 1)], now: now, keep: nil), [])
    }
}
