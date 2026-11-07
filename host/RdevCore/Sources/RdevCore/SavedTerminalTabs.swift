import Foundation

/// **A TERMINAL TAB, AS FAR AS IT CAN BE BROUGHT BACK** (2026-10-03): a tab the driver closed, which ⌘⇧T
/// reopens (`reopen-terminal`), and the session's tabs the APP restores at its next launch (docs/terminal.md,
/// "Tabs that come back"). A `pty:` tab is its shell's DIRECTORY and its user name — the process itself cannot
/// come back, so a new shell starts there; a `tmux:` tab is its SESSION, which outlives the host and is
/// re-attached if it still exists.
public enum SavedTerminalTab: Equatable, Sendable {
    case pty(cwd: String?, name: String?)
    case tmux(session: String)

    /// A `tmux:` tab's session, nil for a `pty:` tab.
    public var tmuxSession: String? {
        if case .tmux(let s) = self { return s }
        return nil
    }
}

/// The session's terminal tabs in the bar's order, and which was active — the app's saved file.
public struct SavedTerminalTabs: Equatable, Sendable {
    public var tabs: [SavedTerminalTab]
    /// Index into `tabs`; nil for none.
    public var active: Int?
    /// Agent tabs share this atomic workspace save; absent in older terminal-only files.
    public var agents: SavedAgentTabs?

    public init(tabs: [SavedTerminalTab] = [], active: Int? = nil) {
        self.tabs = tabs
        self.active = active.flatMap { tabs.indices.contains($0) ? $0 : nil }
    }

    /// Filter unsupported restart metadata without mutating the saved value or file.
    public func restoring(graphicalAgents: Bool) -> SavedTerminalTabs {
        guard !graphicalAgents else { return self }
        var copy = self
        copy.agents = nil
        if copy.active == nil, !copy.tabs.isEmpty { copy.active = 0 }
        return copy
    }

    static let version = 1

    /// `{"v":1,"tabs":[{"kind":"pty","cwd":"/x","name":"n"},{"kind":"tmux","session":"$3"}],"active":0}`.
    public func json() -> Data {
        let tabs: [[String: Any]] = self.tabs.map {
            switch $0 {
            case .pty(let cwd, let name):
                var o: [String: Any] = ["kind": "pty"]
                if let cwd { o["cwd"] = cwd }
                if let name { o["name"] = name }
                return o
            case .tmux(let session):
                return ["kind": "tmux", "session": session]
            }
        }
        var obj: [String: Any] = ["v": Self.version, "tabs": tabs]
        if let active { obj["active"] = active }
        if let agents { obj["agents"] = agents.object }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    /// LENIENT per entry, strict about the file: an entry it cannot read is SKIPPED (the rest still come
    /// back), a tmux session id must be one (it is interpolated into tmux targets), a directory must be
    /// absolute, and an `active` that no longer points at a kept entry is none. Nil for no JSON object or
    /// another version.
    public init?(json data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["v"] as? NSNumber)?.intValue == Self.version,
              let raw = obj["tabs"] as? [Any] else { return nil }
        var tabs: [SavedTerminalTab] = []
        var kept: [Int: Int] = [:]                     // index in the file → index in `tabs`
        for (i, entry) in raw.enumerated() {
            guard let e = entry as? [String: Any], let kind = e["kind"] as? String else { continue }
            switch kind {
            case "pty":
                let cwd = (e["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
                let name = (e["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                kept[i] = tabs.count
                tabs.append(.pty(cwd: cwd, name: name))
            case "tmux":
                guard let s = e["session"] as? String, TmuxList.isSessionId(s) else { continue }
                kept[i] = tabs.count
                tabs.append(.tmux(session: s))
            default:
                continue
            }
        }
        let active = (obj["active"] as? NSNumber).flatMap { kept[$0.intValue] }
        self.init(tabs: tabs, active: active)
        if let object=obj["agents"] as? [String:Any] { agents=SavedAgentTabs(object:object,terminalIndices:kept) }
    }
}

/// The tabs the driver CLOSED, newest last, at most `limit` — what ⌘⇧T reopens, newest first.
public struct ClosedTerminalTabs: Sendable {
    public static let limit = 20
    public private(set) var items: [SavedTerminalTab] = []
    public init() {}
    public var isEmpty: Bool { items.isEmpty }
    public mutating func push(_ tab: SavedTerminalTab) {
        items.append(tab)
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
    }
    public mutating func pop() -> SavedTerminalTab? { items.popLast() }
}
