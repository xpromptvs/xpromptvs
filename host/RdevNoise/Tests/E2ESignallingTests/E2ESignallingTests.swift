import RdevCore
import RdevNoise
import XCTest

/// §17.3: "Use real Noise on both ends. Modified, replayed, reordered, or injected messages
/// terminate the connection; mismatched modes or rooms fail. No SDP or ICE is processed before
/// authentication and the revocation check ... Cover normal connection with no application traffic:
/// `client-confirm` and `session-start` must suffice to finish authorization without a deadlock."
///
/// **THE ONLY PLACE THE HOST'S TWO HALVES MEET.** `RdevCore.E2ESession` decides policy and
/// `RdevNoise.NoiseSession` does the cryptography, and they are separate modules on purpose:
/// RdevCore is pure portable logic that must not link a Rust archive. That separation means no other
/// suite can see them wired together, and the wiring is where `h` and the peer's static key cross
/// from one to the other — the two values the whole §11.2 gate rests on.
///
/// Its TypeScript counterpart is `protocol/test/e2e-signalling.test.ts`, driven by the same fixture.
final class E2ESignallingTests: XCTestCase {

    private struct Device: Decodable {
        let name: String
        let signing_private_key: String, signing_public_key: String
        let noise_private_key: String, noise_public_key: String
        let descriptor: String, device_id: String, bundle: String
    }
    private struct Route: Decodable { let rcode: String, rtoken: String }
    private struct Fixture: Decodable {
        let rp_id: String, allowed_origins: [String], root_id: String
        let devices: [String: Device]
        let routes: [String: Route]
        let operation_ids: [String: String]
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
    private func dev(_ n: String) -> Device { fx.devices[n]! }
    private var policy: E2EVerify.Policy {
        .init(rpID: fx.rp_id, allowedOrigins: fx.allowed_origins)
    }

    /// A complete, really-encrypted session. Every wire message is returned so a test can tamper.
    private struct Session {
        var responder: E2ESession.Responder
        var initiator: E2ESession.Initiator
        var noiseInitiator: NoiseSession
        var noiseResponder: NoiseSession
        var wire: [String: [UInt8]] = [:]
        var steps: [String: String] = [:]
        var handshakeHashInitiator: [UInt8] = []
        var handshakeHashResponder: [UInt8] = []
    }

    private func code<T>(_ r: Result<T, E2ESession.Failure>) -> String {
        switch r {
        case .success: return "ok"
        case .failure(let f): return f.rawValue
        }
    }

    private func connect(mode: E2EWire.Mode = .auth, room: String = "room-1",
                         responderRoom: String? = nil,
                         responderName: String = "H", initiatorName: String = "C",
                         psk: [UInt8]? = nil, responderPSK: [UInt8]? = nil) throws -> Session {
        let noiseMode: NoiseSession.Mode = psk == nil ? .xx : .pair
        let initiatorPrologue = try XCTUnwrap(E2EWire.prologue(mode: mode, roomCode: room))
        let responderPrologue = try XCTUnwrap(
            E2EWire.prologue(mode: mode, roomCode: responderRoom ?? room))

        let ni = try XCTUnwrap(NoiseSession(mode: noiseMode, initiator: true,
                                            prologue: initiatorPrologue,
                                            staticPrivateKey: hex(dev(initiatorName).noise_private_key),
                                            psk: psk))
        let nr = try XCTUnwrap(NoiseSession(mode: noiseMode, initiator: false,
                                            prologue: responderPrologue,
                                            staticPrivateKey: hex(dev(responderName).noise_private_key),
                                            psk: responderPSK ?? psk))

        let route = fx.routes[responderName] ?? fx.routes["H"]!
        var responder = E2ESession.Responder(.init(
            mode: mode, roomCode: room, device: hex(dev(responderName).descriptor),
            bundle: hex(dev(responderName).bundle),
            route: RendezvousRoute(rcode: route.rcode, rtoken: route.rtoken),
            trustedRootID: hex(fx.root_id), policy: policy))
        // §12.3: in `pair` the newcomer arrives with KEYS and names itself only after message 2,
        // because a §10.2 descriptor NAMES its root and it does not know one yet.
        let initiatorKeys = DeviceIdentity.Keys(
            signingPrivateKey: hex(dev(initiatorName).signing_private_key),
            noisePrivateKey: hex(dev(initiatorName).noise_private_key))
        var initiator = try XCTUnwrap(E2ESession.Initiator(.init(
            mode: mode, roomCode: room,
            device: mode == .pair ? [] : hex(dev(initiatorName).descriptor),
            signingPrivateKey: hex(dev(initiatorName).signing_private_key),
            bundle: mode == .auth ? hex(dev(initiatorName).bundle) : [],
            operationID: hex(fx.operation_ids["zero"]!),
            trustedRootID: mode == .pair ? nil : hex(fx.root_id),
            policy: policy,
            devicePublicKeys: mode == .pair
                ? (try XCTUnwrap(initiatorKeys?.signingPublicKey),
                   try XCTUnwrap(initiatorKeys?.noisePublicKey))
                : nil)))

        var s = Session(responder: responder, initiator: initiator,
                        noiseInitiator: ni, noiseResponder: nr)

        // Message 1 — an EMPTY payload, encrypted by Noise all the same.
        s.wire["m1"] = try ni.write(initiator.message1Payload)
        let m1Plain = try nr.read(s.wire["m1"]!)
        s.steps["message1"] = code(responder.receiveMessage1(m1Plain))

        let m2 = responder.message2Payload()
        s.steps["message2"] = code(m2)
        guard case .success(let m2Payload) = m2 else { s.responder = responder; s.initiator = initiator; return s }
        s.wire["m2"] = try nr.write(m2Payload)
        let m2Plain = try ni.read(s.wire["m2"]!)
        // The static key NOISE authenticated — the only honest source for it.
        let responderStatic = try XCTUnwrap(ni.remoteStaticKey)
        s.steps["receiveMessage2"] = code(initiator.receiveMessage2(m2Plain,
                                                                    responderNoiseStatic: responderStatic))

        let m3 = initiator.message3Payload()
        s.steps["message3"] = code(m3)
        guard case .success(let m3Payload) = m3 else { s.responder = responder; s.initiator = initiator; return s }
        s.wire["m3"] = try ni.write(m3Payload)
        let m3Plain = try nr.read(s.wire["m3"]!)
        let initiatorStatic = try XCTUnwrap(nr.remoteStaticKey)
        s.steps["receiveMessage3"] = code(responder.receiveMessage3(m3Plain,
                                                                    initiatorNoiseStatic: initiatorStatic))

        s.handshakeHashInitiator = try XCTUnwrap(ni.handshakeHash)
        s.handshakeHashResponder = try XCTUnwrap(nr.handshakeHash)

        let confirm = initiator.clientConfirm(handshakeHash: s.handshakeHashInitiator)
        s.steps["clientConfirm"] = code(confirm)
        guard case .success(let confirmBytes) = confirm else { s.responder = responder; s.initiator = initiator; return s }
        s.wire["confirm"] = try ni.write(confirmBytes)
        let confirmPlain = try nr.read(s.wire["confirm"]!)
        s.steps["receiveConfirm"] = code(responder.receiveClientConfirm(
            confirmPlain, handshakeHash: s.handshakeHashResponder))

        let start = responder.sessionStart(handshakeHash: s.handshakeHashResponder,
                                           status: .unconfirmed, acceptedBundle: [])
        s.steps["sessionStart"] = code(start)
        guard case .success(let startBytes) = start else { s.responder = responder; s.initiator = initiator; return s }
        s.wire["start"] = try nr.write(startBytes)
        let startPlain = try ni.read(s.wire["start"]!)
        s.steps["receiveSessionStart"] = code(initiator.receiveSessionStart(
            startPlain, handshakeHash: s.handshakeHashInitiator))

        s.responder = responder
        s.initiator = initiator
        return s
    }

    // MARK: - the happy path

    func testACompleteAuthSessionOverRealNoise() throws {
        let s = try connect()
        XCTAssertEqual(s.steps, [
            "message1": "ok", "message2": "ok", "receiveMessage2": "ok", "message3": "ok",
            "receiveMessage3": "ok", "clientConfirm": "ok", "receiveConfirm": "ok",
            "sessionStart": "ok", "receiveSessionStart": "ok",
        ])
        XCTAssertTrue(s.responder.maySignal)
        XCTAssertTrue(s.initiator.maySignal)
    }

    /// §17.3: "Cover normal connection with no application traffic: `client-confirm` and
    /// `session-start` must suffice to finish authorization without a deadlock."
    func testTwoTransportMessagesSuffice() throws {
        let s = try connect()
        XCTAssertEqual(s.wire.keys.sorted(), ["confirm", "m1", "m2", "m3", "start"])
    }

    /// THE FACT THIS TARGET EXISTS TO CHECK. `h` crosses from RdevNoise into RdevCore, and a build
    /// that handed over the wrong one — or one captured at the wrong moment — would pass every test
    /// in both modules separately.
    func testBothEndsDeriveTheSameHandshakeHash() throws {
        let s = try connect()
        XCTAssertEqual(s.handshakeHashInitiator, s.handshakeHashResponder)
        XCTAssertEqual(s.handshakeHashInitiator.count, 32)

        // And a second session derives a different one, so a proof cannot be carried between them.
        let other = try connect()
        XCTAssertNotEqual(other.handshakeHashInitiator, s.handshakeHashInitiator)
    }

    /// The other value that crosses the boundary: the peer's static key. §11.1 requires the
    /// descriptor's DH key to equal it, and the descriptors in the fixture are real X25519 points
    /// precisely so this can be checked rather than assumed.
    func testTheAuthenticatedStaticKeyIsTheOneInTheDescriptor() throws {
        let s = try connect()
        XCTAssertEqual(s.noiseInitiator.remoteStaticKey, hex(dev("H").noise_public_key))
        XCTAssertEqual(s.noiseResponder.remoteStaticKey, hex(dev("C").noise_public_key))
        XCTAssertEqual(s.responder.initiatorDevice?.noisePublicKey, hex(dev("C").noise_public_key))
    }

    // MARK: - pair, over real XXpsk3

    func testAPairSessionCompletesAgainstThePairingSecret() throws {
        let psk = Array(repeating: UInt8(0xA7), count: 32)
        let s = try connect(mode: .pair, initiatorName: "N", psk: psk)
        XCTAssertEqual(s.steps["receiveConfirm"], "ok")
        XCTAssertTrue(s.responder.maySignal)
        XCTAssertNotNil(s.initiator.responderChain)
    }

    func testAOneBitPSKMismatchKillsTheSession() throws {
        var bad = Array(repeating: UInt8(0xA7), count: 32)
        bad[31] ^= 0x01
        // psk3 mixes the secret at the END of message 3, so this fails inside Noise, not in policy.
        XCTAssertThrowsError(try connect(mode: .pair, initiatorName: "N",
                                         psk: Array(repeating: UInt8(0xA7), count: 32),
                                         responderPSK: bad))
    }

    // MARK: - §17.3: tampering and mismatch

    func testAModifiedTransportCiphertextDoesNotDecrypt() throws {
        let s = try connect()
        var tampered = s.wire["confirm"]!
        tampered[tampered.count - 1] ^= 0x01
        // A fresh session, so the receiving cipher state sits at the right nonce.
        let fresh = try connect()
        XCTAssertThrowsError(try fresh.noiseResponder.read(tampered)) { error in
            XCTAssertEqual(error as? NoiseSession.Failure, .noise)
        }
    }

    func testAReplayedTransportMessageDoesNotDecryptTwice() throws {
        // Noise's per-direction counters are the replay defence; the session machine never sees it.
        let s = try connect()
        XCTAssertThrowsError(try s.noiseResponder.read(s.wire["confirm"]!))
    }

    func testADifferentRoomOnEachSideFailsTheHandshake() {
        // The prologue is mixed before anything else, so a disagreement is fatal at the first AEAD
        // and the session machine never gets to apply a policy — which is why it is bound there.
        XCTAssertThrowsError(try connect(room: "room-1", responderRoom: "room-2"))
    }

    func testAModeDisagreementFailsTheHandshake() throws {
        let ni = try XCTUnwrap(NoiseSession(
            mode: .xx, initiator: true,
            prologue: XCTUnwrap(E2EWire.prologue(mode: .auth, roomCode: "r")),
            staticPrivateKey: hex(dev("C").noise_private_key)))
        let nr = try XCTUnwrap(NoiseSession(
            mode: .xx, initiator: false,
            prologue: XCTUnwrap(E2EWire.prologue(mode: .enroll, roomCode: "r")),
            staticPrivateKey: hex(dev("H").noise_private_key)))
        let m1 = try ni.write([])
        _ = try nr.read(m1)
        let m2 = try nr.write([])
        XCTAssertThrowsError(try ni.read(m2))
    }

    // MARK: - §17.3: nothing is processed before the gate

    func testNothingSignalsBeforeTheGateEvenAfterSplit() throws {
        let prologue = try XCTUnwrap(E2EWire.prologue(mode: .auth, roomCode: "room-1"))
        let ni = try XCTUnwrap(NoiseSession(mode: .xx, initiator: true, prologue: prologue,
                                            staticPrivateKey: hex(dev("C").noise_private_key)))
        let nr = try XCTUnwrap(NoiseSession(mode: .xx, initiator: false, prologue: prologue,
                                            staticPrivateKey: hex(dev("H").noise_private_key)))
        let route = fx.routes["H"]!
        var responder = E2ESession.Responder(.init(
            mode: .auth, roomCode: "room-1", device: hex(dev("H").descriptor),
            bundle: hex(dev("H").bundle),
            route: RendezvousRoute(rcode: route.rcode, rtoken: route.rtoken),
            trustedRootID: hex(fx.root_id), policy: policy))
        var initiator = try XCTUnwrap(E2ESession.Initiator(.init(
            mode: .auth, roomCode: "room-1", device: hex(dev("C").descriptor),
            signingPrivateKey: hex(dev("C").signing_private_key), bundle: hex(dev("C").bundle),
            operationID: hex(fx.operation_ids["zero"]!), trustedRootID: hex(fx.root_id),
            policy: policy)))

        func shut(_ line: UInt = #line) {
            XCTAssertFalse(responder.maySignal, line: line)
            XCTAssertFalse(initiator.maySignal, line: line)
        }

        shut()
        _ = responder.receiveMessage1(try nr.read(try ni.write(initiator.message1Payload)))
        shut()
        guard case .success(let m2) = responder.message2Payload() else {
            return XCTFail("message 2 must build")
        }
        _ = initiator.receiveMessage2(try ni.read(try nr.write(m2)),
                                      responderNoiseStatic: try XCTUnwrap(ni.remoteStaticKey))
        shut()
        guard case .success(let m3) = initiator.message3Payload() else {
            return XCTFail("message 3 must build")
        }
        _ = responder.receiveMessage3(try nr.read(try ni.write(m3)),
                                      initiatorNoiseStatic: try XCTUnwrap(nr.remoteStaticKey))
        // SPLIT HAS HAPPENED: the channel is encrypted and each peer knows the other's static key.
        // And STILL neither may signal, because §11.2's confirmation has not run.
        XCTAssertTrue(ni.isTransport)
        XCTAssertTrue(nr.isTransport)
        shut()

        // Fifty perfectly well-encrypted transport messages from an authenticated Noise peer.
        for i in 0 ..< 50 {
            let ct = try ni.write([UInt8(i)])
            XCTAssertEqual(try nr.read(ct), [UInt8(i)])
            shut()
        }
    }
}
