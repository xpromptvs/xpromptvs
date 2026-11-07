import XCTest
import RdevCore

final class AV1PresetTests: XCTestCase {
    private let refSpeed = AV1Preset.referenceMachineFactor

    /// At the reference speed and a 7 ms budget, the ladder must reproduce the measured sweep: small
    /// frames can afford the best rung, a full-native window cannot.
    func testChoosesBetterQualityForSmallerFrames() {
        let small = AV1Preset.choose(pixels: 640 * 400, budgetMs: 7, machineFactor: refSpeed)
        let mid = AV1Preset.choose(pixels: 976 * 454, budgetMs: 7, machineFactor: refSpeed)
        let big = AV1Preset.choose(pixels: 2644 * 1230, budgetMs: 7, machineFactor: refSpeed)
        XCTAssertLessThanOrEqual(small, mid, "a smaller frame must never get a WORSE preset")
        XCTAssertLessThan(mid, big, "a full-native window must be pushed to a faster preset")
    }

    /// Monotonicity is the property that makes the ladder sane: growing the frame can only ever move the
    /// preset toward "faster", never back toward "slower".
    func testPresetIsMonotonicInFrameSize() {
        var last = 0
        for px in stride(from: 100_000, through: 4_000_000, by: 100_000) {
            let p = AV1Preset.choose(pixels: px, budgetMs: 7, machineFactor: refSpeed)
            XCTAssertGreaterThanOrEqual(p, last, "preset went DOWN as pixels grew, at \(px)px")
            last = p
        }
    }

    /// A bigger budget must never buy a worse preset.
    func testLargerBudgetNeverLowersQuality() {
        var last = 12
        for budget in stride(from: 1.0, through: 30.0, by: 0.5) {
            let p = AV1Preset.choose(pixels: 976 * 454, budgetMs: budget, machineFactor: refSpeed)
            XCTAssertLessThanOrEqual(p, last, "preset got WORSE as the budget grew, at \(budget)ms")
            last = p
        }
    }

    /// Nothing fits => the FASTEST rung, not a crash and not the slowest. A big window on a slow machine
    /// must still produce video.
    func testFallsBackToFastestWhenNothingFits() {
        let p = AV1Preset.choose(pixels: 3840 * 2160, budgetMs: 0.1, machineFactor: refSpeed * 20)
        XCTAssertEqual(p, 11)
    }

    /// A slower machine must get a faster preset for the same frame and budget — this is the whole point
    /// of deriving speed at runtime instead of baking in a table from one machine.
    func testSlowerMachineGetsFasterPreset() {
        let fast = AV1Preset.choose(pixels: 976 * 454, budgetMs: 7, machineFactor: refSpeed)
        let slow = AV1Preset.choose(pixels: 976 * 454, budgetMs: 7, machineFactor: refSpeed * 4)
        XCTAssertGreaterThan(slow, fast)
    }

    /// speed <-> prediction must round-trip: feeding a prediction back in as a measurement reproduces the
    /// speed it came from. This is what keeps the live calibration stable instead of drifting.
    func testSpeedAndPredictionRoundTrip() {
        let px = 1400 * 950
        for preset in [4, 7, 9, 11] {
            let ms = AV1Preset.predictedMs(preset: preset, pixels: px, machineFactor: refSpeed)
            let back = AV1Preset.machineFactor(measuredMs: ms, pixels: px, preset: preset)
            XCTAssertEqual(back ?? 0, refSpeed, accuracy: 0.001, "preset \(preset) did not round-trip")
        }
    }

    func testSpeedRejectsDegenerateInput() {
        XCTAssertNil(AV1Preset.machineFactor(measuredMs: 0, pixels: 1000, preset: 9))
        XCTAssertNil(AV1Preset.machineFactor(measuredMs: 5, pixels: 0, preset: 9))
    }

    /// The dominated rungs must stay out: preset 5 measured no cheaper than 4, and 12 no cheaper than 11,
    /// so offering either can only ever be the wrong answer.
    func testDominatedPresetsAreNotOffered() {
        let offered = Set(AV1Preset.relativeCost.map(\.preset))
        XCTAssertFalse(offered.contains(5))
        XCTAssertFalse(offered.contains(12))
    }

    /// Cost must decrease as the preset number rises — a table entry out of order would silently invert
    /// the ladder.
    func testRelativeCostDecreasesWithPresetNumber() {
        let sorted = AV1Preset.relativeCost.sorted { $0.preset < $1.preset }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertGreaterThan(a.cost, b.cost, "preset \(a.preset) should cost more than \(b.preset)")
        }
    }
}
