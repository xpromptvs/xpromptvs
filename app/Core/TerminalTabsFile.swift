import Foundation

/// The session's terminal tabs, saved for the app's next launch: `terminal-tabs.json` in the profile
/// directory (docs/terminal.md, "Tabs that come back"). The bytes are RdevCore's `SavedTerminalTabs`; this is
/// only the FILE — where, atomically, and written only when the bytes changed, so the keeper's periodic save
/// touches the disk only when a tab, its name or its directory did.
public struct TerminalTabsFile {
    public static let name = "terminal-tabs.json"
    public let url: URL
    private var last: Data?

    public init(dir: URL) { url = dir.appendingPathComponent(Self.name) }

    public func read() -> Data? { try? Data(contentsOf: url) }

    /// Atomic: a crash mid-write leaves the old file, never half a new one. Returns whether it wrote.
    @discardableResult
    public mutating func write(_ data: Data) -> Bool {
        guard data != last else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            last = data
            return true
        } catch {
            print("[term] could not save the tabs: \(error)")
            return false
        }
    }
}
