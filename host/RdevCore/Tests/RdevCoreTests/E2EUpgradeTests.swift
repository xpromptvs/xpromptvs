import XCTest
@testable import RdevCore

final class E2EUpgradeTests: XCTestCase {

    /// §10.3's sentence, as the only thing this rule says: a code-enrolled device may ask a passkey
    /// for a direct grant, and a directly enrolled one has nothing to gain by asking.
    func testOnlyADeviceWithoutEnrollMayUpgrade() {
        XCTAssertTrue(E2EUpgrade.mayUpgrade(capabilities: .hostOnly), "capability 2, added by code")
        XCTAssertTrue(E2EUpgrade.mayUpgrade(capabilities: .connectOnly), "capability 1")
        XCTAssertTrue(E2EUpgrade.mayUpgrade(capabilities: E2EIdentity.Capabilities(raw: 3)),
                      "capability 3, also code-enrolled")
        XCTAssertFalse(E2EUpgrade.mayUpgrade(capabilities: .full),
                       "a device with enroll already holds everything a direct grant confers")
    }

    /// **Nil is not a candidate**, and the two reasons differ: an unenrolled device enrols through
    /// the ordinary path, and a chain that cannot be READ is the one state this protocol never
    /// resolves by writing over it.
    func testAnUnknownCapabilityIsNotAnUpgrade() {
        XCTAssertFalse(E2EUpgrade.mayUpgrade(capabilities: nil))
    }
}
