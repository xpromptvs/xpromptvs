import XCTest
@testable import RdevCore

/// The §11 wire encodings, against vectors a THIRD implementation produced
/// (`scripts/gen_e2e_wire_fixture.py`). Byte layouts are exactly where two implementations drift
/// while both look correct, so neither side grades its own homework here.
final class E2EWireTests: XCTestCase {

    private struct Case: Decodable {
        let name: String, kind: String, encoded: String
        let mode: String?, room_code: String?
        let h: String?, device_id: String?, responder_device_id: String?, operation_id: String?
        let proof_body: String?, proof: String?, new_bundle: String?, app_hello: String?
        let publication_status: Int?, accepted_bundle: String?
        let bundle: String?, rcode: String?, rtoken: String?
        let device: String?, is_ordinary_auth: Bool?
    }
    private struct Fixture: Decodable { let cases: [Case] }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-wire.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testMatchesTheCrossImplementationVectors() throws {
        let f = try fixture()
        XCTAssertFalse(f.cases.isEmpty, "an empty fixture would assert nothing")
        var seen = Set<String>()
        for c in f.cases {
            seen.insert(c.kind)
            switch c.kind {
            case "prologue":
                let mode = try XCTUnwrap(E2EWire.Mode(rawValue: c.mode!))
                XCTAssertEqual(hex(try XCTUnwrap(E2EWire.prologue(mode: mode, roomCode: c.room_code!))),
                               c.encoded, c.name)
            case "proof_body":
                let out = try XCTUnwrap(E2EWire.deviceProofBody(
                    mode: XCTUnwrap(E2EWire.Mode(rawValue: c.mode!)), handshakeHash: hex(c.h!),
                    deviceID: hex(c.device_id!), responderDeviceID: hex(c.responder_device_id!),
                    operationID: hex(c.operation_id!)))
                XCTAssertEqual(hex(out), c.encoded, c.name)
            case "client_confirm":
                let out = try XCTUnwrap(E2EWire.clientConfirm(
                    proofBody: hex(c.proof_body!), proof: hex(c.proof!), newBundle: hex(c.new_bundle!),
                    appHello: hex(c.app_hello!)))
                XCTAssertEqual(hex(out), c.encoded, c.name)
                // Round trip: what we encode, we must parse back to the same fields.
                let parsed = try XCTUnwrap(E2EWire.parseClientConfirm(hex(c.encoded)), c.name)
                XCTAssertEqual(hex(parsed.proofBody), c.proof_body!, c.name)
                XCTAssertEqual(hex(parsed.proof), c.proof!, c.name)
                XCTAssertEqual(hex(parsed.newBundle), c.new_bundle!, c.name)
                XCTAssertEqual(hex(parsed.appHello), c.app_hello!, c.name)
            case "session_start":
                let status = try XCTUnwrap(E2EWire.PublicationStatus(rawValue: UInt8(c.publication_status!)))
                let out = try XCTUnwrap(E2EWire.sessionStart(
                    handshakeHash: hex(c.h!), operationID: hex(c.operation_id!),
                    status: status, acceptedBundle: hex(c.accepted_bundle!)))
                XCTAssertEqual(hex(out), c.encoded, c.name)
                let parsed = try XCTUnwrap(E2EWire.parseSessionStart(hex(c.encoded)), c.name)
                XCTAssertEqual(parsed.publicationStatus, status, c.name)
                XCTAssertEqual(hex(parsed.handshakeHash), c.h!, c.name)
                XCTAssertEqual(hex(parsed.acceptedBundle), c.accepted_bundle!, c.name)
            case "responder_hello":
                let out = try XCTUnwrap(E2EWire.responderHello(
                    bundle: hex(c.bundle!), rcode: c.rcode!, rtoken: c.rtoken!))
                XCTAssertEqual(hex(out), c.encoded, c.name)
                let hello = try XCTUnwrap(E2EWire.parseResponderHello(hex(c.encoded)), c.name)
                XCTAssertEqual(hex(hello.bundle), c.bundle!, c.name)
                XCTAssertEqual(hello.rcode, c.rcode!, c.name)
                XCTAssertEqual(hello.rtoken, c.rtoken!, c.name)
            case "initiator_hello":
                let out = try XCTUnwrap(E2EWire.initiatorHello(
                    device: hex(c.device!), operationID: hex(c.operation_id!),
                    bundle: hex(c.bundle!)))
                XCTAssertEqual(hex(out), c.encoded, c.name)
                let hello = try XCTUnwrap(E2EWire.parseInitiatorHello(hex(c.encoded)), c.name)
                XCTAssertEqual(hex(hello.device), c.device!, c.name)
                XCTAssertEqual(hex(hello.operationID), c.operation_id!, c.name)
                XCTAssertEqual(hex(hello.bundle), c.bundle!, c.name)
                XCTAssertEqual(hello.isOrdinaryAuth, c.is_ordinary_auth!, c.name)
            default:
                XCTFail("unknown fixture kind \(c.kind) — a new kind must be asserted, not skipped")
            }
        }
        XCTAssertEqual(seen, ["prologue", "proof_body", "client_confirm", "session_start",
                              "responder_hello", "initiator_hello"],
                       "every message kind must appear; a missing one is coverage that does not exist")
    }

    /// EVERY MODE PRODUCES A DIFFERENT PROLOGUE. This is what stops a `pair` transcript being
    /// replayed as an `auth`: Noise mixes the prologue before anything else, so two peers that
    /// disagree about the mode cannot complete a handshake.
    func testEveryModeIsADifferentPrologue() throws {
        var encodings = Set<[UInt8]>()
        for mode in E2EWire.Mode.allCases {
            encodings.insert(try XCTUnwrap(E2EWire.prologue(mode: mode, roomCode: "room")))
        }
        XCTAssertEqual(encodings.count, E2EWire.Mode.allCases.count)
    }

    /// ...and so does every room. A prologue that ignored the room would let a handshake for one
    /// session be replayed into another.
    func testTheRoomIsBoundIn() throws {
        let a = try XCTUnwrap(E2EWire.prologue(mode: .auth, roomCode: "roomA"))
        let b = try XCTUnwrap(E2EWire.prologue(mode: .auth, roomCode: "roomB"))
        XCTAssertNotEqual(a, b)
    }

    /// WRONG WIDTHS ARE REFUSED AT CONSTRUCTION. §7 requires it before verification — a proof over a
    /// short hash would be a perfectly valid signature over the wrong statement.
    func testWrongWidthsAreRefused() {
        let ok = [UInt8](repeating: 0, count: 32)
        let short = [UInt8](repeating: 0, count: 31)
        XCTAssertNil(E2EWire.deviceProofBody(mode: .auth, handshakeHash: short, deviceID: ok,
                                             responderDeviceID: ok, operationID: ok), "short hash")
        XCTAssertNil(E2EWire.deviceProofBody(mode: .auth, handshakeHash: ok, deviceID: short,
                                             responderDeviceID: ok, operationID: ok), "short device id")
        XCTAssertNil(E2EWire.clientConfirm(proofBody: [], proof: short, newBundle: []), "short signature")
        XCTAssertNil(E2EWire.sessionStart(handshakeHash: short, operationID: ok,
                                          status: .confirmed, acceptedBundle: []), "short hash")
    }

    /// THE PARSER IS THE SECURITY SURFACE. Each of these is a byte string an adversary can send.
    func testTheParserRefusesMalformedInput() throws {
        let good = try XCTUnwrap(E2EWire.sessionStart(
            handshakeHash: [UInt8](repeating: 1, count: 32),
            operationID: [UInt8](repeating: 2, count: 32),
            status: .unconfirmed, acceptedBundle: [9, 9, 9]))
        XCTAssertNotNil(E2EWire.parseSessionStart(good))

        XCTAssertNil(E2EWire.parseSessionStart(good + [0]), "extra trailing bytes")
        XCTAssertNil(E2EWire.parseSessionStart(Array(good.dropLast())), "truncated")
        XCTAssertNil(E2EWire.parseSessionStart([]), "empty")

        // An unsupported status is refused rather than partially interpreted (§7). The status byte
        // sits after the label, h and the operation id.
        var futureStatus = good
        futureStatus[2 + E2EWire.sessionStartLabel.utf8.count + 64] = 3
        XCTAssertNil(E2EWire.parseSessionStart(futureStatus), "an unknown publication status")

        // A confirm must not parse as a session-start, and vice versa — the label is the type tag.
        let confirm = try XCTUnwrap(E2EWire.clientConfirm(
            proofBody: [1, 2, 3], proof: [UInt8](repeating: 7, count: 64), newBundle: []))
        XCTAssertNil(E2EWire.parseSessionStart(confirm), "a confirm is not a session-start")
        XCTAssertNil(E2EWire.parseClientConfirm(good), "a session-start is not a confirm")
    }

    /// §11.2's "BOUNDED": `app_hello` rides the gate's own message, so it is capped on both ends, and the cap is a
    /// rejection when parsing — never a truncation. A confirm MISSING the field is refused, never read as empty.
    func testClientConfirmsAppHelloIsCapped() throws {
        let proof = [UInt8](repeating: 7, count: 64)
        let atCap = try XCTUnwrap(E2EWire.clientConfirm(proofBody: [1], proof: proof, newBundle: [],
                                                        appHello: [UInt8](repeating: 0x7B, count: E2EWire.appHelloMax)))
        XCTAssertEqual(E2EWire.parseClientConfirm(atCap)?.appHello.count, E2EWire.appHelloMax)
        XCTAssertNil(E2EWire.clientConfirm(proofBody: [1], proof: proof, newBundle: [],
                                           appHello: [UInt8](repeating: 0, count: E2EWire.appHelloMax + 1)), "encoding")
        let head = Array(atCap.dropLast(E2EWire.appHelloMax + 2))
        let over = head + [UInt8((E2EWire.appHelloMax + 1) >> 8), UInt8((E2EWire.appHelloMax + 1) & 0xFF)]
            + [UInt8](repeating: 0, count: E2EWire.appHelloMax + 1)
        XCTAssertNil(E2EWire.parseClientConfirm(over), "parsing")
        XCTAssertNil(E2EWire.parseClientConfirm(head), "no app_hello")
    }

    /// A LENGTH PREFIX THAT OVERRUNS THE BUFFER must not be believed — the classic parser defect,
    /// and the one that turns a length field into a read primitive.
    func testALengthPrefixCannotOverrunTheBuffer() throws {
        var bytes = try XCTUnwrap(E2EWire.clientConfirm(
            proofBody: [1, 2, 3], proof: [UInt8](repeating: 7, count: 64), newBundle: [4, 5]))
        // The proof_body length prefix follows the label; claim it is enormous.
        let at = 2 + E2EWire.confirmLabel.utf8.count
        bytes[at] = 0xFF; bytes[at + 1] = 0xFF
        XCTAssertNil(E2EWire.parseClientConfirm(bytes))
    }

    // MARK: - §11.1 handshake payloads

    /// §11.1: "Message 1 has an empty payload." It travels before any authentication, so anything in
    /// it is bytes an unauthenticated stranger chose — a build tolerating a payload here would be
    /// parsing attacker input at the earliest possible point in the protocol.
    func testMessage1CarriesNothing() {
        XCTAssertTrue(E2EWire.message1PayloadIsAcceptable([]))
        XCTAssertFalse(E2EWire.message1PayloadIsAcceptable([0]))
        XCTAssertFalse(E2EWire.message1PayloadIsAcceptable(Array("hello".utf8)))
    }

    /// Both hello payloads are UNLABELLED concatenations, so their parsers have nothing to anchor on
    /// except widths and the total length — which makes trailing bytes the whole defence.
    func testTheHelloPayloadsRejectWhatSection7Requires() throws {
        let bundle: [UInt8] = [1, 2, 3, 4]
        let device = Array(repeating: UInt8(9), count: 70)
        let op = Array(repeating: UInt8(7), count: E2EWire.idLength)

        let responder = try XCTUnwrap(E2EWire.responderHello(
            bundle: bundle, rcode: "x0WuwKuk", rtoken: "f67e21bd-9c7d-4a3b-8f21-0d4e6a1b2c3d"))
        XCTAssertNotNil(E2EWire.parseResponderHello(responder))
        XCTAssertNil(E2EWire.parseResponderHello(responder + [0]))
        XCTAssertNil(E2EWire.parseResponderHello(Array(responder.dropLast())))

        let initiator = try XCTUnwrap(E2EWire.initiatorHello(device: device, operationID: op,
                                                             bundle: bundle))
        XCTAssertNotNil(E2EWire.parseInitiatorHello(initiator))
        XCTAssertNil(E2EWire.parseInitiatorHello(initiator + [0]))
        XCTAssertNil(E2EWire.initiatorHello(device: device, operationID: Array(op.dropLast()),
                                            bundle: bundle))
    }

    /// An rcode that is not UTF-8 is REFUSED, never repaired. A replacement character would make two
    /// different byte strings compare equal as routes.
    func testAnInvalidRouteEncodingIsRefusedRatherThanReplaced() {
        XCTAssertNil(E2EWire.parseResponderHello([0, 4, 1, 2, 3, 4, 0, 2, 0xFF, 0xFE, 0, 0]))
    }

    /// §11.1: "An ordinary `auth` uses an all-zero operation ID." A meaning, not a missing value.
    func testTheAllZeroOperationIDIsRecognisedAsOrdinaryAuth() throws {
        let device = Array(repeating: UInt8(9), count: 40)
        let zero = Array(repeating: UInt8(0), count: E2EWire.idLength)
        var almost = zero
        almost[31] = 1

        let a = try XCTUnwrap(E2EWire.parseInitiatorHello(
            try XCTUnwrap(E2EWire.initiatorHello(device: device, operationID: zero, bundle: []))))
        let b = try XCTUnwrap(E2EWire.parseInitiatorHello(
            try XCTUnwrap(E2EWire.initiatorHello(device: device, operationID: almost, bundle: []))))
        XCTAssertTrue(a.isOrdinaryAuth)
        XCTAssertFalse(b.isOrdinaryAuth, "one bit away from zero is an ENROLLMENT's operation id")
    }
}
