import Foundation

/// Which relying party this host's passkeys belong to and which origin a ceremony may claim, resolved
/// from the one thing a host is configured with.
///
/// **The app trusts the origin it was CONFIGURED with, never one a server names.** §4 puts the
/// Control Plane inside the adversary model, so "which site's passkeys may enrol this device" cannot be
/// an answer that arrives over the wire — it is `RDEV_SIGNALING`, chosen by whoever installed the host.
///
/// The values here are also what §10.1 calls "configured in trusted application code, not in an
/// incoming certificate": the relying-party ID and the accepted ceremony origin. A browser's ceremony
/// uses `location.hostname` and `location.origin`, and the Mac's own native one runs for this `rpID`
/// and reports this origin in its `clientDataJSON` — so deriving both from the configured origin is
/// what makes every side agree by construction rather than by two matching deployment settings.
public enum E2EOrigin {

    public struct Resolved: Equatable, Sendable {
        /// The WebAuthn origin string, spelled the way a browser reports `location.origin`: scheme,
        /// host, and a port only when it is not the scheme's default.
        public let origin: String
        /// The configured origin's host — a page's `location.hostname`. NOT always the relying party:
        /// see `policy`.
        public let rpID: String
        /// The same origin as a URL, for the request builder. Kept rather than reparsed so no
        /// caller can reintroduce a path.
        public let url: URL

        /// §10.1's policy, for verifying what a ceremony returns and what a peer presents. **On the
        /// product's domain it is the PRODUCT's** (2026-10-06, `E2EOrigin.product`): the relying party
        /// `xpromptvs.ai` and BOTH origins, whichever of the two is configured — the client moved to
        /// `app.xpromptvs.ai`, every passkey is still `xpromptvs.ai`'s, and a grant keeps the origin it
        /// was signed at for good. Anywhere else, the origin's own host and the origin alone.
        public var policy: E2EVerify.Policy {
            E2EOrigin.product.origins.contains(origin)
                ? E2EVerify.Policy(rpID: E2EOrigin.product.rpID, allowedOrigins: E2EOrigin.product.origins)
                : E2EVerify.Policy(rpID: rpID, allowedOrigins: [origin])
        }
    }

    /// **The product's two origins and its one relying party** — `web/src/lib/product-origin.ts` in
    /// Swift, both held to `protocol/fixtures/e2e-product-origins.json`; the Worker's `E2E_RP_ID` /
    /// `E2E_ORIGINS` state the same policy. `docs/e2e.md`, "Which relying party, and which origin".
    public static let product = (rpID: "xpromptvs.ai",
                                 origins: ["https://xpromptvs.ai", "https://app.xpromptvs.ai"],
                                 appOrigin: "https://app.xpromptvs.ai")

    public enum Failure: String, Error, Equatable, Sendable {
        case malformed = "malformed"
        /// A plaintext origin that is not loopback. **No passkey can belong to it** — `http` is a
        /// secure context only for localhost and 127.0.0.0/8 — so every ceremony would fail for a
        /// reason nothing would name. Refusing names the real problem instead.
        case insecure = "insecure"
        /// The Control Plane is mounted under a path. Its routes are absolute (`/directory/…`,
        /// `/credential/…`), so a prefix would have to be threaded through every caller. Refused rather
        /// than silently dropped: dropping it would point requests somewhere the operator did not ask
        /// for.
        case unsupportedPath = "unsupported-path"
    }

    /// Resolve `RDEV_SIGNALING` into an origin and a policy.
    public static func resolve(_ base: String) -> Result<Resolved, Failure> {
        guard let components = URLComponents(string: base.trimmingCharacters(in: .whitespaces)),
              let rawScheme = components.scheme?.lowercased(),
              rawScheme == "http" || rawScheme == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil
        else { return .failure(.malformed) }

        guard components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil
        else { return .failure(.unsupportedPath) }

        // Hosts are case-insensitive and browsers report them lowercased; an origin that differed
        // only in case would fail the string comparison WebAuthn makes against it.
        //
        // **An IPv6 literal's brackets are part of the URL, not of the host.** Which of the two
        // `URLComponents.host` hands back has changed between Foundation versions, so both are
        // accepted here and the brackets are re-applied below from one place.
        let host = unbracketed(rawHost.lowercased())
        guard rawScheme == "https" || isLoopback(host) else { return .failure(.insecure) }

        // A default port is ABSENT from an origin string, not spelled out. `https://x:443` and
        // `https://x` are one origin to a browser and two strings to a comparison.
        let defaultPort = rawScheme == "https" ? 443 : 80
        let port = components.port == defaultPort ? nil : components.port

        let authority = host.contains(":") ? "[\(host)]" : host
        let origin = port.map { "\(rawScheme)://\(authority):\($0)" } ?? "\(rawScheme)://\(authority)"

        // Built from the origin string rather than by mutating the components, so the URL and the
        // string a browser compares are the SAME bytes and cannot drift apart.
        guard let url = URL(string: origin), url.host != nil else { return .failure(.malformed) }
        return .success(Resolved(origin: origin, rpID: host, url: url))
    }

    static func unbracketed(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    /// The hosts a browser treats as a secure context over plain `http`. Chrome's rule is the whole
    /// of 127.0.0.0/8, `::1`, `localhost`, and anything under `.localhost` — matched here so a
    /// development host bound to loopback enrolls and one bound to a LAN address is told why it
    /// cannot, rather than discovering it in a browser with no `navigator.credentials`.
    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, let first = UInt8(octets[0]), first == 127 else { return false }
        return octets.dropFirst().allSatisfy { UInt8($0) != nil }
    }
}
