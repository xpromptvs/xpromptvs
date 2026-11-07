import XCTest
@testable import RdevCore

final class SourceLivenessTests: XCTestCase {
    func testWindowsAreLiveWhenOnScreen() {
        let s = buildLivenessSnapshot(watchedWindows: [7, 9], onScreenWindows: [7],
                                      watchedDisplays: [], activeDisplays: [])
        XCTAssertEqual(s.windows, [7: true, 9: false])
        XCTAssertTrue(s.displays.isEmpty)
    }

    func testDisplaysAreLiveWhenAttached() {
        let s = buildLivenessSnapshot(watchedWindows: [], onScreenWindows: [],
                                      watchedDisplays: [1, 2], activeDisplays: [1])
        XCTAssertEqual(s.displays, [1: true, 2: false])
    }

    /// THE WHOLE REASON THESE ARE TWO MAPS. CGWindowID and CGDirectDisplayID are both `UInt32`
    /// typealiases, so Swift's type system offers NO protection: a single combined map would let
    /// window 7 and display 7 overwrite each other, and the surviving value would be reported for
    /// both. Mutation-test this by merging the two dictionaries in the implementation — this is the
    /// test that must fail.
    func testAWindowAndADisplayWithTheSameNumberDoNotAlias() {
        let s = buildLivenessSnapshot(watchedWindows: [7], onScreenWindows: [],      // window 7: NOT live
                                      watchedDisplays: [7], activeDisplays: [7])     // display 7: live
        XCTAssertEqual(s.windows[7], false)
        XCTAssertEqual(s.displays[7], true)
    }

    func testDuplicateWatchedIdsDoNotTrap() {
        // `watched` derives from source-keyed subs (unique today); this removes the latent crash for free.
        let s = buildLivenessSnapshot(watchedWindows: [7, 7], onScreenWindows: [7],
                                      watchedDisplays: [1, 1], activeDisplays: [])
        XCTAssertEqual(s.windows, [7: true])
        XCTAssertEqual(s.displays, [1: false])
    }

    func testEmptyIsEmpty() {
        XCTAssertEqual(buildLivenessSnapshot(watchedWindows: [], onScreenWindows: [],
                                             watchedDisplays: [], activeDisplays: []),
                       LivenessSnapshot())
    }
}
