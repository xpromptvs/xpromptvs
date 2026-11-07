import CryptoKit
import XCTest
@testable import RdevCore

/// The Mac's own ceremony, as decisions (`E2EPasskeyGrant`): the request frozen before a prompt, the
/// pin on a discovered descriptor, and the grant assembled from an answer — against a software
/// authenticator that signs real ES256, because what matters is that the bytes a passkey signed are
/// the bytes every verifier rebuilds.
final class E2EPasskeyGrantTests: XCTestCase {

    private let policy = E2EVerify.Policy(rpID: "rp.example", allowedOrigins: ["https://rp.example"])
    private let key = P256.Signing.PrivateKey()
    private let credentialID: [UInt8] = Array(repeating: 0xC1, count: 20)
    private let keys = DeviceIdentity.Keys(signingPrivateKey: Array(repeating: 0x11, count: 32),
                                           noisePrivateKey: Array(repeating: 0x2A, count: 32))!

    private var root: [UInt8] {
        E2EIdentity.root(rpID: policy.rpID, credentialID: credentialID,
                         rootPublicKey: Array(key.publicKey.x963Representation))!
    }

    /// What a platform authenticator returns for `challenge`, given `origin` and `rpID`.
    private func answer(_ challenge: [UInt8], rpID: String? = nil, origin: String = "https://rp.example",
                        credential: [UInt8]? = nil) -> E2EPasskeyGrant.Answer {
        let clientData = Array(#"{"type":"webauthn.get","challenge":"\#(base64urlEncode(Data(challenge)))","origin":"\#(origin)"}"#.utf8)
        let authData = E2EIdentity.sha256(Array((rpID ?? policy.rpID).utf8)) + [0x05, 0, 0, 0, 0]
        let signature = Array(try! key.signature(for: Data(authData + E2EIdentity.sha256(clientData)))
            .derRepresentation)
        return .init(credentialID: credential ?? credentialID, clientDataJSON: clientData,
                     authenticatorData: authData, signature: signature, largeBlob: nil)
    }

    /// §12.1's direct grant: root-issued, a LOCAL binding drawn fresh, capabilities 7 — and the
    /// challenge is the hash of a commitment that names NO root, which is what lets one prompt both
    /// find the identity and authorise this device.
    func testTheRequestCommitsToThisDevicesKeysAndNoRoot() throws {
        var draws = 0
        let request = try XCTUnwrap(E2EPasskeyGrant.request(keys: keys) { n in
            draws += 1
            return Array(repeating: UInt8(draws), count: n)
        })
        XCTAssertEqual(request.operationID, Array(repeating: 1, count: 32))
        XCTAssertEqual(request.binding, .local(randomness: Array(repeating: 2, count: 32)))
        XCTAssertEqual(request.capabilities, .full)
        XCTAssertEqual(request.preimage, E2EIdentity.grantCommitmentPreimage(
            operationID: request.operationID, issuerKind: .root, signingPublicKey: keys.signingPublicKey!,
            noisePublicKey: keys.noisePublicKey!, capabilities: .full, binding: request.binding))
        XCTAssertEqual(request.challenge, E2EIdentity.sha256(request.preimage))
        XCTAssertEqual(request.preimage.count, 159, "the commitment's fixed width (protocol/src/e2e-identity.ts)")
    }

    func testTwoRequestsNeverShareAnOperationOrABinding() throws {
        let a = try XCTUnwrap(E2EPasskeyGrant.request(keys: keys))
        let b = try XCTUnwrap(E2EPasskeyGrant.request(keys: keys))
        XCTAssertNotEqual(a.operationID, b.operationID)
        XCTAssertNotEqual(a.binding, b.binding)
    }

    /// The grant built from the answer verifies end to end under the root it names, at capability 7,
    /// for THIS device's descriptor.
    func testTheAssembledBundleVerifies() throws {
        let request = try XCTUnwrap(E2EPasskeyGrant.request(keys: keys))
        let parsed = try XCTUnwrap(E2EIdentity.parseRoot(root))
        let bundle = try XCTUnwrap(E2EPasskeyGrant.bundle(root: parsed, answer: answer(request.challenge),
                                                          request: request, keys: keys, policy: policy))
        guard case .success(let chain) = E2EVerify.verifyBundle(bundle, trustedRootID: parsed.id, policy: policy)
        else { return XCTFail("the bundle must verify") }
        XCTAssertEqual(chain.capabilities, .full)
        XCTAssertEqual(chain.leaf.operationID, request.operationID)
        XCTAssertEqual(chain.leafDevice.bytes, keys.descriptor(rootID: parsed.id))
    }

    /// An answer signed for ANOTHER request does not become this one's grant.
    func testAnAnswerForAnotherRequestBuildsNothing() throws {
        let request = try XCTUnwrap(E2EPasskeyGrant.request(keys: keys))
        let other = try XCTUnwrap(E2EPasskeyGrant.request(keys: keys))
        let parsed = try XCTUnwrap(E2EIdentity.parseRoot(root))
        XCTAssertNil(E2EPasskeyGrant.bundle(root: parsed, answer: answer(other.challenge),
                                            request: request, keys: keys, policy: policy))
        XCTAssertEqual(E2EPasskeyGrant.verifyDiscoveredRoot(root: root, answer: answer(other.challenge),
                                                            request: request, policy: policy),
                       .failure(.refused(.clientDataChallenge)))
    }

    /// `verifyDiscoveredRoot` pins every field of a descriptor somebody NAMED: the credential, the key
    /// (through the signature) and the relying party — the check `verifyBundle` does not need.
    func testADiscoveredDescriptorIsPinnedFieldByField() throws {
        let request = try XCTUnwrap(E2EPasskeyGrant.request(keys: keys))
        let good = answer(request.challenge)
        guard case .success(let r) = E2EPasskeyGrant.verifyDiscoveredRoot(
            root: root, answer: good, request: request, policy: policy) else { return XCTFail("the honest case") }
        XCTAssertEqual(r.bytes, root)

        let otherKey = P256.Signing.PrivateKey()
        let squat = E2EIdentity.root(rpID: policy.rpID, credentialID: credentialID,
                                     rootPublicKey: Array(otherKey.publicKey.x963Representation))!
        XCTAssertEqual(E2EPasskeyGrant.verifyDiscoveredRoot(root: squat, answer: good, request: request,
                                                            policy: policy), .failure(.refused(.signature)))
        let elsewhere = E2EIdentity.root(rpID: "elsewhere.example", credentialID: credentialID,
                                         rootPublicKey: Array(key.publicKey.x963Representation))!
        XCTAssertEqual(E2EPasskeyGrant.verifyDiscoveredRoot(root: elsewhere, answer: good, request: request,
                                                            policy: policy), .failure(.rootRPID))
        XCTAssertEqual(E2EPasskeyGrant.verifyDiscoveredRoot(
            root: root, answer: answer(request.challenge, credential: [9, 9]), request: request,
            policy: policy), .failure(.refused(.credentialMismatch)))
        XCTAssertEqual(E2EPasskeyGrant.verifyDiscoveredRoot(
            root: root, answer: answer(request.challenge, origin: "https://evil.example"), request: request,
            policy: policy), .failure(.refused(.clientDataOrigin)))
        XCTAssertEqual(E2EPasskeyGrant.verifyDiscoveredRoot(root: [1, 2, 3], answer: good, request: request,
                                                            policy: policy), .failure(.malformed))
    }
}
