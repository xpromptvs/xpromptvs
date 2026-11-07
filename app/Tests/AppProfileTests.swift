import XCTest
@testable import ShellstormCore

final class AppProfileTests: XCTestCase {
    let support = URL(fileURLWithPath: "/Users/u/Library/Application Support")
    func testTheDefaultProfileLivesAtTheAppsOwnDirectory() {
        let p = AppProfile.resolve(env: [:], appSupport: support)!
        XCTAssertEqual(p.name, "default")
        XCTAssertEqual(p.directory.path, "/Users/u/Library/Application Support/\(AppProfile.folder)")
    }
    func testANamedProfileIsIsolatedAndStable() {
        let a = AppProfile.resolve(env: ["RDEV_APP_PROFILE": "check-1"], appSupport: support)!
        let b = AppProfile.resolve(env: ["RDEV_APP_PROFILE": "check-1"], appSupport: support)!
        let c = AppProfile.resolve(env: ["RDEV_APP_PROFILE": "check-2"], appSupport: support)!
        XCTAssertEqual(a.directory.path, "/Users/u/Library/Application Support/\(AppProfile.folder)/profiles/check-1")
        XCTAssertEqual(a.dataStoreID, b.dataStoreID)
        XCTAssertNotEqual(a.dataStoreID, c.dataStoreID)
        XCTAssertNotEqual(a.dataStoreID, AppProfile.resolve(env: [:], appSupport: support)!.dataStoreID)
    }
    /// THE PASTE FOLDER IS THE PROFILE'S (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §6): one
    /// profile's launch empties its own folder and never another running profile's, and no space anywhere in
    /// the path — it is TYPED into a terminal (`Application Support` has one).
    func testThePasteFolderIsPerProfileUnderCachesWithNoSpace() {
        let caches = URL(fileURLWithPath: "/Users/u/Library/Caches")
        let d = AppProfile.resolve(env: [:], appSupport: support)!
        let c = AppProfile.resolve(env: ["RDEV_APP_PROFILE": "check-1"], appSupport: support)!
        XCTAssertEqual(d.pasteDirectory(caches: caches).path, "/Users/u/Library/Caches/\(AppProfile.folder)/default/Pastes")
        XCTAssertEqual(c.pasteDirectory(caches: caches).path, "/Users/u/Library/Caches/\(AppProfile.folder)/check-1/Pastes")
        XCTAssertTrue(d.pasteDirectory.path.hasSuffix("/Library/Caches/\(AppProfile.folder)/default/Pastes"), d.pasteDirectory.path)
        XCTAssertFalse(d.pasteDirectory.path.contains(" "), d.pasteDirectory.path)
    }
    /// The zips a folder paste makes (`LocalPastes`): beside the paste folder, per profile for the same reason —
    /// a launch EMPTIES it, and must never empty another running profile's.
    func testTheArchiveFolderIsPerProfileBesideThePasteFolder() {
        let caches = URL(fileURLWithPath: "/Users/u/Library/Caches")
        let d = AppProfile.resolve(env: [:], appSupport: URL(fileURLWithPath: "/x"))!
        let c = AppProfile.resolve(env: ["RDEV_APP_PROFILE": "check-1"], appSupport: URL(fileURLWithPath: "/x"))!
        XCTAssertEqual(d.archiveDirectory(caches: caches).path, "/Users/u/Library/Caches/\(AppProfile.folder)/default/PasteArchives")
        XCTAssertEqual(c.archiveDirectory(caches: caches).path, "/Users/u/Library/Caches/\(AppProfile.folder)/check-1/PasteArchives")
    }

    func testStagingIdentityStoreIsRelativeToApplicationSupport() {
        let staging=AppProfile.resolve(env:[:],appSupport:support,channel:"staging")!
        XCTAssertEqual(staging.identityStoreName,"\(AppProfile.folder)/channels/staging/HostIdentity")
        let named=AppProfile.resolve(env:["RDEV_APP_PROFILE":"test"],appSupport:support,channel:"staging")!
        XCTAssertEqual(named.identityStoreName,"\(AppProfile.folder)/channels/staging/profiles/test/HostIdentity")
        XCTAssertEqual(AppProfile.resolve(env:[:],appSupport:support,channel:"public")!.identityStoreName, AppDistribution.official ? nil : "\(AppProfile.folder)/HostIdentity")
    }
    func testPublicNamesCannotCollideWithStagingStorageOrActivation() {
        let named=AppProfile.resolve(env:["RDEV_APP_PROFILE":"staging-default"],appSupport:support,channel:"public")!
        let staging=AppProfile.resolve(env:[:],appSupport:support,channel:"staging")!
        XCTAssertNotEqual(named.name,staging.name)
        XCTAssertNotEqual(named.dataStoreID,staging.dataStoreID)
        XCTAssertNotEqual(named.pasteDirectory,staging.pasteDirectory)
    }
    func testStagingCannotReadPublicStores() {
        let publicProfile = AppProfile.resolve(env: [:], appSupport: support)!
        let staging = AppProfile.resolve(env: [:], appSupport: support, channel: "staging")!
        XCTAssertNotEqual(staging.directory, publicProfile.directory)
        XCTAssertNotEqual(staging.dataStoreID, publicProfile.dataStoreID)
        XCTAssertNotEqual(staging.name, publicProfile.name)
        XCTAssertNotEqual(staging.pasteDirectory, publicProfile.pasteDirectory)
        XCTAssertTrue(staging.directory.path.hasSuffix("/channels/staging"))
    }
    func testAProfileNameCannotEscapeItsDirectory() {
        for bad in ["", "..", ".", "a/b", "x y", String(repeating: "a", count: 65)] {
            XCTAssertNil(AppProfile.resolve(env: ["RDEV_APP_PROFILE": bad], appSupport: support), bad)
        }
    }
}
