import XCTest
@testable import RdevCore

/// §2 and §10.4's HTTPS-to-native ceremony return, against the session fixture's real chains.
///
/// This is the path that lets a Mac app hold a DIRECT grant without the associated-domains
/// entitlement, so it is the path that decides whether the app is a full peer or only ever a
/// code-enrolled one. §18 lists it among the things that must be validated before claiming
/// conformance — these tests are the half that can be validated here.
final class E2ENativeReturnTests: XCTestCase {

    private struct Device: Decodable {
        let descriptor: String, device_id: String, bundle: String
    }
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

    /// H holds a direct root-issued grant with capabilities 7 — which is exactly what this ceremony
    /// produces, so H's bundle stands in for a returned one. Its operation id comes from the grant
    /// itself, because that is what the app would have persisted before asking.
    private func operationID(of name: String) throws -> [UInt8] {
        guard case .success(let bundle) = E2ECertificate.parseBundle(hex(dev(name).bundle)),
              let grant = E2EIdentity.parseGrant(bundle.certificates[0].grant)
        else { throw E2ENativeReturn.Failure.chain }
        return grant.operationID
    }

    private func accept(bundleOf name: String = "H",
                        pending: [UInt8]?? = nil,
                        descriptorOf: String? = nil,
                        revoked: Set<[UInt8]> = []) throws -> String {
        let result = E2ENativeReturn.accept(
            bundle: hex(dev(name).bundle),
            pendingOperationID: try pending ?? operationID(of: name),
            deviceDescriptor: hex(dev(descriptorOf ?? name).descriptor),
            trustedRootID: hex(fx.root_id), policy: policy, revokedDeviceIDs: revoked)
        switch result {
        case .success: return "ok"
        case .failure(let f): return f.rawValue
        }
    }

    func testAWellBoundReturnIsAccepted() throws {
        XCTAssertEqual(try accept(), "ok")
    }

    /// §10.4: bound to "**that exact pending operation**". A grant for a different operation is a
    /// grant for a different ceremony, however valid it is.
    func testAGrantForAnotherOperationIsRefused() throws {
        XCTAssertEqual(try accept(pending: .some(Array(repeating: 0xEE, count: 32))),
                       "operation-mismatch")
    }

    /// ...and "**key descriptor**". THE DESCRIPTOR ITSELF: two devices can share a DH key with
    /// different signing keys, so anything less admits a grant for an identity built around this
    /// app's public key. Y is exactly that device.
    func testAGrantForAnotherDescriptorIsRefused() throws {
        XCTAssertEqual(try accept(bundleOf: "H", pending: try operationID(of: "H"),
                                  descriptorOf: "C"), "descriptor-mismatch")
        // And the DH-key collision specifically: C and Y share a noise key.
        XCTAssertEqual(dev("C").descriptor.suffix(64), dev("Y").descriptor.suffix(64))
        XCTAssertEqual(try accept(bundleOf: "Y", pending: try operationID(of: "Y"),
                                  descriptorOf: "C"), "descriptor-mismatch")
    }

    /// §10.4 binds the return to a PENDING operation. An unsolicited return is not a slow answer to
    /// something — nothing asked for it.
    func testAReturnWithNothingPendingIsRefused() throws {
        XCTAssertEqual(try accept(pending: .some(nil)), "nothing-pending")
    }

    /// §12.1: this ceremony produces a DIRECT grant. A leaf arriving here means the browser
    /// delegated instead of using the passkey — a different ceremony with different authority,
    /// since §10.3 forbids `enroll` on a leaf.
    func testALeafGrantIsRefusedEvenWhenItVerifies() throws {
        XCTAssertEqual(try accept(bundleOf: "C"), "not-direct")
    }

    func testAnUnverifiableBundleIsAHardStopWithoutDetail() throws {
        var corrupt = hex(dev("H").bundle)
        corrupt[corrupt.count - 1] ^= 0x01
        let result = E2ENativeReturn.accept(
            bundle: corrupt, pendingOperationID: try operationID(of: "H"),
            deviceDescriptor: hex(dev("H").descriptor),
            trustedRootID: hex(fx.root_id), policy: policy)
        guard case .failure(let f) = result else { return XCTFail("must refuse") }
        // §14 gives one action for an invalid signature or chain: hard stop. A caller has nothing
        // to decide between, so the failure carries no detail to decide with.
        XCTAssertEqual(f, .chain)
    }

    func testARevokedDeviceCannotArriveThroughTheReturnPath() throws {
        XCTAssertEqual(try accept(revoked: [hex(dev("H").device_id)]), "chain")
    }

    // MARK: - §2: an account token is not a passkey grant

    /// The surrounding product already opens the system browser and polls for an ACCOUNT TOKEN
    /// (`docs/accounts.md`), and the two returns travel the same way. §2 is pointed about it.
    func testAnAccountTokenIsNotABundle() {
        let token = Array("d5a9507e-1234-4abc-9def-0123456789c2".utf8)
        let result = E2ENativeReturn.accept(
            bundle: token, pendingOperationID: Array(repeating: 1, count: 32),
            deviceDescriptor: hex(dev("H").descriptor),
            trustedRootID: hex(fx.root_id), policy: policy)
        guard case .failure(let f) = result else { return XCTFail("a token is not a grant") }
        XCTAssertEqual(f, .notABundle)
    }
}
