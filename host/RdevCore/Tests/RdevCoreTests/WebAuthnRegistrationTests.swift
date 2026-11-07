import XCTest
@testable import RdevCore

/// §10.1's registration ceremony as bytes, against the vectors a THIRD implementation produced
/// (`scripts/gen_webauthn_fixture.py`) and `protocol/test/webauthn.test.ts` asserts too — so the Mac's
/// native create and the browser's read one attestation object the same way.
final class WebAuthnRegistrationTests: XCTestCase {

    private struct Case: Decodable {
        let name: String, expect: String, attestation_object: String
        let credential_id: String?, public_key: String?, flags: Int?
    }
    private struct Fixture: Decodable { let rp_id: String; let cases: [Case] }
    private struct Certificates: Decodable {
        struct Verify: Decodable { let name: String, bundle: String }
        let verify: [Verify]
    }

    private func load<T: Decodable>(_ name: String) throws -> T {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/\(name)")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testMatchesTheCrossImplementationVectors() throws {
        let f: Fixture = try load("webauthn.json")
        // A parser refusing everything passes every refusal; both arms must be populated.
        XCTAssertGreaterThan(f.cases.filter { $0.expect == "ok" }.count, 0)
        XCTAssertGreaterThan(f.cases.filter { $0.expect == "refuse" }.count, 5)
        for c in f.cases {
            let parsed = WebAuthnRegistration.parseAttestedCredential(hex(c.attestation_object))
            if c.expect == "refuse" { XCTAssertNil(parsed, c.name); continue }
            guard let parsed else { XCTFail("\(c.name) → nil"); continue }
            XCTAssertEqual(hex(parsed.credentialID), c.credential_id, c.name)
            XCTAssertEqual(hex(parsed.publicKey), c.public_key, c.name)
            XCTAssertEqual(Int(parsed.flags), c.flags, c.name)
            XCTAssertEqual(parsed.publicKey.count, 65, c.name)
            XCTAssertEqual(parsed.publicKey.first, 0x04, c.name)
        }
    }

    /// THE LOOP CLOSES: the key a registration carries is the key that verifies assertions by that
    /// credential, checked against a second fixture generated independently.
    func testTheRegisteredKeyIsTheRootKeyThatVerifiesAssertions() throws {
        let f: Fixture = try load("webauthn.json")
        let certs: Certificates = try load("e2e-certificate.json")
        let registered = try XCTUnwrap(WebAuthnRegistration.parseAttestedCredential(
            hex(f.cases.first { $0.expect == "ok" }!.attestation_object)))
        guard case .success(let bundle) = E2ECertificate.parseBundle(
                hex(certs.verify.first { $0.name == "direct" }!.bundle)),
              let root = E2EIdentity.parseRoot(bundle.root) else { return XCTFail("fixture bundle") }
        XCTAssertEqual(root.publicKey, registered.publicKey)
        XCTAssertEqual(root.credentialID, registered.credentialID)
    }

    /// The descriptor native create retains: built for the configured relying party, and REFUSED for a
    /// registration whose `rpIdHash` is another one's or that was not user-verified — the browser leaves
    /// both to the browser; native code is told nothing.
    func testTheRootDescriptorIsTheRelyingPartysAndUserVerified() throws {
        let f: Fixture = try load("webauthn.json")
        let synced = f.cases.first { $0.name == "registration/synced-passkey" }!
        let root = try XCTUnwrap(WebAuthnRegistration.root(
            fromAttestationObject: hex(synced.attestation_object), rpID: f.rp_id))
        let parsed = try XCTUnwrap(E2EIdentity.parseRoot(root))
        XCTAssertEqual(parsed.rpID, f.rp_id)
        XCTAssertEqual(hex(parsed.credentialID), synced.credential_id)
        XCTAssertEqual(hex(parsed.publicKey), synced.public_key)

        XCTAssertNil(WebAuthnRegistration.root(fromAttestationObject: hex(synced.attestation_object),
                                               rpID: "elsewhere.example"), "another relying party")
        let unverified = f.cases.first { $0.name == "registration/no-user-verification" }!
        XCTAssertNotNil(WebAuthnRegistration.parseAttestedCredential(hex(unverified.attestation_object)),
                        "readable…")
        XCTAssertNil(WebAuthnRegistration.root(fromAttestationObject: hex(unverified.attestation_object),
                                               rpID: f.rp_id), "…but not a root: UV is required")
    }
}
