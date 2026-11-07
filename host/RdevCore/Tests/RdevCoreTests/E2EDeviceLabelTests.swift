import XCTest
@testable import RdevCore

/// The signed device label — an addition to the specification, closing the gap §10.1's residual
/// names: a directory-supplied name is one "the same adversary chose".
///
/// The attack it stops is narrow and real. §4's adversary cannot invent a device — that needs the
/// root passkey — but it CAN swap the names on two devices the user really owns, and a user then
/// types into the wrong machine. These tests are that swap, refused.
final class E2EDeviceLabelTests: XCTestCase {

    private struct Device: Decodable { let device_id: String, bundle: String }
    private struct LabelCase: Decodable {
        let name: String, target_device_id: String, signer: String
        let body: String, signature: String, signer_bundle: String
    }
    private struct Fixture: Decodable {
        let rp_id: String, allowed_origins: [String], root_id: String
        let devices: [String: Device]
        let labels: [String: LabelCase]
    }

    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-session.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()
    private var fx: Fixture { Self.fx }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private var policy: E2EVerify.Policy {
        .init(rpID: fx.rp_id, allowedOrigins: fx.allowed_origins)
    }

    private func verify(_ caseName: String, expectedDeviceID: [UInt8]? = nil,
                        signature: [UInt8]? = nil, body: [UInt8]? = nil,
                        revoked: Set<[UInt8]> = []) -> String {
        let c = fx.labels[caseName]!
        let result = E2EDeviceLabel.verify(
            body: body ?? hex(c.body), signature: signature ?? hex(c.signature),
            signerBundle: hex(c.signer_bundle),
            expectedDeviceID: expectedDeviceID ?? hex(c.target_device_id),
            trustedRootID: hex(fx.root_id), policy: policy, revokedDeviceIDs: revoked)
        switch result {
        case .success: return "ok"
        case .failure(let f): return f.rawValue
        }
    }

    /// **A DEVICE HOLDING `enroll` MAY NAME ITSELF, and that is the ordinary case** — a device
    /// enrolled with a passkey holds a direct grant with `enroll`, and the person is sitting at the
    /// machine they are naming. The fixture's `valid` case is exactly that: H signs a label for H.
    ///
    /// Paired with `testALeafCannotNameItself` below, which is the SAME SHAPE — C signs a label for
    /// C — and refused. Together they say the rule is about AUTHORITY, not about who: a test that
    /// only showed the refusal would read as "self-naming is forbidden", which is not the rule and
    /// would forbid the common path.
    func testADeviceHoldingEnrollMayNameItself() throws {
        let c = fx.labels["valid"]!
        XCTAssertEqual(c.signer, "H")
        XCTAssertEqual(c.target_device_id, fx.devices["H"]!.device_id,
                       "the valid case must be SELF-signed, or this test proves something else")
        XCTAssertEqual(verify("valid"), "ok")

        let parsed = try XCTUnwrap(E2EDeviceLabel.parse(hex(c.body)))
        XCTAssertEqual(parsed.name, "Isaac's MacBook")
        XCTAssertEqual(hex(parsed.deviceID), c.target_device_id)
    }

    func testTheEncodingRoundTrips() throws {
        let c = fx.labels["valid"]!
        let rebuilt = try XCTUnwrap(E2EDeviceLabel.body(
            rootID: hex(fx.root_id), deviceID: hex(c.target_device_id), name: c.name))
        XCTAssertEqual(hex(rebuilt), c.body, "the third implementation's bytes")
    }

    /// **THE ATTACK THIS EXISTS FOR.** The label is genuine, signed by an authorised device, naming
    /// a device the user owns — and the directory offered it beside a DIFFERENT device. Without
    /// `expectedDeviceID` the name would render against whichever row the Worker chose.
    func testALabelCannotBeMovedToAnotherDevice() {
        XCTAssertEqual(verify("valid", expectedDeviceID: hex(fx.devices["C"]!.device_id)),
                       "device-mismatch")
    }

    /// §6 accepts that "a directly enrolled device can issue access-only leaf grants", so a
    /// compromised leaf is inside the model — and a leaf that could name itself after the machine a
    /// user trusts is the same attack in the one place a user actually looks.
    func testALeafCannotNameItself() {
        let c = fx.labels["signer-not-authorised"]!
        XCTAssertEqual(c.target_device_id, fx.devices["C"]!.device_id)
        XCTAssertEqual(c.signer, "C", "self-signed, exactly like the accepted case above")
        XCTAssertEqual(verify("signer-not-authorised"), "signer-not-authorised")
    }

    func testALabelForAnotherRootIsRefused() {
        XCTAssertEqual(verify("wrong-root"), "root-mismatch")
    }

    func testACorruptSignatureIsRefused() {
        var signature = hex(fx.labels["valid"]!.signature)
        signature[signature.count - 1] ^= 0x01
        XCTAssertEqual(verify("valid", signature: signature), "signature")
    }

    func testARevokedSignerCannotName() {
        // §10.5 applies here as everywhere: a tombstoned device's chain does not verify, so whatever
        // it signed stops being evidence of anything.
        XCTAssertEqual(verify("valid", revoked: [hex(fx.devices["H"]!.device_id)]), "signer-chain")
    }

    // MARK: - what may be shown to a person

    /// Control characters and bidirectional overrides let one string render as another, and this
    /// string's whole job is to say WHICH MACHINE a user is about to control. The signer is
    /// authorised, so this is not the main defence — it stops an authorised-but-careless name from
    /// being a misleading one.
    func testUnsafeNamesAreRefused() {
        for bad in ["", "a\u{0000}b", "a\nb", "a\u{007F}b", "a\u{0085}b",
                    "Isaac\u{202E}koobcaM", "a\u{2066}b\u{2069}c"] {
            XCTAssertFalse(E2EDeviceLabel.nameIsSafe(bad), "\(bad.debugDescription)")
            XCTAssertNil(E2EDeviceLabel.body(rootID: Array(repeating: 1, count: 32),
                                             deviceID: Array(repeating: 2, count: 32), name: bad))
        }
    }

    func testOrdinaryNamesAreAccepted() {
        for good in ["Isaac's MacBook", "Mac mini (office)", "Büro-Mac", "일터 맥", "💻 desk",
                     String(repeating: "a", count: E2EDeviceLabel.maximumNameBytes)] {
            XCTAssertTrue(E2EDeviceLabel.nameIsSafe(good), good)
        }
        // The cap is in BYTES, because that is what the length prefix carries — so a name of
        // multi-byte characters runs out sooner, and that is the honest limit rather than a
        // character count that would let one encoding overflow the other.
        let tooLong = String(repeating: "é", count: E2EDeviceLabel.maximumNameBytes)
        XCTAssertEqual(tooLong.count, E2EDeviceLabel.maximumNameBytes)
        XCTAssertFalse(E2EDeviceLabel.nameIsSafe(tooLong))
    }

    func testAnUnsafeNameIsRefusedAtPARSETimeToo() throws {
        // A label built elsewhere, carrying a name this endpoint must not show. Hand-assembled,
        // because `body` refuses to produce one.
        let rootID = hex(fx.root_id)
        let deviceID = hex(fx.labels["valid"]!.target_device_id)
        let hostile = Array("Isaac\u{202E}koobcaM".utf8)
        let bytes = E2EWire.lp("rdev-e2e/device-label/v1") + rootID + deviceID
                  + E2EWire.lengthPrefixed(hostile)!
        XCTAssertNil(E2EDeviceLabel.parse(bytes))
        XCTAssertEqual(verify("valid", body: bytes), "unsafe-name")
    }

    func testMalformedBytesAreRefusedAsMalformed() throws {
        let c = fx.labels["valid"]!
        XCTAssertEqual(verify("valid", body: hex(c.body) + [0]), "malformed")
        XCTAssertEqual(verify("valid", body: Array(hex(c.body).dropLast())), "malformed")
        XCTAssertEqual(verify("valid", body: []), "malformed")
    }
}
