import XCTest
@testable import RdevCore
final class NativeKeyCodeTests: XCTestCase {
    func testNativePhysicalKeysUseTheExistingBrowserCodeMap() {
        XCTAssertEqual(browserCode(forMacVirtualKey: 0), "KeyA")
        XCTAssertEqual(browserCode(forMacVirtualKey: 36), "Enter")
        XCTAssertEqual(browserCode(forMacVirtualKey: 123), "ArrowLeft")
        XCTAssertNil(browserCode(forMacVirtualKey: 65535))
    }
}
