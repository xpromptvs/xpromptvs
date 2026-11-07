import XCTest
@testable import RdevCore
final class ReleaseIdentityTests: XCTestCase {
    func testSharedIdentityAndComparisonFixtures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("protocol/fixtures/host-update.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        for c in fixture["identities"] as! [[String: Any]] {
            XCTAssertEqual(ReleaseIdentity.parse(c["value"] as Any) != nil, c["valid"] as! Bool, c["name"] as! String)
        }
        for c in fixture["comparisons"] as! [[String: Any]] {
            XCTAssertEqual(ReleaseIdentity.compare(host: ReleaseIdentity.parse(c["host"] as Any), client: ReleaseIdentity.parse(c["client"] as Any)).rawValue, c["result"] as! String)
        }
    }
}
