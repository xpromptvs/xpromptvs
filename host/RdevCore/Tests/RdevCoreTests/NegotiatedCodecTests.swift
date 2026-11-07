import XCTest
import RdevCore

final class NegotiatedCodecTests: XCTestCase {
    /// The wire values are an ABI contract with the Go bridge (bridge.go's cb_codec). Pin them
    /// literally: a reordering of the enum cases would otherwise silently swap H.265 for AV1.
    func testWireValuesArePinned() {
        XCTAssertEqual(NegotiatedCodec.h264.wireValue, 0)
        XCTAssertEqual(NegotiatedCodec.h265.wireValue, 1)
        XCTAssertEqual(NegotiatedCodec.av1.wireValue, 2)
    }

    func testRoundTripsEveryCase() {
        for c in NegotiatedCodec.allCases {
            XCTAssertEqual(NegotiatedCodec(wireValue: c.wireValue), c, "\(c) did not round-trip")
        }
    }

    /// An unknown value must be nil, not a default. A bridge/host version skew should be visible at
    /// the boundary rather than silently encoding H.264 into a track negotiated as something else.
    func testRejectsUnknownWireValue() {
        XCTAssertNil(NegotiatedCodec(wireValue: 3))
        XCTAssertNil(NegotiatedCodec(wireValue: -1))
    }

    func testLogNames() {
        XCTAssertEqual(NegotiatedCodec.h264.logName, "H.264")
        XCTAssertEqual(NegotiatedCodec.h265.logName, "H.265")
        XCTAssertEqual(NegotiatedCodec.av1.logName, "AV1")
    }
}
