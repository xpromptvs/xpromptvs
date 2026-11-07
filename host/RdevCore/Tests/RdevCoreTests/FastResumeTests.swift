import XCTest
@testable import RdevCore
final class FastResumeTests: XCTestCase {
    func testResumeRequiresBothGenerationAndAuthenticatedDevice() {
        let gen = Data(repeating: 1, count: 16), device = Data(repeating: 2, count: 32)
        XCTAssertTrue(FastResume.accepts(retainedGeneration: gen, offeredGeneration: gen, retainedDevice: device, authenticatedDevice: device))
        XCTAssertFalse(FastResume.accepts(retainedGeneration: gen, offeredGeneration: Data(repeating: 3, count: 16), retainedDevice: device, authenticatedDevice: device))
        XCTAssertFalse(FastResume.accepts(retainedGeneration: gen, offeredGeneration: gen, retainedDevice: device, authenticatedDevice: Data(repeating: 3, count: 32)))
        XCTAssertFalse(FastResume.accepts(retainedGeneration: nil, offeredGeneration: gen, retainedDevice: device, authenticatedDevice: device))
        XCTAssertFalse(FastResume.accepts(retainedGeneration: gen, offeredGeneration: gen, retainedDevice: nil, authenticatedDevice: device))
        XCTAssertFalse(FastResume.accepts(retainedGeneration: Data(), offeredGeneration: Data(), retainedDevice: device, authenticatedDevice: device))
    }
}
