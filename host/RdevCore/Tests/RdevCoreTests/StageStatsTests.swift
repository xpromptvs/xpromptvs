import XCTest
@testable import RdevCore

final class StageStatsTests: XCTestCase {
    private func filled(_ values: [Double], capacity: Int = 600) -> StageStats {
        var s = StageStats(capacity: capacity)
        for v in values { s.record(v) }
        return s
    }

    func testEmptyHasNoPercentile() {
        let s = StageStats()
        XCTAssertEqual(s.count, 0)
        XCTAssertNil(s.percentile(0.5))
    }

    func testNearestRankP50() {
        // Nearest-rank: index = ceil(0.5 * 10) - 1 = 4 -> the 5th smallest.
        XCTAssertEqual(filled([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]).percentile(0.5), 5)
    }

    func testNearestRankP95() {
        // ceil(0.95 * 10) - 1 = 9 -> the largest.
        XCTAssertEqual(filled([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]).percentile(0.95), 10)
    }

    func testP0AndP100() {
        let s = filled([5, 1, 9, 3])
        XCTAssertEqual(s.percentile(0), 1)
        XCTAssertEqual(s.percentile(1), 9)
    }

    func testUnsortedInputIsSortedForPercentiles() {
        XCTAssertEqual(filled([9, 1, 5, 3, 7]).percentile(0.5), 5)
    }

    func testRingDropsOldest() {
        let s = filled([1, 2, 3, 4, 5], capacity: 3)   // holds 3, 4, 5
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.percentile(0), 3)
        XCTAssertEqual(s.percentile(1), 5)
    }

    func testResetClears() {
        var s = filled([1, 2, 3])
        s.reset()
        XCTAssertEqual(s.count, 0)
        XCTAssertNil(s.percentile(0.5))
    }
}
