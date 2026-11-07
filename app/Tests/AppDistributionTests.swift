import XCTest
@testable import ShellstormCore
final class AppDistributionTests: XCTestCase {
    func testOfficialPublicStorageAndIdentityMatchTheExistingInstallation() throws {
        guard AppDistribution.official else { throw XCTSkip("Official distribution only") }
        let support = URL(fileURLWithPath: "/support")
        let p = AppProfile.resolve(env: [:], appSupport: support)!
        XCTAssertEqual(p.directory.path, "/support/ai.xpromptvs.app")
        XCTAssertNil(p.identityStoreName)
        XCTAssertEqual(p.name, "default")
        let staging = AppProfile.resolve(env: [:], appSupport: support, channel: "staging")!
        XCTAssertEqual(staging.directory.path, "/support/ai.xpromptvs.app/channels/staging")
        XCTAssertEqual(staging.identityStoreName, "ai.xpromptvs.app/channels/staging/HostIdentity")
        let named = AppProfile.resolve(env: ["RDEV_APP_PROFILE":"work"], appSupport: support)!
        XCTAssertEqual(named.directory.path, "/support/ai.xpromptvs.app/profiles/work")
        XCTAssertNil(named.identityStoreName)
        XCTAssertNotEqual(p.dataStoreID, staging.dataStoreID)
        XCTAssertNotEqual(p.dataStoreID, named.dataStoreID)
    }
    func testTheSelectedDistributionKeepsTheMatchingIdentity() {
        XCTAssertEqual(AppProfile.folder, AppDistribution.official ? "ai.xpromptvs.app" : "ai.xpromptvs.development")
        let p = AppProfile.resolve(env: [:], appSupport: URL(fileURLWithPath: "/support"))!
        XCTAssertEqual(p.identityStoreName, AppDistribution.official ? nil : "ai.xpromptvs.development/HostIdentity")
    }
}
