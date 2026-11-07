import CoreGraphics
import RdevSimKit
import XCTest
import XPC

final class RdevSimKitScrollMessageTests: XCTestCase {
    func testReadinessRequiresTheActualMainTouchscreenService() {
        let reply = xpc_dictionary_create(nil,nil,0), services = xpc_array_create(nil,0)
        xpc_dictionary_set_value(reply,"connectedServices",services)
        XCTAssertFalse(RSKScrollReplySupportsTouchscreen(reply))
        let descriptor = xpc_dictionary_create(nil,nil,0)
        xpc_dictionary_set_uint64(descriptor,"_ServiceID",0x200)
        xpc_array_append_value(services,descriptor)
        XCTAssertFalse(RSKScrollReplySupportsTouchscreen(reply))
        xpc_dictionary_set_uint64(descriptor,"_ServiceID",0x101)
        xpc_dictionary_set_uint64(descriptor,"PrimaryUsagePage",13)
        xpc_dictionary_set_uint64(descriptor,"PrimaryUsage",4)
        XCTAssertTrue(RSKScrollReplySupportsTouchscreen(reply))
        xpc_dictionary_set_uint64(descriptor,"PrimaryUsage",2)
        XCTAssertFalse(RSKScrollReplySupportsTouchscreen(reply))
    }
    private func report(_ phase: RSKScrollTouchPhase, _ point: CGPoint = CGPoint(x: 0.5, y: 0.75)) throws -> [UInt8] {
        let message = RSKScrollDigitizerMessage(phase, point)
        let payload = try XCTUnwrap(xpc_dictionary_get_dictionary(message, "payload"))
        let send = try XCTUnwrap(xpc_dictionary_get_dictionary(payload, "send"))
        XCTAssertTrue(xpc_get_type(try XCTUnwrap(xpc_dictionary_get_value(send, "_1"))) == XPC_TYPE_UINT64)
        XCTAssertEqual(xpc_dictionary_get_uint64(send, "_1"), 0x101)
        var count = 0
        let data = try XCTUnwrap(xpc_dictionary_get_data(send, "_0", &count))
        return Array(UnsafeRawBufferPointer(start: data, count: count))
    }
    func testContactUsesNativeNormalizedCoordinatesAndFullReport() throws {
        let bytes = try report(.contact)
        XCTAssertEqual(bytes.count, 58)
        XCTAssertEqual(Array(bytes.prefix(4)), [9, 1, 5, 0xc0])
        XCTAssertEqual(UInt16(bytes[4]) | UInt16(bytes[5]) << 8, 32767)
        XCTAssertEqual(UInt16(bytes[6]) | UInt16(bytes[7]) << 8, 49151)
        XCTAssertEqual(bytes[56] & 0x40, 0)
    }
    func testCancellationIsNotAnOrdinaryLiftAndClearDropsAllContacts() throws {
        let cancel = try report(.cancel), end = try report(.end), clear = try report(.clear)
        XCTAssertEqual(cancel[3], 0)
        XCTAssertEqual(cancel[56] & 0x40, 0x40, "the actual HID contact-cancel bit, not an invented Indigo eventType")
        XCTAssertEqual(end[56] & 0x40, 0)
        XCTAssertEqual(clear[1], 0, "cancel must be followed by zero contacts before another contact can begin")
        XCTAssertEqual(clear[3], 0)
        XCTAssertTrue(clear[40...].allSatisfy { $0 == 0 })
    }
    func testCoordinatesAreClampedAndNonfiniteCoordinatesAreNeutral() throws {
        let bytes = try report(.contact, CGPoint(x: -1, y: 2))
        XCTAssertEqual(Array(bytes[4...7]), [0, 0, 255, 255])
        let bad = try report(.contact, CGPoint(x: CGFloat.nan, y: CGFloat.infinity))
        XCTAssertEqual(Array(bad[4...7]), [0, 0, 0, 0])
    }
}
