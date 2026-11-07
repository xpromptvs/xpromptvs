import Foundation
import XCTest
@testable import RdevCore

final class TermWireMessageTests: XCTestCase {
    func testExactBigEndianEnvelopeAndFullWidthEpoch() throws {
        let start = TermWireMessage.start(epoch: 0x0020000000000001, compressed: Data([10, 20]))
        let literal = Data([82,90,84,49,0,0,32,0,0,0,0,0,1,10,20])
        XCTAssertEqual(start.encoded(), literal)
        XCTAssertEqual(try TermWireMessage.decode(literal), start)
        let frame = TermWireMessage.data(epoch: 1, sequence: 2, rawLength: 7, compressed: Data([65]))
        XCTAssertEqual(frame.encoded(), Data([82,90,84,49,1,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,2,0,0,0,7,65]))
        XCTAssertEqual(try TermWireMessage.decode(frame.encoded()), frame)
    }
    func testMalformedEnvelopeCannotBecomeTerminalData() throws {
        for b in [Data([4,0]), Data(repeating: 0, count: 60),
                  TermWireMessage.start(epoch: 0, compressed: Data([1])).encoded(),
                  TermWireMessage.data(epoch: 1, sequence: 0, rawLength: 65536, compressed: Data([1])).encoded(),
                  TermWireMessage.start(epoch: 1, compressed: Data()).encoded()] {
            XCTAssertThrowsError(try TermWireMessage.decode(b))
        }
    }
}
