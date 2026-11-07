import Foundation

/// **A PAGE'S `window.open` GOES TO THE DEFAULT BROWSER, http AND https ONLY** (2026-10-05, reported: "In desktop
/// app, pressing on links in the terminal doesn't seem to do anything"; docs/desktop-app.md, "Links open in the
/// browser"). A terminal link opens with `window.open(url, "_blank", "noopener,noreferrer")` (web/src/client/
/// term-links.ts) — in a browser a tab; in the app WKWebView asks `createWebViewWith`, which had no answer, so nothing
/// opened. The client window answers with no window of its own and, for a URL this allows, `NSWorkspace.open`.
/// Never `javascript:`, a `file:` path (on a remote Mac it names THAT Mac's file) or a scheme some app here claims.
public enum ExternalLink {
    /// The URL to hand the default browser, or nil.
    public static func openable(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
