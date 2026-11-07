import XCTest
@testable import RdevCore

/// The §11 session state machine, driven through complete handshakes against the world a THIRD
/// implementation produced (`scripts/gen_e2e_session_fixture.py`) and which
/// `protocol/test/e2e-session.test.ts` drives too.
///
/// THE GATE IS THE SUBJECT. §11.2: "Before this gate ... No SDP, ICE, media, shell, input, or
/// subscription authority exists yet." Every test below either walks a session to that point or
/// proves something stops it.
final class E2ESessionTests: XCTestCase {

    private struct Device: Decodable {
        let name: String
        let signing_private_key: String, signing_public_key: String, noise_public_key: String
        let descriptor: String, device_id: String
        let bundle: String
    }
    private struct Route: Decodable { let rcode: String, rtoken: String }
    private struct Fixture: Decodable {
        let rp_id: String, allowed_origins: [String], root: String, root_id: String
        let devices: [String: Device]
        let routes: [String: Route]
        let operation_ids: [String: String]
        let handshake_hashes: [String: String]
    }

    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-session.json")
        // A fixture that will not load is a suite that asserts nothing; fail loudly and at once.
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
    private func noise(_ n: String) -> [UInt8] { hex(dev(n).noise_public_key) }

    private var policy: E2EVerify.Policy {
        .init(rpID: fx.rp_id, allowedOrigins: fx.allowed_origins)
    }
    private var hA: [UInt8] { hex(fx.handshake_hashes["a"]!) }
    private var hB: [UInt8] { hex(fx.handshake_hashes["b"]!) }
    private var zero: [UInt8] { hex(fx.operation_ids["zero"]!) }
    private var enrollment: [UInt8] { hex(fx.operation_ids["enrollment"]!) }

    private func responderConfig(_ name: String, _ mode: E2EWire.Mode,
                                 route: String? = nil,
                                 revoked: Set<[UInt8]> = []) -> E2ESession.ResponderConfig {
        let r = fx.routes[route ?? name] ?? fx.routes["H"]!
        return .init(mode: mode, roomCode: "room-1", device: hex(dev(name).descriptor),
                     bundle: hex(dev(name).bundle),
                     route: RendezvousRoute(rcode: r.rcode, rtoken: r.rtoken),
                     trustedRootID: hex(fx.root_id), policy: policy, revokedDeviceIDs: revoked)
    }

    private func initiatorConfig(_ name: String, _ mode: E2EWire.Mode,
                                 bundle: [UInt8]? = nil, operationID: [UInt8]? = nil,
                                 trustedRootID: [UInt8]?? = nil, signingKey: [UInt8]? = nil,
                                 revoked: Set<[UInt8]> = [],
                                 expectedResponder: [UInt8]? = nil) -> E2ESession.InitiatorConfig {
        // **In `pair` a newcomer has KEYS and no descriptor**, because §10.2's descriptor names its
        // root and §12.3 puts learning that root AFTER message 2. Everywhere else it has one.
        return .init(mode: mode, roomCode: "room-1",
              device: mode == .pair ? [] : hex(dev(name).descriptor),
              signingPrivateKey: signingKey ?? hex(dev(name).signing_private_key),
              bundle: bundle ?? (mode == .auth ? hex(dev(name).bundle) : []),
              operationID: operationID ?? (mode == .auth ? zero : enrollment),
              trustedRootID: trustedRootID ?? hex(fx.root_id), policy: policy,
              revokedDeviceIDs: revoked, expectedResponderDeviceID: expectedResponder,
              devicePublicKeys: mode == .pair
                  ? (hex(dev(name).signing_public_key), hex(dev(name).noise_public_key)) : nil)
    }

    private func code<T>(_ r: Result<T, E2ESession.Failure>) -> String {
        switch r {
        case .success: return "ok"
        case .failure(let f): return f.rawValue
        }
    }

    /// FAILS, never skips. The first version threw `XCTSkip`, which XCTest reports as a pass —
    /// so a step that quietly stopped working would have turned a whole handshake test into a
    /// no-op that still looked green. A skipped test asserts nothing.
    private struct Unexpected: Error { let code: String }

    private func value<T>(_ r: Result<T, E2ESession.Failure>,
                          _ file: StaticString = #filePath,
                          _ line: UInt = #line) throws -> T {
        switch r {
        case .success(let v):
            return v
        case .failure(let f):
            XCTFail("expected ok, got \(f.rawValue)", file: file, line: line)
            throw Unexpected(code: f.rawValue)
        }
    }

    // MARK: - a complete auth

    private struct Run {
        var responder: E2ESession.Responder
        var initiator: E2ESession.Initiator
        var steps: [String: String] = [:]
    }

    /// One complete `auth`: C (code-enrolled, capabilities 3) connecting to H (the Host).
    private func runAuth(initiator initiatorOver: E2ESession.InitiatorConfig? = nil,
                         responder responderOver: E2ESession.ResponderConfig? = nil,
                         confirmHash: [UInt8]? = nil, startHash: [UInt8]? = nil,
                         acceptedBundle: [UInt8] = []) throws -> Run {
        var run = Run(responder: .init(responderOver ?? responderConfig("H", .auth)),
                      initiator: try XCTUnwrap(E2ESession.Initiator(
                          initiatorOver ?? initiatorConfig("C", .auth))))

        run.steps["message1"] = code(run.responder.receiveMessage1(run.initiator.message1Payload))
        let m2 = run.responder.message2Payload()
        run.steps["message2"] = code(m2)
        guard case .success(let message2) = m2 else { return run }

        run.steps["receiveMessage2"] = code(run.initiator.receiveMessage2(message2,
                                                                          responderNoiseStatic: noise("H")))
        let m3 = run.initiator.message3Payload()
        run.steps["message3"] = code(m3)
        guard case .success(let message3) = m3 else { return run }

        run.steps["receiveMessage3"] = code(run.responder.receiveMessage3(message3,
                                                                          initiatorNoiseStatic: noise("C")))
        let confirm = run.initiator.clientConfirm(handshakeHash: confirmHash ?? hA)
        run.steps["clientConfirm"] = code(confirm)
        guard case .success(let confirmBytes) = confirm else { return run }

        run.steps["receiveConfirm"] = code(run.responder.receiveClientConfirm(confirmBytes,
                                                                              handshakeHash: hA))
        let start = run.responder.sessionStart(handshakeHash: startHash ?? hA, status: .confirmed,
                                               acceptedBundle: acceptedBundle)
        run.steps["sessionStart"] = code(start)
        guard case .success(let startBytes) = start else { return run }

        run.steps["receiveSessionStart"] = code(run.initiator.receiveSessionStart(startBytes,
                                                                                  handshakeHash: hA))
        return run
    }

    func testACompleteAuthSessionEstablishesBothEnds() throws {
        let run = try runAuth()
        XCTAssertEqual(run.steps, [
            "message1": "ok", "message2": "ok", "receiveMessage2": "ok", "message3": "ok",
            "receiveMessage3": "ok", "clientConfirm": "ok", "receiveConfirm": "ok",
            "sessionStart": "ok", "receiveSessionStart": "ok",
        ])
        XCTAssertTrue(run.responder.isEstablished)
        XCTAssertTrue(run.initiator.isEstablished)
        XCTAssertEqual(run.responder.initiatorChain?.leaf.capabilities.raw, 3)
        // §9.2: persisting the route "permits resume after a lost acknowledgement".
        XCTAssertEqual(run.initiator.responderRoute?.rcode, fx.routes["H"]!.rcode)
        XCTAssertEqual(run.initiator.responderRoute?.rtoken, fx.routes["H"]!.rtoken)
    }

    /// §11.2's gate, asserted as a property of EVERY intermediate state rather than only of the end.
    /// A machine that set `maySignal` one step early would still pass the happy path above.
    func testNothingMaySignalBeforeTheGate() throws {
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        var initiator = try XCTUnwrap(E2ESession.Initiator(initiatorConfig("C", .auth)))
        var seen: [Bool] = []
        func watch() { seen.append(responder.maySignal); seen.append(initiator.maySignal) }

        watch()
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        watch()
        let m2 = try value(responder.message2Payload())
        _ = try value(initiator.receiveMessage2(m2, responderNoiseStatic: noise("H")))
        watch()
        let m3 = try value(initiator.message3Payload())
        _ = try value(responder.receiveMessage3(m3, initiatorNoiseStatic: noise("C")))
        watch()
        let confirm = try value(initiator.clientConfirm(handshakeHash: hA))
        watch()                              // the initiator has SENT its proof and still may not

        XCTAssertEqual(seen, Array(repeating: false, count: 10))

        _ = try value(responder.receiveClientConfirm(confirm, handshakeHash: hA))
        // The responder is through its gate here; the initiator is not, and that asymmetry is the
        // protocol's — §11.2 gives the initiator its own verification of `session-start`.
        XCTAssertTrue(responder.maySignal)
        XCTAssertFalse(initiator.maySignal)

        let start = try value(responder.sessionStart(handshakeHash: hA, status: .confirmed,
                                                     acceptedBundle: []))
        _ = try value(initiator.receiveSessionStart(start, handshakeHash: hA))
        XCTAssertTrue(initiator.maySignal)
    }

    // MARK: - §11.1's role table

    func testAConnectOnlyResponderMayNotHostAnAuth() throws {
        // X holds capabilities 1. Its chain is perfectly valid and it is the right root — the only
        // thing wrong is that it has no business being the Host.
        var responder = E2ESession.Responder(responderConfig("X", .auth))
        var initiator = try XCTUnwrap(E2ESession.Initiator(initiatorConfig("C", .auth)))
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        let m2 = try value(responder.message2Payload())
        XCTAssertEqual(code(initiator.receiveMessage2(m2, responderNoiseStatic: noise("X"))),
                       "responder-role")
    }

    func testAPairResponderMustHoldADirectGrantWithEnroll() throws {
        // C carries capabilities 3 and is device-issued: it can never carry `enroll` (§10.3), so it
        // can never be a pairing Issuer however the interface presents it.
        var responder = E2ESession.Responder(responderConfig("C", .pair, route: "H"))
        var initiator = try XCTUnwrap(E2ESession.Initiator(
            initiatorConfig("N", .pair, trustedRootID: .some(nil))))
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        let m2 = try value(responder.message2Payload())
        XCTAssertEqual(code(initiator.receiveMessage2(m2, responderNoiseStatic: noise("C"))),
                       "responder-role")
    }

    func testTheRoleTableItself() throws {
        func chain(_ name: String) throws -> E2EVerify.VerifiedChain {
            switch E2EVerify.verifyBundle(hex(dev(name).bundle), trustedRootID: hex(fx.root_id),
                                          policy: policy) {
            case .success(let c):
                return c
            case .failure(let f):
                XCTFail("fixture bundle \(name): \(f.rawValue)")
                throw Unexpected(code: f.rawValue)
            }
        }
        for mode in [E2EWire.Mode.pair, .enroll, .auth] {
            XCTAssertTrue(E2ESession.responderSatisfiesRole(mode: mode, chain: try chain("H")),
                          "\(mode) H")
            XCTAssertFalse(E2ESession.responderSatisfiesRole(mode: mode, chain: try chain("X")),
                           "\(mode) X")
        }
        // `resume` asks nothing of the role here: §11.1 defers it to the original operation.
        XCTAssertTrue(E2ESession.responderSatisfiesRole(mode: .resume, chain: try chain("X")))
    }

    // MARK: - §11.1's bundle rules

    func testBundlePresenceTable() {
        XCTAssertFalse(E2ESession.bundlePresenceIsCorrect(mode: .auth, bundleIsEmpty: true))
        XCTAssertTrue(E2ESession.bundlePresenceIsCorrect(mode: .auth, bundleIsEmpty: false))
        for mode in [E2EWire.Mode.pair, .enroll] {
            XCTAssertTrue(E2ESession.bundlePresenceIsCorrect(mode: mode, bundleIsEmpty: true))
            XCTAssertFalse(E2ESession.bundlePresenceIsCorrect(mode: mode, bundleIsEmpty: false))
        }
        XCTAssertTrue(E2ESession.bundlePresenceIsCorrect(mode: .resume, bundleIsEmpty: true))
        XCTAssertTrue(E2ESession.bundlePresenceIsCorrect(mode: .resume, bundleIsEmpty: false))
    }

    /// **A `pair` newcomer needs its keys at CONSTRUCTION, and everything else needs a descriptor.**
    /// Refused here rather than three messages in, where the failure would be a `malformed` payload
    /// naming neither the missing input nor the mode that wanted it.
    func testTheDescriptorAndTheKeysAreRequiredByOppositeModes() {
        // `pair` with no keys: it could never name itself after adopting the root.
        XCTAssertNil(E2ESession.Initiator(.init(
            mode: .pair, roomCode: "room-1", device: [],
            signingPrivateKey: hex(dev("N").signing_private_key), bundle: [],
            operationID: enrollment, trustedRootID: nil, policy: policy,
            devicePublicKeys: nil)))
        // `auth` with no descriptor: there is a root already, so there is nothing to wait for.
        XCTAssertNil(E2ESession.Initiator(.init(
            mode: .auth, roomCode: "room-1", device: [],
            signingPrivateKey: hex(dev("C").signing_private_key), bundle: hex(dev("C").bundle),
            operationID: zero, trustedRootID: hex(fx.root_id), policy: policy)))
    }

    /// The descriptor a `pair` newcomer presents is built from the root it just ADOPTED — which is
    /// the ordering §12.3 spells out, and the thing a fixture descriptor cannot demonstrate because
    /// it already names the right root.
    func testAPairNewcomerNamesItselfAfterAdoptingTheRoot() throws {
        var initiator = try XCTUnwrap(E2ESession.Initiator(
            initiatorConfig("N", .pair, trustedRootID: .some(nil))))
        var responder = E2ESession.Responder(responderConfig("H", .pair))
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        let m2 = try value(responder.message2Payload())
        _ = try value(initiator.receiveMessage2(m2, responderNoiseStatic: noise("H")))

        let hello = try XCTUnwrap(E2EWire.parseInitiatorHello(
            try value(initiator.message3Payload())))
        XCTAssertEqual(hello.device, hex(dev("N").descriptor),
                       "assembled from the adopted root and this device's keys")
    }

    func testAPairInitiatorThatShipsABundleIsRefusedBeforeItSendsOne() throws {
        var initiator = try XCTUnwrap(E2ESession.Initiator(
            initiatorConfig("C", .pair, bundle: hex(dev("C").bundle), trustedRootID: .some(nil))))
        var responder = E2ESession.Responder(responderConfig("H", .pair))
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        let m2 = try value(responder.message2Payload())
        _ = try value(initiator.receiveMessage2(m2, responderNoiseStatic: noise("H")))
        XCTAssertEqual(code(initiator.message3Payload()), "bundle-presence")
    }

    func testAnAuthWithNoBundleIsRefused() throws {
        let run = try runAuth(initiator: initiatorConfig("C", .auth, bundle: []))
        XCTAssertEqual(run.steps["message3"], "bundle-presence")
    }

    // MARK: - the descriptor must be the peer the handshake authenticated

    func testADescriptorWhoseDHKeyIsNotTheNoiseStaticIsRefused() throws {
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        var initiator = try XCTUnwrap(E2ESession.Initiator(initiatorConfig("C", .auth)))
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        let m2 = try value(responder.message2Payload())
        _ = try value(initiator.receiveMessage2(m2, responderNoiseStatic: noise("H")))
        let m3 = try value(initiator.message3Payload())
        // C's own descriptor, presented over a handshake that authenticated X's key.
        XCTAssertEqual(code(responder.receiveMessage3(m3, initiatorNoiseStatic: noise("X"))),
                       "descriptor-key-mismatch")
    }

    func testAResponderChainBoundToAnotherDevicesKeyIsRefused() throws {
        var initiator = try XCTUnwrap(E2ESession.Initiator(initiatorConfig("C", .auth)))
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        let m2 = try value(responder.message2Payload())
        XCTAssertEqual(code(initiator.receiveMessage2(m2, responderNoiseStatic: noise("C"))),
                       "peer-chain")
    }

    func testASelectedHostThatAnswersWithADifferentDeviceIsRefused() throws {
        var initiator = try XCTUnwrap(E2ESession.Initiator(
            initiatorConfig("C", .auth, expectedResponder: hex(dev("X").device_id))))
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        let m2 = try value(responder.message2Payload())
        XCTAssertEqual(code(initiator.receiveMessage2(m2, responderNoiseStatic: noise("H"))),
                       "responder-not-selected")
    }

    // MARK: - the device proof is about THIS session

    func testAProofBodyNamingADifferentHandshakeIsRefused() throws {
        // The initiator signs over hB; the responder composes the body from hA. The SIGNATURE is
        // perfectly valid — what fails is that it is a statement about a different session.
        let run = try runAuth(confirmHash: hB)
        XCTAssertEqual(run.steps["receiveConfirm"], "proof-body-mismatch")
    }

    func testTheResponderRebuildsTheBodyRatherThanTrustingTheOneItWasSent() throws {
        // Swap the signing key so the SIGNATURE is wrong while the body is right, and confirm a
        // DIFFERENT failure. If the responder verified the supplied body, both cases would look
        // alike — and a body naming another session would verify.
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        var initiator = try XCTUnwrap(E2ESession.Initiator(
            initiatorConfig("C", .auth, signingKey: hex(dev("X").signing_private_key))))
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        let m2 = try value(responder.message2Payload())
        _ = try value(initiator.receiveMessage2(m2, responderNoiseStatic: noise("H")))
        let m3 = try value(initiator.message3Payload())
        _ = try value(responder.receiveMessage3(m3, initiatorNoiseStatic: noise("C")))
        let confirm = try value(initiator.clientConfirm(handshakeHash: hA))
        XCTAssertEqual(code(responder.receiveClientConfirm(confirm, handshakeHash: hA)),
                       "proof-signature")
    }

    // MARK: - session-start must answer THIS session

    func testADifferentHandshakeHashInSessionStartIsRefused() throws {
        let run = try runAuth(startHash: hB)
        XCTAssertEqual(run.steps["receiveSessionStart"], "handshake-hash-mismatch")
    }

    func testAnAcceptedChainForAnotherDeviceIsRefused() throws {
        // H's own perfectly valid bundle, returned to C. Every signature verifies; it is not C's.
        let run = try runAuth(acceptedBundle: hex(dev("H").bundle))
        XCTAssertEqual(run.steps["receiveSessionStart"], "accepted-chain-mismatch")
    }

    /// THE CASE THAT MADE THE DEVICE-EQUALITY CHECK NON-REDUNDANT. Y holds C's NOISE key with a
    /// different signing key, so its chain satisfies "the leaf's DH key is the static this session
    /// authenticated" — and carries capabilities 7 against C's 3. Nothing but comparing the
    /// descriptor itself separates them, and a mutation removing that comparison passed the whole
    /// suite until this device existed.
    func testAnAcceptedChainThatMerelySharesThisDevicesDHKeyIsRefused() throws {
        XCTAssertEqual(dev("Y").noise_public_key, dev("C").noise_public_key)
        XCTAssertNotEqual(dev("Y").signing_public_key, dev("C").signing_public_key)
        let run = try runAuth(acceptedBundle: hex(dev("Y").bundle))
        XCTAssertEqual(run.steps["receiveSessionStart"], "accepted-chain-mismatch")
    }

    func testAResponderRefusesAMessage3ChainThatMerelySharesThePeersDHKey() throws {
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        var initiator = try XCTUnwrap(E2ESession.Initiator(
            initiatorConfig("C", .auth, bundle: hex(dev("Y").bundle))))
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        let m2 = try value(responder.message2Payload())
        _ = try value(initiator.receiveMessage2(m2, responderNoiseStatic: noise("H")))
        let m3 = try value(initiator.message3Payload())
        XCTAssertEqual(code(responder.receiveMessage3(m3, initiatorNoiseStatic: noise("C"))),
                       "peer-chain")
    }

    func testAnOrdinaryAuthCarriesAnAllZeroOperationID() throws {
        let run = try runAuth(initiator: initiatorConfig("C", .auth, operationID: enrollment))
        XCTAssertEqual(run.steps["receiveMessage3"], "operation-id-mismatch")
    }

    // MARK: - pair bootstraps its root; nothing else may

    func testANewcomerWithNoTrustedRootCompletesAPair() throws {
        var responder = E2ESession.Responder(responderConfig("H", .pair))
        var initiator = try XCTUnwrap(E2ESession.Initiator(
            initiatorConfig("N", .pair, bundle: [], trustedRootID: .some(nil))))
        _ = try value(responder.receiveMessage1(initiator.message1Payload))
        let m2 = try value(responder.message2Payload())
        _ = try value(initiator.receiveMessage2(m2, responderNoiseStatic: noise("H")))
        let m3 = try value(initiator.message3Payload())
        _ = try value(responder.receiveMessage3(m3, initiatorNoiseStatic: noise("N")))
        let confirm = try value(initiator.clientConfirm(handshakeHash: hA))
        _ = try value(responder.receiveClientConfirm(confirm, handshakeHash: hA))
        XCTAssertTrue(responder.maySignal)
        // §10.1: the root the newcomer adopted is the Issuer's, learned through the PSK-authenticated
        // exchange and nowhere else.
        XCTAssertEqual(initiator.responderChain?.root.bytes, hex(fx.root))
    }

    func testAuthEnrollAndResumeRefuseToBeBuiltWithoutATrustedRoot() {
        for mode in [E2EWire.Mode.auth, .enroll, .resume] {
            XCTAssertNil(E2ESession.Initiator(initiatorConfig("C", mode, trustedRootID: .some(nil))),
                         "\(mode)")
        }
        XCTAssertNotNil(E2ESession.Initiator(initiatorConfig("N", .pair, trustedRootID: .some(nil))))
    }

    // MARK: - §11.3: one handshake, and a failure is terminal

    func testMessage1MayNotCarryAPayload() {
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        XCTAssertEqual(code(responder.receiveMessage1([0])), "message1-not-empty")
        XCTAssertEqual(responder.stage, .terminated)
    }

    func testASecondMessage1IsOutOfOrder() throws {
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        _ = try value(responder.receiveMessage1([]))
        XCTAssertEqual(code(responder.receiveMessage1([])), "out-of-order")
    }

    func testEveryRefusalTerminatesAndATerminatedSessionAcceptsNothing() {
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        XCTAssertEqual(code(responder.receiveMessage1([1])), "message1-not-empty")
        XCTAssertEqual(code(responder.message2Payload()), "out-of-order")
        XCTAssertEqual(code(responder.receiveMessage3([], initiatorNoiseStatic: noise("C"))),
                       "out-of-order")
        XCTAssertEqual(code(responder.receiveClientConfirm([], handshakeHash: hA)), "out-of-order")
        XCTAssertFalse(responder.maySignal)
    }

    func testTerminateIsOneWay() throws {
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        _ = try value(responder.receiveMessage1([]))
        responder.terminate()
        XCTAssertEqual(code(responder.message2Payload()), "out-of-order")
        XCTAssertFalse(responder.maySignal)
    }

    func testTheInitiatorCannotConfirmBeforeItsPeersChainHasVerified() throws {
        var initiator = try XCTUnwrap(E2ESession.Initiator(initiatorConfig("C", .auth)))
        XCTAssertEqual(code(initiator.clientConfirm(handshakeHash: hA)), "out-of-order")
        XCTAssertEqual(code(initiator.message3Payload()), "out-of-order")
    }

    func testSessionStartIsUnreachableUntilTheResponderIsThroughItsGate() throws {
        var responder = E2ESession.Responder(responderConfig("H", .auth))
        _ = try value(responder.receiveMessage1([]))
        XCTAssertEqual(code(responder.sessionStart(handshakeHash: hA, status: .confirmed,
                                                   acceptedBundle: [])), "out-of-order")
    }

    /// §10.5: "Reject any chain containing a tombstoned device, including an Issuer." H is C's
    /// Issuer, so revoking H kills C's chain as well as H's own.
    func testARevokedPeerCannotCompleteASession() throws {
        let asLeaf = try runAuth(responder: responderConfig("H", .auth,
                                                            revoked: [hex(dev("C").device_id)]))
        XCTAssertEqual(asLeaf.steps["receiveMessage3"], "peer-chain")

        let asIssuer = try runAuth(initiator: initiatorConfig("C", .auth,
                                                              revoked: [hex(dev("H").device_id)]))
        XCTAssertEqual(asIssuer.steps["receiveMessage2"], "peer-chain")
    }
}
