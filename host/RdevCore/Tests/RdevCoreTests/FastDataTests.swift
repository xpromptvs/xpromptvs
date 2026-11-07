import XCTest
@testable import RdevCore
final class FastDataTests: XCTestCase {
    func testIndependentWireVectors() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/fast-data-vectors.json"))) as! [String: Any]
        func unhex(_ s: String) -> Data { var data = Data(); var i = s.startIndex; while i < s.endIndex { let j = s.index(i, offsetBy: 2); data.append(UInt8(s[i..<j], radix: 16)!); i = j }; return data }
        let generation = unhex(obj["generation"] as! String)
        for v in obj["valid"] as! [[String: Any]] {
            let r = FastData.Record(kind: FastData.Kind(rawValue: (v["kind"] as! NSNumber).uint8Value)!, generation: generation, stream: (v["stream"] as! NSNumber).uint8Value, value: UInt64(v["value"] as! String)!, bytes: unhex(v["payload"] as! String))
            XCTAssertEqual(try FastData.encode(r), unhex(v["wire"] as! String))
            XCTAssertEqual(FastData.decode(unhex(v["wire"] as! String)), r)
        }
        for v in obj["invalid"] as! [String] { XCTAssertNil(FastData.decode(unhex(v))) }
    }
    func testInvalidOutgoingRecordIsRefused() {
        XCTAssertThrowsError(try FastData.encode(.init(kind: .data, generation: Data(count: 15), stream: 0, value: 0, bytes: Data([1]))))
        XCTAssertThrowsError(try FastData.encode(.init(kind: .data, generation: Data(count: 16), stream: 3, value: 0, bytes: Data([1]))))
        XCTAssertThrowsError(try FastData.encode(.init(kind: .data, generation: Data(count: 16), stream: 0, value: 0, bytes: Data(count: 8193))))
    }
}
