import XCTest
@testable import ShellstormCore

final class NativeScrollRoutingTests: XCTestCase {
    func testCapabilityArrivingDuringContactDoesNotStealItsMomentumTail() {
        var route = NativeScrollRouting()
        XCTAssertFalse(route.usesNative(phase:.began,momentum:false,precise:true,supported:false))
        XCTAssertFalse(route.usesNative(phase:.changed,momentum:false,precise:true,supported:true))
        XCTAssertFalse(route.usesNative(phase:.ended,momentum:false,precise:true,supported:true))
        XCTAssertFalse(route.usesNative(phase:.none,momentum:true,precise:true,supported:true))
        XCTAssertTrue(route.usesNative(phase:.began,momentum:false,precise:true,supported:true))
        XCTAssertTrue(route.usesNative(phase:.none,momentum:true,precise:true,supported:true))
    }
    func testUnsupportedSimulatorAndNotchedWheelsKeepTheirOldPath() {
        var route = NativeScrollRouting()
        XCTAssertFalse(route.usesNative(phase:.began,momentum:false,precise:true,supported:false))
        XCTAssertFalse(route.usesNative(phase:.none,momentum:false,precise:false,supported:true))
        XCTAssertFalse(route.usesNative(phase:.none,momentum:false,precise:true,supported:true))
    }
}
