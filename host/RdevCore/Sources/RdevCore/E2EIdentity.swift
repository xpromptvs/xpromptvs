import CryptoKit
import Foundation

/// The §10 identity encodings — root descriptor, device descriptor, grant body, grant id and
/// revocation — and the authority rules that decide whether a grant may exist at all.
///
/// **THESE BYTES ARE WHAT SIGNATURES COVER.** A layout disagreement between two implementations is
/// not a parse error; it is a signature that verifies against the wrong statement, which is the
/// quietest failure in the whole protocol. Hence
/// `protocol/fixtures/e2e-identity.json`, whose vectors a THIRD implementation produced.
///
/// PURE. Nothing here signs or verifies — that needs key material and belongs with it. This is the
/// layer that decides exactly which bytes a signature is over, which is the part that must agree.
public enum E2EIdentity {

    /// §10.3. A bit mask, but only four values are legal, and the set is closed on purpose:
    /// "**Accept exactly `{1, 2, 3, 7}`** and reject every other value".
    public struct Capabilities: Equatable, Sendable {
        public static let connect: UInt8 = 1
        public static let host: UInt8 = 2
        public static let enroll: UInt8 = 4

        public let raw: UInt8

        /// Nil for anything outside `{1, 2, 3, 7}`. `4`, `5` and `6` are all expressible in the
        /// mask and none of them is a role this protocol grants.
        ///
        /// **`2` WAS ADDED 2026-09-15**, when adopt-by-code gave it a holder: a Mac enrolled by
        /// scanning its own code, which shares a screen and may do nothing else. §10.3 refused it
        /// until then for a stated reason — "`host` without `connect` is a device that may share a
        /// screen it can never reach" — which is a semantic judgement rather than a security
        /// invariant, and is the exact property that Mac wants. On a Mac the `connect` bit buys
        /// nothing anyway: its only client is the app's renderer, which needs a subordinate grant
        /// that neither `2` nor `3` can issue.
        ///
        /// **This is wire-visible.** An older verifier reads a capability-2 grant as malformed, so a
        /// Mac enrolled this way is unreachable from a peer on a build predating this line.
        public init?(raw: UInt8) {
            guard raw == 1 || raw == 2 || raw == 3 || raw == 7 else { return nil }
            self.raw = raw
        }

        public var canConnect: Bool { raw & Self.connect != 0 }
        public var canHost: Bool { raw & Self.host != 0 }
        public var canEnroll: Bool { raw & Self.enroll != 0 }

        /// §10.3's four accepted values, by the name its table gives them. `init?(raw:)` stays the
        /// only way to build one from the wire; these exist so a CALLER choosing a capability says
        /// which role it means rather than writing a number and a `!`.
        public static let connectOnly = Capabilities(raw: connect)!
        /// A code-enrolled Mac: it shares its screen and may do nothing else.
        public static let hostOnly = Capabilities(raw: host)!
        public static let connectAndHost = Capabilities(raw: connect | host)!
        public static let full = Capabilities(raw: connect | host | enroll)!
    }

    /// §10.3. `0` root-issued, `1` device-issued. "Unknown issuer kinds or permissions are rejected,
    /// never partially interpreted."
    public enum IssuerKind: UInt8, Sendable, CaseIterable {
        case root = 0, device = 1
    }

    /// §10.3's two binding shapes. The binding is what ties a grant to the ceremony that produced
    /// it — without it a signed grant could be replayed into a different enrollment.
    public enum Binding: Equatable, Sendable {
        /// `U8(0) || random(32)` — a local passkey ceremony.
        case local(randomness: [UInt8])
        /// `U8(1) || h || responder_device_id` — a live remote enrollment, bound to the exact Noise
        /// transcript and the exact responder. §10.4: the responder checks both against its own view.
        case remote(handshakeHash: [UInt8], responderDeviceID: [UInt8])

        public var encoded: [UInt8]? {
            switch self {
            case .local(let r):
                guard r.count == idLength else { return nil }
                return [0] + r
            case .remote(let h, let responder):
                guard h.count == idLength, responder.count == idLength else { return nil }
                return [1] + h + responder
            }
        }
    }

    /// §7 widths. Hashes and raw Ed25519/X25519 public keys are 32 bytes; the root public key is a
    /// validated 65-byte uncompressed SEC1 P-256 point.
    public static let idLength = 32
    public static let rootPublicKeyLength = 65

    static let rootLabel = "rdev-e2e/root/v1"
    static let deviceLabel = "rdev-e2e/device/v1"
    /// **v2, and THE FIELDS DID NOT CHANGE.** What changed is what a signature over them MEANS: a
    /// v1 grant's assertion covered the whole grant, a v2 grant's covers `grantCommitment`'s
    /// projection of it. Domain separation exists so a signature made under one meaning can never
    /// be read under another. It also buys the migration a decent failure — a pre-change bundle now
    /// dies at `parseGrant` as `malformed-grant`, rather than reaching the challenge comparison and
    /// reporting `clientdata-challenge`, which reads like corruption instead of staleness.
    static let grantLabel = "rdev-e2e/grant/v2"
    static let grantIDLabel = "rdev-e2e/grant-id/v1"
    static let grantCommitLabel = "rdev-e2e/grant-commit/v1"
    static let revokeLabel = "rdev-e2e/revoke/v1"

    static func sha256(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: Data(bytes))) }

    // MARK: - §10.1 root

    /// `root = LP("rdev-e2e/root/v1") || LP(rp_id) || LP(credential_id) || root_public_key`
    public static func root(rpID: String, credentialID: [UInt8], rootPublicKey: [UInt8]) -> [UInt8]? {
        guard rootPublicKey.count == rootPublicKeyLength,
              let rp = E2EWire.lengthPrefixed(Array(rpID.utf8)),
              let cred = E2EWire.lengthPrefixed(credentialID) else { return nil }
        return E2EWire.lp(rootLabel) + rp + cred + rootPublicKey
    }

    public static func rootID(_ root: [UInt8]) -> [UInt8] { sha256(root) }

    /// A root descriptor, decoded. The bytes are kept because `root_id` is their hash and a
    /// verifier must be able to prove the descriptor it was handed is the root it trusts.
    public struct Root: Equatable, Sendable {
        public let bytes: [UInt8]
        public let rpID: String
        public let credentialID: [UInt8]
        public let publicKey: [UInt8]

        public var id: [UInt8] { E2EIdentity.rootID(bytes) }
    }

    /// Decode a root descriptor, or nil. The public key is the tail — unprefixed, fixed width — so
    /// a descriptor with anything after it is refused rather than read as a longer key.
    ///
    /// `rp_id` must be ASCII: §10.1 calls it "the canonical ASCII relying-party ID", and its hash
    /// appears in `authenticatorData`. A non-ASCII byte string that decodes to the same Swift
    /// String under two different normalisations would hash two ways, so the encoding is pinned
    /// here rather than discovered at the point of comparison.
    public static func parseRoot(_ bytes: [UInt8]) -> Root? {
        var r = E2EWire.Reader(bytes)
        guard r.expectLabel(rootLabel),
              let rp = r.lengthPrefixed(),
              let rpID = String(bytes: rp, encoding: .utf8), rp.allSatisfy({ $0 < 0x80 }),
              let credentialID = r.lengthPrefixed(),
              let publicKey = r.take(rootPublicKeyLength),
              publicKey[0] == 0x04,          // SEC1 uncompressed; the other forms are not this field
              r.atEnd
        else { return nil }
        return Root(bytes: bytes, rpID: rpID, credentialID: credentialID, publicKey: publicKey)
    }

    // MARK: - §10.2 device

    /// `device = LP("rdev-e2e/device/v1") || root_id || signing_public_key || noise_public_key`
    ///
    /// The signing and DH keys are INDEPENDENT (§7: never converted from each other). Both appear
    /// here, so a device that swapped one has a different identity rather than a quietly altered one.
    public static func device(rootID: [UInt8], signingPublicKey: [UInt8],
                              noisePublicKey: [UInt8]) -> [UInt8]? {
        guard rootID.count == idLength, signingPublicKey.count == idLength,
              noisePublicKey.count == idLength else { return nil }
        return E2EWire.lp(deviceLabel) + rootID + signingPublicKey + noisePublicKey
    }

    public static func deviceID(_ device: [UInt8]) -> [UInt8] { sha256(device) }

    /// A device descriptor, decoded. Both keys matter to a verifier and for different reasons: the
    /// signing key certifies any grant this device issues, and the Noise key is what §10.4 requires
    /// to equal the static key the handshake authenticated.
    public struct Device: Equatable, Sendable {
        public let bytes: [UInt8]
        public let rootID: [UInt8]
        public let signingPublicKey: [UInt8]
        public let noisePublicKey: [UInt8]

        public var id: [UInt8] { E2EIdentity.deviceID(bytes) }
    }

    public static func parseDevice(_ bytes: [UInt8]) -> Device? {
        var r = E2EWire.Reader(bytes)
        guard r.expectLabel(deviceLabel),
              let rootID = r.take(idLength),
              let signing = r.take(idLength),
              let noise = r.take(idLength),
              r.atEnd
        else { return nil }
        return Device(bytes: bytes, rootID: rootID, signingPublicKey: signing, noisePublicKey: noise)
    }

    // MARK: - §10.3 grant

    /// `grant = LP("rdev-e2e/grant/v1") || root_id || operation_id || issuer_kind || issuer_id
    ///        || LP(device) || capabilities || LP(binding)`
    ///
    /// REFUSES A GRANT THE PROTOCOL WOULD NOT ACCEPT, rather than encoding it and leaving the
    /// verifier to catch it. §10.3: "only root-issued grants may carry `enroll`" — a device-issued
    /// grant with capabilities `7` is not a grant to be rejected later, it is one that must never
    /// be constructed.
    public static func grant(rootID: [UInt8], operationID: [UInt8], issuerKind: IssuerKind,
                             issuerID: [UInt8], device: [UInt8], capabilities: Capabilities,
                             binding: Binding) -> [UInt8]? {
        guard rootID.count == idLength, operationID.count == idLength, issuerID.count == idLength,
              let dev = E2EWire.lengthPrefixed(device),
              let bindingBytes = binding.encoded,
              let bind = E2EWire.lengthPrefixed(bindingBytes),
              authorityIsWellFormed(issuerKind: issuerKind, capabilities: capabilities)
        else { return nil }
        return E2EWire.lp(grantLabel) + rootID + operationID + [issuerKind.rawValue] + issuerID
             + dev + [capabilities.raw] + bind
    }

    /// §10.3's authority rule, separated so it can be applied to a RECEIVED grant as well as a
    /// constructed one. A leaf cannot extend the chain; that is what bounds chain depth at two
    /// without counting anything.
    public static func authorityIsWellFormed(issuerKind: IssuerKind,
                                             capabilities: Capabilities) -> Bool {
        capabilities.canEnroll ? issuerKind == .root : true
    }

    /// `grant_commitment = LP("rdev-e2e/grant-commit/v1") || operation_id || issuer_kind
    ///                  || signing_public_key || noise_public_key || capabilities || LP(binding)`
    ///
    /// **THE BYTES A ROOT PASSKEY SIGNS, AND THEY NAME NO ROOT.** That is the entire point. A
    /// browser signing in has not yet learned which credential will answer, so it cannot know
    /// `root_id`; a challenge containing one could not exist until a FIRST ceremony had produced it,
    /// which is exactly the second prompt this removes. `root_id` and `issuer_id` are pinned by the
    /// verifier instead — see `grantCommitment`, which is where that pin lives so it cannot be
    /// skipped.
    ///
    /// The field order mirrors `grant()`'s with the root-dependent fields elided, so this reads as
    /// the projection it is. **`LP(device)` is deliberately NOT used**: a §10.2 descriptor names its
    /// root, which would put `root_id` straight back in. The two keys are carried directly and the
    /// verifier reassembles the descriptor from the root it already trusts.
    ///
    /// Refuses exactly what `grant()` refuses, for the same reason: bytes that could not be a legal
    /// grant must never be signed, rather than rejected by somebody later.
    public static func grantCommitmentPreimage(operationID: [UInt8], issuerKind: IssuerKind,
                                               signingPublicKey: [UInt8], noisePublicKey: [UInt8],
                                               capabilities: Capabilities,
                                               binding: Binding) -> [UInt8]? {
        guard operationID.count == idLength, signingPublicKey.count == idLength,
              noisePublicKey.count == idLength,
              let bindingBytes = binding.encoded,
              let bind = E2EWire.lengthPrefixed(bindingBytes),
              authorityIsWellFormed(issuerKind: issuerKind, capabilities: capabilities)
        else { return nil }
        return E2EWire.lp(grantCommitLabel) + operationID + [issuerKind.rawValue]
             + signingPublicKey + noisePublicKey + [capabilities.raw] + bind
    }

    /// **The verifier's half — and the reason the root binding is still safe without being signed.**
    ///
    /// Because the signature no longer covers `root_id` or `issuer_id`, a verifier has to pin them.
    /// This is where that pin lives, so it CANNOT BE SKIPPED: a verifier that omits the check does
    /// not get an insecure success, it gets no challenge at all and fails closed. Same idiom as
    /// `grant()` in the other direction — bytes that must never be produced are never produced.
    ///
    /// It is deliberately redundant with the chain rules, which reject all three disagreements
    /// earlier. That redundancy is the point: it makes the ORDER of those checks irrelevant rather
    /// than load-bearing, and it is the primary protection for any verifier that validates a chain
    /// differently. `E2EGrantCommitmentTests` is the only place the refusal is observable, because
    /// `verifyBundle` never reaches it.
    ///
    /// Refuses a device-issued grant outright: those are evidenced by a raw Ed25519 signature over
    /// the whole grant, never by an assertion.
    public static func grantCommitment(_ g: Grant, trustedRootID: [UInt8]) -> [UInt8]? {
        guard g.issuerKind == .root,
              trustedRootID.count == idLength,
              g.rootID == trustedRootID,
              g.issuerID == trustedRootID,
              let d = parseDevice(g.device),
              d.rootID == trustedRootID
        else { return nil }
        return grantCommitmentPreimage(operationID: g.operationID, issuerKind: g.issuerKind,
                                       signingPublicKey: d.signingPublicKey,
                                       noisePublicKey: d.noisePublicKey,
                                       capabilities: g.capabilities, binding: g.binding)
    }

    /// `grant_id = H(LP("rdev-e2e/grant-id/v1") || grant)`
    ///
    /// A SECOND LABEL over the same bytes, which is the point: a grant id must not be confusable
    /// with a hash of the grant taken for any other purpose.
    public static func grantID(_ grant: [UInt8]) -> [UInt8] {
        sha256(E2EWire.lp(grantIDLabel) + grant)
    }

    // MARK: - parsing

    /// A grant, decoded. Holding the ORIGINAL BYTES is not a convenience: the signature covers them,
    /// and §7 forbids reserialising to verify. A re-encoded grant that differs by one byte is a
    /// signature check that fails for a reason nobody will find.
    public struct Grant: Equatable, Sendable {
        public let bytes: [UInt8]
        public let rootID: [UInt8]
        public let operationID: [UInt8]
        public let issuerKind: IssuerKind
        public let issuerID: [UInt8]
        public let device: [UInt8]
        public let capabilities: Capabilities
        public let binding: Binding

        public var id: [UInt8] { E2EIdentity.grantID(bytes) }
        public var deviceID: [UInt8] { E2EIdentity.deviceID(device) }
    }

    /// Decode a grant, or nil. EVERY rejection here is one §7 asks for: unsupported enum values,
    /// wrong widths, oversized fields and extra trailing bytes, all BEFORE any signature is checked.
    /// A parser that is lenient about framing lets one byte string mean two things to two peers.
    public static func parseGrant(_ bytes: [UInt8]) -> Grant? {
        var r = E2EWire.Reader(bytes)
        guard r.expectLabel(grantLabel),
              let rootID = r.take(idLength),
              let operationID = r.take(idLength),
              let kindRaw = r.takeByte(),
              let issuerKind = IssuerKind(rawValue: kindRaw),
              let issuerID = r.take(idLength),
              let device = r.lengthPrefixed(),
              let capsRaw = r.takeByte(),
              let capabilities = Capabilities(raw: capsRaw),
              let bindingBytes = r.lengthPrefixed(),
              let binding = parseBinding(bindingBytes),
              r.atEnd,
              // The authority rule is structural, so it is applied at PARSE time: a device-issued
              // grant carrying `enroll` is not a grant with a bad field, it is not a grant.
              authorityIsWellFormed(issuerKind: issuerKind, capabilities: capabilities)
        else { return nil }
        return Grant(bytes: bytes, rootID: rootID, operationID: operationID, issuerKind: issuerKind,
                     issuerID: issuerID, device: device, capabilities: capabilities, binding: binding)
    }

    static func parseBinding(_ b: [UInt8]) -> Binding? {
        switch b.first {
        case 0 where b.count == 1 + idLength:
            return .local(randomness: Array(b[1...]))
        case 1 where b.count == 1 + idLength * 2:
            return .remote(handshakeHash: Array(b[1 ..< 1 + idLength]),
                           responderDeviceID: Array(b[(1 + idLength)...]))
        default:
            return nil          // an unknown binding kind is rejected, never partially interpreted
        }
    }

    // MARK: - §10.3 chain structure

    public enum ChainFailure: Error, Equatable, Sendable {
        case empty, tooLong, malformedGrant
        /// A grant naming a different root. An incoming chain may never replace a trusted root.
        case rootMismatch
        /// The first grant must be issued BY THE ROOT, and name it.
        case firstNotRootIssued
        /// A second grant must be issued by a device and name its parent's exact grant id.
        case secondNotChainedToFirst
        /// §10.3: only root-issued grants may carry `enroll`.
        case unauthorisedCapabilities
    }

    /// The STRUCTURAL half of chain validation — everything decidable without a signature.
    ///
    /// Separated deliberately: signatures need key material and two different algorithms (WebAuthn
    /// ES256 for a root grant, Ed25519 for a device grant), while these rules are pure and are the
    /// ones a reader can check against §10.3 line by line. A caller MUST also verify signatures; this
    /// returning success is necessary and not sufficient, and its name says so.
    ///
    /// `chain` is ordered from the root outward: `[direct]` or `[direct, leaf]`.
    public static func validateChainStructure(_ chain: [[UInt8]],
                                              trustedRootID: [UInt8]) -> Result<Grant, ChainFailure> {
        guard !chain.isEmpty else { return .failure(.empty) }
        // §10.3: "No chain has more than two grants." Checked before anything else, so a long chain
        // costs one comparison rather than a parse per element.
        guard chain.count <= 2 else { return .failure(.tooLong) }

        var parsed: [Grant] = []
        for bytes in chain {
            guard let g = parseGrant(bytes) else { return .failure(.malformedGrant) }
            guard g.rootID == trustedRootID else { return .failure(.rootMismatch) }
            parsed.append(g)
        }

        let direct = parsed[0]
        guard direct.issuerKind == .root, direct.issuerID == trustedRootID else {
            return .failure(.firstNotRootIssued)
        }
        guard parsed.count == 2 else { return .success(direct) }

        let leaf = parsed[1]
        guard leaf.issuerKind == .device, leaf.issuerID == direct.id else {
            return .failure(.secondNotChainedToFirst)
        }
        // Re-stated here as well as at parse time: the parse rule protects a single grant, this
        // protects the CHAIN, and a future parser relaxation must not silently widen authority.
        guard !leaf.capabilities.canEnroll else { return .failure(.unauthorisedCapabilities) }
        return .success(leaf)
    }

    // MARK: - §10.5 revocation

    /// `revocation = LP("rdev-e2e/revoke/v1") || root_id || operation_id || target_device_id`
    ///
    /// The target is the WHOLE DEVICE IDENTITY, not one grant: revoking a grant would leave a device
    /// free to present a sibling. §10.5 stores an irreversible tombstone against
    /// `(root_id, target_device_id)`, and re-enrollment requires NEW device keys.
    public static func revocation(rootID: [UInt8], operationID: [UInt8],
                                  targetDeviceID: [UInt8]) -> [UInt8]? {
        guard rootID.count == idLength, operationID.count == idLength,
              targetDeviceID.count == idLength else { return nil }
        return E2EWire.lp(revokeLabel) + rootID + operationID + targetDeviceID
    }
}
