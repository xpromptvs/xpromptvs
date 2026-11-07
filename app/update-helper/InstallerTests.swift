import XCTest
import ShellstormCore
@testable import UpdateInstaller
final class InstallerTests:XCTestCase {
    func testHomebrewOwnsInstallationAndSuccessRequiresAcknowledgement() throws {
        try exercise(fail:false)
    }
    func testFailedUpgradeReopensRemainingAppAndReportsFailureWithoutChangingReceipts() throws {
        try exercise(fail:true)
    }
    func testARejectedRemainingBundleIsNeverLaunched() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent("journal.json"),app=root.appendingPathComponent("Installed.app")
        try Data("untrusted".utf8).write(to:app)
        try HostUpdateJournal(token:"token",requestID:"id",owner:"owner",installed:app.path,channel:"staging",targetBuild:2,oldPID:1,oldLaunch:0,profile:nil,wasSharing:false,phase:"committed").write(to:url)
        try Installer.upgrade(journalURL:url,upgrade:{},verify:{_ in throw NSError(domain:"signature",code:1)},verifyRemaining:{_ in throw NSError(domain:"signature",code:1)},launchAndConfirm:{_ in XCTFail("launched rejected code")})
        XCTAssertEqual(try HostUpdateJournal.read(url).phase,"failed")
    }
    private func exercise(fail:Bool) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent("journal.json"),app=root.appendingPathComponent("Installed.app")
        try Data("old".utf8).write(to:app)
        var j=HostUpdateJournal(token:"token",requestID:"id",owner:"owner",installed:app.path,channel:"staging",targetBuild:2,oldPID:1,oldLaunch:0,profile:nil,wasSharing:true,phase:"committed")
        j.pairingCarrier="secret";try j.write(to:url)
        var events:[String]=[]
        try Installer.upgrade(journalURL:url,upgrade:{
            events.append("brew");if fail{throw NSError(domain:"brew",code:1)}
            try Data("new".utf8).write(to:app)
        },verify:{_ in events.append("verify")},verifyRemaining:{_ in events.append("verify-remaining")},launchAndConfirm:{_ in events.append("launch")})
        XCTAssertEqual(events,fail ? ["brew","verify-remaining","launch"]:["brew","verify","launch"])
        XCTAssertEqual(try HostUpdateJournal.read(url).phase,fail ? "failed":"succeeded")
        XCTAssertNil(try HostUpdateJournal.read(url).pairingCarrier)
        XCTAssertEqual(try String(contentsOf:app,encoding:.utf8),fail ? "old":"new")
    }
}
