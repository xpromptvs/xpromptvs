import XCTest
@testable import ShellstormCore

final class InstrumentsTests: XCTestCase {
    func testOffByDefault() { XCTAssertEqual(Instruments.overrides(env: [:]), [:]) }
    func testOneSwitchTurnsBothOn() {
        XCTAssertEqual(Instruments.overrides(env: ["RDEV_INSTRUMENTS": "1"]),
                       ["RDEV_CURSOR_OVERLAY": "1", "RDEV_LATENCY_PROBE": "1"])
    }
    func testANarrowerExplicitChoiceWins() {
        XCTAssertEqual(Instruments.overrides(env: ["RDEV_INSTRUMENTS": "1", "RDEV_CURSOR_OVERLAY": "0"]),
                       ["RDEV_LATENCY_PROBE": "1"])
    }
}
