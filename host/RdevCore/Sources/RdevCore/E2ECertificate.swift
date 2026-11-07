import Foundation

/// The §10.4 evidence encodings — the WebAuthn assertion, the certificate that pairs a grant with
/// the evidence authorising it, and the bundle that carries a whole chain.
///
/// ```
/// assertion   = LP(credential_id) || LP(clientDataJSON) || LP(authenticatorData) || LP(signature)
/// certificate = LP(grant) || LP(evidence)     evidence = assertion | raw Ed25519 signature
/// bundle      = LP(root) || U8(count) || LP(certificate_1) [|| LP(certificate_2)]
/// ```
///
/// **WHICH EVIDENCE FORM APPLIES IS DECIDED BY THE GRANT, NEVER BY PROBING THE BYTES.** The two
/// forms are not disjoint: `protocol/fixtures/e2e-certificate.json` carries a CRAFTED 64-byte value
/// — the width of a raw Ed25519 signature — that parses cleanly as an assertion. A verifier that
/// tries one form and falls back to the other therefore lets the party supplying the evidence
/// choose which check it faces, so `issuer_kind` picks and a mismatch is a rejection rather than a
/// second attempt. The hazard is deliberate construction, not coincidence — a real signature
/// colliding with the assertion grammar is ~1e-14, and 0 of 2,000,000 random ones did.
///
/// PURE. Nothing here verifies a signature; that is `E2EVerify`, which needs key material and a
/// deployment policy. This layer decides only what the bytes mean.
public enum E2ECertificate {

    /// A parsed WebAuthn assertion. `clientDataJSON` is kept as the ORIGINAL OCTETS: §10.4 says
    /// "Do not reserialize `clientDataJSON`", because the signature is over exactly those bytes and
    /// any round trip through a JSON encoder is free to change them.
    public struct Assertion: Equatable, Sendable {
        public let credentialID: [UInt8]
        public let clientDataJSON: [UInt8]
        public let authenticatorData: [UInt8]
        public let signature: [UInt8]

        public init(credentialID: [UInt8], clientDataJSON: [UInt8],
                    authenticatorData: [UInt8], signature: [UInt8]) {
            self.credentialID = credentialID
            self.clientDataJSON = clientDataJSON
            self.authenticatorData = authenticatorData
            self.signature = signature
        }
    }

    /// A grant and the evidence that authorises it, still undivided: `evidence` is whatever the
    /// certificate carried, and the caller decides how to read it from the grant's issuer kind.
    public struct Certificate: Equatable, Sendable {
        public let grant: [UInt8]
        public let evidence: [UInt8]
    }

    public struct Bundle: Equatable, Sendable {
        public let root: [UInt8]
        public let certificates: [Certificate]
    }

    /// `countInvalid` is separated from `malformed` because it is the one framing error a peer can
    /// make that says something specific — it declared a chain length this protocol does not have.
    public enum ParseFailure: Error, Equatable, Sendable {
        case malformed, countInvalid
    }

    public static func assertion(credentialID: [UInt8], clientDataJSON: [UInt8],
                                 authenticatorData: [UInt8], signature: [UInt8]) -> [UInt8]? {
        guard let c = E2EWire.lengthPrefixed(credentialID),
              let d = E2EWire.lengthPrefixed(clientDataJSON),
              let a = E2EWire.lengthPrefixed(authenticatorData),
              let s = E2EWire.lengthPrefixed(signature) else { return nil }
        return c + d + a + s
    }

    public static func parseAssertion(_ bytes: [UInt8]) -> Assertion? {
        var r = E2EWire.Reader(bytes)
        guard let credentialID = r.lengthPrefixed(),
              let clientDataJSON = r.lengthPrefixed(),
              let authenticatorData = r.lengthPrefixed(),
              let signature = r.lengthPrefixed(),
              r.atEnd                                   // §7: trailing bytes are a rejection
        else { return nil }
        return Assertion(credentialID: credentialID, clientDataJSON: clientDataJSON,
                         authenticatorData: authenticatorData, signature: signature)
    }

    public static func certificate(grant: [UInt8], evidence: [UInt8]) -> [UInt8]? {
        guard let g = E2EWire.lengthPrefixed(grant),
              let e = E2EWire.lengthPrefixed(evidence) else { return nil }
        return g + e
    }

    public static func parseCertificate(_ bytes: [UInt8]) -> Certificate? {
        var r = E2EWire.Reader(bytes)
        guard let grant = r.lengthPrefixed(), let evidence = r.lengthPrefixed(), r.atEnd
        else { return nil }
        return Certificate(grant: grant, evidence: evidence)
    }

    /// `bundle = LP(root) || U8(count) || LP(certificate_1) [|| LP(certificate_2)]`, root-to-leaf.
    /// Refuses to encode a chain length §10.3 does not permit, rather than leaving it to a verifier.
    public static func bundle(root: [UInt8], certificates: [[UInt8]]) -> [UInt8]? {
        guard certificates.count == 1 || certificates.count == 2,
              let r = E2EWire.lengthPrefixed(root) else { return nil }
        var out = r + [UInt8(certificates.count)]
        for c in certificates {
            guard let lp = E2EWire.lengthPrefixed(c) else { return nil }
            out += lp
        }
        return out
    }

    public static func parseBundle(_ bytes: [UInt8]) -> Result<Bundle, ParseFailure> {
        var r = E2EWire.Reader(bytes)
        guard let root = r.lengthPrefixed(), let count = r.takeByte() else {
            return .failure(.malformed)
        }
        // Checked at the declared length, BEFORE reading that many certificates: "No chain has
        // more than two grants" (§10.3), so a bundle claiming 255 costs one comparison.
        guard count == 1 || count == 2 else { return .failure(.countInvalid) }

        var certificates: [Certificate] = []
        for _ in 0 ..< count {
            guard let raw = r.lengthPrefixed(), let c = parseCertificate(raw) else {
                return .failure(.malformed)
            }
            certificates.append(c)
        }
        guard r.atEnd else { return .failure(.malformed) }
        return .success(Bundle(root: root, certificates: certificates))
    }
}
