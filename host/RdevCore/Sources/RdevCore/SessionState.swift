import Foundation

/// Where the driver left a window on the DESKTOP (floating) layout, in the client's stage CSS px.
///
/// A CLIENT COORDINATE, KEPT BY THE HOST. The host never interprets it: it is session state only so the
/// next client, on whatever device, can put the window back — clamping it onto its own viewport. Pinned
/// layouts (phone, glasses) ignore it; their windows are full-bleed.
public struct WindowPosition: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    /// The magnitude neither axis may exceed. Generous — a real stage is a few thousand px — and there
    /// only so a garbled or hostile number cannot sit in the state and be sent to every client forever.
    public static let bound: Double = 100_000

    /// Finite and within `bound` on both axes. A position that fails this is REFUSED, never clamped:
    /// clamping would put the window somewhere nobody dragged it.
    public static func isValid(x: Double, y: Double) -> Bool {
        x.isFinite && y.isFinite && abs(x) <= bound && abs(y) <= bound
    }
}

/// One window in the session: a source the driver opened, in TAB order.
public struct SessionWindow: Equatable, Sendable {
    public let source: String            // a Source.id: "win:<id>" / "dsp:<id>"
    /// Parked as its tab: still in the session and NOT captured — the host streams only what is neither
    /// closed nor minimized (`SessionState.streamed`).
    public var minimized: Bool
    /// Absent = the client cascades it (`tileOffset`), which is also what a never-dragged window is.
    public var position: WindowPosition?
    /// The name the driver gave it (`SessionState.setName`), or nil — the client then shows the source's
    /// own name. Kept while the window is minimized; gone with the window.
    public var name: String?
    public init(source: String, minimized: Bool = false, position: WindowPosition? = nil, name: String? = nil) {
        self.source = source; self.minimized = minimized; self.position = position; self.name = name
    }
}

/// Which surface a PINNED layout (phone, glasses) shows. The floating layout shows both at once.
public enum SessionSurface: String, Equatable, Sendable {
    case terminal, windows, agents
}

public struct SessionView: Equatable, Sendable {
    public var surface: SessionSurface
    /// The window in the PAGE's full-screen mode, or nil. The browser's own full screen needs a user
    /// gesture, so it is the client's to ask for and is never restored.
    public var fullscreen: String?
    public init(surface: SessionSurface = .terminal, fullscreen: String? = nil) {
        self.surface = surface; self.fullscreen = fullscreen
    }
}

/// Where the person LANDS when the window they were at leaves the bar (`SessionState.landing`): the tab to
/// its left — a streamed window or a TERMINAL tab, the bar interleaving the two.
public enum SessionLanding: Equatable, Sendable {
    case window(String)
    case terminal(String)
    case agent(String)
}

public struct SessionAgent: Equatable, Sendable {
    public let id: String
    public var title: String
    public var cwd: String
    public var name: String?
    public var status: String?
    public var activeFlags: [String] = []
}

/// THE HOST'S SESSION — what every client renders and what the host reconciles its captures against
/// (docs/superpowers/specs/2026-09-29-host-session-state-design.md). A pure value type that REPLACES
/// `ViewSet`, whose subscribed-sources-plus-focus it grew out of.
///
/// ONLY THE DRIVER'S INTENTS CHANGE IT. The gate is the caller's (`ChannelHub`); this type only decides
/// what a change means and refuses what it cannot mean.
///
/// EVERY MUTATOR RETURNS WHETHER THE STATE CHANGED, and `version` moves by exactly one when it did and
/// never when it did not. Callers broadcast on `true`; clients and tests read `version` to see order. A
/// no-op that bumped it would read as a change nobody made.
///
/// NO CAP, unlike `ViewSet(maxSubs:)`: its only caller ran unbounded. Video settings are not here
/// either — they are the DEVICE's (`ClientPrefs`), applied to every window the host streams.
public struct SessionState: Equatable, Sendable {
    /// In the BAR's order: the same RELATIVE order as `tabOrder`'s window keys, so every use of it — the
    /// focus fall-back, `streamed` — follows what the person sees, and a drag that moves a window moves it
    /// here too.
    public private(set) var windows: [SessionWindow] = []
    /// EVERY TAB OF THE BAR, in bar order, by KEY (`TabKey`): terminal tabs (`pty:<n>`, `tmux:$<n>`) and
    /// windows (`win:<n>`, `dsp:<n>`) interleaved as the driver dragged them
    /// (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §1.1). One piece of session state,
    /// not one per strip, because a tab can be dragged anywhere in the bar.
    ///
    /// INVARIANTS: no duplicates; every window in `windows` exactly once (a window that leaves the session
    /// leaves it); its terminal keys exactly the last `syncTerminals` set; `windows` in the same relative
    /// order as its window keys.
    ///
    /// DEFAULT PLACEMENT — a new tab goes right after the last tab of ITS OWN KIND; with none, a terminal
    /// goes FIRST and a window LAST. So a bar nobody dragged is the bar before this existed (terminals,
    /// then windows), and a new tab lands beside its siblings rather than at the far end.
    public private(set) var tabOrder: [String] = []
    /// The session's windows in the order they were OPENED — what `windows` was before the bar could be
    /// dragged. The audio election reads it (`streamedByOpening`): "first subscriber wins"
    /// (docs/audio.md) must not change because a tab moved. A window opened again after a close is a new
    /// subscription, so it goes last; a restore keeps its place.
    public private(set) var openingOrder: [String] = []
    /// One open, non-minimized window, or nil. When the focused window closes, is parked or its app quits,
    /// focus falls to the nearest streamed window BEFORE it in tab order — the tab to its left — or, with
    /// none before it, the nearest after it: the terminal tabs' rule (`TabPool.close`). Until 2026-09-30 it
    /// fell to the FIRST (ViewSet's rule), two or more tabs away from where the person was working.
    ///
    /// THE PERSON can land on a TERMINAL tab instead (`landing`, 2026-10-02): then the terminal surface
    /// shows and this still falls back by the window rule, so the windows surface has a window to show
    /// when they go back to it.
    public private(set) var focused: String? = nil
    public private(set) var view = SessionView()
    public private(set) var version: UInt64 = 0

    public private(set) var agents: [SessionAgent] = []
    public private(set) var selectedAgent: String?

    /// Launch-only, before clients: restore tab metadata, never cached runtime authority/status.
    @discardableResult
    public mutating func restoreAgents(_ saved:SavedAgentTabs,terminalIDs:[Int:String]) -> Bool {
        guard agents.isEmpty,!saved.tabs.isEmpty else{return false}
        return commit { s in
            s.agents=saved.tabs;s.selectedAgent=saved.selected
            if saved.showing,s.selectedAgent != nil {s.view=SessionView(surface:.agents)}
            var order:[String]=[]
            for key in saved.order {
                let mapped:String?
                if TabKey.isAgent(key) {mapped=key}
                else if key.hasPrefix("terminal:"),let index=Int(key.dropFirst(9)) {mapped=terminalIDs[index]}
                else {mapped=nil}
                if let mapped,!order.contains(mapped) {order.append(mapped)}
            }
            for key in s.tabOrder+saved.tabs.map({"agent:"+$0.id}) where !order.contains(key) {order.append(key)}
            s.tabOrder=order
        }
    }

    @discardableResult
    public mutating func openAgent(_ id: String, title: String, cwd: String) -> Bool {
        guard TabKey.isAgent("agent:" + id), title.utf8.count <= 4096, cwd.utf8.count <= 4096,
              agents.contains(where: { $0.id == id }) || agents.count < 100 else { return false }
        return commit { s in
            if let i = s.agents.firstIndex(where: { $0.id == id }) {
                s.agents[i].title = title; s.agents[i].cwd = cwd
            } else {
                s.agents.append(SessionAgent(id: id, title: title, cwd: cwd))
                let at = s.tabOrder.lastIndex(where: TabKey.isAgent).map { $0 + 1 } ?? s.tabOrder.endIndex
                s.tabOrder.insert("agent:" + id, at: at)
            }
            s.selectedAgent = id; s.view.surface = .agents; s.view.fullscreen = nil
        }
    }

    @discardableResult
    public mutating func selectAgent(_ id: String) -> Bool {
        guard agents.contains(where: { $0.id == id }) else { return false }
        return commit { $0.selectedAgent = id; $0.view.surface = .agents; $0.view.fullscreen = nil }
    }

    @discardableResult
    public mutating func closeAgent(_ id: String) -> Bool {
        guard agents.contains(where: { $0.id == id }) else { return false }
        let landing = view.surface == .agents && selectedAgent == id ? self.landing(leaving: "agent:" + id) : nil
        return commit { s in
            s.agents.removeAll { $0.id == id }; s.tabOrder.removeAll { $0 == "agent:" + id }
            if s.selectedAgent == id {
                s.selectedAgent = s.tabOrder.last(where: TabKey.isAgent).map { String($0.dropFirst(6)) }
                if s.view.surface == .agents, s.selectedAgent == nil { s.view.surface = .terminal }
                switch landing {
                case .terminal?: s.view.surface = .terminal
                case .window(let source)?: s.view.surface = .windows; s.focused = source
                case .agent(let next)?: s.view.surface = .agents; s.selectedAgent = next
                case nil: break
                }
            }
        }
    }

    @discardableResult
    public mutating func setAgentName(_ id: String, _ name: String) -> Bool {
        guard TabName.isValid(name), let i = agents.firstIndex(where: { $0.id == id }) else { return false }
        return commit { $0.agents[i].name = name.isEmpty ? nil : name }
    }

    @discardableResult
    public mutating func setAgentStatus(_ id: String, _ status: String?, activeFlags: [String] = []) -> Bool {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return false }
        let status = status.flatMap { ["active", "idle", "notLoaded", "systemError"].contains($0) ? $0 : nil }
        let flags = status == "active" ? activeFlags.filter { ["waitingOnApproval", "waitingOnUserInput"].contains($0) }.sorted() : []
        return commit { $0.agents[i].status = status; $0.agents[i].activeFlags = flags }
    }

    public init() {}

    /// The windows the host should capture and stream: open and not minimized, in tab order.
    public var streamed: [String] { windows.filter { !$0.minimized }.map(\.source) }

    /// `streamed` in the order the windows were OPENED, never the bar's — the AUDIO ELECTION's order.
    /// Review I1 (2026-10-01): the election read `streamed`, so dragging a sibling's tab in front of an
    /// application's carrier moved its sound at the next election.
    public var streamedByOpening: [String] { openingOrder.filter { isStreamed($0) } }

    public func contains(_ source: String) -> Bool { index(of: source) != nil }
    public func window(_ source: String) -> SessionWindow? { index(of: source).map { windows[$0] } }

    /// Open `source` — append it if new, un-minimize it if parked — and focus it. A NEW window enters
    /// `tabOrder` right after the last window, or last with none — which is also the end of `windows`, so
    /// the two stay in the same relative order. One already in the session keeps its place.
    @discardableResult
    public mutating func open(_ source: String) -> Bool {
        commit { s in
            if let i = s.index(of: source) { s.windows[i].minimized = false }
            else {
                let windowKeys = Set(s.windows.map(\.source))
                let at = s.tabOrder.lastIndex { windowKeys.contains($0) }.map { $0 + 1 } ?? s.tabOrder.endIndex
                s.windows.append(SessionWindow(source: source))
                s.tabOrder.insert(source, at: at)
                s.openingOrder.append(source)
            }
            s.focused = source
        }
    }

    /// Remove `source` from the session. Focus and full screen fall back if it held them. `landing`: where the
    /// person lands, when they were AT the window (`landing(leaving:)`, asked by the caller BEFORE the change).
    @discardableResult
    public mutating func close(_ source: String, landing: SessionLanding? = nil) -> Bool {
        guard let i = index(of: source) else { return false }
        let order = windows.map(\.source)
        return commit { s in
            s.windows.remove(at: i)
            s.tabOrder.removeAll { $0 == source }
            s.openingOrder.removeAll { $0 == source }
            s.settle(from: order, landing: landing)
        }
    }

    /// Park `source` as its tab. It keeps its place and position; focus and full screen fall back. `landing`
    /// as for `close`.
    @discardableResult
    public mutating func minimize(_ source: String, landing: SessionLanding? = nil) -> Bool {
        guard let i = index(of: source) else { return false }
        let order = windows.map(\.source)
        return commit { s in
            s.windows[i].minimized = true
            s.settle(from: order, landing: landing)
        }
    }

    /// Bring a parked window back and focus it.
    @discardableResult
    public mutating func restore(_ source: String) -> Bool {
        guard let i = index(of: source) else { return false }
        return commit { s in
            s.windows[i].minimized = false
            s.focused = source
        }
    }

    /// Focus an open, non-minimized window. Anything else is refused.
    @discardableResult
    public mutating func focus(_ source: String) -> Bool {
        guard isStreamed(source) else { return false }
        return commit { $0.focused = source }
    }

    /// Where the driver left `source` on the desktop layout. Refused unless `WindowPosition.isValid`;
    /// kept while the window is minimized.
    @discardableResult
    public mutating func setPosition(_ source: String, x: Double, y: Double) -> Bool {
        guard WindowPosition.isValid(x: x, y: y), let i = index(of: source) else { return false }
        return commit { $0.windows[i].position = WindowPosition(x: x, y: y) }
    }

    /// `nil` leaves a field alone; for `fullscreen`, `.some(nil)` ends the mode and `.some(id)` must name
    /// a STREAMED window. A refusal is WHOLE: an invalid full-screen half changes nothing, not even a
    /// valid surface beside it — a half-applied message is a state nobody asked for.
    @discardableResult
    public mutating func setView(surface: SessionSurface?, fullscreen: String??) -> Bool {
        if surface == .agents, selectedAgent == nil { return false }
        if case .some(.some(let id)) = fullscreen, !isStreamed(id) { return false }
        return commit { s in
            if let surface { s.view.surface = surface }
            if let fullscreen { s.view.fullscreen = fullscreen }
        }
    }

    /// Drop every window whose source is not in `live` — its app quit or its display went away —
    /// minimized or not. Returns the dropped sources in tab order. ONE change however many it drops.
    /// It NEVER LANDS (`landing`): a quit is discovered on any client's listing, possibly long after the
    /// person moved on, and must not move the terminal or the surface under them.
    @discardableResult
    public mutating func retain(onlyIn live: Set<String>) -> [String] {
        let dropped = windows.map(\.source).filter { !live.contains($0) }
        guard !dropped.isEmpty else { return [] }
        let order = windows.map(\.source)
        commit { s in
            s.windows.removeAll { !live.contains($0.source) }
            s.tabOrder.removeAll { dropped.contains($0) }
            s.openingOrder.removeAll { dropped.contains($0) }
            s.settle(from: order, landing: nil)
        }
        return dropped
    }

    // MARK: - the bar (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §1.1)

    /// Move `tab` to just before `before`, or to the END when `before` is nil. REFUSED (false, nothing
    /// changes) when `tab` is not in `tabOrder`, `before` is non-nil and not in it, or `before == tab`. A
    /// move that leaves the order as it was is no change. A moved WINDOW moves in `windows` too.
    ///
    /// `before`, never an index: a client's bar can be a SUBSET of the session's (a window-less client
    /// shows no windows), and "before X" means the same thing on both.
    @discardableResult
    public mutating func moveTab(_ tab: String, before: String?) -> Bool {
        guard tabOrder.contains(tab) else { return false }
        if let before { guard before != tab, tabOrder.contains(before) else { return false } }
        return commit { s in
            s.tabOrder.removeAll { $0 == tab }
            if let before, let i = s.tabOrder.firstIndex(of: before) { s.tabOrder.insert(tab, at: i) }
            else { s.tabOrder.append(tab) }
            // `windows` re-derived from the order: the same windows, in the order's relative order.
            let byKey = Dictionary(uniqueKeysWithValues: s.windows.map { ($0.source, $0) })
            s.windows = s.tabOrder.compactMap { byKey[$0] }
        }
    }

    /// The terminal half of the order follows the terminal pool: `ids` is the pool's tabs IN POOL ORDER.
    /// Terminal keys not in `ids` leave; ids not yet in the order enter by the default placement (right
    /// after the last terminal, else FIRST), in pool order. It never REORDERS a terminal already in it —
    /// the order is the state's and the pool follows it (`TabPool.arrange`), never the reverse. An id that
    /// is a window's key is ignored, and a repeated one counts once.
    ///
    /// The same set again is NO CHANGE: a title change re-syncs constantly, and must broadcast nothing.
    @discardableResult
    public mutating func syncTerminals(_ ids: [String]) -> Bool {
        let windowKeys = Set(windows.map(\.source))
        var wanted: [String] = []
        for id in ids where !windowKeys.contains(id) && !TabKey.isAgent(id) && !wanted.contains(id) { wanted.append(id) }
        return commit { s in
            s.tabOrder.removeAll { !windowKeys.contains($0) && !TabKey.isAgent($0) && !wanted.contains($0) }
            for id in wanted where !s.tabOrder.contains(id) {
                let at = s.tabOrder.lastIndex { !windowKeys.contains($0) && !TabKey.isAgent($0) }.map { $0 + 1 } ?? s.tabOrder.startIndex
                s.tabOrder.insert(id, at: at)
            }
        }
    }

    /// A WINDOW's user name (§1.2); nil or `""` CLEARS it (stored as nil). Refused (false, nothing changes)
    /// for a source that is not a window in the session — a terminal's name is the pool's — or a name
    /// `TabName` refuses.
    @discardableResult
    public mutating func setName(_ source: String, _ name: String?) -> Bool {
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        if let name, !TabName.isValid(name) { return false }
        guard let i = index(of: source) else { return false }
        return commit { $0.windows[i].name = name }
    }

    private func index(of source: String) -> Int? { windows.firstIndex { $0.source == source } }
    private func isStreamed(_ source: String) -> Bool { window(source).map { !$0.minimized } ?? false }

    /// WHERE THE PERSON LANDS if `source` — the FOCUSED window — goes now, closed or parked (asked
    /// 2026-10-01: "closing a window should land on the previous tab, terminal or window"). The tab to its
    /// LEFT in the bar (`tabOrder`), or with none, to its right: another STREAMED window or a TERMINAL tab. A
    /// parked window is skipped, as the window rule skips it (landing on it would mean restoring it). Nil for
    /// an unfocused window — its going moves nobody — and with nothing left to land on.
    ///
    /// ASKED ONLY WHEN THE PERSON WAS AT THE WINDOW, and only the CLIENT can tell that (its intent says
    /// `land`): on a desktop the surface means nothing — it stays "windows" after a palette pick while the
    /// person types in the terminal — so this does not second-guess the client with it (review, 2026-10-02:
    /// the surface gate switched the shell being typed into). An app quitting never asks (`retain`).
    ///
    /// PURE. The caller applies the ONE answer twice: to the terminal pool (which tab is ACTIVE is the pool's,
    /// not this state's) and then to `close`/`minimize`, whose `.terminal` landing shows the terminal surface.
    public func landing(leaving source: String) -> SessionLanding? {
        guard (focused == source && isStreamed(source)) || (source == selectedAgent.map { "agent:" + $0 } && view.surface == .agents) else { return nil }
        let windowKeys = Set(windows.map(\.source))
        func candidate(_ key: String) -> SessionLanding? {
            if key == source { return nil }
            if TabKey.isAgent(key) { return .agent(String(key.dropFirst(6))) }
            guard windowKeys.contains(key) else { return .terminal(key) }
            return isStreamed(key) && key != source ? .window(key) : nil
        }
        let i = tabOrder.firstIndex(of: source) ?? tabOrder.count
        let before = tabOrder[..<i].reversed(), after = tabOrder[min(i + 1, tabOrder.count)...]
        return before.lazy.compactMap(candidate).first ?? after.lazy.compactMap(candidate).first
    }

    /// After anything that can close or park a window: focus and full screen may only name a streamed one.
    /// A focus that went falls to the nearest window still streamed BEFORE it in `order` (the tab order
    /// before the change), else the nearest after it — whatever the person landed on. A landing on a
    /// TERMINAL tab of the bar shows the terminal surface; one naming no terminal tab of it changes nothing.
    private mutating func settle(from order: [String], landing: SessionLanding?) {
        if let f = focused, !isStreamed(f) {
            let i = order.firstIndex(of: f) ?? order.count
            let before = order[..<i].reversed(), after = order[min(i + 1, order.count)...]
            focused = before.first { isStreamed($0) } ?? after.first { isStreamed($0) }
        }
        if let f = view.fullscreen, !isStreamed(f) { view.fullscreen = nil }
        if case .agent(let id)? = landing { selectedAgent = id; view.surface = .agents }
        if case .terminal(let key)? = landing, tabOrder.contains(key), !windows.contains(where: { $0.source == key }) {
            view.surface = .terminal
        }
    }

    /// Apply `change` to a copy and keep it — with `version` + 1 — only if it changed something.
    @discardableResult
    private mutating func commit(_ change: (inout SessionState) -> Void) -> Bool {
        var next = self
        change(&next)
        guard next != self else { return false }
        next.version = version &+ 1
        self = next
        return true
    }
}
