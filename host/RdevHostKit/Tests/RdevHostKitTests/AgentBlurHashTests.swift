import XCTest
@testable import RdevHostKit
final class AgentBlurHashTests:XCTestCase {
    func testNegativeCosineCoefficientsContributeToTheMaximumScale() throws {
        let pixels=(0..<64).flatMap{p -> [UInt8] in let v:UInt8=p%8<4 ? 0:255;return[v,v,v,255]}
        let hash=try XCTUnwrap(AgentBlurHash.encode(pixels,width:8,height:8))
        XCTAssertEqual(Array(hash)[1],"~") // |negative X coefficient| exceeds 82/166.
        XCTAssertEqual(hash,"K~Lqe900D%%MRjWBfQfQfQ")
    }
    func testEncodingMatchesTheReferencePackageForRGBA() {
        let pixels=(0..<16).flatMap{_ -> [UInt8] in [255,0,0,255]}
        XCTAssertEqual(AgentBlurHash.encode(pixels,width:4,height:4),"K~TI:j|cfQ|c$5fQfQfQfQ")
    }
}
