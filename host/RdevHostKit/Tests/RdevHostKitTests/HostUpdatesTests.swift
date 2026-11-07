import XCTest
import RdevCore
@testable import RdevHostKit
final class HostUpdatesTests:XCTestCase {
    func testNativeOwnerClientIsAdvertisedAndRoutedButGuestIsDenied() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-session.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let devices = try XCTUnwrap(fixture["devices"] as? [String: [String: String]])
        func hex(_ s: String) -> [UInt8] {
            stride(from: 0, to: s.count, by: 2).map {
                let i = s.index(s.startIndex, offsetBy: $0)
                return UInt8(s[i...s.index(after: i)], radix: 16)!
            }
        }
        let root = hex(try XCTUnwrap(fixture["root"] as? String))
        let rootID = E2EIdentity.rootID(root)
        let policy = E2EVerify.Policy(rpID: try XCTUnwrap(fixture["rp_id"] as? String),
            allowedOrigins: try XCTUnwrap(fixture["allowed_origins"] as? [String]))
        let owner = try XCTUnwrap(devices["H"]), renderer = try XCTUnwrap(devices["N"])
        let bundle = try E2ESubordinateGrant.issue(to: hex(try XCTUnwrap(renderer["descriptor"])),
            ownRoot: root, ownBundle: hex(try XCTUnwrap(owner["bundle"])),
            signingPrivateKey: hex(try XCTUnwrap(owner["signing_private_key"])),
            operationID: [UInt8](repeating: 1, count: 32), randomness: [UInt8](repeating: 2, count: 32), policy: policy).get()
        let native = try E2EVerify.verifyBundle(bundle, trustedRootID: rootID, policy: policy).get()
        let guest = try E2EVerify.verifyBundle(hex(try XCTUnwrap(devices["C"]?["bundle"])), trustedRootID: rootID, policy: policy).get()
        let updates = HostUpdates(), accepted = expectation(description: "native request reaches installer")
        updates.setAuthority { peer in HostUpdateRequester(chain: peer == "native" ? native : guest) }
        updates.configure(release: nil, allowed: true, available: 2, handler: { _, requester, _ in
            XCTAssertEqual(requester.deviceID, native.leafDevice.id)
            accepted.fulfill()
        })
        for (peer, eligible) in [("native", true), ("guest", false)] {
            let info = try XCTUnwrap(JSONSerialization.jsonObject(with: updates.info(for: peer)) as? [String: Any])
            XCTAssertEqual((info["update"] as? [String: Any])?["eligible"] as? Bool, eligible)
        }
        let request = Data(#"{"t":"host-update-request","requestId":"47b01652-900b-44c7-bb13-60704c2bb0b4","minimumBuild":2}"#.utf8)
        XCTAssertTrue(updates.receive(request, client: "native", reply: { _ in XCTFail("native client was rejected") }))
        wait(for: [accepted], timeout: 1)
        let denied = expectation(description: "guest rejected")
        XCTAssertTrue(updates.receive(request, client: "guest", reply: { response in
            let status = try! JSONSerialization.jsonObject(with: response) as! [String: Any]
            XCTAssertEqual(status["phase"] as? String, "failed")
            denied.fulfill()
        }))
        wait(for: [denied], timeout: 1)
        updates.configure(release: nil, allowed: false, available: 2, handler: { _, _, _ in XCTFail("disabled update reached installer") })
        let disabled = expectation(description: "host setting still wins")
        XCTAssertTrue(updates.receive(request, client: "native", reply: { _ in disabled.fulfill() }))
        wait(for: [disabled], timeout: 1)
    }
    func testAnAnonymousSocketCannotAskTheAppToInstallAnything() throws {
        let updates=HostUpdates(),denied=expectation(description:"denied")
        updates.configure(release:nil,allowed:true,available:2,handler:{_,_,_ in XCTFail("unverified requester reached installer")})
        let data=Data(#"{"t":"host-update-request","requestId":"47b01652-900b-44c7-bb13-60704c2bb0b4","minimumBuild":2}"#.utf8)
        XCTAssertTrue(updates.receive(data,client:"sock:anonymous",reply:{response in
            let o=try! JSONSerialization.jsonObject(with:response) as! [String:Any]
            XCTAssertEqual(o["phase"] as? String,"failed");denied.fulfill()
        }))
        wait(for:[denied],timeout:1)
        let info=try JSONSerialization.jsonObject(with:updates.info(for:"sock:anonymous")) as! [String:Any]
        XCTAssertEqual((info["update"] as? [String:Any])?["eligible"] as? Bool,false)
    }
    func testCallerCannotSmuggleAnArtifactURL() {
        let updates=HostUpdates()
        updates.configure(release:nil,allowed:true,available:2,handler:{_,_,_ in XCTFail("malformed requester reached installer")})
        XCTAssertTrue(updates.receive(Data(#"{"t":"host-update-request","requestId":"47b01652-900b-44c7-bb13-60704c2bb0b4","minimumBuild":2,"url":"https://evil.test"}"#.utf8),client:"peer",reply:{_ in XCTFail("malformed request was accepted")}))
    }
}
