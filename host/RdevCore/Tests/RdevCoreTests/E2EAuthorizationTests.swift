import XCTest
@testable import RdevCore

/// §13's authorization rules, against the same world the session machine uses
/// (`scripts/gen_e2e_session_fixture.py`) and which `protocol/test/e2e-authorization.test.ts`
/// asserts too.
///
/// H holds capabilities 7 root-issued; C holds 3 and is device-issued; X holds 1 root-issued. Those
/// three cover every cell of the table below with real, signed chains rather than hand-built values.
final class E2EAuthorizationTests: XCTestCase {

    private struct Device: Decodable { let bundle: String }
    private struct Fixture: Decodable {
        let rp_id: String, allowed_origins: [String], root_id: String
        let devices: [String: Device]
    }

    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-session.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }

    private func chain(_ name: String) throws -> E2EVerify.VerifiedChain {
        let f = Self.fx
        switch E2EVerify.verifyBundle(hex(f.devices[name]!.bundle),
                                      trustedRootID: hex(f.root_id),
                                      policy: .init(rpID: f.rp_id,
                                                    allowedOrigins: f.allowed_origins)) {
        case .success(let c): return c
        case .failure(let e):
            XCTFail("\(name): \(e.rawValue)")
            throw e
        }
    }

    private func outcome(_ effect: E2EAuthorization.Effect, _ name: String,
                         gatePassed: Bool = true, revocationChecked: Bool = true) throws -> String {
        switch E2EAuthorization.authorize(effect, chain: try chain(name), gatePassed: gatePassed,
                                          revocationChecked: revocationChecked) {
        case .success: return "ok"
        case .failure(let d): return d.rawValue
        }
    }

    func testDirectOwnersCanRequestUpdatesButRemoteAndAccessOnlyClientsCannot() throws {
        XCTAssertTrue(HostUpdatePolicy.mayRequest(chain: try chain("H"), allowed: true))
        XCTAssertFalse(HostUpdatePolicy.mayRequest(chain: try chain("C"), allowed: true))
        XCTAssertFalse(HostUpdatePolicy.mayRequest(chain: try chain("X"), allowed: true))
        XCTAssertFalse(HostUpdatePolicy.mayRequest(chain: try chain("H"), allowed: false))
        XCTAssertFalse(HostUpdatePolicy.mayRequest(chain: nil, allowed: true))
    }


    // MARK: - §13's capability table

    func testTheCapabilityTable() throws {
        // capabilities: H = 7 (root), C = 3 (device-issued), X = 1 (root)
        let table: [(E2EAuthorization.Effect, String, String)] = [
            (.connect, "H", "ok"), (.connect, "C", "ok"), (.connect, "X", "ok"),
            (.host, "H", "ok"), (.host, "C", "ok"), (.host, "X", "missing-capability"),
            (.issueCode, "H", "ok"),
            (.issueCode, "C", "not-direct-enroll"), (.issueCode, "X", "not-direct-enroll"),
        ]
        for (effect, name, want) in table {
            XCTAssertEqual(try outcome(effect, name), want, "\(effect.rawValue) for \(name)")
        }
    }

    /// §10.3: "a Client-only device still receives full remote control of the Host it connects to,
    /// including a shell." X holds capabilities 1 and this is a full session, not a viewer.
    func testConnectIsNotReadOnly() throws {
        XCTAssertEqual(try outcome(.connect, "X"), "ok")
    }

    /// §13: "Only a direct `enroll` grant authorizes code issuance."
    ///
    /// **THIS BRANCH IS UNREACHABLE THROUGH THE PARSER, AND THAT IS WHY IT IS TESTED HERE.**
    /// `E2EIdentity.parseGrant` already refuses any device-issued grant carrying `enroll` (§10.3),
    /// so no bundle can produce such a chain and no fixture can contain one — a mutation deleting
    /// the `issuerKind == .root` conjunct passed the entire suite. The check is defence in depth
    /// across two files, so it is exercised by building the chain the parser will not.
    func testCodeIssuanceRequiresARootIssuedGrantEvenIfTheParserWouldRefuseOne() {
        let device = E2EIdentity.Device(bytes: [], rootID: [], signingPublicKey: [],
                                        noisePublicKey: [])
        func leaf(_ kind: E2EIdentity.IssuerKind) -> E2EVerify.VerifiedChain {
            let grant = E2EIdentity.Grant(bytes: [], rootID: [], operationID: [],
                                          issuerKind: kind, issuerID: [], device: [],
                                          capabilities: E2EIdentity.Capabilities(raw: 7)!,
                                          binding: .local(randomness: []))
            return E2EVerify.VerifiedChain(
                root: E2EIdentity.Root(bytes: [], rpID: "", credentialID: [], publicKey: []),
                grants: [grant], leaf: grant, leafDevice: device)
        }

        func decide(_ chain: E2EVerify.VerifiedChain) -> String {
            switch E2EAuthorization.authorize(.issueCode, chain: chain, gatePassed: true,
                                              revocationChecked: true) {
            case .success: return "ok"
            case .failure(let d): return d.rawValue
            }
        }
        XCTAssertEqual(decide(leaf(.root)), "ok")
        XCTAssertEqual(decide(leaf(.device)), "not-direct-enroll",
                       "capabilities 7 on a DEVICE-issued grant must not authorize issuance")

        // And the reason it cannot arrive that way in practice, asserted so the two rules stay tied:
        // the parser refuses to decode one at all.
        XCTAssertFalse(E2EIdentity.authorityIsWellFormed(issuerKind: .device,
                                                         capabilities: .init(raw: 7)!))
    }

    // MARK: - both preconditions, separately

    func testBothPreconditionsAreRequiredAndSeparate() throws {
        // Folding them into one "ready" flag would let a caller that did one satisfy a check meant
        // for both. They are made at different times by different code.
        XCTAssertEqual(try outcome(.connect, "H", revocationChecked: false),
                       "revocation-not-checked")
        XCTAssertEqual(try outcome(.connect, "H", gatePassed: false), "not-authenticated")
        XCTAssertEqual(try outcome(.connect, "H", gatePassed: false, revocationChecked: false),
                       "not-authenticated")
    }

    func testNoEffectIsReachableWithoutBoth() throws {
        for effect in E2EAuthorization.Effect.allCases {
            for name in ["H", "C", "X"] {
                XCTAssertNotEqual(try outcome(effect, name, gatePassed: false), "ok")
                XCTAssertNotEqual(try outcome(effect, name, revocationChecked: false), "ok")
            }
        }
    }

    func testRevocationAndRootChangesCancelAnAcceptedUpdate() throws {
        let requester=try XCTUnwrap(HostUpdateRequester(chain:try chain("H")))
        XCTAssertTrue(requester.isAuthorized(root:requester.rootID,revoked:[]))
        XCTAssertFalse(requester.isAuthorized(root:requester.rootID,revoked:[requester.deviceID]))
        XCTAssertFalse(requester.isAuthorized(root:nil,revoked:[]))
        XCTAssertFalse(requester.isAuthorized(root:[0],revoked:[]))
    }

    // MARK: - §13: a replaced or revoked session withdraws its authority

    func testAStampFromThePreviousSessionNeverRunsAgain() {
        var authority = E2EAuthorization.Authority()
        let first = authority.current
        XCTAssertTrue(authority.permits(first))

        let second = authority.replace()
        XCTAssertTrue(authority.permits(second))
        // The late callback: captured under `first`, firing after the handover.
        XCTAssertFalse(authority.permits(first))
        guard case .failure(let denial) = authority.check(first) else {
            return XCTFail("a superseded stamp must be refused")
        }
        XCTAssertEqual(denial, .authorityWithdrawn)
    }

    /// §10.5 on revocation: "withdraw active control, release held input, and prevent further
    /// effects from those sessions." The session being current is exactly what is taken away.
    func testWithdrawalRefusesTheCurrentStampToo() {
        var authority = E2EAuthorization.Authority()
        let stamp = authority.current
        authority.withdraw()
        XCTAssertFalse(authority.permits(stamp))
        XCTAssertTrue(authority.withdrawn)
    }

    func testTheWayBackFromWithdrawalIsANewSessionNeverAResumption() {
        var authority = E2EAuthorization.Authority()
        let withdrawn = authority.current
        authority.withdraw()
        let fresh = authority.replace()
        XCTAssertTrue(authority.permits(fresh))
        XCTAssertFalse(authority.permits(withdrawn))
        XCTAssertGreaterThan(fresh.epoch, withdrawn.epoch)
    }

    func testEpochsOnlyMoveForward() {
        var authority = E2EAuthorization.Authority()
        var stamps = [authority.current]
        for _ in 0 ..< 5 { stamps.append(authority.replace()) }
        for s in stamps.dropLast() { XCTAssertFalse(authority.permits(s)) }
        XCTAssertTrue(authority.permits(stamps.last!))
        XCTAssertEqual(Set(stamps.map(\.epoch)).count, stamps.count)
    }

    /// A COPY IS A SNAPSHOT. `Authority` is a value type on purpose: a component that captured one
    /// cannot be brought back into currency by someone else's `replace()`, and cannot revive itself.
    func testACopiedAuthorityIsASnapshot() {
        var authority = E2EAuthorization.Authority()
        let captured = authority
        let stamp = authority.current
        authority.replace()

        XCTAssertTrue(captured.permits(stamp), "the copy still describes the world it was taken in")
        XCTAssertFalse(authority.permits(stamp), "the live one has moved on")
        // Which is why a caller must consult the LIVE authority, never a captured copy — the copy
        // is evidence of what was true, not of what is.
    }
}
