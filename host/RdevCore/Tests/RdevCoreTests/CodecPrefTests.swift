import XCTest
@testable import RdevCore

final class CodecPrefTests: XCTestCase {
    func testWireNamesRoundTrip() {
        for p in CodecPref.allCases {
            XCTAssertEqual(CodecPref(wire: p.wireName), p, "round-trip failed for \(p.wireName)")
        }
    }

    // The bridge numbering is a CONTRACT with codecorder.go's codecPref, and deliberately not
    // NegotiatedCodec's. Assert the literals so a "tidy-up" that aligns them fails here.
    func testBridgeValuesMatchTheABI() {
        XCTAssertEqual(CodecPref.auto.bridgeValue, 0)
        XCTAssertEqual(CodecPref.av1.bridgeValue, 1)
        XCTAssertEqual(CodecPref.h265.bridgeValue, 2)
        XCTAssertEqual(CodecPref.h264.bridgeValue, 3)
    }

    // An unknown string must be rejected, so applyVideoPrefs can leave the current value alone rather
    // than silently reinterpreting a typo as `auto` and dropping a deliberate pin.
    func testUnknownWireNameIsNil() {
        XCTAssertNil(CodecPref(wire: "vp9"))
        XCTAssertNil(CodecPref(wire: ""))
        XCTAssertNil(CodecPref(wire: "AV1"))   // case-sensitive: the wire form is lowercase
    }

    func testNegotiatedCodecWireNamesMatchCodecPref() {
        XCTAssertEqual(NegotiatedCodec.h264.wireName, CodecPref.h264.wireName)
        XCTAssertEqual(NegotiatedCodec.h265.wireName, CodecPref.h265.wireName)
        XCTAssertEqual(NegotiatedCodec.av1.wireName, CodecPref.av1.wireName)
    }

    func testApplyVideoPrefsCarriesCodecAndLeavesItAloneWhenNil() {
        let base = VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000, codec: .auto)
        let pinned = applyVideoPrefs(base, fps: nil, scale: nil, bitrateBps: nil,
                                     codec: .h265, bitrateCap: 20_000_000)
        XCTAssertEqual(pinned.codec, .h265)
        let untouched = applyVideoPrefs(pinned, fps: 30, scale: nil, bitrateBps: nil,
                                        codec: nil, bitrateCap: 20_000_000)
        XCTAssertEqual(untouched.codec, .h265, "a nil codec patch must not reset the pin")
        XCTAssertEqual(untouched.fps, 30)
    }

    // Throttling changes rate, never codec — a focus flip must not renegotiate.
    func testThrottlePreservesCodec() {
        let full = VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000, codec: .av1)
        XCTAssertEqual(throttledPrefs(full, throttleFps: 8, throttleBitrateBps: 400_000).codec, .av1)
    }
}
