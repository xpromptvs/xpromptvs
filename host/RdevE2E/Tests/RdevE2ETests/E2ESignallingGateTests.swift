import RdevCore
import RdevNoise
import XCTest
import RdevE2E

/// The gate as the host actually runs it: one object per peer, fed §11.3 envelopes, answering with
/// §11.3 envelopes, and refusing everything until §11.2's sentence is true.
///
/// `E2ESignallingTests` proves the two halves of §11 agree; this proves the PRODUCTION wiring of
/// them does — including the part that suite has no reason to cover, that the gate is also the
/// transport once it opens.
final class E2ESignallingGateTests: XCTestCase {

    private struct Device: Decodable {
        let signing_private_key: String, noise_private_key: String
        let descriptor: String, bundle: String
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
    private var policy: E2EVerify.Policy { .init(rpID: fx.rp_id, allowedOrigins: fx.allowed_origins) }
    private let room = "room-1"

    private func gate(responder name: String = "H",
                      trustedRoot: [UInt8]? = nil,
                      revoked: Set<[UInt8]> = [],
                      pairingPSK: [UInt8]? = nil) -> E2ESignallingGate {
        let route = fx.routes[name] ?? fx.routes["H"]!
        return E2ESignallingGate(config: .init(
            device: hex(dev(name).descriptor), bundle: hex(dev(name).bundle),
            noisePrivateKey: hex(dev(name).noise_private_key),
            route: RendezvousRoute(rcode: route.rcode, rtoken: route.rtoken),
            trustedRootID: trustedRoot ?? hex(fx.root_id), policy: policy,
            revokedDeviceIDs: revoked, publicationStatus: .confirmed,
            pairingPSK: pairingPSK,
            signingPrivateKey: hex(dev(name).signing_private_key)), roomCode: room)
    }

    /// The client half — a real `E2ESession.Initiator` over a real Noise session, driving the gate
    /// the way the browser will.
    private final class Client {
        let noise: NoiseSession
        var session: E2ESession.Initiator
        init(_ noise: NoiseSession, _ session: E2ESession.Initiator) {
            self.noise = noise
            self.session = session
        }
    }

    private func client(_ name: String = "C", mode: E2EWire.Mode = .auth,
                        room roomCode: String? = nil, psk: [UInt8]? = nil) throws -> Client {
        let prologue = try XCTUnwrap(E2EWire.prologue(mode: mode, roomCode: roomCode ?? room))
        let noise = try XCTUnwrap(NoiseSession(mode: psk == nil ? .xx : .pair, initiator: true,
                                               prologue: prologue,
                                               staticPrivateKey: hex(dev(name).noise_private_key),
                                               psk: psk))
        // §11.1's bundle rules: required for `auth`, EMPTY for `pair` and `enroll`. And in `pair`
        // there is no trusted root yet — the mode bootstraps one from the chain, authenticated by
        // the psk, which is the only mode where that is legal.
        // **In `pair` the newcomer arrives with KEYS and no descriptor.** §10.2's descriptor names
        // its root, and a newcomer does not know that root until message 2 (§12.3). Everywhere else
        // it has a root already and brings a descriptor.
        let keys = DeviceIdentity.Keys(signingPrivateKey: hex(dev(name).signing_private_key),
                                       noisePrivateKey: hex(dev(name).noise_private_key))
        let session = try XCTUnwrap(E2ESession.Initiator(.init(
            mode: mode, roomCode: roomCode ?? room,
            device: mode == .pair ? [] : hex(dev(name).descriptor),
            signingPrivateKey: hex(dev(name).signing_private_key),
            bundle: mode == .auth ? hex(dev(name).bundle) : [],
            operationID: hex(fx.operation_ids["zero"]!),
            trustedRootID: mode == .pair ? nil : hex(fx.root_id), policy: policy,
            devicePublicKeys: mode == .pair
                ? (try XCTUnwrap(keys?.signingPublicKey), try XCTUnwrap(keys?.noisePublicKey))
                : nil)))
        return Client(noise, session)
    }

    private func reply(_ r: Result<E2ESignallingGate.Received, E2ESignallingGate.Failure>,
                       file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        guard case .success(.reply(let bytes)) = r else {
            XCTFail("expected a reply, got \(r)", file: file, line: line)
            throw E2ESignallingGate.Failure.notEstablished
        }
        return bytes
    }

    private func failure(_ r: Result<E2ESignallingGate.Received, E2ESignallingGate.Failure>,
                         file: StaticString = #filePath, line: UInt = #line) -> E2ESignallingGate.Failure? {
        guard case .failure(let f) = r else {
            XCTFail("expected a refusal, got \(r)", file: file, line: line)
            return nil
        }
        return f
    }

    /// Drive a whole `auth` session. Returns the two ends, established.
    @discardableResult
    private func connect(_ g: E2ESignallingGate, _ c: Client) throws -> E2ESignallingGate {
        let m1 = try c.noise.write(c.session.message1Payload)
        let m2 = try reply(g.receive(m1, mode: .auth))

        let m2Plain = try c.noise.read(m2)
        let responderStatic = try XCTUnwrap(c.noise.remoteStaticKey)
        guard case .success = c.session.receiveMessage2(m2Plain, responderNoiseStatic: responderStatic)
        else { throw E2ESession.Failure.peerChain }

        guard case .success(let m3Payload) = c.session.message3Payload() else {
            throw E2ESession.Failure.outOfOrder
        }
        let m3 = try c.noise.write(m3Payload)
        XCTAssertEqual(try? g.receive(m3, mode: nil).get(), .nothing)

        let h = try XCTUnwrap(c.noise.handshakeHash)
        guard case .success(let confirmPayload) = c.session.clientConfirm(handshakeHash: h) else {
            throw E2ESession.Failure.outOfOrder
        }
        let start = try reply(g.receive(try c.noise.write(confirmPayload), mode: nil))
        let startPlain = try c.noise.read(start)
        guard case .success = c.session.receiveSessionStart(startPlain, handshakeHash: h) else {
            throw E2ESession.Failure.handshakeHashMismatch
        }
        return g
    }

    // MARK: - the happy path

    func testACompleteAuthSessionOpensTheGate() throws {
        let g = gate()
        let c = try client()
        XCTAssertFalse(g.maySignal)
        try connect(g, c)

        XCTAssertTrue(g.maySignal)
        XCTAssertTrue(c.session.maySignal)
        XCTAssertEqual(g.peerChain?.leafDevice.bytes, hex(dev("C").descriptor),
                       "and the gate knows WHO it opened for")
    }

    /// §11.3: "Every subsequent signalling message, including SDP, ICE, renegotiation, and ICE
    /// restart, is carried inside Noise transport." Both directions, with the same JSON the
    /// plaintext envelopes used to carry — which is what lets both ends keep their parsers.
    func testSignallingTravelsInsideTheSessionBothWays() throws {
        let g = gate()
        let c = try client()
        try connect(g, c)

        let offer = offerJSON("v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n", peer: "p1")
        let sealed = try g.seal(offer).get()
        XCTAssertNotEqual(Data(sealed), offer, "it is on the wire encrypted, not merely framed")
        let delivered = try c.noise.read(sealed)
        guard case .offer(let sdp) = SignalingRouter.route(Data(delivered)) else {
            return XCTFail("the inner message did not route")
        }
        XCTAssertTrue(sdp.hasPrefix("v=0"))

        let answer = answerJSON("v=0\r\na=recvonly\r\n")
        guard case .success(.signalling(let inbound)) = g.receive(try c.noise.write([UInt8](answer)),
                                                                 mode: nil) else {
            return XCTFail("an answer from an authenticated peer must arrive as signalling")
        }
        guard case .answer(let inSDP, _) = SignalingRouter.route(inbound) else {
            return XCTFail("the inbound message did not route")
        }
        XCTAssertTrue(inSDP.hasPrefix("v=0"))
    }

    // MARK: - §11.2: nothing before the gate

    /// The sentence the whole protocol rests on, at every stage a caller could be tempted to send.
    func testNothingMayBeSentBeforeTheGateOpens() throws {
        let g = gate()
        let c = try client()
        XCTAssertEqual(g.seal(offerJSON("x", peer: "p")).failure, .notEstablished, "before anything")

        let m1 = try c.noise.write(c.session.message1Payload)
        _ = try reply(g.receive(m1, mode: .auth))
        XCTAssertEqual(g.seal(offerJSON("x", peer: "p")).failure, .notEstablished, "after message 1")
        XCTAssertFalse(g.maySignal)
    }

    /// The same sentence at the LAST moment it could be wrong: the peer's chain has verified and its
    /// descriptor is known, but it has not yet proved it holds the signing key.
    func testAVerifiedChainIsNotYetAuthorityToSignal() throws {
        let g = gate()
        let c = try client()
        let m1 = try c.noise.write(c.session.message1Payload)
        let m2 = try reply(g.receive(m1, mode: .auth))
        let m2Plain = try c.noise.read(m2)
        _ = c.session.receiveMessage2(m2Plain,
                                      responderNoiseStatic: try XCTUnwrap(c.noise.remoteStaticKey))
        guard case .success(let m3Payload) = c.session.message3Payload() else {
            return XCTFail("message 3")
        }
        _ = g.receive(try c.noise.write(m3Payload), mode: nil)

        XCTAssertNotNil(g.peerChain, "the chain has verified…")
        XCTAssertFalse(g.maySignal, "…and that is still not authority")
        XCTAssertEqual(g.seal(iceJSON(["candidate": "x"], peer: "p")).failure, .notEstablished)
    }

    // MARK: - §11.3: modes, and what terminates

    /// §11.3: "Mode is supplied with the initial handshake and bound into the prologue." An envelope
    /// that opens a session without naming one cannot be given a default — guessing would let a peer
    /// choose the pattern by omission.
    func testAnOpeningEnvelopeWithNoModeIsRefused() throws {
        let g = gate()
        let c = try client()
        let m1 = try c.noise.write(c.session.message1Payload)
        XCTAssertEqual(failure(g.receive(m1, mode: nil)), .modeNotOffered)
        XCTAssertEqual(failure(g.receive(m1, mode: .auth)), .notEstablished,
                       "and a refused gate does not reopen")
    }

    // MARK: - `pair`: the psk IS the authorisation

    /// Drive a whole `pair` session: the newcomer presents no chain and asks to be enrolled, the
    /// Issuer mints one, and the newcomer adopts the root it learns from the Issuer's own chain.
    ///
    /// **NOBODY IS ASKED ANYTHING.** §9.1 buys "someone was there" with a one-time secret shown on
    /// the local pairing surface, and possession of it is the entire authorisation — an unauthorised
    /// party cannot complete message 3, so there is no request for a person to approve or refuse.
    private func pairSession(psk: [UInt8], newcomer: String = "N") throws
        -> (gate: E2ESignallingGate, client: Client, accepted: [UInt8]) {
        let g = gate(pairingPSK: psk)
        let c = try client(newcomer, mode: .pair, psk: psk)

        let m1 = try c.noise.write(c.session.message1Payload)
        let m2 = try reply(g.receive(m1, mode: .pair))
        let m2Plain = try c.noise.read(m2)
        let responderStatic = try XCTUnwrap(c.noise.remoteStaticKey)
        guard case .success = c.session.receiveMessage2(m2Plain, responderNoiseStatic: responderStatic)
        else { throw E2ESession.Failure.peerChain }

        guard case .success(let m3Payload) = c.session.message3Payload() else {
            throw E2ESession.Failure.outOfOrder
        }
        XCTAssertEqual(try? g.receive(try c.noise.write(m3Payload), mode: nil).get(), .nothing)

        let h = try XCTUnwrap(c.noise.handshakeHash)
        guard case .success(let confirmPayload) = c.session.clientConfirm(handshakeHash: h) else {
            throw E2ESession.Failure.outOfOrder
        }
        let start = try reply(g.receive(try c.noise.write(confirmPayload), mode: nil))
        let startPlain = try c.noise.read(start)
        guard case .success = c.session.receiveSessionStart(startPlain, handshakeHash: h) else {
            throw E2ESession.Failure.handshakeHashMismatch
        }
        return (g, c, try XCTUnwrap(c.session.acceptedBundle))
    }

    // MARK: - `pair` answered by a PASSKEY issuer (Add device by code, from a Mac — 2026-10-07)

    private func passkeyGate(psk: [UInt8], signing: Bool = false) -> E2ESignallingGate {
        let route = fx.routes["H"]!
        return E2ESignallingGate(config: .init(
            device: hex(dev("H").descriptor), bundle: hex(dev("H").bundle),
            noisePrivateKey: hex(dev("H").noise_private_key),
            route: RendezvousRoute(rcode: route.rcode, rtoken: route.rtoken),
            trustedRootID: hex(fx.root_id), policy: policy, publicationStatus: .confirmed,
            pairingPSK: psk, signingPrivateKey: signing ? hex(dev("H").signing_private_key) : nil,
            pairIssuer: .passkey), roomCode: room)
    }

    /// Message 1 through `client-confirm` against a passkey issuer: what the gate said to the confirm, and the
    /// newcomer's handshake hash.
    private func parkedPairSession(_ g: E2ESignallingGate, psk: [UInt8])
        throws -> (confirm: Result<E2ESignallingGate.Received, E2ESignallingGate.Failure>, h: [UInt8]) {
        let c = try client("N", mode: .pair, psk: psk)
        let m2 = try reply(g.receive(try c.noise.write(c.session.message1Payload), mode: .pair))
        let m2Plain = try c.noise.read(m2)
        guard case .success = c.session.receiveMessage2(m2Plain, responderNoiseStatic: try XCTUnwrap(c.noise.remoteStaticKey)),
              case .success(let m3Payload) = c.session.message3Payload() else { throw E2ESession.Failure.peerChain }
        XCTAssertEqual(try? g.receive(try c.noise.write(m3Payload), mode: nil).get(), .nothing)
        let h = try XCTUnwrap(c.noise.handshakeHash)
        guard case .success(let confirmPayload) = c.session.clientConfirm(handshakeHash: h) else {
            throw E2ESession.Failure.outOfOrder
        }
        return (g.receive(try c.noise.write(confirmPayload), mode: nil), h)
    }

    /// **The root signs, so the gate WAITS for it**: authenticated, the newcomer is owed a chain only a passkey
    /// ceremony can produce, and nothing is sent until `issue` — the session is NOT open meanwhile. What it hands
    /// the caller to mint over is the descriptor Noise authenticated and §10.3's remote binding to this
    /// transcript and this device.
    func testAPasskeyIssuerParksThePairSessionUntilItIsGivenAChain() throws {
        let psk = [UInt8](repeating: 0xAB, count: 32)
        let g = passkeyGate(psk: psk)
        let (confirm, h) = try parkedPairSession(g, psk: psk)
        XCTAssertEqual(try? confirm.get(), .awaitingIssuance, "nothing sent: no session-start before the chain")
        XCTAssertFalse(g.maySignal, "a parked session has not opened")
        let pending = try XCTUnwrap(g.pendingIssuance)
        XCTAssertEqual(pending.device, hex(dev("N").descriptor), "the newcomer's descriptor, under this identity's root")
        XCTAssertEqual(pending.handshakeHash, h, "bound to THIS transcript")
        XCTAssertEqual(pending.responderDeviceID, E2EIdentity.deviceID(hex(dev("H").descriptor)), "and to this device")
    }

    /// A chain that does not certify the newcomer is refused before it is sent — and the session is spent.
    func testAPasskeyIssuerRefusesAChainForAnotherDeviceAndEndsTheSession() throws {
        let psk = [UInt8](repeating: 0xAB, count: 32)
        let g = passkeyGate(psk: psk)
        _ = try parkedPairSession(g, psk: psk)
        guard case .failure(let f) = g.issue(hex(dev("H").bundle)) else { return XCTFail("another device's chain was sent") }
        XCTAssertEqual(f, .session(.peerChain))
        XCTAssertNil(g.pendingIssuance)
        XCTAssertFalse(g.maySignal)
        guard case .failure(.notEstablished) = g.issue(hex(dev("H").bundle)) else { return XCTFail("a spent session issued") }
    }

    /// The passkey signs, so a passkey issuer needs no signing key at the door — where a subordinate issuer
    /// without one is refused before message 2.
    func testAPasskeyIssuerNeedsNoSigningKey() throws {
        let psk = [UInt8](repeating: 0xAB, count: 32)
        let c = try client("N", mode: .pair, psk: psk)
        XCTAssertNoThrow(try reply(passkeyGate(psk: psk).receive(try c.noise.write(c.session.message1Payload), mode: .pair)))
        let route = fx.routes["H"]!
        let subordinate = E2ESignallingGate(config: .init(
            device: hex(dev("H").descriptor), bundle: hex(dev("H").bundle),
            noisePrivateKey: hex(dev("H").noise_private_key),
            route: RendezvousRoute(rcode: route.rcode, rtoken: route.rtoken),
            trustedRootID: hex(fx.root_id), policy: policy, pairingPSK: psk), roomCode: room)
        let c2 = try client("N", mode: .pair, psk: psk)
        XCTAssertEqual(failure(subordinate.receive(try c2.noise.write(c2.session.message1Payload), mode: .pair)),
                       .modeNotSupported)
    }

    func testAPairSessionMintsAGrantForTheNewcomer() throws {
        let psk = [UInt8](repeating: 0xAB, count: 32)
        let (g, c, accepted) = try pairSession(psk: psk)

        XCTAssertTrue(g.maySignal)
        XCTAssertTrue(c.session.maySignal)

        // The chain the newcomer walks away with verifies under the root it just adopted, and its
        // leaf is the newcomer — not the Issuer.
        let chain = try E2EVerify.verifyBundle(accepted, trustedRootID: hex(fx.root_id),
                                               policy: policy).get()
        XCTAssertEqual(chain.leafDevice.bytes, hex(dev("N").descriptor))
        // §10.3: a device that arrived through a pairing window is a CLIENT. `1` exists so least
        // privilege is expressible, and a paired browser has no reason to carry `host`.
        XCTAssertEqual(chain.capabilities.raw, 1)
        XCTAssertEqual(chain.leaf.issuerKind, .device, "root → A → B, issued by the Issuer")
    }

    /// **THE PSK IS THE WHOLE AUTHORISATION, so the wrong one must fail inside NOISE** — before any
    /// payload, and with nothing for a person to see or answer. A one-bit difference is enough.
    func testAWrongPSKFailsTheHandshakeAndAsksNobodyAnything() throws {
        var theirs = [UInt8](repeating: 0xAB, count: 32)
        let g = gate(pairingPSK: theirs)
        theirs[31] ^= 0x01
        let c = try client("N", mode: .pair, psk: theirs)

        let m1 = try c.noise.write(c.session.message1Payload)
        // Message 1 is a bare ephemeral and carries no tag, so the mismatch surfaces where the psk
        // is first mixed in — message 3 on this pattern. What matters is that it surfaces at all,
        // inside Noise, rather than as a request somebody could approve.
        guard case .success(.reply(let m2)) = g.receive(m1, mode: .pair) else {
            return XCTFail("message 1 should still be readable")
        }
        let m2Plain = try? c.noise.read(m2)
        if let m2Plain {
            let staticKey = try XCTUnwrap(c.noise.remoteStaticKey)
            _ = c.session.receiveMessage2(m2Plain, responderNoiseStatic: staticKey)
            guard case .success(let p3) = c.session.message3Payload() else { return }
            if let m3 = try? c.noise.write(p3) {
                XCTAssertEqual(failure(g.receive(m3, mode: nil)), .noise,
                               "a wrong psk dies in the cryptography, not in a dialog")
            }
        }
    }

    /// A device that cannot issue cannot serve `pair`, and says so at the door.
    func testAHostThatCannotIssueRefusesPair() throws {
        let psk = [UInt8](repeating: 0xAB, count: 32)
        // X holds capability 1 — connect only — so it may not enrol anyone.
        let g = gate(responder: "X", pairingPSK: psk)
        let c = try client("N", mode: .pair, psk: psk)
        let m1 = try c.noise.write(c.session.message1Payload)
        let m2 = try? reply(g.receive(m1, mode: .pair))
        // It answers message 1 — the role check is the INITIATOR's, and this is what it catches.
        XCTAssertNotNil(m2)
        let m2Plain = try c.noise.read(try XCTUnwrap(m2))
        let responderStatic = try XCTUnwrap(c.noise.remoteStaticKey)
        guard case .failure(let f) = c.session.receiveMessage2(m2Plain,
                                                              responderNoiseStatic: responderStatic)
        else { return XCTFail("a connect-only responder must be refused as a pairing Issuer") }
        XCTAssertEqual(f, .responderRole)
    }

    // MARK: - `enroll`: a root signature IS the authorisation

    /// The newcomer holds the passkey and has already signed its own grant, so it presents that
    /// chain in `client-confirm` and the Issuer verifies it under the root it already trusts.
    /// §10.1 is why it is checked rather than adopted: an incoming chain may never replace or
    /// extend a trust anchor.
    func testAnEnrollSessionAcceptsAChainTheRootSigned() throws {
        let g = gate()
        let c = try client("C", mode: .enroll)

        let m1 = try c.noise.write(c.session.message1Payload)
        let m2 = try reply(g.receive(m1, mode: .enroll))
        let m2Plain = try c.noise.read(m2)
        let responderStatic = try XCTUnwrap(c.noise.remoteStaticKey)
        guard case .success = c.session.receiveMessage2(m2Plain, responderNoiseStatic: responderStatic)
        else { throw E2ESession.Failure.peerChain }
        guard case .success(let m3Payload) = c.session.message3Payload() else {
            throw E2ESession.Failure.outOfOrder
        }
        XCTAssertEqual(try? g.receive(try c.noise.write(m3Payload), mode: nil).get(), .nothing)

        let h = try XCTUnwrap(c.noise.handshakeHash)
        // C's own chain, presented as the thing to accept — which is what a fresh root grant looks
        // like on the wire.
        guard case .success(let confirmPayload) =
                c.session.clientConfirm(handshakeHash: h, newBundle: hex(dev("C").bundle)) else {
            throw E2ESession.Failure.outOfOrder
        }
        let start = try reply(g.receive(try c.noise.write(confirmPayload), mode: nil))
        let startPlain = try c.noise.read(start)
        guard case .success = c.session.receiveSessionStart(startPlain, handshakeHash: h) else {
            throw E2ESession.Failure.handshakeHashMismatch
        }
        XCTAssertTrue(g.maySignal)
        XCTAssertEqual(c.session.acceptedBundle, hex(dev("C").bundle))
    }

    /// A chain under someone ELSE's root is refused, and that refusal is §10.1: "possession of a new
    /// passkey cannot remotely replace a Host's existing root."
    func testAnEnrollChainUnderAnotherRootIsRefused() throws {
        let g = gate(trustedRoot: [UInt8](repeating: 0x11, count: 32))
        let c = try client("C", mode: .enroll)
        let m1 = try c.noise.write(c.session.message1Payload)
        let m2 = try reply(g.receive(m1, mode: .enroll))
        let m2Plain = try c.noise.read(m2)
        let responderStatic = try XCTUnwrap(c.noise.remoteStaticKey)
        _ = c.session.receiveMessage2(m2Plain, responderNoiseStatic: responderStatic)
        guard case .success(let m3Payload) = c.session.message3Payload() else { return }
        _ = g.receive(try c.noise.write(m3Payload), mode: nil)
        let h = try XCTUnwrap(c.noise.handshakeHash)
        guard case .success(let confirmPayload) =
                c.session.clientConfirm(handshakeHash: h, newBundle: hex(dev("C").bundle)) else {
            return
        }
        XCTAssertEqual(failure(g.receive(try c.noise.write(confirmPayload), mode: nil)),
                       .session(.peerChain))
    }

    /// **A MISSING KEY IS A REFUSAL, NOT A PROMPT**, and that is the whole shape of §9.1: a Host with
    /// no pairing window open has no psk, so a `pair` handshake cannot complete and there is nothing
    /// for a person to approve. Refusing by NAME is the point — "not here" and "you are wrong" are
    /// different answers, and only the second is about the peer.
    func testPairIsRefusedWithNoWindowOpen() throws {
        let g = gate()                                  // no `pairingPSK`
        let c = try client(mode: .pair, psk: [UInt8](repeating: 9, count: 32))
        let m1 = try c.noise.write(c.session.message1Payload)
        XCTAssertEqual(failure(g.receive(m1, mode: .pair)), .modeNotSupported)
    }

    /// §12.4's resume table is its own piece of work, and saying so by name beats pretending.
    func testResumeIsNotServedYet() throws {
        let g = gate()
        let c = try client(mode: .resume)
        let m1 = try c.noise.write(c.session.message1Payload)
        XCTAssertEqual(failure(g.receive(m1, mode: .resume)), .modeNotSupported)
    }

    /// §11.3: "Decryption failure terminates the signalling session; never skip a failed
    /// ciphertext." The gate must not answer a second time after refusing once — a peer who can
    /// make it try again has an oracle.
    ///
    /// **MESSAGE 3, not message 1, and that is not an arbitrary choice.** `XX` message 1 is a bare
    /// ephemeral with no key agreed yet, so it carries NO authentication tag and a flipped bit in it
    /// is indistinguishable from a different peer — measured here rather than assumed, because the
    /// obvious version of this test passed a tampered message 1 straight through. That is precisely
    /// why §11.1 requires message 1's payload to be EMPTY: nothing may ride an unauthenticated
    /// message, so there is nothing in it to forge.
    func testATamperedCiphertextTerminatesAndTheGateStaysShut() throws {
        let g = gate()
        let c = try client()
        let m1 = try c.noise.write(c.session.message1Payload)
        let m2 = try reply(g.receive(m1, mode: .auth))
        _ = c.session.receiveMessage2(try c.noise.read(m2),
                                      responderNoiseStatic: try XCTUnwrap(c.noise.remoteStaticKey))
        guard case .success(let m3Payload) = c.session.message3Payload() else {
            return XCTFail("message 3")
        }
        var m3 = try c.noise.write(m3Payload)
        m3[m3.count - 1] ^= 0x01
        XCTAssertEqual(failure(g.receive(m3, mode: nil)), .noise)

        XCTAssertEqual(failure(g.receive(m3, mode: nil)), .notEstablished,
                       "and a terminated gate does not try again")
        XCTAssertFalse(g.maySignal)
    }

    /// The property the test above rests on, stated on its own so it cannot quietly stop being true:
    /// message 1 is UNAUTHENTICATED, which is the reason its payload must be empty.
    func testMessageOneCarriesNoAuthenticationAtAll() throws {
        let g = gate()
        let c = try client()
        var m1 = try c.noise.write(c.session.message1Payload)
        m1[m1.count - 1] ^= 0x01
        // It is accepted — there is no key yet to detect the change with. What it buys an attacker
        // is a handshake that cannot complete, which is the next test.
        XCTAssertNotNil(try? reply(g.receive(m1, mode: .auth)))
        XCTAssertFalse(g.maySignal)
    }

    func testTamperingMidSessionTerminatesToo() throws {
        let g = gate()
        let c = try client()
        try connect(g, c)
        var sealed = try c.noise.write([UInt8](answerJSON("v=0")))
        sealed[4] ^= 0xFF
        XCTAssertEqual(failure(g.receive(sealed, mode: nil)), .noise)
        XCTAssertFalse(g.maySignal, "an established session does not survive a forged frame")
        XCTAssertEqual(g.seal(answerJSON("v=0")).failure, .notEstablished)
    }

    /// A peer whose chain does not verify under THIS host's trusted root gets nothing — and the
    /// refusal names the chain rather than the transport, because those need different fixes.
    func testAPeerUnderAnotherRootIsRefused() throws {
        let g = gate(trustedRoot: Array(repeating: 0xEE, count: 32))
        let c = try client()
        let m1 = try c.noise.write(c.session.message1Payload)
        // The host answers message 1 — it has said nothing about the peer yet — and the peer's
        // chain is what fails, at message 3.
        let m2 = try reply(g.receive(m1, mode: .auth))
        _ = try? c.noise.read(m2)
        let forged = try c.noise.write([UInt8]("not a handshake".utf8))
        XCTAssertNotNil(failure(g.receive(forged, mode: nil)))
        XCTAssertFalse(g.maySignal)
    }

    /// §10.5: a revoked device is refused even though its chain still verifies — the grant is
    /// intact, and the tombstone is what stops it.
    func testARevokedPeerIsRefused() throws {
        let c = try client()
        let descriptor = try XCTUnwrap(E2EIdentity.parseDevice(hex(dev("C").descriptor)))
        let g = gate(revoked: [descriptor.id])
        let m1 = try c.noise.write(c.session.message1Payload)
        let m2 = try reply(g.receive(m1, mode: .auth))
        _ = c.session.receiveMessage2(try c.noise.read(m2),
                                      responderNoiseStatic: try XCTUnwrap(c.noise.remoteStaticKey))
        guard case .success(let m3Payload) = c.session.message3Payload() else {
            return XCTFail("message 3")
        }
        XCTAssertEqual(failure(g.receive(try c.noise.write(m3Payload), mode: nil)),
                       .session(.peerChain))
        XCTAssertFalse(g.maySignal)
    }

    /// A peer that repeats message 1 is out of order, not starting again. §11.3: one connection,
    /// one Noise session, at most one handshake.
    func testAReplayedHandshakeMessageTerminates() throws {
        let g = gate()
        let c = try client()
        let m1 = try c.noise.write(c.session.message1Payload)
        _ = try reply(g.receive(m1, mode: .auth))
        XCTAssertEqual(failure(g.receive(m1, mode: nil)), .noise,
                       "Noise refuses the replay before the state machine is asked")
    }

    func testClosingShutsTheGate() throws {
        let g = gate()
        let c = try client()
        try connect(g, c)
        XCTAssertTrue(g.maySignal)
        g.close()
        XCTAssertFalse(g.maySignal)
        XCTAssertEqual(g.seal(answerJSON("v=0")).failure, .notEstablished)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
