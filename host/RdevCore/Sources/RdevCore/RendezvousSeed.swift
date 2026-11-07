import CryptoKit
import Foundation

/// A Host's or pairing Issuer's DURABLE route: the address a peer returns to, derived once from a
/// 32-byte seed persisted beside the device keys.
public struct RendezvousRoute: Equatable, Sendable {
    /// §9.2's names, kept rather than shortened to `code`/`token`: a pairing `code` and a rendezvous
    /// `rcode` occupy the same character space and are the same length, so the one-letter prefix is
    /// the only thing at a call site distinguishing a ONE-TIME routing ID from a DURABLE one.
    public let rcode: String
    public let rtoken: String

    public init(rcode: String, rtoken: String) { self.rcode = rcode; self.rtoken = rtoken }
}

/// §9.2 of `docs/superpowers/specs/2026-09-10-e2e-protocol-specification.md`.
///
/// The same construction as §9.1's pairing derivation — HKDF over one seed, the same 64-character
/// alphabet, the same UUID formatting — with **two differences that matter**:
///
/// 1. **It is DURABLE, not one-time.** `rseed` is persisted with the device keys and the SAME route
///    is registered after every restart. §9.2: "A durable-route conflict fails visibly; do not
///    silently choose a new identity or address." A device that quietly re-derives a new route after
///    a conflict has changed its address without telling anyone who persisted the old one.
/// 2. **There is no `psk`.** A durable route is public by construction — §9.2: "Addresses and room
///    tokens confer no E2E authority ... Room seizure is denial of service." All the authority is in
///    the chain, which is why an Issuer can safely send this address in Noise message 2, before the
///    newcomer has asked for anything.
///
/// **THE SALT IS `rdev/rendezvous/v7`, NOT `rdev-e2e/...`.** That is the spec's, and it is the one
/// label in this protocol that does not carry the `rdev-e2e` prefix. Do not "fix" it to match its
/// neighbours: the label IS the domain separation, and changing it changes every route ever derived.
public enum RendezvousSeed {

    public static let seedByteCount = 32

    /// §9.2's salt, quoted exactly. See the type comment before changing it.
    static let salt = "rdev/rendezvous/v7"

    /// Deliberately `PairingSeed`'s, not a second copy: §9.1 and §9.2 name the same 64 characters,
    /// and it is also byte-for-byte the Control Plane's `CODE_ALPHABET`, so a derived route occupies
    /// the same character space as a minted pairing code. Exactly 64, so `% 64` is unbiased.
    static var alphabet: [Character] { PairingSeed.alphabet }

    /// Derive the durable route, or nil if the seed is not exactly 32 bytes.
    public static func derive(seed: [UInt8]) -> RendezvousRoute? {
        guard seed.count == seedByteCount else { return nil }
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: Data(seed)),
                                       salt: Data(salt.utf8))
        let codeBytes = expand(prk, info: "code", count: 8)
        let tokenBytes = expand(prk, info: "token", count: 16)
        return RendezvousRoute(rcode: String(codeBytes.map { alphabet[Int($0) % alphabet.count] }),
                               rtoken: PairingSeed.uuidV4(from: tokenBytes))
    }

    private static func expand(_ prk: HashedAuthenticationCode<SHA256>,
                               info: String, count: Int) -> [UInt8] {
        HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data(info.utf8), outputByteCount: count)
            .withUnsafeBytes { [UInt8]($0) }
    }
}
