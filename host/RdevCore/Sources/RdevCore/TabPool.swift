import Foundation

/// One terminal tab as surfaced to the client picker. `ordinal` is the 1-based creation number
/// (never reused) used for the "Terminal N" fallback label; `title` is the live OSC title ("" = none).
public struct TabDescriptor: Equatable, Sendable {
    public let id: TermTabID
    public let ordinal: Int
    public var title: String
    /// A `pty:` tab's USER name (`setName`), or nil — the client's label is then the title, then
    /// "Terminal N". A `tmux:` tab NEVER has one: its label is its SESSION's name, which is its `title`
    /// (`%session-renamed` keeps it current), and renaming it renames the session.
    public var name: String?
    /// The agent working — or idle — in it, as its screen says (`AgentActivity`); nil while none runs in its foreground.
    public var agent: AgentActivity.State?
    /// Foreground process identity, independent of its activity. Used to gate composer recognition.
    public var agentKind: String?
    public init(id: TermTabID, ordinal: Int, title: String, name: String? = nil, agent: AgentActivity.State? = nil, agentKind: String? = nil) {
        self.id = id; self.ordinal = ordinal; self.title = title; self.name = name; self.agent = agent; self.agentKind = agentKind
    }
}

/// Pure bookkeeping for the host's shell pool: stable ids, creation ordinals, the active tab, and
/// the open/close/switch transitions (no minimum since 2026-09-25 / max-`maxTabs` / neighbor-on-close). Holds no PTYs —
/// `TerminalManager` maps these decisions onto real shells.
public struct TabPool: Equatable, Sendable {
    public private(set) var tabs: [TabDescriptor] = []
    public private(set) var activeId: TermTabID? = nil
    private var nextId = 1
    private var nextOrdinal = 1
    public let maxTabs: Int

    /// How many tabs a session holds — `pty:` and `tmux:` together. 100 since 2026-10-09 (asked for: "There are 8 tabs
    /// limit. Make it 100"); the client's refusal names it (`TERMINAL_TAB_LIMIT`, terminal-tabs.ts).
    public static let defaultMaxTabs = 100

    public init(maxTabs: Int = TabPool.defaultMaxTabs) { self.maxTabs = maxTabs }

    public var count: Int { tabs.count }
    public func contains(_ id: TermTabID) -> Bool { tabs.contains { $0.id == id } }
    private func index(of id: TermTabID) -> Int? { tabs.firstIndex { $0.id == id } }

    /// Append a new shell tab (fresh `pty:` id + ordinal) and make it active. Returns its id, or nil
    /// at the cap.
    @discardableResult
    public mutating func open() -> TermTabID? {
        guard tabs.count < maxTabs else { return nil }
        let id = TermTabID.pty(nextId); nextId += 1
        let ord = nextOrdinal; nextOrdinal += 1
        tabs.append(TabDescriptor(id: id, ordinal: ord, title: ""))
        activeId = id
        return id
    }

    /// Append a tmux session's tab and make it active. False at the cap, or when that session already
    /// has a tab (selecting an open session is `switchTo`, never a second tab).
    @discardableResult
    public mutating func add(tmux session: String, title: String) -> Bool {
        let id = TermTabID.tmux(session)
        guard tabs.count < maxTabs, !contains(id) else { return false }
        let ord = nextOrdinal; nextOrdinal += 1
        tabs.append(TabDescriptor(id: id, ordinal: ord, title: title))
        activeId = id
        return true
    }

    /// Remove a tab — ANY tab, the last one included. Returns nil if rejected (unknown id); otherwise `.some(newActiveId)`,
    /// which is itself nil when the pool is now empty. When the active tab is closed, the previous
    /// neighbor becomes active (the next one if it was first).
    @discardableResult
    public mutating func close(_ id: TermTabID) -> TermTabID?? {
        guard let idx = index(of: id) else { return nil }
        let wasActive = (activeId == id)
        tabs.remove(at: idx)
        if wasActive { activeId = tabs.isEmpty ? nil : tabs[max(0, idx - 1)].id }
        return .some(activeId)
    }

    /// Make `id` the active tab. Returns false for an unknown id.
    public mutating func switchTo(_ id: TermTabID) -> Bool {
        guard contains(id) else { return false }
        activeId = id
        return true
    }

    /// Set a tab's agent state (`AgentTracker`). Returns whether it actually changed.
    @discardableResult
    public mutating func setAgent(_ id: TermTabID, _ agent: AgentActivity.State?, kind: String? = nil) -> Bool {
        let kind = agent == nil ? nil : kind
        guard let idx = index(of: id), tabs[idx].agent != agent || tabs[idx].agentKind != kind else { return false }
        tabs[idx].agent = agent
        tabs[idx].agentKind = kind
        return true
    }

    /// Update a tab's title. Returns whether it actually changed.
    @discardableResult
    public mutating func setTitle(_ id: TermTabID, _ title: String) -> Bool {
        guard let idx = index(of: id), tabs[idx].title != title else { return false }
        tabs[idx].title = title
        return true
    }

    /// A `pty:` tab's user name; nil or `""` CLEARS it (stored as nil — `""` is never a name). Refused
    /// (false, nothing changes) for a `tmux:` tab — renaming one renames its tmux session — an unknown id,
    /// or a name `TabName` refuses. Returns whether it actually changed.
    @discardableResult
    public mutating func setName(_ id: TermTabID, _ name: String?) -> Bool {
        guard case .pty = id, let idx = index(of: id) else { return false }
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        if let name, !TabName.isValid(name) { return false }
        guard tabs[idx].name != name else { return false }
        tabs[idx].name = name
        return true
    }

    /// The pool's tabs in `order` — the bar's order (`SessionState.tabOrder`'s terminal half), so that
    /// `close`'s "the previous neighbour becomes active" is the neighbour the person SEES. Ids the pool does
    /// not hold are ignored, a repeated one counts once, and tabs the list omits keep their relative order
    /// AFTER the listed ones. Changes nothing else: the active tab and every ordinal stay. Returns whether
    /// the order changed.
    @discardableResult
    public mutating func arrange(_ order: [TermTabID]) -> Bool {
        var listed: [TabDescriptor] = []
        for id in order where !listed.contains(where: { $0.id == id }) {
            if let i = index(of: id) { listed.append(tabs[i]) }
        }
        let rest = tabs.filter { t in !listed.contains { $0.id == t.id } }
        let next = listed + rest
        guard next.map(\.id) != tabs.map(\.id) else { return false }
        tabs = next
        return true
    }

    /// Move `id` to just before `before`, or to the END when `before` is nil — the bar's `move-tab` when the
    /// host has no session state to order (the test-pattern harness: terminals only). Refused (false,
    /// nothing changes) for an unknown `id`, an unknown `before`, or `before == id`. A move that leaves the
    /// order as it was is no change.
    @discardableResult
    public mutating func move(_ id: TermTabID, before: TermTabID?) -> Bool {
        guard contains(id) else { return false }
        if let before { guard before != id, contains(before) else { return false } }
        var order = tabs.map(\.id)
        order.removeAll { $0 == id }
        if let before, let i = order.firstIndex(of: before) { order.insert(id, at: i) } else { order.append(id) }
        return arrange(order)
    }
}
