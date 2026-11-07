import XCTest
@testable import RdevCore

final class AV1ReferenceWireTests: XCTestCase {
    func testHelloCapabilityIsOptionalAndVersioned() {
        for value in ["null", "true", "2", "0", "\"1\""] {
            let json = "{\"t\":\"client-hello\",\"prefs\":{},\"av1ReferenceAck\":" + value + "}"
            XCTAssertEqual(parseInbound(Data(json.utf8)), .clientHello(prefs: .default, delivery: .rtp))
        }
        XCTAssertEqual(parseInbound(Data(#"{"t":"client-hello","prefs":{},"av1ReferenceAck":1}"#.utf8)),
                       .clientHello(prefs: .default, delivery: .rtp, av1ReferenceAck: 1))
    }
    func testSharedWireFixtures() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("protocol/fixtures/av1-reference.json"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let object = try XCTUnwrap(c["message"] as? [String: Any])
            let parsed = AV1ReferenceMessage.decode(object)
            XCTAssertEqual(parsed != nil, c["valid"] as? Bool, c["name"] as? String ?? "")
            if let parsed {
                XCTAssertEqual(parsed.source, object["source"] as? String)
                XCTAssertEqual(parsed.frameID.map(String.init), object["frameId"] as? String)
            }
        }
    }
}
