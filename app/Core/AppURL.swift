import Foundation

/// `app://<root>/<path>` → a file beneath `roots[<root>]`, or nil to refuse. The URL HOST selects
/// the root, which is what gives `app://ui` and `app://client` separate origins and storage.
///
/// LOAD-BEARING: decode BEFORE the containment check. `%2e%2e%2f%2e%2e%2fetc` is one segment until
/// it is decoded into `../../etc`; checking the still-encoded path would pass it.
public enum AppURL {
    public static func resolve(_ raw: String, roots: [String: URL]) -> URL? {
        guard let u = URL(string: raw), u.scheme == "app",
              let host = u.host(percentEncoded: false), let root = roots[host] else { return nil }
        guard var rel = u.path(percentEncoded: true).removingPercentEncoding else { return nil }
        if rel.isEmpty || rel.hasSuffix("/") { rel += "index.html" }
        let base = root.standardizedFileURL.path
        let full = URL(fileURLWithPath: base).appendingPathComponent(rel).standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full == base || full.hasPrefix(prefix) else { return nil }
        return URL(fileURLWithPath: full)
    }

    private static let types: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "json": "application/json", "map": "application/json", "svg": "image/svg+xml", "png": "image/png",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "ico": "image/x-icon", "webp": "image/webp",
        "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "wasm": "application/wasm",
        "txt": "text/plain", "webmanifest": "application/manifest+json",
    ]
    public static func mimeType(for file: URL) -> String {
        types[file.pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
