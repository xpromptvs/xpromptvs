import XCTest
@testable import ShellstormCore

final class StateSnapshotTests: XCTestCase {
    func snap(auto: Bool = false, status: Int = 5, adopt: Any? = ["phase": "waiting"],
              rows: [[String: Any]] = []) -> StateSnapshot {
        StateSnapshot(state: ["status": 0, "autoShare": auto], account: ["publish": "off"],
                      e2e: ["status": status, "detail": "", "identity": ""], capabilities: 7,
                      adopt: adopt, listing: ["state": "ready", "error": "", "refreshing": false, "sessions": rows])!
    }
    func testEqualInputsAreEqualRegardlessOfKeyOrder() {
        let a = StateSnapshot(state: ["a": 1, "b": 2], account: [:], e2e: ["status": 5], capabilities: 0,
                              adopt: nil, listing: [:])!
        let b = StateSnapshot(state: ["b": 2, "a": 1], account: [:], e2e: ["status": 5], capabilities: 0,
                              adopt: nil, listing: [:])!
        XCTAssertEqual(a, b)
    }
    func testAChangedFieldIsAChange() { XCTAssertNotEqual(snap(auto: false), snap(auto: true)) }
    func testAdoptIsDroppedUnlessUnenrolled() {
        XCTAssertEqual(snap(status: 5, adopt: ["phase": "waiting"]), snap(status: 5, adopt: nil))
        XCTAssertNotEqual(snap(status: 1, adopt: ["phase": "waiting"]), snap(status: 1, adopt: nil))
    }
    /// The Add device dialog's run rides the snapshot whatever the e2e status (the Mac doing the adding is
    /// ENROLLED), and is null when none is under way — never a stale phase.
    func testAddDeviceRidesTheSnapshotAndIsNullWhenIdle() {
        let running = StateSnapshot(state: [:], account: [:], e2e: ["status": 5], capabilities: 7, adopt: nil,
                                    addDevice: ["phase": "confirm", "identity": "C1P9-HM5S-6D93-FPDC"], listing: [:])!
        XCTAssertTrue(running.json.contains(#""addDevice":{"identity":"C1P9-HM5S-6D93-FPDC","phase":"confirm"}"#))
        let idle = StateSnapshot(state: [:], account: [:], e2e: ["status": 5], capabilities: 7, adopt: nil, listing: [:])!
        XCTAssertTrue(idle.json.contains(#""addDevice":null"#))
    }
    func testTheJSONCarriesNoTokenKey() {
        let s = snap(rows: [["name": "Studio", "code": "c1"]])
        XCTAssertFalse(s.json.contains("\"token\""))
    }
    func testUnserialisableInputIsRefusedNotCrashed() {
        XCTAssertNil(StateSnapshot(state: ["x": Double.nan], account: [:], e2e: [:], capabilities: 0,
                                   adopt: nil, listing: [:]))
    }
}
