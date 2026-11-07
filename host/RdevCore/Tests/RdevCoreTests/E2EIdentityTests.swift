import XCTest
@testable import RdevCore

/// The §10 identity encodings, against vectors a THIRD implementation produced
/// (`scripts/gen_e2e_identity_fixture.py`).
///
/// These bytes are what signatures cover, so a layout disagreement is not a parse error — it is a
/// signature that verifies against the wrong statement.
final class E2EIdentityTests: XCTestCase {

    private struct Case: Decodable {
        let name: String, kind: String, encoded: String
        let id: String?
        let rp_id: String?, credential_id: String?, root_public_key: String?
        let root_id: String?, signing_public_key: String?, noise_public_key: String?
        let operation_id: String?, issuer_kind: Int?, issuer_id: String?
        let device: String?, capabilities: Int?, binding: String?
        let target_device_id: String?
    }
    private struct Fixture: Decodable { let cases: [Case] }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-identity.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    private func binding(from encoded: [UInt8]) -> E2EIdentity.Binding? {
        switch encoded.first {
        case 0 where encoded.count == 33: return .local(randomness: Array(encoded[1...]))
        case 1 where encoded.count == 65:
            return .remote(handshakeHash: Array(encoded[1 ..< 33]),
                           responderDeviceID: Array(encoded[33...]))
        default: return nil
        }
    }

    func testMatchesTheCrossImplementationVectors() throws {
        let f = try fixture()
        XCTAssertFalse(f.cases.isEmpty, "an empty fixture would assert nothing")
        var kinds = Set<String>()
        for c in f.cases {
            kinds.insert(c.kind)
            switch c.kind {
            case "root":
                let out = try XCTUnwrap(E2EIdentity.root(rpID: c.rp_id!,
                                                         credentialID: hex(c.credential_id!),
                                                         rootPublicKey: hex(c.root_public_key!)), c.name)
                XCTAssertEqual(hex(out), c.encoded, c.name)
                XCTAssertEqual(hex(E2EIdentity.rootID(out)), c.id!, "\(c.name) id")
            case "device":
                let out = try XCTUnwrap(E2EIdentity.device(rootID: hex(c.root_id!),
                                                           signingPublicKey: hex(c.signing_public_key!),
                                                           noisePublicKey: hex(c.noise_public_key!)), c.name)
                XCTAssertEqual(hex(out), c.encoded, c.name)
                XCTAssertEqual(hex(E2EIdentity.deviceID(out)), c.id!, "\(c.name) id")
            case "grant":
                let out = try XCTUnwrap(E2EIdentity.grant(
                    rootID: hex(c.root_id!), operationID: hex(c.operation_id!),
                    issuerKind: XCTUnwrap(E2EIdentity.IssuerKind(rawValue: UInt8(c.issuer_kind!))),
                    issuerID: hex(c.issuer_id!), device: hex(c.device!),
                    capabilities: XCTUnwrap(E2EIdentity.Capabilities(raw: UInt8(c.capabilities!))),
                    binding: XCTUnwrap(binding(from: hex(c.binding!)))), c.name)
                XCTAssertEqual(hex(out), c.encoded, c.name)
                XCTAssertEqual(hex(E2EIdentity.grantID(out)), c.id!, "\(c.name) id")
            case "grant-commitment":
                // §10.4's commitment. No `id` and no root fields: these bytes deliberately name no
                // root, which is what lets ONE ceremony identify the credential and sign the grant.
                let out = try XCTUnwrap(E2EIdentity.grantCommitmentPreimage(
                    operationID: hex(c.operation_id!),
                    issuerKind: XCTUnwrap(E2EIdentity.IssuerKind(rawValue: UInt8(c.issuer_kind!))),
                    signingPublicKey: hex(c.signing_public_key!),
                    noisePublicKey: hex(c.noise_public_key!),
                    capabilities: XCTUnwrap(E2EIdentity.Capabilities(raw: UInt8(c.capabilities!))),
                    binding: XCTUnwrap(binding(from: hex(c.binding!)))), c.name)
                XCTAssertEqual(hex(out), c.encoded, c.name)
            case "revocation":
                let out = try XCTUnwrap(E2EIdentity.revocation(
                    rootID: hex(c.root_id!), operationID: hex(c.operation_id!),
                    targetDeviceID: hex(c.target_device_id!)), c.name)
                XCTAssertEqual(hex(out), c.encoded, c.name)
            default:
                XCTFail("unknown fixture kind \(c.kind) — a new kind must be asserted, not skipped")
            }
        }
        XCTAssertEqual(kinds, ["root", "device", "grant", "grant-commitment", "revocation"],
                       "every kind must appear; a missing one is coverage that does not exist")
    }

    /// §10.3: "**Accept exactly `{1, 2, 3, 7}`**". The rejected values are all EXPRESSIBLE in the
    /// mask, which is why an explicit set is needed rather than a bit test: `5` and `6` are
    /// `connect|enroll` and `host|enroll`, and neither is a role.
    ///
    /// **`2` joined the set on 2026-09-15**, when adopt-by-code gave it a holder — a Mac enrolled by
    /// scanning its own code, which shares a screen and may do nothing else. It was refused until
    /// then for a stated reason, "a device that may share a screen it can never reach", which is a
    /// semantic judgement rather than a security invariant and is the property that Mac wants.
    func testOnlyFourCapabilityValuesExist() {
        for raw in UInt8(0) ... UInt8(9) {
            let caps = E2EIdentity.Capabilities(raw: raw)
            if raw == 1 || raw == 2 || raw == 3 || raw == 7 {
                XCTAssertNotNil(caps, "\(raw) is accepted")
            } else {
                XCTAssertNil(caps, "\(raw) must be rejected, not partially interpreted")
            }
        }
        XCTAssertTrue(E2EIdentity.Capabilities(raw: 7)!.canEnroll)
        XCTAssertFalse(E2EIdentity.Capabilities(raw: 3)!.canEnroll)
        XCTAssertFalse(E2EIdentity.Capabilities(raw: 1)!.canHost)
        XCTAssertTrue(E2EIdentity.Capabilities(raw: 1)!.canConnect)
    }

    /// Host-only, by the name a caller should use for it rather than a number and a `!`.
    func testHostOnlyIsARole() throws {
        let caps = try XCTUnwrap(E2EIdentity.Capabilities(raw: 2))
        XCTAssertTrue(caps.canHost)
        XCTAssertFalse(caps.canConnect, "host-only never connects out — that is the point of it")
        XCTAssertFalse(caps.canEnroll)
        XCTAssertEqual(E2EIdentity.Capabilities.hostOnly.raw, 2)

        // It encodes and parses like any other role, root-issued or device-issued: only `enroll` is
        // restricted by issuer kind, and nothing about that changed when `2` became a role.
        let id = [UInt8](repeating: 1, count: 32)
        let dev = try XCTUnwrap(E2EIdentity.device(rootID: id, signingPublicKey: id,
                                                   noisePublicKey: id))
        let bind = E2EIdentity.Binding.local(randomness: [UInt8](repeating: 2, count: 32))
        for kind: E2EIdentity.IssuerKind in [.root, .device] {
            let bytes = try XCTUnwrap(E2EIdentity.grant(rootID: id, operationID: id, issuerKind: kind,
                                                        issuerID: id, device: dev,
                                                        capabilities: caps, binding: bind))
            XCTAssertEqual(E2EIdentity.parseGrant(bytes)?.capabilities.raw, 2)
        }

        // The set stayed CLOSED. `6` is `host|enroll`, the value a widened bit test would admit.
        XCTAssertNil(E2EIdentity.Capabilities(raw: 6), "host|enroll is not a role")
    }

    /// §10.3: "only root-issued grants may carry `enroll`". A LEAF CANNOT EXTEND THE CHAIN, which is
    /// what bounds chain depth at two without counting anything — and the refusal happens at
    /// CONSTRUCTION, so such a grant is never signed in the first place.
    func testOnlyARootMayIssueEnroll() throws {
        let id = [UInt8](repeating: 1, count: 32)
        let dev = try XCTUnwrap(E2EIdentity.device(rootID: id, signingPublicKey: id, noisePublicKey: id))
        let bind = E2EIdentity.Binding.local(randomness: [UInt8](repeating: 2, count: 32))

        func make(_ kind: E2EIdentity.IssuerKind, _ caps: UInt8) -> [UInt8]? {
            E2EIdentity.grant(rootID: id, operationID: id, issuerKind: kind, issuerID: id,
                              device: dev, capabilities: E2EIdentity.Capabilities(raw: caps)!,
                              binding: bind)
        }
        XCTAssertNotNil(make(.root, 7), "a root may issue enroll")
        XCTAssertNil(make(.device, 7), "a device may NOT issue enroll")
        XCTAssertNotNil(make(.device, 3), "a device may issue connect+host")
        XCTAssertNotNil(make(.device, 1), "a device may issue connect")

        XCTAssertTrue(E2EIdentity.authorityIsWellFormed(issuerKind: .root,
                                                        capabilities: .init(raw: 7)!))
        XCTAssertFalse(E2EIdentity.authorityIsWellFormed(issuerKind: .device,
                                                         capabilities: .init(raw: 7)!))
    }

    /// Wrong widths are refused at construction — §7 requires it before verification.
    func testWrongWidthsAreRefused() {
        let ok = [UInt8](repeating: 0, count: 32)
        let short = [UInt8](repeating: 0, count: 31)
        XCTAssertNil(E2EIdentity.root(rpID: "x", credentialID: [], rootPublicKey: ok),
                     "a 32-byte root key is not a SEC1 point")
        XCTAssertNil(E2EIdentity.device(rootID: short, signingPublicKey: ok, noisePublicKey: ok))
        XCTAssertNil(E2EIdentity.revocation(rootID: ok, operationID: ok, targetDeviceID: short))
        XCTAssertNil(E2EIdentity.Binding.local(randomness: short).encoded)
        XCTAssertNil(E2EIdentity.Binding.remote(handshakeHash: ok, responderDeviceID: short).encoded)
    }

    /// THE GRANT ID IS NOT THE GRANT'S HASH. A second label over the same bytes is what stops a
    /// grant id being confusable with a hash taken for any other purpose.
    func testTheGrantIDIsDomainSeparated() throws {
        let id = [UInt8](repeating: 3, count: 32)
        let dev = try XCTUnwrap(E2EIdentity.device(rootID: id, signingPublicKey: id, noisePublicKey: id))
        let g = try XCTUnwrap(E2EIdentity.grant(
            rootID: id, operationID: id, issuerKind: .root, issuerID: id, device: dev,
            capabilities: .init(raw: 7)!, binding: .local(randomness: id)))
        XCTAssertNotEqual(E2EIdentity.grantID(g), E2EIdentity.sha256(g))
    }

    /// Every field is bound in: change one and the identity changes. A descriptor that ignored a key
    /// would let a device swap it silently.
    func testEveryFieldChangesTheIdentity() throws {
        let a = [UInt8](repeating: 1, count: 32)
        let b = [UInt8](repeating: 2, count: 32)
        let base = try XCTUnwrap(E2EIdentity.device(rootID: a, signingPublicKey: a, noisePublicKey: a))
        for changed in [try XCTUnwrap(E2EIdentity.device(rootID: b, signingPublicKey: a, noisePublicKey: a)),
                        try XCTUnwrap(E2EIdentity.device(rootID: a, signingPublicKey: b, noisePublicKey: a)),
                        try XCTUnwrap(E2EIdentity.device(rootID: a, signingPublicKey: a, noisePublicKey: b))] {
            XCTAssertNotEqual(E2EIdentity.deviceID(base), E2EIdentity.deviceID(changed))
        }
    }
}

/// Grant parsing and the §10.3 chain rules — everything decidable without a signature.
///
/// The structural half is separated from the cryptographic one on purpose, and these are the rules a
/// reader can check against the specification line by line.
final class E2EChainTests: XCTestCase {

    private let rootID = [UInt8](repeating: 0x71, count: 32)

    private func id(_ b: UInt8) -> [UInt8] { [UInt8](repeating: b, count: 32) }

    private func device(_ seed: UInt8) -> [UInt8] {
        E2EIdentity.device(rootID: rootID, signingPublicKey: id(seed), noisePublicKey: id(seed &+ 1))!
    }

    private func grant(kind: E2EIdentity.IssuerKind, issuer: [UInt8], caps: UInt8,
                       device dev: [UInt8]? = nil, root: [UInt8]? = nil) -> [UInt8] {
        E2EIdentity.grant(rootID: root ?? rootID, operationID: id(0x99), issuerKind: kind,
                          issuerID: issuer, device: dev ?? device(0x10),
                          capabilities: .init(raw: caps)!,
                          binding: .local(randomness: id(0xC0)))!
    }

    /// THE PARSER HOLDS THE ORIGINAL BYTES. §7 forbids reserialising to verify, because a re-encoded
    /// grant differing by one byte is a signature check that fails for a reason nobody will find.
    func testParsingRoundTripsAndKeepsTheExactBytes() throws {
        let bytes = grant(kind: .root, issuer: rootID, caps: 7)
        let g = try XCTUnwrap(E2EIdentity.parseGrant(bytes))
        XCTAssertEqual(g.bytes, bytes, "the original bytes are retained, not rebuilt")
        XCTAssertEqual(g.rootID, rootID)
        XCTAssertEqual(g.issuerKind, .root)
        XCTAssertEqual(g.capabilities.raw, 7)
        XCTAssertEqual(g.id, E2EIdentity.grantID(bytes))
    }

    /// Every rejection §7 asks for, applied BEFORE any signature is checked.
    func testTheParserRefusesMalformedGrants() throws {
        let good = grant(kind: .root, issuer: rootID, caps: 7)
        XCTAssertNotNil(E2EIdentity.parseGrant(good))
        XCTAssertNil(E2EIdentity.parseGrant(good + [0]), "extra trailing bytes")
        XCTAssertNil(E2EIdentity.parseGrant(Array(good.dropLast())), "truncated")
        XCTAssertNil(E2EIdentity.parseGrant([]), "empty")

        // An unknown issuer kind: the byte sits straight after the label, root id and operation id.
        var badKind = good
        badKind[2 + E2EIdentity.grantLabel.utf8.count + 64] = 9
        XCTAssertNil(E2EIdentity.parseGrant(badKind), "an unknown issuer kind")

        // A revocation is not a grant — the label is the type tag.
        let rev = try XCTUnwrap(E2EIdentity.revocation(rootID: rootID, operationID: id(1),
                                                       targetDeviceID: id(2)))
        XCTAssertNil(E2EIdentity.parseGrant(rev))
    }

    /// A one-grant chain is the normal direct enrollment.
    func testADirectChainValidates() throws {
        let result = E2EIdentity.validateChainStructure([grant(kind: .root, issuer: rootID, caps: 7)],
                                                        trustedRootID: rootID)
        let g = try XCTUnwrap(try? result.get())
        XCTAssertTrue(g.capabilities.canEnroll)
    }

    /// A two-grant chain must be linked by the parent's EXACT grant id, and the leaf is what the
    /// caller ends up authorising.
    func testATwoGrantChainValidatesAndReturnsTheLeaf() throws {
        let directBytes = grant(kind: .root, issuer: rootID, caps: 7)
        let parent = E2EIdentity.grantID(directBytes)
        let leafBytes = grant(kind: .device, issuer: parent, caps: 3)
        let g = try XCTUnwrap(try? E2EIdentity.validateChainStructure([directBytes, leafBytes],
                                                                      trustedRootID: rootID).get())
        XCTAssertEqual(g.bytes, leafBytes, "the LEAF is the authorised grant, not the root's")
        XCTAssertEqual(g.capabilities.raw, 3)
    }

    /// Each structural rule, with the failure it produces. §10.3 line by line.
    func testEveryStructuralRuleIsEnforced() {
        let directBytes = grant(kind: .root, issuer: rootID, caps: 7)
        let parent = E2EIdentity.grantID(directBytes)

        func failure(_ chain: [[UInt8]], _ root: [UInt8] = [UInt8](repeating: 0x71, count: 32))
            -> E2EIdentity.ChainFailure? {
            if case .failure(let f) = E2EIdentity.validateChainStructure(chain, trustedRootID: root) {
                return f
            }
            return nil
        }

        XCTAssertEqual(failure([]), .empty)
        XCTAssertEqual(failure([directBytes, grant(kind: .device, issuer: parent, caps: 3), directBytes]),
                       .tooLong, "no chain has more than two grants")
        XCTAssertEqual(failure([[0, 1, 2]]), .malformedGrant)
        XCTAssertEqual(failure([directBytes], id(0xEE)), .rootMismatch,
                       "an incoming chain may never replace a trusted root")
        XCTAssertEqual(failure([grant(kind: .root, issuer: id(0xAB), caps: 7)]), .firstNotRootIssued,
                       "the first grant must name the root as its issuer")
        XCTAssertEqual(failure([directBytes, grant(kind: .device, issuer: id(0xAB), caps: 3)]),
                       .secondNotChainedToFirst, "the leaf must name its parent's exact grant id")
        XCTAssertEqual(failure([directBytes, directBytes]), .secondNotChainedToFirst,
                       "a root-issued grant cannot be a leaf")
    }

    /// A LEAF CARRYING `enroll` CANNOT EVEN BE CONSTRUCTED, so the chain rule guarding it can only be
    /// reached by hand-assembled bytes — which is exactly the case that matters, since an adversary
    /// does not use our constructor.
    func testALeafCannotCarryEnrollEvenIfHandAssembled() throws {
        let directBytes = grant(kind: .root, issuer: rootID, caps: 7)
        let parent = E2EIdentity.grantID(directBytes)
        // Build a legal leaf, then flip its capability byte to 7 in the encoded bytes.
        var forged = grant(kind: .device, issuer: parent, caps: 3)
        let capsAt = forged.count - 1 - 2 - 33     // caps sits before LP(binding): 2 + 33 bytes
        XCTAssertEqual(forged[capsAt], 3, "located the capability byte")
        forged[capsAt] = 7
        XCTAssertNil(E2EIdentity.parseGrant(forged), "the parser refuses it outright")
        if case .failure(let f) = E2EIdentity.validateChainStructure([directBytes, forged],
                                                                     trustedRootID: rootID) {
            XCTAssertEqual(f, .malformedGrant)
        } else {
            XCTFail("a forged leaf with enroll must not validate")
        }
    }
}

/// §10.4's grant commitment — the bytes a ROOT PASSKEY signs, which must name no root.
///
/// **These are the only tests that observe the structural pin.** `verifyBundle` rejects every one of
/// the disagreements below earlier, in the chain rules, so no end-to-end fixture ever reaches
/// `grantCommitment`'s refusal. Without this file the mechanism that replaces the signature's own
/// root binding is entirely untested.
final class E2EGrantCommitmentTests: XCTestCase {

    private let rootID = [UInt8](repeating: 0x11, count: 32)
    private let op = [UInt8](repeating: 0x22, count: 32)
    private let sign = [UInt8](repeating: 0x33, count: 32)
    private let noise = [UInt8](repeating: 0x44, count: 32)
    private var binding: E2EIdentity.Binding { .local(randomness: [UInt8](repeating: 0x55, count: 32)) }
    private var caps: E2EIdentity.Capabilities { E2EIdentity.Capabilities(raw: 7)! }

    private func device(root: [UInt8]? = nil) -> [UInt8] {
        E2EIdentity.device(rootID: root ?? rootID, signingPublicKey: sign, noisePublicKey: noise)!
    }

    private func grant(rootID r: [UInt8]? = nil, issuerID: [UInt8]? = nil, device d: [UInt8]? = nil,
                       issuerKind: E2EIdentity.IssuerKind = .root,
                       capabilities c: E2EIdentity.Capabilities? = nil,
                       operationID: [UInt8]? = nil) -> E2EIdentity.Grant {
        E2EIdentity.parseGrant(E2EIdentity.grant(
            rootID: r ?? rootID, operationID: operationID ?? op, issuerKind: issuerKind,
            issuerID: issuerID ?? rootID, device: d ?? device(),
            capabilities: c ?? caps, binding: binding)!)!
    }

    private func signerCommitment() -> [UInt8]? {
        E2EIdentity.grantCommitmentPreimage(operationID: op, issuerKind: .root,
                                            signingPublicKey: sign, noisePublicKey: noise,
                                            capabilities: caps, binding: binding)
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for i in 0 ... (haystack.count - needle.count)
        where Array(haystack[i ..< i + needle.count]) == needle { return true }
        return false
    }

    /// **THE WHOLE POINT.** A browser signing in has not yet learned which credential will answer,
    /// so it cannot know `root_id`; a challenge containing one could not exist until a FIRST
    /// ceremony had produced it — which is exactly the second prompt this encoding removes.
    func testTheCommitmentNamesNoRoot() throws {
        let commit = try XCTUnwrap(signerCommitment())
        XCTAssertFalse(contains(commit, rootID), "the identity's id must not appear")
    }

    func testTheVerifiersProjectionEqualsTheSigners() {
        XCTAssertEqual(E2EIdentity.grantCommitment(grant(), trustedRootID: rootID),
                       signerCommitment())
    }

    func testTheCommitmentRefusesADisagreeingRootID() {
        XCTAssertNil(E2EIdentity.grantCommitment(
            grant(), trustedRootID: [UInt8](repeating: 0x99, count: 32)))
    }

    func testTheCommitmentRefusesADisagreeingIssuerID() {
        XCTAssertNil(E2EIdentity.grantCommitment(
            grant(issuerID: [UInt8](repeating: 0x99, count: 32)), trustedRootID: rootID))
    }

    func testTheCommitmentRefusesADeviceNamingAnotherRoot() {
        XCTAssertNil(E2EIdentity.grantCommitment(
            grant(device: device(root: [UInt8](repeating: 0x99, count: 32))), trustedRootID: rootID))
    }

    /// A device-issued grant is evidenced by a raw Ed25519 signature over the WHOLE grant, never by
    /// an assertion, so there is no case in which this should answer for one.
    func testTheCommitmentRefusesADeviceIssuedGrant() {
        let parent = E2EIdentity.grant(rootID: rootID, operationID: op, issuerKind: .root,
                                       issuerID: rootID, device: device(),
                                       capabilities: caps, binding: binding)!
        let leaf = grant(issuerID: E2EIdentity.grantID(parent), issuerKind: .device,
                         capabilities: E2EIdentity.Capabilities(raw: 3)!,
                         operationID: [UInt8](repeating: 0x66, count: 32))
        XCTAssertNil(E2EIdentity.grantCommitment(leaf, trustedRootID: rootID))
    }

    /// Refuses exactly what `grant()` refuses. Bytes that could not be a legal grant must never be
    /// signed, rather than rejected by somebody later.
    func testTheSignersHalfRefusesWhatAGrantWouldRefuse() {
        XCTAssertNil(E2EIdentity.grantCommitmentPreimage(
            operationID: [UInt8](repeating: 0x22, count: 31), issuerKind: .root,
            signingPublicKey: sign, noisePublicKey: noise, capabilities: caps, binding: binding),
            "a 31-byte operation id is not an id")
        // §10.3: only root-issued grants may carry `enroll`.
        XCTAssertNil(E2EIdentity.grantCommitmentPreimage(
            operationID: op, issuerKind: .device,
            signingPublicKey: sign, noisePublicKey: noise, capabilities: caps, binding: binding),
            "a device-issued grant may not carry enroll")
    }
}
