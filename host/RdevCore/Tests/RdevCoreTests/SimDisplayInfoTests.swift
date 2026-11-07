import XCTest
@testable import RdevCore

final class SimDisplayInfoTests: XCTestCase {
    private let measured = #"""
    {"info":{"outcome":"success"},"result":{"backlightState":"activeOn","displays":[{"backlightState":"activeOn",
    "bounds":[[0,0],[1206,2622]],"currentOrientation":"rot270","displayId":1,"name":"LCD","nativeOrientation":"rot0",
    "nativeSize":[1206,2622],"pointScale":3,"primary":true,"type":{"integrated":{}},
    "uniqueId":"E96A363E-DB71-4CAF-AEB5-35D33EA18C57"}],"orientation":{"currentDeviceOrientation":"landscapeLeft"}}}
    """#

    func testTheMeasuredReport() throws {
        let d = try XCTUnwrap(SimDisplayInfo.parse(devicectlJSON: Data(measured.utf8)))
        XCTAssertEqual(d, SimDisplayInfo(rotation: .rot270, nativeW: 1206, nativeH: 2622, pointScale: 3))
    }

    func testThePrimaryDisplayWins() throws {
        let two = #"{"result":{"displays":[{"currentOrientation":"rot90","nativeSize":[10,20],"pointScale":1,"primary":false},{"currentOrientation":"rot0","nativeSize":[1206,2622],"pointScale":3,"primary":true}]}}"#
        XCTAssertEqual(SimDisplayInfo.parse(devicectlJSON: Data(two.utf8))?.rotation, .rot0)
    }

    func testAnythingElseIsNil() {
        XCTAssertNil(SimDisplayInfo.parse(devicectlJSON: Data("not json".utf8)))
        XCTAssertNil(SimDisplayInfo.parse(devicectlJSON: Data(#"{"result":{"displays":[]}}"#.utf8)))
        XCTAssertNil(SimDisplayInfo.parse(devicectlJSON: Data(#"{"result":{"displays":[{"currentOrientation":"sideways","nativeSize":[1,2],"pointScale":1}]}}"#.utf8)))
    }
}
