import XCTest
@testable import RdevCore

final class SimMessagesTests: XCTestCase {

    private func parse(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    func testSimStatusJSONWithMessage() {
        let obj = parse(simStatusJSON(udid: "A", phase: "error", message: "boot failed"))
        XCTAssertEqual(obj["t"] as? String, "sim-status")
        XCTAssertEqual(obj["udid"] as? String, "A")
        XCTAssertEqual(obj["phase"] as? String, "error")
        XCTAssertEqual(obj["message"] as? String, "boot failed")
    }

    func testSimStatusJSONWithoutMessageOmitsKey() {
        let obj = parse(simStatusJSON(udid: "A", phase: "streaming", message: nil))
        XCTAssertEqual(obj["phase"] as? String, "streaming")
        XCTAssertNil(obj["message"])
    }
}
