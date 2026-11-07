import XCTest
@testable import RdevCore

final class E2EDirectoryWatchTests: XCTestCase {
    private let key = [UInt8](repeating: 7, count: 32)
    private lazy var creds = E2EDirectoryWatch.Credentials(
        bundle: [9, 9], rootID: [UInt8](repeating: 0x77, count: 32), signingPrivateKey: key,
        ownDeviceID: "me")
    private func machine() -> E2EDirectoryWatch {
        E2EDirectoryWatch(credentials: creds, operationID: { [UInt8](repeating: 0x44, count: 32) })
    }
    private let challenge = base64urlEncode(Data([UInt8](repeating: 0x66, count: 32)))
    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    func testAChallengeIsAnsweredWithASubscribeTheWorkerCanVerify() throws {
        var m = machine()
        let effects = m.handle(.message(#"{"t":"challenge","challenge":"\#(challenge)"}"#))
        guard case .send(let text) = effects.first else { return XCTFail("\(effects)") }
        let frame = json(text)
        XCTAssertEqual(frame["t"] as? String, "subscribe")
        let body = try XCTUnwrap(E2EDirectory.requestBody(
            action: .subscribe, challenge: [UInt8](repeating: 0x66, count: 32),
            rootID: creds.rootID, operationID: [UInt8](repeating: 0x44, count: 32), payload: []))
        let signature = try XCTUnwrap(base64urlDecode(frame["signature"] as? String ?? ""))
        let publicKey = try XCTUnwrap(E2EVerify.ed25519PublicKey(privateKey: key))
        XCTAssertTrue(E2EVerify.verifyEd25519(signature: signature, message: body, publicKey: publicKey))
    }

    func testSubscribedSchedulesTheRenewalAtHalfItsInterval() {
        var m = machine()
        XCTAssertEqual(m.handle(.message(#"{"t":"subscribed","renew_in":60,"challenge":"\#(challenge)"}"#)),
                       [.renew(after: 30, challenge: challenge)])
        guard case .send = m.handle(.renewDue(challenge: challenge)).first else { return XCTFail() }
    }

    func testSnapshotsDropMalformedRowsAndThisMacsOwnRow() {
        var m = machine()
        let text = #"{"t":"sessions","sessions":[{"code":"A","token":"t","label":"Mac","device_id":"d"},{"code":"B","token":"t","label":"Me","device_id":"me"},{"code":"C"}]}"#
        XCTAssertEqual(m.handle(.message(text)),
                       [.sessions([E2EDirectory.Session(code: "A", token: "t", label: "Mac", deviceID: "d")])])
    }

    func testTerminalCodesStop() {
        for code in [4401, 4403, 4429] {
            var m = machine()
            _ = m.handle(.opened)
            XCTAssertEqual(m.handle(.closed(code: code)), [.stop(.refused(code))], "\(code)")
        }
    }

    func test4408ReconnectsAtOnce() {
        var m = machine()
        _ = m.handle(.opened)
        XCTAssertEqual(m.handle(.closed(code: 4408)), [.down, .reconnectNow])
    }

    func testThreeAttemptsThatNeverOpenedGiveUp() {
        var m = machine()
        XCTAssertEqual(m.handle(.closed(code: nil)), [.down])
        XCTAssertEqual(m.handle(.closed(code: nil)), [.down])
        XCTAssertEqual(m.handle(.closed(code: nil)), [.stop(.unavailable)])
    }

    func testAnOpenResetsTheNeverOpenedCount() {
        var m = machine()
        _ = m.handle(.closed(code: nil)); _ = m.handle(.closed(code: nil))
        _ = m.handle(.opened)
        XCTAssertEqual(m.handle(.closed(code: nil)), [.down])
        XCTAssertEqual(m.handle(.closed(code: nil)), [.down])
    }

    func testGarbageIsIgnored() {
        var m = machine()
        XCTAssertEqual(m.handle(.message("not json")), [])
        XCTAssertEqual(m.handle(.message(#"{"t":"pong"}"#)), [])
    }
}
