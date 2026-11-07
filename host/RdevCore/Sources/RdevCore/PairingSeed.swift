import CryptoKit
import Foundation

/// Everything one pairing window needs, derived from a single 32-byte seed.
///
/// `code` is the Issuer's temporary registered routing ID and `token` is room admission material —
/// both public to the Control Plane, because the Issuer registers them. `psk` is the 256-bit
/// pre-shared key for `Noise_XXpsk3_25519_ChaChaPoly_SHA256` and is **never transmitted**: not to the
/// Control Plane, not in a registration request, not in a URL query, not to analytics, not to a log.
public struct PairingMaterial: Equatable, Sendable {
    public let code: String
    public let token: String
    public let psk: [UInt8]

    public init(code: String, token: String, psk: [UInt8]) {
        self.code = code; self.token = token; self.psk = psk
    }
}

/// The v3 one-time pairing derivation — §9.1 of
/// `docs/superpowers/specs/2026-09-10-e2e-protocol-specification.md`.
///
/// ONE SEED CARRIES ALL THREE VALUES, AND ONLY THE SEED LEAVES THE DEVICE. HKDF is a pseudorandom
/// function, so the two public outputs reveal nothing about the seed or about `psk` — which is what
/// lets the Control Plane learn a routing ID and a room token while learning nothing that would let
/// it complete a handshake. Carrying three independent values instead would roughly double the typed
/// code, 79 characters against 47, and the human carrier is exactly where that is felt.
///
/// **THE SEED IS THE SECRET.** It is never sent to the Control Plane, never logged, and never
/// permitted into captured output. It IS rendered on the local pairing surface — that display is the
/// out-of-band channel, and the capture boundary (`SelfCapture`, §16) exists to protect it rather
/// than to forbid it. Anyone who obtains these 32 bytes can derive `psk` and complete a `pair`
/// handshake with keys of their own.
///
/// PURE, so the whole derivation is testable without a network, a Worker or a browser, and the
/// cross-implementation vectors in `protocol/fixtures/pairing-v3.json` are asserted by BOTH suites —
/// the Swift one here and the TypeScript one in `protocol/test`. A derivation that agrees with
/// itself and with nothing else is the failure this repo has paid for before.
public enum PairingSeed {

    /// **SIXTEEN uniform random bytes** (2026-09-15; it was 32). Any other length is refused rather
    /// than padded or truncated: a short seed is a bug at the call site, and silently deriving from
    /// one would produce a perfectly well-formed pairing window with less entropy than anyone
    /// reading this code would assume.
    ///
    /// The seed's only job is the psk's resistance to an OFFLINE attack — the `XXpsk3` transcript is
    /// on the wire, so a recorder can test guesses at leisure — and 128 bits is comfortably
    /// infeasible for that. 256 bits was matched to Noise's PSK slot rather than to a threat, and it
    /// cost 25 characters of the one value in this protocol a person carries by hand.
    public static let seedByteCount = 16

    /// `b64u(16 bytes)` — 128 bits in 22 characters, with no padding and **no prefix**.
    ///
    /// **THE `ss3.` DISCRIMINATOR IS GONE** (2026-09-15). It existed so a v3 carrier could not be
    /// read as a v2 one; v2 is retired, nothing else in the product is a bare base64url string, and
    /// a 22-character payload cannot be read as a URL because none of `:`, `/`, `?`, `#` or `=` is
    /// in the alphabet. **Shape is the discriminator now**, which is why `decode` checks the length
    /// before anything else and `parsePairing` checks it on both sides.
    public static let encodedLength = 22

    /// §9.2's alphabet, and it is byte-for-byte the Control Plane's existing `CODE_ALPHABET`
    /// (`control-plane/src/index.ts`) on purpose: a derived routing ID then occupies exactly the same
    /// character space as a minted one, so nothing downstream has to learn a second shape.
    ///
    /// EXACTLY 64 CHARACTERS, which is why `% 64` introduces no modulo bias — 256 is a whole multiple
    /// of 64, so every character is reachable from exactly four byte values. An alphabet of any other
    /// length would quietly skew the distribution, and the skew would be invisible in every test that
    /// only checks the length and the character set.
    public static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// The HKDF salt (§8's `rdev-e2e/pair/v3` label). Domain separation: the same seed bytes under a
    /// different label are a different, unrelated key schedule.
    static let salt = "rdev-e2e/pair/v3"

    /// Derive the pairing window's three values, or nil if the seed is not exactly 16 bytes.
    public static func derive(seed: [UInt8]) -> PairingMaterial? {
        guard seed.count == seedByteCount else { return nil }
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: Data(seed)),
                                       salt: Data(salt.utf8))
        let codeBytes = expand(prk, info: "code", count: 8)
        let tokenBytes = expand(prk, info: "token", count: 16)
        let psk = expand(prk, info: "psk", count: 32)
        return PairingMaterial(code: String(codeBytes.map { alphabet[Int($0) % alphabet.count] }),
                               token: uuidV4(from: tokenBytes),
                               psk: psk)
    }

    /// The out-of-band carrier: `b64u(seed)`, bare. Nil unless the seed is exactly 16 bytes.
    public static func encode(seed: [UInt8]) -> String? {
        guard seed.count == seedByteCount else { return nil }
        return base64urlEncode(Data(seed))
    }

    /// The inverse, and STRICT: exactly `encodedLength` characters that decode to exactly
    /// `seedByteCount` bytes. **The length check is the discriminator now that the prefix is gone** —
    /// without it, a short base64url fragment of something else would decode to a seed-shaped value.
    /// Leading and trailing whitespace is trimmed because this value is typed and pasted by a human,
    /// and a trailing newline from a copy is not a different secret.
    public static func decode(_ text: String) -> [UInt8]? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count == encodedLength,
              let bytes = base64urlDecode(s),
              bytes.count == seedByteCount else { return nil }
        return bytes
    }

    private static func expand(_ prk: HashedAuthenticationCode<SHA256>,
                               info: String, count: Int) -> [UInt8] {
        HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data(info.utf8), outputByteCount: count)
            .withUnsafeBytes { [UInt8]($0) }
    }

    /// 16 bytes -> a canonical lowercase UUID string with the v4 version and RFC 4122 variant bits
    /// stamped in, exactly as §9.2's "UUID-format" specifies.
    ///
    /// LOWERCASE AND FORMATTED FROM THE BYTES, never through `UUID.uuidString` — that emits UPPERCASE,
    /// and the session Durable Object compares the token as an exact string against what
    /// `crypto.randomUUID()` minted. The same rule already cost this repo once; see `parsePairing`.
    static func uuidV4(from raw: [UInt8]) -> String {
        var b = raw
        b[6] = (b[6] & 0x0f) | 0x40      // version 4
        b[8] = (b[8] & 0x3f) | 0x80      // RFC 4122 variant
        let hex = b.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))"
            + "-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }
}
