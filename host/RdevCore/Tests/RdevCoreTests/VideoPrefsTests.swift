import XCTest
@testable import RdevCore

final class VideoPrefsTests: XCTestCase {

    private let base = VideoPrefs(fps: 30, scale: 1.0, bitrateBps: 2_000_000)
    private let cap = 2_000_000

    // MARK: - applyVideoPrefs tests

    func testPartialPatchLeavesOthersUnchanged() {
        let out = applyVideoPrefs(base, fps: 60, scale: nil, bitrateBps: nil, bitrateCap: cap)
        XCTAssertEqual(out, VideoPrefs(fps: 60, scale: 1.0, bitrateBps: 2_000_000))
    }

    func testNilPatchIsIdentity() {
        XCTAssertEqual(applyVideoPrefs(base, fps: nil, scale: nil, bitrateBps: nil, bitrateCap: cap), base)
    }

    func testBitrateClampedToCap() {
        let out = applyVideoPrefs(base, fps: nil, scale: nil, bitrateBps: 8_000_000, bitrateCap: cap)
        XCTAssertEqual(out.bitrateBps, 2_000_000)
    }

    func testBitrateFloorGuardsNonPositive() {
        let out = applyVideoPrefs(base, fps: nil, scale: nil, bitrateBps: 0, bitrateCap: cap)
        XCTAssertEqual(out.bitrateBps, 1)
    }

    func testScaleClampedToBounds() {
        XCTAssertEqual(applyVideoPrefs(base, fps: nil, scale: 2.0, bitrateBps: nil, bitrateCap: cap).scale, 1.0)
        XCTAssertEqual(applyVideoPrefs(base, fps: nil, scale: 0.0, bitrateBps: nil, bitrateCap: cap).scale, 0.05)
    }

    func testFpsFloor() {
        XCTAssertEqual(applyVideoPrefs(base, fps: 0, scale: nil, bitrateBps: nil, bitrateCap: cap).fps, 1)
    }

    // MARK: - throttledPrefs tests

    func testThrottledLowersFpsAndBitrateNeverRaises() {
        let full = VideoPrefs(fps: 60, scale: 0.75, bitrateBps: 2_000_000)
        let t = throttledPrefs(full, throttleFps: 8, throttleBitrateBps: 400_000)
        XCTAssertEqual(t.fps, 8)
        XCTAssertEqual(t.bitrateBps, 400_000)
        XCTAssertEqual(t.scale, 0.75)   // scale preserved
    }

    func testThrottledNeverRaisesAboveFull() {
        let full = VideoPrefs(fps: 5, scale: 0.5, bitrateBps: 300_000)
        let t = throttledPrefs(full, throttleFps: 8, throttleBitrateBps: 400_000)
        XCTAssertEqual(t.fps, 5)              // min(5, 8)
        XCTAssertEqual(t.bitrateBps, 300_000) // min(300k, 400k)
    }

    // MARK: - displayDefaultScale

    func testDisplayDefaultScaleIsOneWhenInsideTheEncoderCeiling() {
        XCTAssertEqual(displayDefaultScale(pixelW: 2560, pixelH: 1440), 1.0)   // 1440p: comfortably inside
        XCTAssertEqual(displayDefaultScale(pixelW: 3840, pixelH: 2160), 1.0)   // EXACTLY at the ceiling
    }

    func testDisplayDefaultScaleShrinksAPanelPastTheCeiling() {
        // 5K: 5120x2880. Width binds at 3840/5120 = 0.75; height gives 2160/2880 = 0.75 too.
        XCTAssertEqual(displayDefaultScale(pixelW: 5120, pixelH: 2880), 0.75, accuracy: 1e-9)
        // THE 16" MBP PANEL, measured on the machine this was developed against: 3456x2234 native
        // clamped to 3340x2160 by EncodeDimensions.fit on the first subscribe. Height binds.
        XCTAssertEqual(displayDefaultScale(pixelW: 3456, pixelH: 2234), 2160.0 / 2234.0, accuracy: 1e-9)
    }

    func testDisplayDefaultScaleTakesTheBindingAxis() {
        // An ultrawide: width binds hard, height not at all. min() must win, not the last axis read.
        XCTAssertEqual(displayDefaultScale(pixelW: 7680, pixelH: 2160), 0.5, accuracy: 1e-9)
    }

    func testDisplayDefaultScaleRefusesNonsense() {
        // A zero or negative size means we could not read the mode; asking for 1.0 is the safe
        // answer because EncodeDimensions.fit still clamps downstream.
        XCTAssertEqual(displayDefaultScale(pixelW: 0, pixelH: 0), 1.0)
        XCTAssertEqual(displayDefaultScale(pixelW: -1, pixelH: 1080), 1.0)
    }
}

// MARK: - resolution-derived starting bitrate

extension VideoPrefsTests {
    func testAMidSizeWindowKeepsTodaysBitrate() {
        // THE SLOPE IS CALIBRATED SO THE COMMON CASE DOES NOT MOVE. ~1 megapixel at 60fps is what the
        // 2 Mbit/s default was implicitly sized for, so a window of that order must come out where it
        // already is — otherwise this change is a re-tuning of every source rather than a fix for the
        // starved ones.
        let bps = resolutionBitrateBps(pixelW: 1200, pixelH: 800, fps: 60,
                                       floorBps: 2_000_000, capBps: 20_000_000)
        XCTAssertEqual(Double(bps), 2_000_000, accuracy: 200_000)
    }

    func testASmallWindowIsFlooredAtTheOldDefault() {
        // NOTHING MAY GET WORSE. A small source computes well under the floor, and the floor is the
        // bitrate it already had — so this can only ever raise a source's budget, never lower it.
        let bps = resolutionBitrateBps(pixelW: 400, pixelH: 300, fps: 60,
                                       floorBps: 2_000_000, capBps: 20_000_000)
        XCTAssertEqual(bps, 2_000_000)
    }

    func testAFullDesktopGetsSubstantiallyMore() {
        // The reported case: a 3456x2234 panel. At the flat 2 Mbit/s default this is ~0.0002 bits per
        // pixel — the encoder cannot afford steady-state detail, so a scene change spends the whole
        // budget in one enormous frame, and that frame is the one whose packets go stale before a
        // NACK can repair them.
        let bps = resolutionBitrateBps(pixelW: 3456, pixelH: 2234, fps: 60,
                                       floorBps: 2_000_000, capBps: 20_000_000)
        XCTAssertGreaterThan(bps, 8_000_000)
        XCTAssertLessThanOrEqual(bps, 20_000_000)
    }

    func testTheCapIsNeverExceeded() {
        // The cap is the host's hard ceiling — the most a client may ASK for. A derived default must
        // respect it, or `applyVideoPrefs` would clamp a number this function had already promised.
        let bps = resolutionBitrateBps(pixelW: 7680, pixelH: 4320, fps: 120,
                                       floorBps: 2_000_000, capBps: 20_000_000)
        XCTAssertEqual(bps, 20_000_000)
    }

    func testItScalesWithPixelsAndWithFrameRate() {
        // Both axes matter: twice the pixels or twice the frames is twice the work. Asserted as a
        // RATIO rather than against constants, so the slope can be retuned without rewriting this.
        let base = resolutionBitrateBps(pixelW: 1600, pixelH: 1200, fps: 30,
                                        floorBps: 1, capBps: 100_000_000)
        let twicePixels = resolutionBitrateBps(pixelW: 3200, pixelH: 1200, fps: 30,
                                               floorBps: 1, capBps: 100_000_000)
        let twiceFrames = resolutionBitrateBps(pixelW: 1600, pixelH: 1200, fps: 60,
                                               floorBps: 1, capBps: 100_000_000)
        XCTAssertEqual(Double(twicePixels) / Double(base), 2.0, accuracy: 0.01)
        XCTAssertEqual(Double(twiceFrames) / Double(base), 2.0, accuracy: 0.01)
    }

    func testAnUnreadableSizeFallsBackToTheFloor() {
        // Same rule as displayDefaultScale: a size we cannot read is not a licence to guess. The floor
        // is the behaviour that shipped, so an unknown size degrades to it exactly.
        XCTAssertEqual(resolutionBitrateBps(pixelW: 0, pixelH: 2234, fps: 60,
                                            floorBps: 2_000_000, capBps: 20_000_000), 2_000_000)
        XCTAssertEqual(resolutionBitrateBps(pixelW: 3456, pixelH: -1, fps: 60,
                                            floorBps: 2_000_000, capBps: 20_000_000), 2_000_000)
        XCTAssertEqual(resolutionBitrateBps(pixelW: 3456, pixelH: 2234, fps: 0,
                                            floorBps: 2_000_000, capBps: 20_000_000), 2_000_000)
    }
}

// ── the viewer's crop ────────────────────────────────────────────────────────────────────────────
extension VideoPrefsTests {
    private var cropBase: VideoPrefs { VideoPrefs(fps: 60, scale: 1.0, bitrateBps: 2_000_000) }
    private var someCrop: CropRect { CropRect(x: 0.2, y: 0.1, w: 0.3, h: 0.4) }

    /// THE DEFAULT IS THE WHOLE SOURCE, which is what keeps every existing client on today's
    /// behaviour without knowing this field exists.
    func testCropDefaultsToTheWholeSource() {
        XCTAssertEqual(cropBase.crop, CropRect.full)
    }

    /// ABSENT MEANS "NO PATCH", not "whole window" — the same rule fps/scale/bitrate already follow.
    /// A client that wants the whole window back sends the FULL RECT explicitly; it never clears the
    /// field. Getting this backwards would reset the crop on every unrelated pref change.
    func testAnAbsentCropLeavesTheCurrentOneAlone() {
        var p = cropBase
        p.crop = someCrop
        let out = applyVideoPrefs(p, fps: 30, scale: nil, bitrateBps: nil, bitrateCap: 20_000_000)
        XCTAssertEqual(out.crop, someCrop)
        XCTAssertEqual(out.fps, 30)   // non-zero guard: the patch really was applied
    }

    func testAPresentCropReplacesTheCurrentOne() {
        let out = applyVideoPrefs(cropBase, fps: nil, scale: nil, bitrateBps: nil, crop: someCrop,
                                  bitrateCap: 20_000_000)
        XCTAssertEqual(out.crop, someCrop)
    }

    /// THROTTLING DROPS RATE, NOT GEOMETRY — the same reason it already preserves `scale`. A focus
    /// flip must not repaint the mask, and an unfocused source that lost its crop would spend its
    /// reduced budget on the nine tenths nobody is looking at.
    func testThrottlingPreservesTheCrop() {
        var full = cropBase
        full.crop = someCrop
        let t = throttledPrefs(full, throttleFps: 8, throttleBitrateBps: 300_000)
        XCTAssertEqual(t.crop, full.crop)
        XCTAssertEqual(t.scale, full.scale)   // the neighbouring rule this one is modelled on
        XCTAssertEqual(t.fps, 8)              // non-zero guard: throttling really did something
    }

    /// THE HIDDEN BRANCH BUILDS ITS OWN `VideoPrefs` and would otherwise default the crop back to
    /// full — so a tab switch would silently repaint the mask and hand the encoder the whole window
    /// again. `effectiveVideoPrefs` is documented RATE ONLY; the crop is geometry, like `scale`.
    func testHiddenPreservesTheCropToo() {
        var full = cropBase
        full.crop = someCrop
        let e = effectiveVideoPrefs(full: full, focused: true, hidden: true,
                                    throttleFps: 8, throttleBitrateBps: 300_000)
        XCTAssertEqual(e.crop, someCrop)
        XCTAssertEqual(e.scale, full.scale)
        XCTAssertEqual(e.fps, hiddenFps)      // non-zero guard: the hidden branch really ran
    }
}
