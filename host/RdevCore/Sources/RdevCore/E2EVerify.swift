import CryptoKit
import Foundation

/// §10.4 signature verification — Ed25519 over a device-issued grant, WebAuthn ES256 over a
/// root-issued one, and the whole-bundle check that combines them with §10.3's chain rules and
/// §10.5's tombstones.
///
/// `E2EIdentity.validateChainStructure` decides everything a signature is not needed for, and says
/// in its own documentation that success there is necessary and not sufficient. **This is the
/// sufficient half.** Nothing above this layer may treat a chain as authority without it.
///
/// Held to `protocol/fixtures/e2e-certificate.json`, whose 33 verification cases each mutate ONE
/// thing and are re-signed, so a case fails for exactly one reason and names it. A verifier that
/// rejects everything passes none of them.
public enum E2EVerify {

    /// Deployment configuration, and §10.1 is emphatic about where it comes from: the relying-party
    /// ID and the accepted ceremony origins "are also configured in trusted application code, not in
    /// an incoming certificate". Nothing on the wire may widen either.
    public struct Policy: Sendable, Equatable {
        public let rpID: String
        public let allowedOrigins: [String]

        public init(rpID: String, allowedOrigins: [String]) {
            self.rpID = rpID
            self.allowedOrigins = allowedOrigins
        }
    }

    /// Every way a bundle can be refused. The raw values are the codes the shared fixture uses, so
    /// the three implementations agree on the REASON and not merely on the rejection — "rejected for
    /// the wrong reason" is a real class of defect, and it is exactly the one that survives a test
    /// suite that only asserts failure.
    public enum Failure: String, Error, Equatable, Sendable {
        case malformed = "malformed"
        case countInvalid = "count-invalid"
        /// The bundle's own root descriptor is not the root this endpoint trusts. §10.1: "An
        /// incoming chain is never allowed to replace an already trusted root."
        case rootMismatch = "root-mismatch"

        case chainEmpty = "chain/empty"
        case chainTooLong = "chain/too-long"
        case chainMalformedGrant = "chain/malformed-grant"
        case chainRootMismatch = "chain/root-mismatch"
        case chainFirstNotRootIssued = "chain/first-not-root-issued"
        case chainSecondNotChainedToFirst = "chain/second-not-chained-to-first"
        case chainUnauthorisedCapabilities = "chain/unauthorised-capabilities"

        case credentialMismatch = "credential-mismatch"
        case clientDataType = "clientdata-type"
        case clientDataChallenge = "clientdata-challenge"
        case clientDataOrigin = "clientdata-origin"
        case clientDataCrossOrigin = "clientdata-crossorigin"
        case clientDataDuplicate = "clientdata-duplicate"
        case rpIDHash = "rpid-hash"
        case userPresence = "user-presence"
        case userVerification = "user-verification"
        case signature = "signature"
        case revoked = "revoked"
        /// The certified leaf is not the peer this Noise session authenticated. §10.4: "require the
        /// final device's DH key to equal the static key authenticated by Noise."
        case noiseStaticMismatch = "noise-static-mismatch"
    }

    public struct VerifiedChain: Sendable {
        public let root: E2EIdentity.Root
        public let grants: [E2EIdentity.Grant]
        public let leaf: E2EIdentity.Grant
        public let leafDevice: E2EIdentity.Device

        public var capabilities: E2EIdentity.Capabilities { leaf.capabilities }
    }

    // MARK: - Ed25519

    public static func ed25519PublicKey(privateKey: [UInt8]) -> [UInt8]? {
        guard let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(privateKey))
        else { return nil }
        return Array(k.publicKey.rawRepresentation)
    }

    public static func signEd25519(message: [UInt8], privateKey: [UInt8]) -> [UInt8]? {
        guard let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(privateKey)),
              let sig = try? k.signature(for: Data(message)) else { return nil }
        return Array(sig)
    }

    public static func verifyEd25519(signature: [UInt8], message: [UInt8],
                                     publicKey: [UInt8]) -> Bool {
        guard signature.count == E2EWire.signatureLength,
              let k = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(publicKey))
        else { return false }
        return k.isValidSignature(Data(signature), for: Data(message))
    }

    // MARK: - WebAuthn ES256

    static let flagUserPresent: UInt8 = 0x01
    static let flagUserVerified: UInt8 = 0x04
    /// 32-byte RP-ID hash + 1 flags byte + 4 signature-counter bytes. §10.4 reads the counter and
    /// then ignores it: "Syncable credentials may have non-monotonic/zero signature counters; those
    /// counters are not a global freshness or revocation mechanism."
    static let authenticatorDataMinimum = 37

    /// Verify a WebAuthn assertion as the evidence for `grant`. Returns nil on success, or the one
    /// reason it was refused.
    ///
    /// The order is deliberate: everything decidable from the message itself runs BEFORE the elliptic
    /// curve operation, so a flood of malformed assertions costs parsing rather than signature
    /// verification.
    public static func verifyAssertion(_ a: E2ECertificate.Assertion, preimage: [UInt8],
                                       root: E2EIdentity.Root, policy: Policy) -> Failure? {
        // §10.1/§10.4: "Restrict the request to that candidate's credential ID ... and reject an
        // assertion returning any other credential ID."
        guard a.credentialID == root.credentialID else { return .credentialMismatch }

        guard let members = topLevelMembers(a.clientDataJSON) else { return .malformed }
        var seen = Set<String>()
        var fields: [String: [UInt8]] = [:]
        for (keyToken, valueToken) in members {
            guard let key = jsonString(keyToken) else { return .malformed }
            // §10.4: "Reject duplicate security-relevant JSON fields." STRICTER THAN THAT ON
            // PURPOSE — any duplicate top-level name is refused, because "security-relevant" is a
            // judgement someone would have to re-make correctly for every field added later, and
            // the two parsers that disagree about which copy wins are the whole attack.
            guard seen.insert(key).inserted else { return .clientDataDuplicate }
            fields[key] = valueToken
        }

        guard let typeToken = fields["type"], jsonString(typeToken) == "webauthn.get" else {
            return .clientDataType
        }
        guard let challengeToken = fields["challenge"],
              let challenge = jsonString(challengeToken),
              let decoded = base64urlDecode(challenge),
              decoded == E2EIdentity.sha256(preimage) else { return .clientDataChallenge }

        // §10.4: "reject cross-origin ceremonies in this version". Compared against the literal
        // token rather than a decoded value: `"crossOrigin": 1` must not coerce to false.
        if let cross = fields["crossOrigin"] {
            switch String(bytes: cross, encoding: .utf8) {
            case "true": return .clientDataCrossOrigin
            case "false": break
            default: return .malformed
            }
        }
        guard let originToken = fields["origin"], let origin = jsonString(originToken),
              policy.allowedOrigins.contains(origin) else { return .clientDataOrigin }

        guard a.authenticatorData.count >= authenticatorDataMinimum else { return .malformed }
        guard Array(a.authenticatorData[0 ..< 32]) == E2EIdentity.sha256(Array(policy.rpID.utf8))
        else { return .rpIDHash }
        let flags = a.authenticatorData[32]
        guard flags & flagUserPresent != 0 else { return .userPresence }
        // §10.4: "Require `userVerification: \"required\"`" — which is only a request at ceremony
        // time. This bit is the part that can be checked afterwards.
        guard flags & flagUserVerified != 0 else { return .userVerification }

        guard let key = try? P256.Signing.PublicKey(x963Representation: Data(root.publicKey)),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: Data(a.signature))
        else { return .signature }
        let signed = a.authenticatorData + E2EIdentity.sha256(a.clientDataJSON)
        // CryptoKit applies SHA-256 itself, which is what ES256 specifies, and it accepts a high-S
        // signature. THAT IS REQUIRED, not incidental: WebAuthn authenticators are under no
        // obligation to normalise, and a verifier enforcing low-S rejects real passkeys. The
        // fixture carries a high-S assertion so neither implementation can drift into doing that.
        guard key.isValidSignature(sig, for: Data(signed)) else { return .signature }
        return nil
    }

    // MARK: - the bundle

    /// Verify a §10.4 bundle end to end: framing, the trusted root, §10.3's chain rules, §10.5's
    /// tombstones, every signature, and — when given — that the certified leaf is the Noise peer.
    ///
    /// `expectedNoiseStatic` is optional because §10.4 asks for that equality only where a live
    /// handshake supplies the static key. Passing nil verifies the certificate; it does not bind it
    /// to a session, and a caller holding a session must not pass nil.
    public static func verifyBundle(_ bytes: [UInt8], trustedRootID: [UInt8], policy: Policy,
                                    revokedDeviceIDs: Set<[UInt8]> = [],
                                    expectedNoiseStatic: [UInt8]? = nil)
        -> Result<VerifiedChain, Failure> {

        let parsed: E2ECertificate.Bundle
        switch E2ECertificate.parseBundle(bytes) {
        case .success(let b): parsed = b
        case .failure(.countInvalid): return .failure(.countInvalid)
        case .failure(.malformed): return .failure(.malformed)
        }

        guard let root = E2EIdentity.parseRoot(parsed.root) else { return .failure(.malformed) }
        // The bundle carries its own root descriptor, so this is the step that makes it OURS. An
        // attacker may present a perfectly signed chain under a root of their own creation.
        guard root.id == trustedRootID else { return .failure(.rootMismatch) }

        let chain = parsed.certificates.map(\.grant)
        let leafGrant: E2EIdentity.Grant
        switch E2EIdentity.validateChainStructure(chain, trustedRootID: trustedRootID) {
        case .success(let g): leafGrant = g
        case .failure(let f): return .failure(map(f))
        }

        var grants: [E2EIdentity.Grant] = []
        var devices: [E2EIdentity.Device] = []
        for certificate in parsed.certificates {
            guard let g = E2EIdentity.parseGrant(certificate.grant),
                  let d = E2EIdentity.parseDevice(g.device) else { return .failure(.malformed) }
            // The device descriptor names a root too, and a device scoped to another root inside a
            // grant for this one is incoherent rather than merely unlucky. Fail closed on nonsense.
            guard d.rootID == trustedRootID else { return .failure(.chainRootMismatch) }
            grants.append(g)
            devices.append(d)
        }

        // §10.5: "Reject any chain containing a tombstoned device, including an Issuer." Before the
        // signatures, so a revoked device costs no curve operations — its status is not a secret.
        for d in devices where revokedDeviceIDs.contains(d.id) { return .failure(.revoked) }

        for (index, certificate) in parsed.certificates.enumerated() {
            let g = grants[index]
            switch g.issuerKind {
            case .root:
                // The evidence form is chosen HERE, by the grant. Never by probing the bytes:
                // the forms are not disjoint (a crafted 64-byte value parses as an assertion), so a
                // verifier that falls back from one to the other lets the sender pick its check.
                guard let assertion = E2ECertificate.parseAssertion(certificate.evidence)
                else { return .failure(.malformed) }
                // **THE PIN IS INSIDE THIS CALL, WHICH IS WHY IT CANNOT BE SKIPPED** — see the
                // TypeScript mirror for the full reasoning. §10.4's challenge is
                // `H(grant_commitment)`, which does NOT cover `root_id` or `issuer_id`, and
                // `grantCommitment` yields no pre-image unless both plus the device's `root_id`
                // equal the trusted root id. A verifier that skips the check fails closed.
                guard let preimage = E2EIdentity.grantCommitment(g, trustedRootID: trustedRootID)
                else { return .failure(.chainRootMismatch) }
                if let failure = verifyAssertion(assertion, preimage: preimage,
                                                 root: root, policy: policy) {
                    return .failure(failure)
                }
            case .device:
                // §10.3: a device-issued grant must "use its certified signing key" — the parent's,
                // which the chain rules have already established is `grants[index - 1]`.
                guard index > 0 else { return .failure(.chainFirstNotRootIssued) }
                guard certificate.evidence.count == E2EWire.signatureLength
                else { return .failure(.malformed) }
                guard verifyEd25519(signature: certificate.evidence, message: g.bytes,
                                    publicKey: devices[index - 1].signingPublicKey)
                else { return .failure(.signature) }
            }
        }

        guard let leafDevice = devices.last else { return .failure(.malformed) }
        if let expected = expectedNoiseStatic, leafDevice.noisePublicKey != expected {
            return .failure(.noiseStaticMismatch)
        }
        return .success(VerifiedChain(root: root, grants: grants,
                                      leaf: leafGrant, leafDevice: leafDevice))
    }

    static func map(_ f: E2EIdentity.ChainFailure) -> Failure {
        switch f {
        case .empty: return .chainEmpty
        case .tooLong: return .chainTooLong
        case .malformedGrant: return .chainMalformedGrant
        case .rootMismatch: return .chainRootMismatch
        case .firstNotRootIssued: return .chainFirstNotRootIssued
        case .secondNotChainedToFirst: return .chainSecondNotChainedToFirst
        case .unauthorisedCapabilities: return .chainUnauthorisedCapabilities
        }
    }

    // MARK: - the JSON clientDataJSON needs, and no more

    /// Decode ONE JSON string token (quotes included) with the platform parser, so escapes,
    /// surrogate pairs and UTF-8 are handled by code that is already correct. Nil for anything that
    /// is not a JSON string.
    static func jsonString(_ token: [UInt8]) -> String? {
        guard let any = try? JSONSerialization.jsonObject(with: Data(token),
                                                          options: [.fragmentsAllowed]),
              let s = any as? String else { return nil }
        return s
    }

    /// The ordered top-level members of a JSON object, as raw (key token, value token) slices.
    ///
    /// **THIS EXISTS BECAUSE EVERY PLATFORM JSON PARSER DESTROYS THE EVIDENCE.** `JSONSerialization`
    /// and `JSON.parse` both collapse a duplicated name silently — one keeps the last, and a
    /// different parser elsewhere may keep the first — so `{"origin":"good","origin":"evil"}` is
    /// exactly the ambiguity §10.4 asks to be rejected, and by the time a dictionary exists it is
    /// gone. The scanner only has to find member boundaries; the values are still decoded by the
    /// platform parser afterwards.
    static func topLevelMembers(_ json: [UInt8]) -> [([UInt8], [UInt8])]? {
        var i = 0
        let n = json.count

        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func skipSpace() { while i < n, isSpace(json[i]) { i += 1 } }

        func skipString() -> Bool {
            guard i < n, json[i] == 0x22 else { return false }
            i += 1
            while i < n {
                let c = json[i]
                if c == 0x5C { i += 2; continue }        // an escape consumes the next byte, whole
                i += 1
                if c == 0x22 { return true }
            }
            return false
        }

        func skipValue() -> Range<Int>? {
            let start = i
            guard i < n else { return nil }
            switch json[i] {
            case 0x22:
                guard skipString() else { return nil }
            case 0x7B, 0x5B:                            // a nested object or array is skipped whole
                var depth = 0
                while i < n {
                    let c = json[i]
                    if c == 0x22 { guard skipString() else { return nil }; continue }
                    if c == 0x7B || c == 0x5B { depth += 1; i += 1; continue }
                    if c == 0x7D || c == 0x5D {
                        depth -= 1; i += 1
                        if depth == 0 { return start ..< i }
                        continue
                    }
                    i += 1
                }
                return nil
            default:                                    // number, true, false, null
                while i < n, json[i] != 0x2C, json[i] != 0x7D, json[i] != 0x5D, !isSpace(json[i]) {
                    i += 1
                }
                if i == start { return nil }
            }
            return start ..< i
        }

        skipSpace()
        guard i < n, json[i] == 0x7B else { return nil }
        i += 1
        var members: [([UInt8], [UInt8])] = []
        skipSpace()
        if i < n, json[i] == 0x7D { i += 1; skipSpace(); return i == n ? members : nil }

        while true {
            skipSpace()
            let keyStart = i
            guard skipString() else { return nil }
            let key = Array(json[keyStart ..< i])
            skipSpace()
            guard i < n, json[i] == 0x3A else { return nil }
            i += 1
            skipSpace()
            guard let value = skipValue() else { return nil }
            members.append((key, Array(json[value])))
            skipSpace()
            guard i < n else { return nil }
            if json[i] == 0x2C { i += 1; continue }
            if json[i] == 0x7D { i += 1; break }
            return nil
        }
        skipSpace()
        return i == n ? members : nil
    }
}
