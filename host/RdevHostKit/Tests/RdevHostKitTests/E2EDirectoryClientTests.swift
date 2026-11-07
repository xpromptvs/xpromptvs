import XCTest
@testable import RdevCore
@testable import RdevHostKit

/// §12.2's publication, driven through a fake directory.
///
/// Every DECISION is `E2EDirectory` and tested without a network. What is tested here is the
/// REQUEST — what is asked for, what is signed, and which answers mean what — and the one rule that
/// cannot live in either: **publication can never fail an enrollment**, so this returns a status and
/// nothing else, in every case.
final class E2EDirectoryClientTests: XCTestCase {

    private struct Device: Decodable { let signing_private_key: String, bundle: String }
    private struct Fixture: Decodable {
        let root_id: String
        let devices: [String: Device]
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

    /// A directory that answers from a script and records what was asked.
    private final class World: E2EDirectoryClient.Transport, @unchecked Sendable {
        var challengeAnswer: (Data, Int)? = nil
        /// Answers EVERY non-challenge request, whichever of the four actions it is.
        var answer: (Data, Int)? = nil
        private(set) var requests: [URLRequest] = []

        init(challenge: [UInt8]? = Array(repeating: 0x5C, count: 32)) {
            if let challenge {
                challengeAnswer = (try! JSONSerialization.data(withJSONObject: [
                    "challenge": base64urlEncode(Data(challenge)), "expires_in": 120,
                ]), 200)
            }
        }

        func send(_ request: URLRequest) async -> (Data, Int)? {
            requests.append(request)
            return request.url!.lastPathComponent == "challenge" ? challengeAnswer : answer
        }
    }

    private let origin = URL(string: "https://cp.example")!
    private var operationID: [UInt8] { hex(fx.operation_ids["zero"]!) }
    private var rootID: [UInt8] { hex(fx.root_id) }
    private var bundle: [UInt8] { hex(fx.devices["C"]!.bundle) }
    private var signingKey: [UInt8] { hex(fx.devices["C"]!.signing_private_key) }

    private func publish(_ world: World) async -> E2EWire.PublicationStatus {
        await E2EDirectoryClient(origin: origin, transport: world)
            .registerGrant(bundle: bundle, operationID: operationID, rootID: rootID,
                     signingPrivateKey: signingKey)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                        as? [String: Any])
    }

    // MARK: - the request

    /// The routes are keyed by `root_id`, and the challenge is asked for FIRST — §12.2 has the
    /// Worker consume it "before anything expensive", which only works if it is fresh per attempt.
    func testItAsksForAChallengeUnderThisRootThenRegisters() async throws {
        let world = World()
        world.answer = (Data("{}".utf8), 200)
        _ = await publish(world)

        XCTAssertEqual(world.requests.count, 2)
        let root = base64urlEncode(Data(rootID))
        XCTAssertEqual(world.requests[0].url?.path, "/directory/\(root)/challenge")
        XCTAssertEqual(world.requests[0].httpMethod, "POST")
        XCTAssertEqual(world.requests[1].url?.path, "/directory/\(root)/register")
    }

    /// §12.2: the device signs `LP(label) || LP(action) || challenge || root_id || operation_id ||
    /// H(payload)` with its CERTIFIED key — and the Worker rebuilds that body rather than trusting
    /// the one sent, so a signature over anything else proves only that someone signed something.
    func testTheSignatureIsOverTheBodyTheWorkerWillRebuild() async throws {
        let challenge = Array(repeating: 0xA7 as UInt8, count: 32)
        let world = World(challenge: challenge)
        world.answer = (Data("{}".utf8), 200)
        _ = await publish(world)

        let sent = try body(world.requests[1])
        XCTAssertEqual(sent["challenge"] as? String, base64urlEncode(Data(challenge)))
        XCTAssertEqual(sent["bundle"] as? String, base64urlEncode(Data(bundle)))

        let expected = try XCTUnwrap(E2EDirectory.requestBody(
            action: .register, challenge: challenge, rootID: rootID,
            operationID: operationID, payload: bundle))
        let signature = try XCTUnwrap(base64urlDecode(try XCTUnwrap(sent["signature"] as? String)))
        // The key the WORKER will use: the leaf of the bundle being registered, because a device
        // registering its own grant is the requester §12.2 names.
        guard case .success(let chain) = E2EVerify.verifyBundle(
                bundle, trustedRootID: rootID,
                policy: .init(rpID: "rdev.example", allowedOrigins: ["https://rdev.example"])) else {
            return XCTFail("the fixture bundle must verify")
        }
        let publicKey = chain.leafDevice.signingPublicKey
        XCTAssertTrue(E2EVerify.verifyEd25519(signature: signature, message: expected,
                                              publicKey: publicKey))
    }

    // MARK: - what each answer means

    func testAnAcknowledgementIsConfirmed() async {
        let world = World()
        world.answer = (Data("{\"status\":\"registered\"}".utf8), 200)
        let status = await publish(world)
        XCTAssertEqual(status, .confirmed)
    }


    /// §12.2: "A 409 carrying the SAME content is the idempotent success path, not a rejection."
    func testAConflictCarryingTheSameContentIsSuccess() async throws {
        let world = World()
        let record: [String: Any] = ["record": ["bundle": base64urlEncode(Data(bundle))]]
        world.answer = (try JSONSerialization.data(withJSONObject: record), 409)
        let status = await publish(world)
        XCTAssertEqual(status, .confirmed)
    }

    func testAConflictCarryingDifferentContentIsTerminal() async throws {
        let world = World()
        let record: [String: Any] = ["record": ["bundle": base64urlEncode(Data([1, 2, 3]))]]
        world.answer = (try JSONSerialization.data(withJSONObject: record), 409)
        let status = await publish(world)
        XCTAssertEqual(status, .rejected)
    }

    /// **A REPLY THAT DID NOT ARRIVE IS TRANSIENT**, and that is the whole reason the transport
    /// returns an OPTIONAL rather than a status code: `classify` reads an unrecognised code as
    /// terminal, so a transport reporting a failure as `0` would pause the retry job on every
    /// network hiccup.
    func testALostReplyIsUnconfirmedRatherThanRejected() async {
        let world = World()
        world.answer = nil
        let status = await publish(world)
        XCTAssertEqual(status, .unconfirmed)
    }

    /// §12.2 lists 404 as TRANSIENT because "a deployment may be in progress".
    func testTheTransientHTTPSetIsHonoured() async {
        for code in [404, 429, 500, 503] {
            let world = World()
            world.answer = (Data(), code)
            let status = await publish(world)
            XCTAssertEqual(status, .unconfirmed, "\(code)")
        }
        for code in [400, 401, 403, 422] {
            let world = World()
            world.answer = (Data(), code)
            let status = await publish(world)
            XCTAssertEqual(status, .rejected, "\(code)")
        }
    }

    // MARK: - before the request

    /// A challenge this device cannot get is silence, not a refusal — and it must not register
    /// without one, because the Worker consumes it as the only thing bounding how often an
    /// unauthorised caller can make it verify a chain.
    func testNoChallengeMeansNoRegistrationAndATransientStatus() async {
        let world = World(challenge: nil)
        let status = await publish(world)
        XCTAssertEqual(status, .unconfirmed)
        XCTAssertEqual(world.requests.count, 1, "it did not register without one")
    }

    func testAChallengeOfTheWrongWidthIsRefused() async throws {
        let world = World(challenge: Array(repeating: 0x01, count: 31))
        let status = await publish(world)
        XCTAssertEqual(status, .unconfirmed)
        XCTAssertEqual(world.requests.count, 1)
    }

    /// §12.2's deadline, on both requests: "a request that is neither answered nor refused has not
    /// failed", and without a bound it stalls enrollment indefinitely.
    func testBothRequestsCarryThePublishDeadline() async {
        let world = World()
        world.answer = (Data(), 200)
        _ = await publish(world)
        for request in world.requests {
            XCTAssertEqual(request.timeoutInterval, E2EDirectory.publishDeadlineSeconds)
        }
    }

    // MARK: - session discovery (the signed replacement for `PUT /account/sessions`)

    private var session: E2EDirectory.Session {
        .init(code: "AbCd1234", token: "fa9c2f01-7a5b-4c33-9f6d-0b1e2d3c4a5b", label: "studio mac")
    }

    private func publishSession(_ world: World) async -> E2EWire.PublicationStatus {
        await E2EDirectoryClient(origin: origin, transport: world)
            .publishSession(session, bundle: bundle, operationID: operationID, rootID: rootID,
                            signingPrivateKey: signingKey)
    }

    /// The same authorisation `register` uses, on a different route: a one-use challenge first, then
    /// a body signed by this device's certified key. **There is no bearer token anywhere** — that is
    /// the whole of what changed when OAuth accounts were removed.
    func testPublishingAsksForAChallengeThenPostsToPublish() async throws {
        let world = World()
        world.answer = (Data("{\"status\":\"published\"}".utf8), 200)
        let status = await publishSession(world)

        XCTAssertEqual(world.requests.count, 2)
        let root = base64urlEncode(Data(rootID))
        XCTAssertEqual(world.requests[0].url?.path, "/directory/\(root)/challenge")
        XCTAssertEqual(world.requests[1].url?.path, "/directory/\(root)/publish")
        XCTAssertEqual(status, .confirmed)
    }

    /// **The signature is over the CANONICAL payload, never over the JSON.** A JSON encoder's key
    /// order is not a contract, and the Worker rebuilds `directorySessionPayload` from the fields it
    /// parsed — so a device that signed its own serialisation would produce a signature the Worker
    /// could never reproduce, whatever the two agreed about content.
    func testTheSignatureCoversTheCanonicalSessionPayload() async throws {
        let challenge = Array(repeating: 0xA7 as UInt8, count: 32)
        let world = World(challenge: challenge)
        world.answer = (Data("{}".utf8), 200)
        _ = await publishSession(world)

        let sent = try body(world.requests[1])
        let payload = try XCTUnwrap(E2EDirectory.sessionPayload(session))
        let expected = try XCTUnwrap(E2EDirectory.requestBody(
            action: .publish, challenge: challenge, rootID: rootID, operationID: operationID,
            payload: payload))
        let signature = try XCTUnwrap(base64urlDecode(try XCTUnwrap(sent["signature"] as? String)))
        XCTAssertTrue(E2EVerify.verifyEd25519(
            signature: signature, message: expected,
            publicKey: try XCTUnwrap(E2EVerify.ed25519PublicKey(privateKey: signingKey))))

        // And it is NOT the `register` body — an action mixed up here would authorise the wrong
        // mutation under a signature that still verified.
        let asRegister = try XCTUnwrap(E2EDirectory.requestBody(
            action: .register, challenge: challenge, rootID: rootID, operationID: operationID,
            payload: payload))
        XCTAssertFalse(E2EVerify.verifyEd25519(
            signature: signature, message: asRegister,
            publicKey: try XCTUnwrap(E2EVerify.ed25519PublicKey(privateKey: signingKey))))
    }

    /// `device_id` is DERIVED BY THE WORKER from the verified chain. Sending one would be a field
    /// nobody consults, free to disagree with the chain that is actually authorising the request.
    func testThePublishedSessionCarriesNoDeviceID() async throws {
        let world = World()
        world.answer = (Data("{}".utf8), 200)
        _ = await publishSession(world)

        let sent = try body(world.requests[1])
        let payload = try XCTUnwrap(sent["session"] as? [String: Any])
        XCTAssertEqual(payload["code"] as? String, session.code)
        XCTAssertEqual(payload["token"] as? String, session.token)
        XCTAssertEqual(payload["label"] as? String, session.label)
        XCTAssertNil(payload["device_id"])
    }

    /// §12.2's transient/terminal split reaches the caller unchanged: a silent Worker is something a
    /// retry fixes, a refusal is not, and **neither can fail sharing** — both are statuses.
    func testPublishingClassifiesWhatCameBack() async throws {
        let silent = World()
        silent.answer = nil
        await AssertEqualAsync(await publishSession(silent), .unconfirmed)

        let refused = World()
        refused.answer = (Data("{}".utf8), 422)
        await AssertEqualAsync(await publishSession(refused), .rejected)

        let noChallenge = World(challenge: nil)
        await AssertEqualAsync(await publishSession(noChallenge), .unconfirmed)
    }

    /// Withdrawal signs over the room CODE, which is what the Worker rebuilds — and the room is
    /// named in the request so the Worker can check the publisher owns it.
    func testUnpublishingSignsOverTheCode() async throws {
        let challenge = Array(repeating: 0x3E as UInt8, count: 32)
        let world = World(challenge: challenge)
        world.answer = (Data("{\"status\":\"unpublished\"}".utf8), 200)
        let status = await E2EDirectoryClient(origin: origin, transport: world)
            .unpublishSession(code: session.code, bundle: bundle, operationID: operationID,
                              rootID: rootID, signingPrivateKey: signingKey)

        XCTAssertEqual(status, .confirmed)
        XCTAssertEqual(world.requests[1].url?.lastPathComponent, "unpublish")
        let sent = try body(world.requests[1])
        XCTAssertEqual(sent["code"] as? String, session.code)

        let expected = try XCTUnwrap(E2EDirectory.requestBody(
            action: .unpublish, challenge: challenge, rootID: rootID, operationID: operationID,
            payload: Array(session.code.utf8)))
        let signature = try XCTUnwrap(base64urlDecode(try XCTUnwrap(sent["signature"] as? String)))
        XCTAssertTrue(E2EVerify.verifyEd25519(
            signature: signature, message: expected,
            publicKey: try XCTUnwrap(E2EVerify.ed25519PublicKey(privateKey: signingKey))))
    }

    private func AssertEqualAsync(_ got: E2EWire.PublicationStatus,
                                  _ want: E2EWire.PublicationStatus,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(got, want, file: file, line: line)
    }
}
