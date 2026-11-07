import XCTest
@testable import ShellstormCore
final class HomebrewUpdateTests:XCTestCase {
    func testCancellationStopsTheRunningPreparationProcess() throws {
        let cancellation=HomebrewCancellation(),process=Process()
        process.executableURL=URL(fileURLWithPath:"/bin/sleep");process.arguments=["30"]
        try process.run();cancellation.attach(process);cancellation.cancel();process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus,0)
        XCTAssertThrowsError(try cancellation.check())
    }
    func testOnlyTheInstalledMatchingCaskAndExactAppAreAccepted() throws {
        let json="""
        {"casks":[{"full_token":"xpromptvs/tap/xpromptvs-staging","installed":"0.1.0,1","version":"0.2.0,42","sha256":"abc","url":"https://example.test/a.dmg","artifacts":[{"app":["Xpromptvs.app"],"target":"/Applications/Xpromptvs Staging.app"}]}]}
        """
        XCTAssertNoThrow(try HomebrewUpdate.validateInfo(Data(json.utf8),channel:"staging",installed:"/Applications/Xpromptvs Staging.app",version:"0.2.0,42",sha256:"abc",url:"https://example.test/a.dmg"))
        for (channel,path,version) in [("public","/Applications/Xpromptvs Staging.app","0.2.0,42"),("staging","/tmp/Xpromptvs.app","0.2.0,42"),("staging","/Applications/Xpromptvs Staging.app","0.2.0,43")] {
            XCTAssertThrowsError(try HomebrewUpdate.validateInfo(Data(json.utf8),channel:channel,installed:path,version:version,sha256:"abc",url:"https://example.test/a.dmg"))
        }
        XCTAssertThrowsError(try HomebrewUpdate.validateInfo(Data(json.replacingOccurrences(of:"\"installed\":\"0.1.0,1\"",with:"\"installed\":null").utf8),channel:"staging",installed:"/Applications/Xpromptvs Staging.app",version:"0.2.0,42",sha256:"abc",url:"https://example.test/a.dmg"))
    }
}
