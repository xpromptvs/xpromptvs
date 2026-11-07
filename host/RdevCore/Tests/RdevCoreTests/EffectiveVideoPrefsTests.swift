import XCTest
@testable import RdevCore

final class EffectiveVideoPrefsTests: XCTestCase {
    private let full = VideoPrefs(fps: 60, scale: 0.75, bitrateBps: 2_000_000, codec: .av1)
    private func eff(focused: Bool, hidden: Bool) -> VideoPrefs {
        effectiveVideoPrefs(full: full, focused: focused, hidden: hidden,
                            throttleFps: 8, throttleBitrateBps: 500_000)
    }

    func testFocusedAndVisibleGetsTheFullRequest() {
        XCTAssertEqual(eff(focused: true, hidden: false), full)
    }
    func testUnfocusedAndVisibleIsThrottled() {
        XCTAssertEqual(eff(focused: false, hidden: false).fps, 8)
        XCTAssertEqual(eff(focused: false, hidden: false).bitrateBps, 500_000)
    }

    // HIDDEN BEATS FOCUSED. A hidden tab is not being looked at whatever the focus says.
    func testHiddenBeatsFocused() {
        XCTAssertEqual(eff(focused: true, hidden: true).fps, hiddenFps)
    }
    func testHiddenBeatsUnfocused() {
        XCTAssertEqual(eff(focused: false, hidden: true).fps, hiddenFps)
    }

    // HIDDEN CUTS BITRATE TOO, and this is not symmetry for its own sake: the encoder is CBR, so at
    // 2 Mbit/s fed 1 fps it is entitled to spend the whole per-second budget on ONE frame — ~250 KB
    // of encoding work for a picture nobody receives.
    func testHiddenAlsoReducesBitrate() {
        XCTAssertEqual(eff(focused: true, hidden: true).bitrateBps, 500_000)
    }
    func testHiddenNeverRaisesBitrate() {
        let modest = VideoPrefs(fps: 60, scale: 1.0, bitrateBps: 100_000, codec: .auto)
        let out = effectiveVideoPrefs(full: modest, focused: true, hidden: true,
                                      throttleFps: 8, throttleBitrateBps: 500_000)
        XCTAssertEqual(out.bitrateBps, 100_000)   // min(), not assignment
    }

    // RATE ONLY. A tab switch must not renegotiate (codec) and must not undo the resolution the
    // client's Auto mode settled on (scale). Same rule throttledPrefs already states.
    func testRateOnlyLeavesScaleAndCodecAlone() {
        for (f, h) in [(true, true), (false, true), (false, false)] {
            let out = eff(focused: f, hidden: h)
            XCTAssertEqual(out.scale, full.scale, "scale changed for focused=\(f) hidden=\(h)")
            XCTAssertEqual(out.codec, full.codec, "codec changed for focused=\(f) hidden=\(h)")
        }
    }
}
