import XCTest
@testable import RdevCore

/// §12's directory contract. The encodings are held to vectors a THIRD implementation produced
/// (`scripts/gen_e2e_directory_fixture.py`); the rules are §12.2's and §12.4's own tables, and
/// `protocol/test/e2e-directory.test.ts` asserts all of it too.
final class E2EDirectoryTests: XCTestCase {

    private struct Case: Decodable {
        let name: String, kind: String, encoded: String
        let action: String?, challenge: String?, root_id: String?, operation_id: String?
        let payload: String?, payload_hash: String?
        let code: String?, token: String?, label: String?, device_id: String?
    }
    private struct Fixture: Decodable {
        let challenge_length: Int, challenge_max_age_seconds: Int
        let publish_deadline_seconds: Double, revoke_deadline_seconds: Double
        let rejected_wording: String
        let cases: [Case]
    }

    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-directory.json")
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

    // MARK: - §12.2's signed request body

    private var requestCases: [Case] { fx.cases.filter { $0.kind == "directory_request" } }
    private var sessionCases: [Case] { fx.cases.filter { $0.kind == "directory_session" } }

    func testMatchesTheCrossImplementationVectors() throws {
        XCTAssertFalse(requestCases.isEmpty, "an empty fixture would assert nothing")
        for c in requestCases {
            let action = try XCTUnwrap(E2EDirectory.Action(rawValue: try XCTUnwrap(c.action)), c.name)
            let body = try XCTUnwrap(E2EDirectory.requestBody(
                action: action, challenge: hex(c.challenge!), rootID: hex(c.root_id!),
                operationID: hex(c.operation_id!), payload: hex(c.payload!)))
            XCTAssertEqual(hex(body), c.encoded, c.name)

            let parsed = try XCTUnwrap(E2EDirectory.parseRequestBody(hex(c.encoded)), c.name)
            XCTAssertEqual(parsed.action, action, c.name)
            XCTAssertEqual(hex(parsed.challenge), c.challenge, c.name)
            XCTAssertEqual(hex(parsed.rootID), c.root_id, c.name)
            XCTAssertEqual(hex(parsed.operationID), c.operation_id, c.name)
            // The PAYLOAD is not in the body; its hash is. That is what keeps the signed statement
            // a fixed size whatever the bundle weighs.
            XCTAssertEqual(hex(parsed.payloadHash), c.payload_hash, c.name)
        }
    }

    /// **EVERY action, not a subset.** The TypeScript parser hardcoded `register` while its builder
    /// accepted four, so a well-formed `publish` body round-tripped to nil — a disagreement about
    /// the vocabulary that no caller had yet exercised. The fixture is what stops either side
    /// drifting again.
    func testTheFixtureExercisesEveryAction() {
        XCTAssertEqual(Set(requestCases.compactMap(\.action)),
                       Set(E2EDirectory.Action.allCases.map(\.rawValue)))
    }

    /// The payload `publish` signs over. Canonical, because a JSON encoder's key order is not a
    /// contract and two implementations that disagree about it produce a signature neither can check.
    func testTheSessionPayloadMatchesTheThirdImplementation() throws {
        XCTAssertFalse(sessionCases.isEmpty)
        for c in sessionCases {
            let payload = try XCTUnwrap(E2EDirectory.sessionPayload(.init(
                code: try XCTUnwrap(c.code), token: try XCTUnwrap(c.token),
                label: try XCTUnwrap(c.label), deviceID: try XCTUnwrap(c.device_id))), c.name)
            XCTAssertEqual(hex(payload), c.encoded, c.name)
        }
    }

    /// FOR ONE ACTION. Across actions the body differs only by the action's own name, so the two
    /// `register` cases — one with a 40-byte bundle, one with nothing — are what this is about.
    func testTheBodyIsTheSameSizeWhateverThePayloadWeighs() {
        let registers = requestCases.filter { $0.action == "register" }
        XCTAssertGreaterThan(registers.count, 1)
        let sizes = Set(registers.map { hex($0.encoded).count })
        XCTAssertEqual(sizes.count, 1)
        XCTAssertEqual(sizes.first, 161)
    }

    func testWrongWidthFieldsAreRefused() {
        let ok = Array(repeating: UInt8(0), count: 32)
        XCTAssertNotNil(E2EDirectory.requestBody(action: .register, challenge: ok, rootID: ok,
                                                 operationID: ok, payload: []))
        XCTAssertNil(E2EDirectory.requestBody(action: .register, challenge: Array(ok.dropLast()),
                                              rootID: ok, operationID: ok, payload: []))
        XCTAssertNil(E2EDirectory.requestBody(action: .register, challenge: ok,
                                              rootID: Array(ok.dropLast()), operationID: ok,
                                              payload: []))
        XCTAssertNil(E2EDirectory.requestBody(action: .register, challenge: ok, rootID: ok,
                                              operationID: ok + [0], payload: []))
    }

    func testTrailingBytesAndAnUnknownActionAreRefused() throws {
        let ok = Array(repeating: UInt8(0), count: 32)
        let good = try XCTUnwrap(E2EDirectory.requestBody(action: .register, challenge: ok,
                                                          rootID: ok, operationID: ok, payload: []))
        XCTAssertNotNil(E2EDirectory.parseRequestBody(good))
        XCTAssertNil(E2EDirectory.parseRequestBody(good + [0]))
        XCTAssertNil(E2EDirectory.parseRequestBody(Array(good.dropLast())))

        // "revoke" is deliberately NOT an action here: §12.2 says the WebAuthn-signed revocation
        // authorizes its own idempotent submission and needs no device authority.
        var revoke = good
        revoke.replaceSubrange(25 ..< 33, with: Array("revoke!!".utf8))
        XCTAssertNil(E2EDirectory.parseRequestBody(revoke))
        XCTAssertEqual(E2EDirectory.Action.allCases.map(\.rawValue),
                       ["register", "publish", "unpublish", "list", "subscribe"])
    }

    // MARK: - §12.2's transient/terminal table

    func testTheTransientTerminalTable() {
        let table: [(E2EDirectory.Response, E2EWire.PublicationStatus, String)] = [
            (.acknowledged, .confirmed, "a plain acknowledgement"),
            (.conflictSameContent, .confirmed, "409 with the SAME content"),
            (.noReply, .unconfirmed, "nothing came back"),
            (.conflictDifferentContent, .rejected, "409, DIFFERENT content"),
            (.httpStatus(200), .confirmed, "200"),
            (.httpStatus(204), .confirmed, "204"),
            (.httpStatus(404), .unconfirmed, "404 — a deploy in progress"),
            (.httpStatus(429), .unconfirmed, "429"),
            (.httpStatus(500), .unconfirmed, "500"),
            (.httpStatus(503), .unconfirmed, "503"),
            (.httpStatus(400), .rejected, "400 malformed"),
            (.httpStatus(401), .rejected, "401 refused"),
            (.httpStatus(403), .rejected, "403 refused"),
            (.httpStatus(422), .rejected, "422 invalid chain"),
            (.httpStatus(409), .rejected, "a bare 409, content uncompared"),
        ]
        for (response, want, why) in table {
            XCTAssertEqual(E2EDirectory.classify(response), want, why)
        }
    }

    /// The two rules most likely to be "tidied" into something that looks more sensible.
    func testFourZeroFourIsTransientAndAMatching409IsSuccess() {
        XCTAssertTrue(E2EDirectory.retriesAutomatically(E2EDirectory.classify(.httpStatus(404))))
        XCTAssertEqual(E2EDirectory.classify(.conflictSameContent), .confirmed)
        XCTAssertNotEqual(E2EDirectory.classify(.conflictDifferentContent), .confirmed)
    }

    func testRetryAndSurfacingPolicies() {
        XCTAssertTrue(E2EDirectory.retriesAutomatically(.unconfirmed))
        XCTAssertFalse(E2EDirectory.retriesAutomatically(.rejected))
        XCTAssertFalse(E2EDirectory.retriesAutomatically(.confirmed))
        XCTAssertFalse(E2EDirectory.mustSurface(.confirmed))
        XCTAssertTrue(E2EDirectory.mustSurface(.unconfirmed))
        XCTAssertTrue(E2EDirectory.mustSurface(.rejected))
    }

    func testTheDeadlinesAndWordingMatchTheFixturesRecordOfThem() {
        // The constants ARE the contract; a suite asserting them against itself asserts nothing.
        XCTAssertEqual(E2EDirectory.publishDeadlineSeconds, fx.publish_deadline_seconds)
        XCTAssertEqual(E2EDirectory.revokeDeadlineSeconds, fx.revoke_deadline_seconds)
        XCTAssertEqual(E2EDirectory.challengeLength, fx.challenge_length)
        XCTAssertEqual(E2EDirectory.challengeMaxAgeSeconds, fx.challenge_max_age_seconds)
        XCTAssertEqual(E2EDirectory.rejectedWording, fx.rejected_wording)
        // "An interface that says 'not listed' asserts an absence no endpoint has established."
        XCTAssertFalse(E2EDirectory.rejectedWording.lowercased().contains("not listed"))
    }

    // MARK: - §12.2: status is monotonic toward confirmed

    func testConfirmedIsTerminalAndNoPeerResetsIt() {
        for reported in E2EWire.PublicationStatus.allCases {
            for holds in [true, false] {
                XCTAssertEqual(E2EDirectory.merge(stored: .confirmed, reported: reported,
                                                  reporterHoldsPublicationJob: holds),
                               .confirmed, "\(reported) holds=\(holds)")
            }
        }
    }

    /// THE RULE THAT MAKES THIS NON-TRIVIAL. `publication_status` rides in EVERY `session-start`,
    /// including an ordinary `auth` to a Host that never participated in the publication — and such
    /// a Host correctly reports `unconfirmed`, because it does not know. Without the job test, every
    /// connection to an unrelated Host would erase what the issuing endpoint reported.
    func testAResponderHoldingNoPublicationJobIsInformationalOnly() {
        XCTAssertEqual(E2EDirectory.merge(stored: .rejected, reported: .unconfirmed,
                                          reporterHoldsPublicationJob: false), .rejected)
        XCTAssertEqual(E2EDirectory.merge(stored: .unconfirmed, reported: .rejected,
                                          reporterHoldsPublicationJob: false), .unconfirmed)
        XCTAssertNil(E2EDirectory.merge(stored: nil, reported: .unconfirmed,
                                        reporterHoldsPublicationJob: false))
    }

    func testTheJobHolderMayChangeANonConfirmedValueEitherWay() {
        XCTAssertEqual(E2EDirectory.merge(stored: .unconfirmed, reported: .rejected,
                                          reporterHoldsPublicationJob: true), .rejected)
        XCTAssertEqual(E2EDirectory.merge(stored: .rejected, reported: .unconfirmed,
                                          reporterHoldsPublicationJob: true), .unconfirmed)
        XCTAssertEqual(E2EDirectory.merge(stored: .unconfirmed, reported: .confirmed,
                                          reporterHoldsPublicationJob: true), .confirmed)
        XCTAssertEqual(E2EDirectory.merge(stored: nil, reported: .unconfirmed,
                                          reporterHoldsPublicationJob: true), .unconfirmed)
    }

    func testObservingYourOwnGrantClearsTheFlagAndItNeverComesBack() {
        let cleared = E2EDirectory.observedOwnGrantInDirectory()
        XCTAssertEqual(cleared, .confirmed)
        // M can later omit the record; re-raising the warning would hand it a nuisance channel.
        XCTAssertEqual(E2EDirectory.merge(stored: cleared, reported: .unconfirmed,
                                          reporterHoldsPublicationJob: true), .confirmed)
    }

    // MARK: - §12.4's resume table

    func testTheResumeTable() {
        XCTAssertEqual(E2EDirectory.nextAction(.keysOnly), .freshEnrollment)
        XCTAssertEqual(E2EDirectory.nextAction(.pendingOperation), .resume)
        XCTAssertEqual(E2EDirectory.nextAction(.committedWithCleanupPending),
                       .auth(repeatCleanup: true))
        XCTAssertEqual(E2EDirectory.nextAction(.committedClean), .auth(repeatCleanup: false))
        XCTAssertEqual(E2EDirectory.nextAction(.keysLost), .generateNewKeysAndEnroll)
        // Every state decides something; a case added later without a rule fails here.
        XCTAssertEqual(E2EDirectory.DurableState.allCases.count, 5)
    }

    func testACommittedChainNeverRestartsACeremony() {
        // Restarting would reserve a second window for a device that already holds a grant.
        for state in [E2EDirectory.DurableState.committedWithCleanupPending, .committedClean] {
            guard case .auth = E2EDirectory.nextAction(state) else {
                return XCTFail("\(state) must be an auth")
            }
        }
        // ...and keys with no committed chain never go straight to `auth`.
        for state in [E2EDirectory.DurableState.keysOnly, .pendingOperation] {
            if case .auth = E2EDirectory.nextAction(state) { XCTFail("\(state) must not be an auth") }
        }
    }
}
