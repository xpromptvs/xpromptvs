// host/RdevCore/Tests/RdevCoreTests/LatencyTimecodeTests.swift
import XCTest
@testable import RdevCore

final class LatencyTimecodeTests: XCTestCase {
    func testBitCountIs32() { XCTAssertEqual(LatencyTimecode.bitCount, 32) }

    func testRoundTrip() {
        for v: UInt32 in [0, 1, 0x0A0B0C0D, 0xFFFFFFFF, 123_456_789] {
            XCTAssertEqual(LatencyTimecode.decode(LatencyTimecode.encode(v)), v)
        }
    }

    func testGoldenVectorMSBFirst() {
        // 0x0A0B0C0D, most-significant bit first — must match web/test/timecode.test.ts exactly.
        let bits = LatencyTimecode.encode(0x0A0B0C0D)
        let expected = "00001010000010110000110000001101"
        XCTAssertEqual(bits.map { $0 ? "1" : "0" }.joined(), expected)
    }

    func testDecodeZeroPadsShortInput() {
        XCTAssertEqual(LatencyTimecode.decode([true]), 0x80000000)   // 1 bit, MSB slot only -> not bit0
    }
}
