import Foundation

/// **§10.1's identity, as a person actually reads it.** The reasoning, the alphabet and the
/// eighty-bit length are all in `protocol/src/identity-code.ts`; this is the same function, and the
/// two are held to `protocol/fixtures/identity-code.json` rather than to each other.
///
/// DISPLAY ONLY — there is no decoder, because nothing takes an identity as input.
extension E2EIdentity {

    /// Crockford's: no `I`, `L`, `O` or `U`.
    public static let identityCodeAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    /// Ten bytes is eighty bits is exactly sixteen characters, with no padding to explain.
    public static let identityCodeBytes = 10

    public static func code(rootID: [UInt8]) -> String {
        // Shorter than the prefix is not an identity, and a half-length code would LOOK like one.
        guard rootID.count >= identityCodeBytes else { return "" }

        var chars: [Character] = []
        var acc = 0
        var bits = 0
        for byte in rootID.prefix(identityCodeBytes) {
            acc = (acc << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                chars.append(identityCodeAlphabet[(acc >> bits) & 31])
            }
        }
        return stride(from: 0, to: chars.count, by: 4)
            .map { String(chars[$0 ..< min($0 + 4, chars.count)]) }
            .joined(separator: "-")
    }
}
