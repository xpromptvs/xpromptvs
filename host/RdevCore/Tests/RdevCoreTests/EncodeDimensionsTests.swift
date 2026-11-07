import XCTest
@testable import RdevCore

/// libaom's real limits, so these tests fail if the assumption they encode stops matching
/// `LLVCore.RealtimeVideoDimensions`. RdevCore cannot import LLVCore (that would put the engine
/// under RdevCore too), so the coupling is stated here rather than compiled.
private let loW = 72, hiW = 3840, loH = 64, hiH = 2160

final class EncodeDimensionsTests: XCTestCase {
    private func fit(_ w: Int, _ h: Int) -> (width: Int, height: Int) {
        EncodeDimensions.fit(width: w, height: h,
                             minWidth: loW, maxWidth: hiW, minHeight: loH, maxHeight: hiH)
    }

    /// The common case must be EXACT, not merely close. Every legal size goes through this function
    /// on every encoder recreate, and the adapter decides "am I scaling?" by comparing the result to
    /// the input — a function that nudged a legal size would put every source through a needless
    /// vImage scale and hide the clamp it exists to announce.
    func testAlreadyLegalSizesAreUntouched() {
        for (w, h) in [(640, 480), (816, 538), (1126, 742), (3840, 2160), (72, 64), (2644, 1230)] {
            let out = fit(w, h)
            XCTAssertEqual(out.width, w, "\(w)x\(h) should be untouched")
            XCTAssertEqual(out.height, h, "\(w)x\(h) should be untouched")
        }
    }

    /// THE CASE THIS FUNCTION EXISTS FOR, taken verbatim from AGENTS.md's auto-resolution gate: a
    /// 1658×1084 pt retina window is 3316×2168 native — 8 px over on height and nothing else wrong
    /// with it. Before the fit step that source streamed zero frames indefinitely.
    func testTheRealRetinaWindowThatUsedToStreamNothing() {
        let out = fit(3316, 2168)
        XCTAssertLessThanOrEqual(out.height, hiH)
        XCTAssertEqual(out.height, 2160)
        // 3316 * (2160/2168) = 3303.8 -> 3302 even. Aspect is held to within a pixel.
        XCTAssertEqual(out.width, 3302)
        XCTAssertEqual(Double(out.width) / Double(out.height), 3316.0 / 2168.0, accuracy: 0.001)
    }

    func testOversizeIsClampedOnBothAxesAndStaysEven() {
        for (w, h) in [(5000, 3000), (7680, 4320), (4000, 100), (3316, 2168), (3842, 2162)] {
            let out = fit(w, h)
            XCTAssertGreaterThanOrEqual(out.width, loW, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(out.width, hiW, "\(w)x\(h)")
            XCTAssertGreaterThanOrEqual(out.height, loH, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(out.height, hiH, "\(w)x\(h)")
            XCTAssertEqual(out.width % 2, 0, "\(w)x\(h) width must be even")
            XCTAssertEqual(out.height % 2, 0, "\(w)x\(h) height must be even")
        }
    }

    /// 7680×4320 is exactly 2:1 against the ceiling on both axes, so the uniform scale lands on the
    /// corner and aspect is preserved perfectly. Worth pinning separately from the general clamp: it
    /// is the case where a per-axis clamp (the obvious wrong implementation) would ALSO produce
    /// 3840×2160, and therefore the one that cannot distinguish the two.
    func testEightKLandsExactlyOnTheCeiling() {
        let out = fit(7680, 4320)
        XCTAssertEqual(out.width, 3840)
        XCTAssertEqual(out.height, 2160)
    }

    /// A per-axis clamp would give 3840×2160 here and stretch the picture; the uniform scale must
    /// shrink the WIDE axis to the ceiling and let the other come down with it.
    func testAspectIsPreservedNotStretched() {
        let out = fit(5000, 2200)      // width is 1.30x over, height only 1.02x
        XCTAssertEqual(out.width, 3840)
        XCTAssertNotEqual(out.height, 2160, "a per-axis clamp would produce this and distort")
        XCTAssertEqual(Double(out.width) / Double(out.height), 5000.0 / 2200.0, accuracy: 0.01)
    }

    /// Undersize is raised rather than refused, for the same reason oversize is lowered: libaom
    /// rejects it, and the alternative to a slightly upscaled picture is no picture.
    func testUndersizeIsRaisedToTheFloor() {
        let out = fit(64, 40)
        XCTAssertEqual(out.width, 72)
        XCTAssertEqual(out.height, 64)
    }

    /// The documented sacrifice: a strip so extreme that the uniform scale drives the short axis
    /// under the floor gets distorted rather than dropped. Pinned so the behaviour is a decision on
    /// the record and not an accident of clamp ordering.
    func testExtremeStripIsDistortedRatherThanRefused() {
        let out = fit(20_000, 100)
        XCTAssertEqual(out.width, 3840)
        XCTAssertEqual(out.height, 64, "the uniform scale would give 19; the floor wins")
        XCTAssertEqual(out.width % 2, 0)
    }

    /// Degenerate input cannot produce a degenerate answer — a 0-sized encoder would be a permanent
    /// failure, which is precisely the outcome this function replaces.
    func testDegenerateInputFallsBackToTheFloor() {
        for (w, h) in [(0, 0), (-4, 500), (500, 0)] {
            let out = fit(w, h)
            XCTAssertGreaterThanOrEqual(out.width, loW, "\(w)x\(h)")
            XCTAssertGreaterThanOrEqual(out.height, loH, "\(w)x\(h)")
        }
    }

    /// An odd bound must never leak an odd dimension out — the whole point of the function is that
    /// its output is acceptable to a 4:2:0 encoder.
    func testOddBoundsStillProduceEvenOutput() {
        let out = EncodeDimensions.fit(width: 9999, height: 9999,
                                       minWidth: 71, maxWidth: 3841,
                                       minHeight: 63, maxHeight: 2161)
        XCTAssertEqual(out.width % 2, 0)
        XCTAssertEqual(out.height % 2, 0)
        XCTAssertLessThanOrEqual(out.width, 3841)
        XCTAssertLessThanOrEqual(out.height, 2161)
    }
}
