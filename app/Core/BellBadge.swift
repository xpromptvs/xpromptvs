import Foundation

/// THE DOCK'S BELL (docs/desktop-app.md, "The bell"). Each client window's page reports how many of its
/// terminal tabs rang a bell nobody has seen yet (`__rdevShell.setBell`, web/src/client/term-bell.ts); the
/// Dock's badge is their SUM, and a window's count GROWING — a tab newly unseen — is what may ask for the
/// person's attention (the caller adds "while the app is not active"). Keyed by the window's id; a window that
/// closes, reloads or whose page dies is `remove`d, so a dead page leaves no badge behind.
public struct BellBadge: Equatable, Sendable {
    /// The largest count a page may report — far beyond the tab cap, so only a malformed one is refused.
    public static let maxCount = 999
    private var counts: [Int: Int] = [:]

    public init() {}

    /// Window `id` now has `count` unseen bells. True when that GREW its count: news.
    public mutating func set(_ count: Int, for id: Int) -> Bool {
        let old = counts[id] ?? 0
        counts[id] = count > 0 ? count : nil
        return count > old
    }

    public mutating func remove(_ id: Int) { counts[id] = nil }

    public func count(for id: Int) -> Int { counts[id] ?? 0 }
    public var total: Int { counts.values.reduce(0, +) }

    /// The Dock badge's text: nil (no badge) at zero, the count, or "99+" past two digits.
    public var label: String? {
        let n = total
        return n == 0 ? nil : n > 99 ? "99+" : String(n)
    }

    /// A client window's title while its page has an unseen bell — the page's own title carries the same
    /// prefix (`BELL_TITLE_PREFIX`), and the window's title bar is the app's equivalent of a browser tab.
    public static func title(_ base: String, ringing: Bool) -> String { ringing ? "🔔 " + base : base }
}
