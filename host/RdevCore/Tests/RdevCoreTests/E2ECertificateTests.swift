import XCTest
@testable import RdevCore

/// The §10.4 evidence encodings and the bundle verifier, against vectors a THIRD implementation
/// produced (`scripts/gen_e2e_certificate_fixture.py`, whose own signature arithmetic is pinned to
/// the published RFC 8032 §7.1 and RFC 6979 A.2.5 answers before it emits a byte) and which
/// `protocol/test/e2e-certificate.test.ts` asserts too.
///
/// **The negative cases carry the weight.** Each mutates ONE thing and is re-signed, so it fails for
/// exactly one reason and names it — a verifier that rejected everything would pass none of them.
final class E2ECertificateTests: XCTestCase {

    private struct EncodingCase: Decodable {
        let name: String, kind: String
        let encoded: String?
        let credential_id: String?, client_data_json: String?
        let authenticator_data: String?, signature: String?
        let grant: String?, evidence: String?, real_signature: String?
        let root: String?, certificates: [String]?
    }
    private struct VerifyCase: Decodable {
        let name: String, bundle: String, trusted_root_id: String
        let rp_id: String, allowed_origins: [String], expect: String
        let leaf_device_id: String?, leaf_capabilities: Int?, leaf_noise_public_key: String?
        let revoked_device_ids: [String]?, expected_noise_static: String?
    }
    private struct Fixture: Decodable { let cases: [EncodingCase]; let verify: [VerifyCase] }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-certificate.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    // MARK: - encodings

    func testMatchesTheCrossImplementationEncodings() throws {
        let f = try fixture()
        XCTAssertFalse(f.cases.isEmpty, "an empty fixture would assert nothing")
        var kinds = Set<String>()

        for c in f.cases {
            kinds.insert(c.kind)
            switch c.kind {
            case "assertion":
                let encoded = E2ECertificate.assertion(
                    credentialID: hex(c.credential_id!), clientDataJSON: hex(c.client_data_json!),
                    authenticatorData: hex(c.authenticator_data!), signature: hex(c.signature!))
                XCTAssertEqual(hex(encoded!), c.encoded, c.name)
                let back = E2ECertificate.parseAssertion(hex(c.encoded!))
                XCTAssertEqual(hex(back!.credentialID), c.credential_id, c.name)
                XCTAssertEqual(hex(back!.clientDataJSON), c.client_data_json, c.name)
                XCTAssertEqual(hex(back!.authenticatorData), c.authenticator_data, c.name)
                XCTAssertEqual(hex(back!.signature), c.signature, c.name)

            case "certificate":
                let encoded = E2ECertificate.certificate(grant: hex(c.grant!),
                                                         evidence: hex(c.evidence!))
                XCTAssertEqual(hex(encoded!), c.encoded, c.name)
                let back = E2ECertificate.parseCertificate(hex(c.encoded!))
                XCTAssertEqual(hex(back!.grant), c.grant, c.name)
                XCTAssertEqual(hex(back!.evidence), c.evidence, c.name)

            case "bundle":
                let encoded = E2ECertificate.bundle(root: hex(c.root!),
                                                    certificates: c.certificates!.map(hex))
                XCTAssertEqual(hex(encoded!), c.encoded, c.name)
                guard case .success(let back) = E2ECertificate.parseBundle(hex(c.encoded!)) else {
                    return XCTFail("\(c.name): did not parse")
                }
                XCTAssertEqual(hex(back.root), c.root, c.name)
                XCTAssertEqual(back.certificates.map {
                    hex(E2ECertificate.certificate(grant: $0.grant, evidence: $0.evidence)!)
                }, c.certificates, c.name)

            case "ambiguity":
                // The two evidence forms are NOT DISJOINT: this crafted 64-byte value — the width
                // of a raw Ed25519 signature — parses cleanly as an assertion, which is the whole
                // reason the form is chosen by the grant's issuer_kind and never by probing.
                XCTAssertEqual(hex(c.evidence!).count, 64, c.name)
                XCTAssertNotNil(E2ECertificate.parseAssertion(hex(c.evidence!)), c.name)
                // And the control: a REAL signature does not parse. Without this arm the assertion
                // above reads as "signatures collide with assertions", which is false (~1e-14) and
                // points at the wrong hazard.
                XCTAssertNil(E2ECertificate.parseAssertion(hex(c.real_signature!)), c.name)

            default:
                XCTFail("unhandled kind \(c.kind)")
            }
        }
        XCTAssertEqual(kinds.sorted(), ["ambiguity", "assertion", "bundle", "certificate"])
    }

    // MARK: - verification

    func testVerifiesEveryFixtureCaseForTheStatedReason() throws {
        let f = try fixture()
        XCTAssertFalse(f.verify.isEmpty, "an empty fixture would assert nothing")
        var reached = Set<String>()

        for c in f.verify {
            let result = E2EVerify.verifyBundle(
                hex(c.bundle),
                trustedRootID: hex(c.trusted_root_id),
                policy: .init(rpID: c.rp_id, allowedOrigins: c.allowed_origins),
                revokedDeviceIDs: Set((c.revoked_device_ids ?? []).map(hex)),
                expectedNoiseStatic: c.expected_noise_static.map(hex))
            reached.insert(c.expect)

            switch result {
            case .success(let chain):
                XCTAssertEqual("ok", c.expect, "\(c.name): accepted a bundle that must be refused")
                XCTAssertEqual(hex(chain.leafDevice.id), c.leaf_device_id, c.name)
                XCTAssertEqual(Int(chain.leaf.capabilities.raw), c.leaf_capabilities, c.name)
                XCTAssertEqual(hex(chain.leafDevice.noisePublicKey), c.leaf_noise_public_key, c.name)
            case .failure(let failure):
                XCTAssertEqual(failure.rawValue, c.expect, c.name)
            }
        }

        // A verifier returning one blanket rejection would pass every negative case. This is what
        // makes the suite discriminate: each outcome names the single thing its case mutated.
        XCTAssertEqual(reached.count, Set(f.verify.map(\.expect)).count)
        XCTAssertGreaterThanOrEqual(reached.count, 20)
    }

    // MARK: - Ed25519 against an external answer

    func testRFC8032Vector() {
        // RFC 8032 §7.1 TEST 1 — not something this repo computed. It also pins the key encoding:
        // a raw 32-byte seed, never a 64-byte libsodium "secret key".
        //
        // The SIGNATURE is asserted by verifying the published one, NOT by reproducing it — see
        // `testCryptoKitEd25519IsHedgedAndThatIsFine` immediately below for why it cannot be
        // reproduced on this platform.
        let seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let pub = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
        let sig = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
                + "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"

        XCTAssertEqual(hex(E2EVerify.ed25519PublicKey(privateKey: seed)!), pub)
        XCTAssertTrue(E2EVerify.verifyEd25519(signature: hex(sig), message: [], publicKey: hex(pub)),
                      "the published RFC 8032 signature must verify")
    }

    /// **CRYPTOKIT'S Ed25519 SIGNING IS RANDOMIZED, NOT RFC 8032 DETERMINISTIC.** Two signatures
    /// over the same message with the same key differ, and both verify.
    ///
    /// This is not a defect on either side and it changes nothing about the protocol: a hedged
    /// signature is an ordinary Ed25519 signature, and @noble, the Python generator and CryptoKit
    /// all verify each other's. What it forbids is a whole shape of test — **no fixture may ever
    /// compare a Swift-produced signature against a byte string**, because the first version of the
    /// test above did exactly that and failed against the published RFC vector while the TypeScript
    /// mirror, over deterministic @noble, passed. Cross-implementation agreement on signatures is
    /// asserted through VERIFICATION, never through equality.
    func testCryptoKitEd25519IsHedgedAndThatIsFine() {
        let seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let message: [UInt8] = [0x72]
        let a = E2EVerify.signEd25519(message: message, privateKey: seed)!
        let b = E2EVerify.signEd25519(message: message, privateKey: seed)!
        XCTAssertNotEqual(a, b, "if this ever passes, CryptoKit became deterministic — good, but "
                              + "the rule above is what the fixtures are built on, so re-read it")

        let pub = E2EVerify.ed25519PublicKey(privateKey: seed)!
        XCTAssertTrue(E2EVerify.verifyEd25519(signature: a, message: message, publicKey: pub))
        XCTAssertTrue(E2EVerify.verifyEd25519(signature: b, message: message, publicKey: pub))
        // RFC 8032 §7.1 TEST 2 over the same message: a THIRD signature, deterministic, also valid.
        let rfc = hex("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
                    + "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
        let rfcSeed = hex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
        XCTAssertTrue(E2EVerify.verifyEd25519(signature: rfc, message: message,
                                              publicKey: E2EVerify.ed25519PublicKey(
                                                  privateKey: rfcSeed)!))
    }

    func testEd25519RefusesRatherThanThrowing() {
        let seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let pub = E2EVerify.ed25519PublicKey(privateKey: seed)!
        let sig = E2EVerify.signEd25519(message: [1, 2, 3], privateKey: seed)!

        XCTAssertTrue(E2EVerify.verifyEd25519(signature: sig, message: [1, 2, 3], publicKey: pub))
        XCTAssertFalse(E2EVerify.verifyEd25519(signature: Array(sig.dropLast()),
                                               message: [1, 2, 3], publicKey: pub))
        XCTAssertFalse(E2EVerify.verifyEd25519(signature: sig, message: [1, 2, 4], publicKey: pub))
        XCTAssertFalse(E2EVerify.verifyEd25519(signature: sig, message: [1, 2, 3],
                                               publicKey: Array(repeating: 0, count: 31)))
    }

    // MARK: - the evidence form is chosen by the grant

    func testARootIssuedGrantIsNeverVerifiedAgainstARawSignature() throws {
        let f = try fixture()
        let direct = f.verify.first { $0.name == "direct" }!
        let chain = f.verify.first { $0.name == "chain" }!

        guard case .success(let parsedChain) = E2ECertificate.parseBundle(hex(chain.bundle)),
              case .success(let parsedDirect) = E2ECertificate.parseBundle(hex(direct.bundle))
        else { return XCTFail("fixture bundles must parse") }

        // The leaf's GENUINE Ed25519 signature, moved onto the root-issued grant. Every byte is
        // authentic; only the form is wrong for the grant that carries it.
        let leafEvidence = parsedChain.certificates[1].evidence
        XCTAssertEqual(leafEvidence.count, 64)
        let swapped = E2ECertificate.bundle(
            root: parsedDirect.root,
            certificates: [E2ECertificate.certificate(grant: parsedDirect.certificates[0].grant,
                                                      evidence: leafEvidence)!])!

        let result = E2EVerify.verifyBundle(
            swapped, trustedRootID: hex(direct.trusted_root_id),
            policy: .init(rpID: direct.rp_id, allowedOrigins: direct.allowed_origins))
        guard case .failure = result else { return XCTFail("a raw signature is not an assertion") }
    }

    // MARK: - verifyAssertion in isolation

    /// **The pre-image is §10.4's COMMITMENT, not the grant.** A root passkey signs a projection of
    /// the grant that names no root, so these tests hand `verifyAssertion` what the verifier would:
    /// `grantCommitment`'s output for the grant under the root actually trusted.
    private func directAssertion() throws
        -> (E2ECertificate.Assertion, [UInt8], E2EIdentity.Root, E2EVerify.Policy) {
        let f = try fixture()
        let direct = f.verify.first { $0.name == "direct" }!
        guard case .success(let b) = E2ECertificate.parseBundle(hex(direct.bundle)),
              let root = E2EIdentity.parseRoot(b.root),
              let grant = E2EIdentity.parseGrant(b.certificates[0].grant),
              let preimage = E2EIdentity.grantCommitment(grant,
                                                         trustedRootID: hex(direct.trusted_root_id)),
              let assertion = E2ECertificate.parseAssertion(b.certificates[0].evidence)
        else { throw XCTSkip("fixture must parse") }
        return (assertion, preimage, root,
                .init(rpID: direct.rp_id, allowedOrigins: direct.allowed_origins))
    }

    func testAcceptsTheFixturesOwnAssertion() throws {
        let (assertion, preimage, root, policy) = try directAssertion()
        XCTAssertNil(E2EVerify.verifyAssertion(assertion, preimage: preimage,
                                               root: root, policy: policy))
    }

    func testTheChallengeIsTheHashOfThisCommitmentAndNoOther() throws {
        let (assertion, _, root, policy) = try directAssertion()
        let f = try fixture()
        // A DIFFERENT root-issued grant under the SAME root — different operation id, device keys,
        // capabilities and binding, so its commitment differs in every field the commitment carries.
        // `chain`'s first certificate would not do: it IS this bundle's grant. Its leaf would not
        // either, being device-issued, which `grantCommitment` refuses outright.
        let otherCase = f.verify.first { $0.name == "forged-root-issued-leaf" }!
        guard case .success(let other) = E2ECertificate.parseBundle(hex(otherCase.bundle)),
              let otherGrant = E2EIdentity.parseGrant(other.certificates[0].grant)
        else { return XCTFail("fixture must parse") }
        guard let otherPreimage = E2EIdentity.grantCommitment(
                otherGrant, trustedRootID: hex(otherCase.trusted_root_id))
        else { return XCTFail("a root-issued grant must have a commitment") }

        XCTAssertEqual(E2EVerify.verifyAssertion(assertion, preimage: otherPreimage,
                                                 root: root, policy: policy),
                       .clientDataChallenge)
    }

    func testAnOriginOutsideTheConfiguredSetIsRefused() throws {
        let (assertion, preimage, root, policy) = try directAssertion()
        // Including a SUFFIX and a PREFIX of the real one: origin comparison is exact string
        // equality, and "starts with" or "contains" would accept both of these.
        for origins in [[], ["https://rdev.example.evil.test"], ["https://rdev.exampl"]] {
            XCTAssertEqual(E2EVerify.verifyAssertion(assertion, preimage: preimage, root: root,
                                                     policy: .init(rpID: policy.rpID,
                                                                   allowedOrigins: origins)),
                           .clientDataOrigin, "\(origins)")
        }
    }

    // MARK: - the clientDataJSON scanner

    func testTopLevelMembersFindsDuplicatesThePlatformParserWouldHide() {
        let json = Array(#"{"type":"webauthn.get","origin":"a","origin":"b"}"#.utf8)
        // The platform parser collapses it silently, which is the whole reason the scanner exists.
        let collapsed = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any]
        XCTAssertEqual((collapsed as? [String: Any])?.count, 2)
        XCTAssertEqual(E2EVerify.topLevelMembers(json)?.count, 3)
    }

    func testTopLevelMembersSkipsNestedStructuresWithoutDescendingIntoThem() {
        // `tokenBinding` is a real WebAuthn member and an object; a scanner that counted its keys
        // as top-level would see "status" twice across two sibling objects and refuse a valid
        // ceremony. A brace inside a STRING must not move the depth either.
        let json = Array(#"{"a":{"status":1,"s":"}"},"b":[1,{"status":2}],"c":"x"}"#.utf8)
        let members = E2EVerify.topLevelMembers(json)
        XCTAssertEqual(members?.map { String(decoding: $0.0, as: UTF8.self) },
                       ["\"a\"", "\"b\"", "\"c\""])
    }

    func testTopLevelMembersRefusesMalformedInput() {
        for bad in ["", "{", "[]", "null", #"{"a"}"#, #"{"a":}"#, #"{"a":1,}"#, #"{"a":1}x"#,
                    #"{"a":1"#, #"{"a":"unterminated}"#] {
            XCTAssertNil(E2EVerify.topLevelMembers(Array(bad.utf8)), bad)
        }
        XCTAssertNotNil(E2EVerify.topLevelMembers(Array("{}".utf8)))
        XCTAssertNotNil(E2EVerify.topLevelMembers(Array(#" { "a" : 1 , "b" : [ ] } "#.utf8)))
    }

    func testAnEscapedKeyIsDecodedBeforeItIsCompared() {
        // `"type"` IS `"type"`. A scanner comparing raw tokens would see two different names
        // and let a duplicate through — and a verifier reading raw tokens would miss the field
        // entirely and reject a ceremony that is in fact well formed.
        let json = Array(#"{"type":"webauthn.get"}"#.utf8)
        let members = E2EVerify.topLevelMembers(json)!
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(E2EVerify.jsonString(members[0].0), "type")
    }
}
