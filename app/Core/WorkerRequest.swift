import Foundation

/// **`__rdevShell.request`'s allow-list — the Worker calls the client window makes NATIVELY.**
///
/// The client window runs from `app://client/`, an origin the Worker sends no CORS for, so its own
/// `fetch` of the Worker fails. Rather than teach the Worker to trust an origin any WKWebView can
/// claim, the app performs exactly these requests for it — and ONLY these, against ITS OWN
/// signalling origin (`ShellEnvironment.signalingBase`), because the page is on the other side of
/// this boundary and must not be able to turn it into a proxy onto the LAN or another origin.
///
/// The list is what the page's three callers actually send (`web/src/lib/directory-api.ts`,
/// `credential-lookup.ts`), matched to the Worker's own routes (`control-plane/src/index.ts`):
///
/// - `POST /directory/<root>/challenge` · `…/register` · `…/list` — §12.2. `<root>` is 43 base64url
///   characters, a 32-byte root id, exactly the Worker's pattern.
/// - `GET /credential/<id>` — §10.1's discovery lookup, 4…344 base64url characters, the Worker's
///   own bound.
///
/// `publish` is NOT on it: only a Mac publishes, and the Mac does it natively already.
/// `docs/desktop-app.md`, "Native Worker requests".
public enum WorkerRequest {
    public enum Route: Equatable, Sendable {
        case directoryChallenge(root: String)
        case directoryRegister(root: String)
        case directoryList(root: String)
        case credential(id: String)

        public var method: String {
            switch self {
            case .credential: return "GET"
            case .directoryChallenge, .directoryRegister, .directoryList: return "POST"
            }
        }

        /// Rebuilt from the parsed parts, never echoed from the page.
        public var path: String {
            switch self {
            case .directoryChallenge(let r): return "/directory/\(r)/challenge"
            case .directoryRegister(let r): return "/directory/\(r)/register"
            case .directoryList(let r): return "/directory/\(r)/list"
            case .credential(let id): return "/credential/\(id)"
            }
        }
    }

    public enum Refusal: Error, Equatable, Sendable {
        case path, method, bodyTooLarge, bodyNotAllowed, base
        public var reason: String {
            switch self {
            case .path: return "refused: path is not on the allow-list"
            case .method: return "refused: wrong method for this path"
            case .bodyTooLarge: return "refused: body too large"
            case .bodyNotAllowed: return "refused: a GET carries no body"
            case .base: return "refused: no http(s) signalling origin"
            }
        }
    }

    public static let maxRequestBody = 64 * 1024
    public static let maxResponseBody = 1024 * 1024
    /// A redirect is returned to the page as the answer it is, and followed nowhere — not even
    /// same-origin, because nothing on this list redirects.
    public static let followsRedirects = false

    public static func validate(method: String, path: String) -> Result<Route, Refusal> {
        guard let route = parse(path) else { return .failure(.path) }
        return method == route.method ? .success(route) : .failure(.method)
    }

    /// Nil when acceptable.
    public static func checkBody(_ body: String?, route: Route) -> Refusal? {
        guard let body else { return nil }
        if route.method == "GET" { return .bodyNotAllowed }
        return body.utf8.count > maxRequestBody ? .bodyTooLarge : nil
    }

    /// The request URL: the signalling origin's scheme, host and port, and the route's own path.
    public static func url(base: String, route: Route) -> URL? {
        guard let b = URLComponents(string: base), let scheme = b.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = b.host, !host.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = scheme; c.host = host; c.port = b.port
        // `path`, NOT `percentEncodedPath`: the latter TRAPS on a string that is not valid percent
        // encoding (measured: a `?` in a widened route took the app down with SIGTRAP), and a Route
        // is a public value anyone can construct. For a parsed route the two are identical.
        c.path = route.path
        return c.url
    }

    private static func parse(_ path: String) -> Route? {
        // Split on "/" and require EXACTLY the expected segments: no empty ones (`//`, a trailing
        // `/`), and a segment's charset is base64url, so `.`, `%`, `?`, `#` and `\` can never pass.
        guard path.hasPrefix("/") else { return nil }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 2 where parts[0] == "credential" && isBase64URL(parts[1], 4...344):
            return .credential(id: parts[1])
        case 3 where parts[0] == "directory" && isBase64URL(parts[1], 43...43):
            switch parts[2] {
            case "challenge": return .directoryChallenge(root: parts[1])
            case "register": return .directoryRegister(root: parts[1])
            case "list": return .directoryList(root: parts[1])
            default: return nil
            }
        default: return nil
        }
    }

    private static func isBase64URL(_ s: String, _ length: ClosedRange<Int>) -> Bool {
        let u = s.utf8
        return length.contains(u.count) && u.allSatisfy { b in
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x5F
        }
    }
}
