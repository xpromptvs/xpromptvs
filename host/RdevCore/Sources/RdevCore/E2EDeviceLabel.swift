import Foundation

/// A device's human-readable name, **signed by someone entitled to assign it**.
///
/// ```
/// label = LP("rdev-e2e/device-label/v1") || root_id || device_id || LP(name)
/// ```
///
/// **AN ADDITION TO THE SPECIFICATION, not one of its sections**, and it exists to close a gap the
/// specification names without closing. §10.1's residual says of a root: "that name MUST come from
/// local state or from the authenticator's own credential metadata, **never from a directory-supplied
/// label, which the same adversary chose**." The same argument applies to a Host in an account list,
/// where today the name is host-supplied, Worker-stored and client-displayed — which is precisely a
/// directory-supplied label.
///
/// What that costs without this: §4's adversary cannot invent a device (that needs the root passkey)
/// but **can swap the names on two devices the user really owns**, so a user types into the wrong
/// machine. This makes the name as trustworthy as the device that assigned it.
///
/// **THE RULE IS ABOUT AUTHORITY, NOT ABOUT WHO.** The signer must hold `enroll` — and nothing
/// stops that being the device being named. A device that enrolled itself with a passkey holds a
/// direct grant with `enroll`, so it names itself, which is the ordinary case: the person is sitting
/// at the machine they are naming. `E2EDeviceLabelTests` pins both halves against the same fixture.
///
/// What the rule excludes is a device WITHOUT that authority naming anything, itself included. §6
/// accepts that "a directly enrolled device can issue access-only leaf grants", so a compromised
/// leaf is inside the model — and a leaf that could name itself "Isaac's MacBook" is the same attack
/// in the one place a user actually looks. A compromised `enroll` holder could of course lie about
/// its own name, but it could also enroll an attacker's device outright (§6, "Issuer compromise"),
/// so its name is not the marginal risk.
///
/// **ORDERING, not a circularity:** the label is signed AFTER the grant exists. A device being
/// enrolled has no authority until its grant is issued, and then it has enough. A device that will
/// never hold `enroll` — anything code-enrolled, capabilities 1 or 3 — can never name itself, and
/// its Issuer names it; the Issuer is present at a code enrollment by construction.
///
/// It does NOT take a passkey ceremony: renaming a machine should not prompt for a fingerprint.
public enum E2EDeviceLabel {

    /// Generous for a human name, small enough that a list stays a list. Measured in BYTES because
    /// that is what the length prefix carries.
    public static let maximumNameBytes = 128

    static let label = "rdev-e2e/device-label/v1"

    public struct Label: Equatable, Sendable {
        public let bytes: [UInt8]
        public let rootID: [UInt8]
        public let deviceID: [UInt8]
        public let name: String
    }

    public enum Failure: String, Error, Equatable, Sendable {
        case malformed = "malformed"
        /// The name is not something to put in front of a person.
        case unsafeName = "unsafe-name"
        /// The label names a root this endpoint does not trust.
        case rootMismatch = "root-mismatch"
        /// The signer's own chain did not verify.
        case signerChain = "signer-chain"
        /// The signer's chain is valid and does not carry `enroll`.
        case signerNotAuthorised = "signer-not-authorised"
        case signature = "signature"
        /// The label names a device other than the one being displayed.
        case deviceMismatch = "device-mismatch"
    }

    /// `LP("rdev-e2e/device-label/v1") || root_id || device_id || LP(name)`
    public static func body(rootID: [UInt8], deviceID: [UInt8], name: String) -> [UInt8]? {
        guard rootID.count == E2EWire.idLength, deviceID.count == E2EWire.idLength,
              nameIsSafe(name) else { return nil }
        guard let encoded = E2EWire.lengthPrefixed(Array(name.utf8)) else { return nil }
        return E2EWire.lp(label) + rootID + deviceID + encoded
    }

    public static func parse(_ bytes: [UInt8]) -> Label? {
        var r = E2EWire.Reader(bytes)
        guard r.expectLabel(label),
              let rootID = r.take(E2EWire.idLength),
              let deviceID = r.take(E2EWire.idLength),
              let raw = r.lengthPrefixed(),
              let name = String(bytes: raw, encoding: .utf8),
              r.atEnd,
              nameIsSafe(name)
        else { return nil }
        return Label(bytes: bytes, rootID: rootID, deviceID: deviceID, name: name)
    }

    /// What may be shown to a person in a list of machines they are about to control.
    ///
    /// **Control characters and bidirectional overrides are refused**, and that is not general
    /// hygiene: this string's whole job is to tell a user WHICH MACHINE they are connecting to, and
    /// both classes let one string render as another. The signer is authorised, so this is not the
    /// main defence — it is the part that stops an authorised-but-careless name being a misleading
    /// one, and it costs nothing.
    public static func nameIsSafe(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumNameBytes else { return false }
        for scalar in name.unicodeScalars {
            // C0, DEL and C1.
            if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) { return false }
            // LRE RLE PDF LRO RLO, and the isolates LRI RLI FSI PDI.
            if (0x202A ... 0x202E).contains(scalar.value) { return false }
            if (0x2066 ... 0x2069).contains(scalar.value) { return false }
        }
        return true
    }

    /// Verify a label against the chain of whoever signed it.
    ///
    /// `expectedDeviceID` is the device the caller is about to DISPLAY this name beside. Passing it
    /// is what makes the label a statement about that row rather than a valid label for some other
    /// device that the directory moved.
    public static func verify(body labelBytes: [UInt8], signature: [UInt8],
                              signerBundle: [UInt8], expectedDeviceID: [UInt8],
                              trustedRootID: [UInt8], policy: E2EVerify.Policy,
                              revokedDeviceIDs: Set<[UInt8]> = []) -> Result<Label, Failure> {
        guard let parsed = parse(labelBytes) else {
            // A name that fails `nameIsSafe` parses as nothing, so the caller hears one refusal for
            // "not a label" and another for "not a name a list may show".
            return .failure(E2EDeviceLabel.parse(stripName(labelBytes)) == nil
                            ? .malformed : .unsafeName)
        }
        guard parsed.rootID == trustedRootID else { return .failure(.rootMismatch) }
        guard parsed.deviceID == expectedDeviceID else { return .failure(.deviceMismatch) }

        let signer: E2EVerify.VerifiedChain
        switch E2EVerify.verifyBundle(signerBundle, trustedRootID: trustedRootID, policy: policy,
                                      revokedDeviceIDs: revokedDeviceIDs) {
        case .success(let chain): signer = chain
        case .failure: return .failure(.signerChain)
        }
        // The same authority §13 requires for code issuance, and for the same reason: this is an
        // administrative act over the identity, not a use of it.
        guard signer.leaf.capabilities.canEnroll, signer.leaf.issuerKind == .root else {
            return .failure(.signerNotAuthorised)
        }
        guard E2EVerify.verifyEd25519(signature: signature, message: parsed.bytes,
                                      publicKey: signer.leafDevice.signingPublicKey)
        else { return .failure(.signature) }
        return .success(parsed)
    }

    /// Re-encode a label with its name replaced by a placeholder, to tell "these bytes are not a
    /// label" apart from "these bytes are a label carrying a name a list must not show".
    private static func stripName(_ bytes: [UInt8]) -> [UInt8] {
        var r = E2EWire.Reader(bytes)
        guard r.expectLabel(label), let rootID = r.take(E2EWire.idLength),
              let deviceID = r.take(E2EWire.idLength), r.lengthPrefixed() != nil, r.atEnd,
              let rebuilt = body(rootID: rootID, deviceID: deviceID, name: "?")
        else { return [] }
        return rebuilt
    }
}
