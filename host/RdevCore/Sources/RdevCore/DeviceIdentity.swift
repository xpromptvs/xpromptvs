import CryptoKit
import Foundation

/// §10.2's local device keys, and the installation record a Host stores them in.
///
/// ```
/// device    = LP("rdev-e2e/device/v1") || root_id || signing_public_key || noise_public_key
/// device_id = H(device)
/// ```
///
/// **THE TWO KEYS ARE INDEPENDENT AND BOTH ARE IDENTITY.** §7 forbids deriving one from the other,
/// and §10.2 says "Changing either key creates a new device identity" — so a build that regenerated
/// one and kept the other has not rotated anything, it has become a different device with a grant
/// that no longer describes it. `deviceID` is over BOTH, which is what makes that automatic.
///
/// **THERE IS NO RECOVERY.** §10.2: "Private-key loss means generating new keys and enrolling again,
/// not reconstructing the old device." Nothing here takes a passphrase, a seed phrase or a backup,
/// and nothing should be added that does — §6 lists key recovery among the things this protocol
/// deliberately does not provide.
public enum DeviceIdentity {

    /// A device's two private keys. **Both are secret and neither is ever transmitted.**
    ///
    /// The public halves are derived on demand rather than stored beside them: a record carrying
    /// both halves can disagree with itself, and a disagreement here would produce a descriptor
    /// whose `device_id` names keys the device does not hold.
    public struct Keys: Equatable, Sendable {
        public let signingPrivateKey: [UInt8]
        public let noisePrivateKey: [UInt8]

        /// Nil if either key is the wrong width. Refused rather than padded: a short key is a bug at
        /// the call site, and deriving from one silently produces a well-formed identity with less
        /// entropy than any reader would assume.
        public init?(signingPrivateKey: [UInt8], noisePrivateKey: [UInt8]) {
            guard signingPrivateKey.count == 32, noisePrivateKey.count == 32 else { return nil }
            self.signingPrivateKey = signingPrivateKey
            self.noisePrivateKey = noisePrivateKey
        }

        /// Ed25519 (§10.3's grant signatures, §11.2's device proof).
        public var signingPublicKey: [UInt8]? {
            guard let k = try? Curve25519.Signing.PrivateKey(
                    rawRepresentation: Data(signingPrivateKey)) else { return nil }
            return Array(k.publicKey.rawRepresentation)
        }

        /// X25519 (the Noise static, §11.1). A DIFFERENT ALGORITHM on a different curve
        /// representation, not a reuse of the signing key — converting between them is exactly what
        /// §7 forbids.
        public var noisePublicKey: [UInt8]? {
            guard let k = try? Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: Data(noisePrivateKey)) else { return nil }
            return Array(k.publicKey.rawRepresentation)
        }

        public func descriptor(rootID: [UInt8]) -> [UInt8]? {
            guard let signing = signingPublicKey, let noise = noisePublicKey else { return nil }
            return E2EIdentity.device(rootID: rootID, signingPublicKey: signing,
                                      noisePublicKey: noise)
        }

        public func deviceID(rootID: [UInt8]) -> [UInt8]? {
            descriptor(rootID: rootID).map(E2EIdentity.deviceID)
        }
    }

    /// §10.2: "A Host stores its keys and rendezvous seed as ONE installation record; reinstallation
    /// generates both anew."
    ///
    /// One record because they share a lifetime. Regenerating the keys while keeping the seed would
    /// leave a new device answering at the old address — and §9.2 requires a durable-route conflict
    /// to fail visibly rather than have an identity quietly change behind a stable address.
    public struct Installation: Equatable, Sendable {
        public let keys: Keys
        public let rendezvousSeed: [UInt8]

        public init?(keys: Keys, rendezvousSeed: [UInt8]) {
            guard rendezvousSeed.count == RendezvousSeed.seedByteCount else { return nil }
            self.keys = keys
            self.rendezvousSeed = rendezvousSeed
        }

        public var route: RendezvousRoute? { RendezvousSeed.derive(seed: rendezvousSeed) }
    }

    /// Generate a fresh installation. `randomBytes` is injectable so the derivation is testable and
    /// so a caller can supply a source it trusts; it defaults to the system CSPRNG.
    ///
    /// **THE THREE VALUES ARE INDEPENDENT DRAWS.** Deriving them from one seed would be smaller and
    /// is wrong here: §9.1's pairing seed does exactly that on purpose, because all three of its
    /// outputs belong to one short-lived window, whereas these are a signing identity, a DH identity
    /// and a public address that must not be linkable to each other by anyone who learns one.
    public static func generate(
        randomBytes: (Int) -> [UInt8] = DeviceIdentity.systemRandom
    ) -> Installation? {
        guard let keys = Keys(signingPrivateKey: randomBytes(32),
                              noisePrivateKey: clampedX25519(randomBytes(32))) else { return nil }
        return Installation(keys: keys, rendezvousSeed: randomBytes(RendezvousSeed.seedByteCount))
    }

    /// RFC 7748's scalar clamping. CryptoKit clamps internally, but the STORED bytes are what a
    /// future reader compares and what the TypeScript side must agree with, so they are clamped
    /// before they are stored rather than at every use.
    static func clampedX25519(_ raw: [UInt8]) -> [UInt8] {
        guard raw.count == 32 else { return raw }
        var k = raw
        k[0] &= 248
        k[31] &= 127
        k[31] |= 64
        return k
    }

    public static func systemRandom(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        // A failed CSPRNG is not a condition to carry on from with a zeroed key; §6 says RNG failure
        // is not repaired by any mechanism in this protocol, so the only honest response is to stop.
        precondition(status == errSecSuccess, "the system CSPRNG failed")
        return bytes
    }

    // MARK: - the stored record

    static let recordLabel = "rdev-e2e/installation/v1"

    /// `LP("rdev-e2e/installation/v1") || signing_private || noise_private || rendezvous_seed`
    ///
    /// **LOCAL ONLY — these bytes never touch a wire and no peer ever parses them.** The label is
    /// here so a keychain item that turns out to hold something else is REFUSED rather than read as
    /// 96 bytes of key material, which is the failure that would silently produce a device nobody
    /// can authenticate.
    public static func encode(_ installation: Installation) -> [UInt8] {
        E2EWire.lp(recordLabel) + installation.keys.signingPrivateKey
             + installation.keys.noisePrivateKey + installation.rendezvousSeed
    }

    public static func decode(_ bytes: [UInt8]) -> Installation? {
        var r = E2EWire.Reader(bytes)
        guard r.expectLabel(recordLabel),
              let signing = r.take(32),
              let noise = r.take(32),
              let seed = r.take(RendezvousSeed.seedByteCount),
              r.atEnd,
              let keys = Keys(signingPrivateKey: signing, noisePrivateKey: noise)
        else { return nil }
        return Installation(keys: keys, rendezvousSeed: seed)
    }
}
