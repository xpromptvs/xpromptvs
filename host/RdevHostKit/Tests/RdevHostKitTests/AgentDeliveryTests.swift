import XCTest
@testable import RdevHostKit

final class AgentDeliveryTests: XCTestCase {
    func testLargeUnicodeResponseUsesBoundedBulkChunksWithoutChangingBytes() throws {
        let object: [String:Any] = ["t":"agent-response","id":"a","epoch":"7","result":["text":String(repeating:"🙂",count:10000)]]
        let lock=NSLock(),done=expectation(description:"all three actual bulk chunks")
        var frames:[(bulk:Bool,bytes:Data)]=[]
        AgentSender().send(object,authorized:{true},buffered:{0}){bulk,bytes in
            lock.withLock{frames.append((bulk,bytes));if frames.count==3{done.fulfill()}}
        }
        wait(for:[done],timeout:3)
        XCTAssertEqual(frames.count,3)
        var data = Data()
        for (seq,frame) in frames.enumerated() {
            XCTAssertTrue(frame.bulk)
            let chunk = try XCTUnwrap(JSONSerialization.jsonObject(with:frame.bytes) as? [String:Any])
            XCTAssertEqual(chunk["seq"] as? Int,seq)
            let part = try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(chunk["data"] as? String)))
            XCTAssertLessThanOrEqual(part.count,16384); data.append(part)
        }
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual((decoded["result"] as? [String:String])?["text"],String(repeating:"🙂",count:10000))
    }
}
