import XCTest
@testable import RdevCore

final class H264Tests: XCTestCase {
    func testAvccToAnnexBSingleNAL() {
        // 4-byte length (3) + 3 bytes of NAL.
        let avcc: [UInt8] = [0, 0, 0, 3, 0x41, 0xAA, 0xBB]
        XCTAssertEqual(H264.avccToAnnexB(avcc, nalLengthSize: 4),
                       [0, 0, 0, 1, 0x41, 0xAA, 0xBB])
    }
    func testAvccToAnnexBTwoNALs() {
        let avcc: [UInt8] = [0, 0, 0, 1, 0x67, 0, 0, 0, 2, 0x68, 0xCC]
        XCTAssertEqual(H264.avccToAnnexB(avcc, nalLengthSize: 4),
                       [0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68, 0xCC])
    }
    func testParameterSets() {
        let sps: [UInt8] = [0x67, 0x42], pps: [UInt8] = [0x68, 0x01]
        XCTAssertEqual(H264.annexBParameterSets([sps, pps]),
                       [0,0,0,1, 0x67,0x42, 0,0,0,1, 0x68,0x01])
    }
    func testTruncatedReturnsEmpty() {
        XCTAssertEqual(H264.avccToAnnexB([0, 0, 0, 9, 0x41], nalLengthSize: 4), [])
    }
}
