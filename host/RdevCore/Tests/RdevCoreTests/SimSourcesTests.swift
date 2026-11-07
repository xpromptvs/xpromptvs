import XCTest
@testable import RdevCore

final class SimSourcesTests: XCTestCase {
    private let udid = "9B45C574-451C-475D-8498-66BD68AEE17D"

    func testCoreSimulatorStates() {
        XCTAssertEqual(SimState(coreSimulator: 1), .shutdown)
        XCTAssertEqual(SimState(coreSimulator: 2), .booting)
        XCTAssertEqual(SimState(coreSimulator: 3), .booted)
        XCTAssertEqual(SimState(coreSimulator: 4), .shuttingDown)
        XCTAssertNil(SimState(coreSimulator: 0), "creating: not a device to list")
        XCTAssertEqual(SimState.shuttingDown.rawValue, "shutting-down")
    }

    func testASimulatorSource() throws {
        let s = makeSources(sims: [SimInfo(udid: udid, name: "iPhone 18 Pro", os: "iOS 27.0", state: .shutdown,
                                           w: 402, h: 874, pxW: 1206, pxH: 2622)], windows: [])
        XCTAssertEqual(s, [Source(id: "sim:\(udid)", kind: "sim", name: "iPhone 18 Pro (iOS 27.0)",
                                  inputCapable: true, running: false, w: 402, h: 874, simState: .shutdown)])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sourceListJSON(sources: s)) as? [String: Any])
        let row = try XCTUnwrap((json["sources"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["simState"] as? String, "shutdown")
        XCTAssertEqual(row["running"] as? Bool, false)
        XCTAssertEqual(row["w"] as? Int, 402)
    }

    func testAWindowCarriesNoSimState() throws {
        let s = makeSources(windows: [WindowInfo(id: 7, app: "Safari", title: "T")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sourceListJSON(sources: s)) as? [String: Any])
        let row = try XCTUnwrap((json["sources"] as? [[String: Any]])?.first)
        XCTAssertNil(row["simState"])
    }

    func testAStatusCarriesItsSimState() throws {
        let data = sourceStatusJSON(statuses: [SourceStatus(id: "sim:\(udid)", live: false, simState: .booting)])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let row = try XCTUnwrap((json["statuses"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["simState"] as? String, "booting")
        XCTAssertEqual(row["live"] as? Bool, false)
    }

    /// A simulator is a tab of the bar now — ONLY in the spelling the host writes: an uppercase UUID.
    func testASimulatorIsATabOnlyInItsCanonicalSpelling() {
        XCTAssertTrue(TabKey.isValid("sim:\(udid)"))
        XCTAssertTrue(TabKey.isWindow("sim:\(udid)"))
        XCTAssertFalse(TabKey.isValid("sim:\(udid.lowercased())"))
        XCTAssertFalse(TabKey.isValid("sim:abc"))
        XCTAssertFalse(TabKey.isValid("sim:"))
    }
}
