import CoreGraphics
import RdevSimKit
import XCTest
import XPC

/// The DTUHID wire, as `dtuhidd` decodes it (spec, "Measured" — New HID). A field of the wrong XPC TYPE is dropped by
/// the guest without a word, so the types are asserted, not just the values.
final class RdevSimKitMessageTests: XCTestCase {
    private func string(_ m: xpc_object_t, _ k: String) -> String? {
        xpc_dictionary_get_string(m, k).map { String(cString: $0) }
    }
    private func type(_ m: xpc_object_t, _ k: String) -> xpc_type_t? { xpc_dictionary_get_value(m, k).map(xpc_get_type) }

    func testOneContact() throws {
        let m = RSKDigitizerMessage(.start, CGPoint(x: 0.25, y: 0.75), false, .zero)
        XCTAssertEqual(string(m, "messageType"), "IndigoDigitizerEvent")
        XCTAssertEqual(string(m, "featureIdentifier"), RSKDigitizerService)
        XCTAssertEqual(string(m, "featureIdentifier"), "com.apple.coredevice.feature.remote.hid.digitizer")
        XCTAssertFalse(xpc_dictionary_get_bool(m, "isBarrier"))
        let p = try XCTUnwrap(xpc_dictionary_get_dictionary(m, "payload"))
        let one = try XCTUnwrap(xpc_dictionary_get_dictionary(p, "pointOne"))
        XCTAssertEqual(xpc_dictionary_get_double(one, "x"), 0.25)
        XCTAssertEqual(xpc_dictionary_get_double(one, "y"), 0.75)
        XCTAssertTrue(type(one, "x") == XPC_TYPE_DOUBLE)
        XCTAssertEqual(xpc_dictionary_get_uint64(p, "eventType"), 0)
        XCTAssertTrue(type(p, "eventType") == XPC_TYPE_UINT64)
        XCTAssertTrue(type(p, "edge") == XPC_TYPE_UINT64)
        XCTAssertTrue(type(p, "target") == XPC_TYPE_UINT64)
        XCTAssertNil(xpc_dictionary_get_value(p, "pointTwo"), "one contact carries NO pointTwo, not a zero one")
    }

    func testTwoContactsAndThePhases() throws {
        let m = RSKDigitizerMessage(.end, CGPoint(x: 0.1, y: 0.2), true, CGPoint(x: 0.3, y: 0.4))
        let p = try XCTUnwrap(xpc_dictionary_get_dictionary(m, "payload"))
        let two = try XCTUnwrap(xpc_dictionary_get_dictionary(p, "pointTwo"))
        XCTAssertEqual(xpc_dictionary_get_double(two, "y"), 0.4)
        XCTAssertEqual(xpc_dictionary_get_uint64(p, "eventType"), 2)
        let move = try XCTUnwrap(xpc_dictionary_get_dictionary(RSKDigitizerMessage(.position, .zero, false, .zero), "payload"))
        XCTAssertEqual(xpc_dictionary_get_uint64(move, "eventType"), 1)
    }

    func testAKeyAndTheLivenessBarrier() throws {
        let down = RSKKeyboardMessage(4, true, false)
        XCTAssertEqual(string(down, "messageType"), "IndigoKeyboardButtonEvent")
        let p = try XCTUnwrap(xpc_dictionary_get_dictionary(down, "payload"))
        XCTAssertEqual(xpc_dictionary_get_uint64(p, "usageCode"), 4)
        XCTAssertEqual(xpc_dictionary_get_uint64(p, "state"), 1, "down is 1")
        let barrier = RSKKeyboardMessage(0, false, true)
        XCTAssertTrue(xpc_dictionary_get_bool(barrier, "isBarrier"))
        XCTAssertEqual(xpc_dictionary_get_uint64(try XCTUnwrap(xpc_dictionary_get_dictionary(barrier, "payload")), "state"), 2,
                       "up is 2")
    }

    func testAButton() throws {
        let m = RSKButtonMessage(0x0C, 0x40, true)
        XCTAssertEqual(string(m, "messageType"), "IndigoButtonEvent")
        let p = try XCTUnwrap(xpc_dictionary_get_dictionary(m, "payload"))
        XCTAssertEqual(xpc_dictionary_get_uint64(p, "usagePage"), 0x0C)
        XCTAssertEqual(xpc_dictionary_get_uint64(p, "usageCode"), 0x40)
        XCTAssertEqual(xpc_dictionary_get_uint64(p, "state"), 1)
    }
}
