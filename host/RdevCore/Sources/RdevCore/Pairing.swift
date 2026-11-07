import Foundation

/// A room and the credentials for reaching it.
public struct Pairing: Equatable, Sendable {
    public let code: String
    public let token: String
    /// §9.1's pre-shared key, present exactly when the carrier was a SEED — the only input that can
    /// produce one. A `?code=&token=` link admits a client to the room and gives it nothing to
    /// handshake `pair` with, and that difference is why this is optional rather than empty.
    public let psk: [UInt8]?

    public init(code: String, token: String, psk: [UInt8]? = nil) {
        self.code = code
        self.token = token
        self.psk = psk
    }
}

/// **What a person carried, back into a room and (when they carried a seed) its PSK.**
///
/// Accepts §9.1's carrier (`b64u(seed)`, 22 bare characters), a pasted connect URL or query string,
/// or a
/// link whose FRAGMENT carries a seed. Mirror of `web/src/client/pairing.ts`, down to the accepted
/// inputs, and the cross-implementation vectors in `protocol/fixtures/pairing-v3.json` are asserted
/// by both suites.
///
/// **A SEED IS READ FROM THE FRAGMENT AND NEVER FROM THE QUERY.** A query string is sent to the
/// Control Plane on the first navigation, and §9.1 forbids the seed reaching it — so accepting one
/// there would turn a correct link into a leak the moment somebody rewrote it by hand. The fragment
/// is checked FIRST, because a link carrying a seed carries everything and the query's code/token
/// would be a strictly weaker reading of the same link.
///
/// LOAD-BEARING: the token is canonical LOWERCASE hex, because the session Durable Object compares
/// it as an exact string against what the derivation produced. An uppercase token is rejected as
/// `bad-token`, which presents as a wrong pairing code rather than as a formatting bug.
public func parsePairing(_ input: String) -> Pairing? {
    let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }

    // **URLS FIRST, BECAUSE SHAPE IS THE DISCRIMINATOR NOW.** The `ss3.` prefix is gone, so a bare
    // carrier is recognised by being exactly 22 base64url characters — and a URL can never be that,
    // since none of `:`, `/`, `?`, `#` or `=` is in the alphabet. Testing the URL shape first keeps
    // the two rules from ever having to disagree.
    if s.contains("://") || s.contains("?") || s.contains("#") || s.contains("code=") {
        if let hash = s.firstIndex(of: "#") {
            let fragment = String(s[s.index(after: hash)...])
            if let carrier = field("pair", in: fragment), PairingSeed.decode(carrier) != nil {
                return fromSeed(carrier)
            }
        }
        let beforeFragment = s.firstIndex(of: "#").map { String(s[s.startIndex ..< $0]) } ?? s
        let query = beforeFragment.firstIndex(of: "?")
            .map { String(beforeFragment[beforeFragment.index(after: $0)...]) } ?? beforeFragment
        guard let code = field("code", in: query), let token = field("token", in: query),
              !code.isEmpty, !token.isEmpty else { return nil }
        return Pairing(code: code, token: token)
    }

    // A bare carrier: `decode` enforces the exact length and alphabet, so nothing else reaches here.
    return fromSeed(s)
}

private func fromSeed(_ carrier: String) -> Pairing? {
    guard let seed = PairingSeed.decode(carrier),
          let material = PairingSeed.derive(seed: seed) else { return nil }
    return Pairing(code: material.code, token: material.token, psk: material.psk)
}

private func field(_ name: String, in query: String) -> String? {
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == name else { continue }
        return String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? String(parts[1])
    }
    return nil
}

/// Standard base64 of `data`, converted to the URL-safe alphabet with padding stripped.
///
/// PUBLIC because §11.3's envelope carries a Noise message as base64url, and the host encodes and
/// decodes that outside this module. One spelling of the alphabet, in one place — two would differ
/// over padding exactly once, in production, against a peer that had already encrypted something.
public func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// URL-safe base64 (padded or unpadded) -> bytes, or nil if it is not valid base64.
public func base64urlDecode(_ s: String) -> [UInt8]? {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    guard let d = Data(base64Encoded: b) else { return nil }
    return [UInt8](d)
}
