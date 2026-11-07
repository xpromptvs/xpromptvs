import XCTest
@testable import RdevCore

final class ByteIOTests: XCTestCase {
    func testLittleEndianRoundTrip() {
        var w = ByteWriter()
        w.u8(0x01); w.u16(0x0203); w.u32(0x04050607)
        XCTAssertEqual([UInt8](w.data), [0x01, 0x03, 0x02, 0x07, 0x06, 0x05, 0x04])
        var r = ByteReader(w.data)
        XCTAssertEqual(r.u8(), 0x01)
        XCTAssertEqual(r.u16(), 0x0203)
        XCTAssertEqual(r.u32(), 0x04050607)
        XCTAssertEqual(r.remaining, 0)
    }
}
