import Foundation
import RdevCore

/// One per host. Owns the pool of terminal tabs — each a PtyProcess + SwiftTerm emulator, or a tmux
/// session — and EVERY open tab streams to the driver (`onEmit`: a snapshot,
/// then live output); the "active" tab survives only for keystrokes (`write`) and the tab strip.
/// Mirrors SimManager: ChannelHub calls in to run tab ops, and TerminalManager calls back out
/// (`onEmit`, `onTabsChanged`) to stream and to announce tab-set changes.
///
/// Two kinds of tab share the one `TabPool` (`TermTabID`): `pty:` tabs are shells this host owns;
/// `tmux:` tabs are tmux sessions, each reached through ITS OWN `TmuxControlClient` (tmux control mode),
/// attached for as long as the tab is open, output ON — tmux holds the screen, so a tmux tab's
/// snapshot comes from tmux itself (`TmuxSnapshot`), taken IN ORDER with the pane's `%output` on that
/// client. One client moved between sessions with `switch-client` resized every session that another
/// client (the user's own terminal) also showed, on every switch — and its app redrew: the flicker on
/// switching to a shared session. tmux tabs are the SESSION's, like shells: a change of driver keeps
/// them attached, and closing one DETACHES — the session lives.
///
/// Concurrency: ALL terminal state (each tab's term/pty, the TabPool, the cached
/// `driverDecodesWire` flag) is guarded by `lock` — except a `pty:` tab's SNAPSHOT CAPTURE, which reads
/// its emulator under that tab's `serial` alone (every write to the emulator holds `serial` too; see
/// `snapshot`). Callbacks are invoked ONLY after `lock` is released.
/// A tab's `term.onRespond` / `term.onTitle` fire synchronously inside `term.feed()` while `lock` is
/// held — they read pool/flag state DIRECTLY (same thread; NSLock is NOT reentrant, so they must never
/// re-lock) and only mutate their own tab. Because no callback runs while `lock` is held, TerminalManager's
/// lock and ChannelHub's lock are never held simultaneously → no lock-ordering deadlock.
public final class TerminalManager: @unchecked Sendable {

    /// One tab = one shell + its emulator (SwiftTerm, which a snapshot serializes).
    final class Tab {
        let id: TermTabID
        let pty = PtyProcess()
        let term: Terminal
        var cols: Int
        var rows: Int
        /// The tab's SERIAL PATH: feeding SwiftTerm, forwarding output and taking a snapshot all hold
        /// it, so a snapshot sits at an exact byte position and the output after it follows it.
        /// Taken BEFORE `lock` (never the other way round).
        let serial = NSLock()
        /// Output is forwarded (a snapshot has been emitted since the last pause or change of wire).
        /// Guarded by `lock`. Only `stopForwarding` clears it, so held output never outlives it.
        private(set) var live = false
        /// Live output held for coalescing (`TermSendBuffer`). Non-empty ONLY while `live`. Guarded by
        /// `lock`; taken and emitted only on the serial path.
        var buffer = TermSendBuffer()
        /// Follows EVERY byte of the tab's output (forwarded or not, so a query split across reads —
        /// past the 4 KB hold too — is seen on the read that completes it): which queries a read completed
        /// and how many answers xterm.js gives each, and every other sequence that could be a query — the
        /// send buffer never holds one. Guarded by `lock`.
        var queryWatch = StreamingQueryStripper()
        /// Where the client's CURRENT instance of this tab begins in the tab's stream (`queryWatch.fed` at
        /// the last snapshot emitted). A query that BEGAN before it straddles the snapshot: its head went to
        /// an older instance (or nowhere) and the new one sees only its tail, so it is the host's to answer,
        /// reached or not, and earns no credit. Guarded by `lock`; written on the serial path.
        var instanceStart = 0
        func startForwarding() { live = true }
        /// The tab's output no longer reaches the context its held bytes were meant for (a new wire, a
        /// pause): drop them — the next snapshot supersedes them.
        func stopForwarding() { live = false; buffer.drop() }
        /// Device-query answers the emulator produced during the feed in progress, held until that
        /// feed's output has been emitted — only then is it known whether the driver's xterm.js sees the
        /// query (`handleTabOutput`). nil outside a feed. Guarded by `lock`.
        var answers: [UInt8]?
        /// Device-query replies the host OWES the client for this tab: one per query in bytes that
        /// reached the driver (the host left it to the client's instance), spent by each `term-reply`
        /// accepted for it (`writeReply`). Capped, so a client that never answers cannot grow it. Guarded
        /// by `lock`.
        var owedReplies = 0
        /// The host has sent a `term-bell` for this tab since its output last REACHED the driver (or its last
        /// snapshot): at most one per withheld stretch (docs/terminal.md, "The bell"). Guarded by `lock`.
        var bellSent = false
        /// The agent in it, as its screen last said (`checkAgent`). Guarded by `lock`.
        var agent = AgentTracker()
        init(id: TermTabID, cols: Int, rows: Int) {
            self.id = id; self.cols = cols; self.rows = rows
            self.term = Terminal(cols: cols, rows: rows)
        }
    }

    /// One tmux tab. `pane` is the pane its last SNAPSHOT captured; output for that pane is forwarded
    /// from then on (`live`); `modes` and `stripper` follow the pane's output from that snapshot.
    /// `carries` follow every pane's output whether it is forwarded or not: tmux's snapshot excludes a
    /// character (or escape sequence) its parser has half-read, and the first live bytes after it need
    /// that half in front (`PaneStreamCarry`).
    final class TmuxTab {
        let session: String
        var pane: String?
        var modes = TermModeTracker()
        var stripper = StreamingQueryStripper()
        /// Follows the pane's bytes — forwarded AND withheld, as `modes` does — for the BELs xterm.js would
        /// ring (`TermBellWatch`): the host rings the ones that reach no client. Reseeded with `modes`.
        var bells = TermBellWatch()
        /// As `Tab.bellSent`. Guarded by `lock`.
        var bellSent = false
        /// As `Tab.agent`: its pane's screen. Guarded by `lock`.
        var agent = AgentTracker()
        /// The followed pane's terminal (`#{pane_tty}`), asked once per pane: where its foreground is read. Guarded by
        /// `lock`.
        var paneTTY: (pane: String, tty: String)?
        var carries: [String: PaneStreamCarry] = [:]
        /// This tab's own control client, and the token its callbacks carry (a replaced client's late
        /// callbacks are ignored).
        var client: TmuxControlClient?
        var token: UUID?
        /// Someone else resized this window (`%layout-change` at a size other than rdev's grid). The
        /// next keystroke claims it back first: typing through `send-keys` does NOT make rdev's client
        /// tmux's "latest" (measured), so without the claim rdev would draw another client's size.
        var sizeDirty = false
        /// Output is forwarded (a snapshot was emitted since the last pause/restart). Guarded by `lock`.
        /// Only `stopForwarding` clears it, so held output never outlives it.
        private(set) var live = false
        /// Live output held for coalescing (`TermSendBuffer`). Non-empty ONLY while `live`. Guarded by
        /// `lock`; taken and emitted only on the tab's control-client callback queue.
        var buffer = TermSendBuffer()
        func startForwarding() { live = true }
        func stopForwarding() { live = false; buffer.drop() }
        /// Replies the host OWES the client for this tab (as `Tab.owedReplies`): one per answer xterm.js
        /// gives to a query the stripper LEFT IN — one tmux does not answer (OSC 4, OSC 12, multi-colour
        /// OSC 10/11, DECDSR, anything a C1 code point introduces). Guarded by `lock`.
        var owedReplies = 0
        /// Snapshot batches that failed in a row (not counting a dead client, whose exit recovers). One
        /// is retried; a second closes the tab. Guarded by `lock`.
        var failedSnapshots = 0
        /// The snapshot batch's timeout, doubled per consecutive timeout (a starved host) and reset by
        /// a snapshot that succeeds. Outlives the control client a timeout kills. Guarded by `lock`.
        var snapshotTimeout: TmuxSnapshotTimeout
        /// Snapshot batches issued for this tab; each batch knows its own number, so a failed one's
        /// retry can tell that a NEWER snapshot was issued meanwhile (and is the retry). Guarded by `lock`.
        var snapshotsIssued = 0
        /// The host's answers to left-in queries (`answerLeftIn`). Guarded by `lock`. Reads whose queries
        /// wait for the ONE `display` round trip in flight (`answerInFlight`), how many queries they hold
        /// (at most `maxQueuedHostQueries`), and the answer bytes typed that tmux has not acknowledged
        /// (at most `maxHostAnswerBytes`).
        var answerQueue: [(pane: String, queries: [(query: [UInt8], modes: TermModes)])] = []
        var answerQueued = 0
        var answerInFlight = false
        var answerUnacked = 0
        /// Queries dropped since the last round trip reported them (one log line per round trip).
        var answersDropped = 0
        /// The default colours this tab last REPORTED to tmux for each pane (`TmuxColourReport`) — what
        /// tmux answers a program's OSC 10/11 with. Every snapshot reports the session's live panes whose
        /// entry is not the driver's palette, and a palette change re-reports them all. Cleared with a new
        /// control client. Guarded by `lock`.
        var reported: [String: TmuxColourReport.Colours] = [:]
        init(session: String, snapshotTimeout: TimeInterval = 5) {
            self.session = session
            self.snapshotTimeout = TmuxSnapshotTimeout(base: snapshotTimeout)
        }

        /// Forget the carries of panes that no longer exist — each snapshot lists the session's panes,
        /// so a closed pane's carry does not outlive the next one.
        func prune(keeping live: Set<String>) {
            carries = carries.filter { live.contains($0.key) }
            reported = reported.filter { live.contains($0.key) }
        }
    }

    private let lock = NSLock()
    private var pool: TabPool {
        didSet { if pool.activeId != oldValue.activeId { clipboardSelection &+= 1 } }
    }
    private var clipboardSelection: UInt64 = 0
    private var clipboardSequence: UInt64 = 0
    private struct ClipboardRequest {
        let name: String, session: String
        let token: UUID
        let epoch: UInt64, selection: UInt64, sequence: UInt64
        let client: TmuxControlClient
    }
    private var clipboardPending: ClipboardRequest?
    private var clipboardReading = false
    private var clipboardQueuedDeliveries = 0
    private var clipboardCompleted: (ClipboardRequest, Data)?
    private let clipboardQueue = DispatchQueue(label: "term.tmux-clipboard")
    private var tabsById: [TermTabID: Tab] = [:]
    private var tmuxTabs: [String: TmuxTab] = [:]
    /// The tmux session whose window size rdev last CLAIMED (`switch-client`), i.e. the active tmux
    /// tab when `syncTmuxClients` last ran. Guarded by `lock`.
    private var claimed: String?
    /// The driver's grid as last reported — what a tmux client is sized to when it (re)attaches.
    private var gridCols = 80
    private var gridRows = 24
    /// Tabs were RESTORED at launch (`restore`) and no driver has reported a grid since: no tmux control
    /// client starts until one does (`resizeAll`), or every restored session — and the program in it — is
    /// resized to 80×24 and back. Guarded by `lock`.
    private var awaitingGrid = false
    /// The tabs the driver CLOSED (`closeRemembering`), what ⌘⇧T reopens (`reopenClosed`). The session's,
    /// never saved. Guarded by `lock`.
    private var closedTabs = ClosedTerminalTabs()
    /// The driver has a terminal wire bound (it declared `term-mode raw` and its channel is open). NOT
    /// read by the device-query decision — that is the emission's own result (`handleTabOutput`) — only
    /// by tests; what matters in the product is the GENERATION beside it, which orders the writes.
    private var driverDecodesWire = false
    /// The hub's wire generation `driverDecodesWire` was last written at; an older write is stale.
    private var driverWireGeneration: UInt64 = 0
    private var titleDirtyDuringFeed = false
    /// Tabs whose screen is to be READ for an agent's activity, a check scheduled (`scheduleAgentCheck`).
    /// Guarded by `lock`.
    private var agentChecks: Set<TermTabID> = []
    /// When each tab was last RESIZED and, since, last printed (`awaitSettled`: `screenPreview`'s and a new wire's
    /// snapshots') — a mark lives while its redraw could still be coming (`previewSettleMaxNanos`). Guarded by `lock`.
    private var settleMarks: [TermTabID: (resized: UInt64, output: UInt64?)] = [:]
    /// SwiftTerm executed a BEL during the feed in progress (`Terminal.onBell`). Guarded by `lock`.
    private var bellDuringFeed = false
    /// The colours the DRIVER's xterm.js reports (`term-palette`; xterm.js's own until it has said): what
    /// the host answers a tmux tab's left-in colour queries from when their bytes reach no client.
    /// Guarded by `lock`.
    private var palette = TermPalette.xtermDefault
    /// The hub's stamp of the hand-off `palette` came from (`setTermPalette`). Guarded by `lock`.
    private var paletteSeq: UInt64 = 0

    // Debounced title-change broadcast (titles can change per command). Touched only on `titleQueue`.
    private let titleQueue = DispatchQueue(label: "term.title")
    /// Where tmux renames run (`renameTmux`): off the hub's message path, and SERIAL, so two renames of
    /// one session land in the order they were asked for.
    private let renameQueue = DispatchQueue(label: "term.tmux-rename")
    private var titleWork: DispatchWorkItem?

    /// Tab set / active tab / a title changed. Invoked OUTSIDE `lock`.
    var onTabsChanged: (() -> Void)?
    /// The HOST removed a tmux tab (its session ended or was killed). Invoked OUTSIDE `lock`.
    var onTmuxClosed: ((_ session: String, _ reason: String) -> Void)?
    /// The HOST gave up on a tmux tab it could not read (`snapshot-failed`) and closed it — the session
    /// lives — or tmux refused a rename (`rename-failed`; `renameTmux`, on its own queue). The driver
    /// hears it as a `tmux-error`. Invoked OUTSIDE `lock`.
    var onTmuxError: ((_ session: String, _ reason: String) -> Void)?
    /// The set of tmux sessions may have changed. Invoked OUTSIDE `lock`.
    var onTmuxSessionsChanged: (() -> Void)?
    /// Every open tab's terminal stream (TermWire.swift). Invoked OUTSIDE `lock`, on the tab's serial
    /// path — a `pty:` tab's `serial`, a `tmux:` tab's control-client callback queue — so one tab's
    /// emissions arrive in stream order. Returns whether the emission went INTO A CONTEXT the driver
    /// decodes (a bound wire that has this tab's snapshot) — for `.output`, whether the driver's
    /// xterm.js will see those bytes, and so whether it answers a device query in them.
    var onEmit: ((TermEmission) -> Bool)?
    /// THE HOST'S BELL (docs/terminal.md, "The bell"): `id` rang a bell in output that reached NO client
    /// context — a pause, a resume's gap, a new wire before the tab's snapshot, no wire — so no xterm.js rang
    /// it. At most once per tab per such stretch (`bellSent`). The hub sends the driver a `term-bell`; with
    /// no driver it goes nowhere. Invoked OUTSIDE `lock`, on the tab's serial path.
    var onBell: ((TermTabID) -> Void)?
    /// New server clipboard text, captured for one active tmux tab/wire. Outside lock, on its callback queue.
    var onClipboard: ((TermTabID, UInt64, Data) -> Void)?
    var readClipboardForTests: ((String, Int) -> Data?)?
    /// A hidden driver's pause is in force: nothing is forwarded or snapshotted. Guarded by `lock`.
    private var paused = false

    /// nil ⇒ tmux is unavailable on this host. Set once by the owner, before any client connects.
    var tmux: TmuxRunner?
    /// The shell a new `pty:` tab runs, as a LOGIN shell (`TermEnvironment`). Tests substitute their own.
    var shell = "/bin/zsh"
    /// Where the FIRST tab starts, and any tab whose directory cannot be read or no longer exists
    /// (`newTabDirectory`). Tests substitute their own.
    var home = FileManager.default.homeDirectoryForCurrentUser.path

    /// The send buffer's clock (monotonic ns) and its timers — one per tab at most (`TermSendBuffer`).
    /// Injected by tests; the product uses the uptime clock and a global queue. A timer's work finds its
    /// way onto the tab's serial path itself.
    private let clock: @Sendable () -> UInt64
    private let schedule: @Sendable (_ afterNanos: UInt64, _ work: @escaping @Sendable () -> Void) -> Void

    init(cols: Int, rows: Int, maxTabs: Int = TabPool.defaultMaxTabs,
         clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         schedule: @escaping @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void = TerminalManager.strictTimer) {
        self.pool = TabPool(maxTabs: maxTabs)
        self.gridCols = cols; self.gridRows = rows
        self.clock = clock; self.schedule = schedule
    }

    // MARK: tab lifecycle

    /// Create + start a new shell and make it active. False at the cap. Sized to the grid the driver
    /// last REPORTED unless told otherwise — never a hard-coded 80x24 the client's size then corrects.
    /// It starts in `directory` — home if that is no directory now — or, with none, by the new-tab rule
    /// (`newTabDirectory`); `name` is its user name (`rename`'s), for a tab that comes back.
    @discardableResult
    func open(cols: Int? = nil, rows: Int? = nil, directory: String? = nil, name: String? = nil) -> Bool {
        openTab(cols: cols, rows: rows, directory: directory, name: name) != nil
    }

    private func openTab(cols: Int? = nil, rows: Int? = nil, directory: String?, name: String?) -> TermTabID? {
        let dir = directory.map { Self.isDirectory($0) ? $0 : home } ?? newTabDirectory()
        lock.lock()
        let c = max(1, cols ?? gridCols), r = max(1, rows ?? gridRows)
        guard let id = pool.open() else { lock.unlock(); return nil }
        if let name { _ = pool.setName(id, name) }
        let tab = makeTabLocked(id: id, cols: c, rows: r)
        lock.unlock()
        snapshot(id)                                         // the empty screen, then live output
        tab.pty.start(shell: shell, cols: UInt16(c), rows: UInt16(r), cwd: dir)
        onTabsChanged?()
        return id
    }

    /// **WHERE A NEW TAB STARTS** (docs/terminal.md, "Tabs that come back"): HOME for the first tab, else
    /// the ACTIVE tab's directory — what runs in it now: a `pty:` tab's foreground program's
    /// (`PtyProcess.currentDirectory`), a `tmux:` tab's active pane's (`pane_current_path`) — and home when
    /// that cannot be read. A new `pty:` tab and a new tmux session (`newTmux`) both follow it. Outside
    /// `lock`: the tmux arm runs a process.
    func newTabDirectory() -> String {
        lock.lock()
        let pty = activeTabLocked()?.pty
        let session = pool.activeId?.tmuxSession
        let tmux = self.tmux
        lock.unlock()
        let found = pty?.currentDirectory() ?? session.flatMap { tmux?.panePath($0) }
        return found.flatMap { Self.isDirectory($0) ? $0 : nil } ?? home
    }

    /// **THE DIRECTORY A PATH PRINTED IN TAB `id` IS RELATIVE TO** (`FileFetch.resolve`): what runs in it now — a
    /// `pty:` tab's foreground program's, a `tmux:` tab's active pane's — as `newTabDirectory` reads the active tab's.
    /// Nil when unreadable or the tab is gone. Outside `lock`: the tmux arm runs a process.
    func directory(of id: TermTabID) -> String? {
        lock.lock()
        let pty = tabsById[id]?.pty
        let tmux = self.tmux
        lock.unlock()
        let found = pty?.currentDirectory() ?? id.tmuxSession.flatMap { tmux?.panePath($0) }
        return found.flatMap { Self.isDirectory($0) ? $0 : nil }
    }

    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// Close a tab — the last one included. A `pty:` tab's shell is killed; a `tmux:` tab DETACHES
    /// (its session keeps running). False for an unknown id. If it was active, the neighbor becomes
    /// active.
    @discardableResult
    func close(_ id: TermTabID) -> Bool {
        lock.lock()
        guard pool.close(id) != nil else { lock.unlock(); return false }
        let victim = tabsById.removeValue(forKey: id)
        let detached = id.tmuxSession.flatMap { tmuxTabs.removeValue(forKey: $0) }
        if let s = id.tmuxSession, claimed == s { claimed = nil }
        lock.unlock()
        // `closed` on the tab's serial path: an output chunk already past its liveness check lands
        // BEFORE it, and none after (handleTabOutput re-checks `tabsById` under `serial`; a tmux
        // handler finds its tab gone by token).
        if let victim {
            // A BOUNDARY: its held bytes first (the stream up to `closed` is whole), then `closed`.
            victim.serial.lock()
            lock.lock(); let held = victim.buffer.take(); lock.unlock()
            if !held.isEmpty { _ = onEmit?(.output(id, held)) }
            _ = onEmit?(.closed(id))
            victim.serial.unlock()
        } else if let detached {
            emitTmuxClosed(detached, wait: true)
        }
        victim?.pty.stop()
        detached?.client?.stop()                         // DETACH this session only
        // ALWAYS, whichever kind closed: the neighbour that became active may be a tmux tab.
        syncTmuxClients()
        onTabsChanged?()
        return true
    }

    // MARK: tabs that come back (docs/terminal.md, "Tabs that come back")

    /// The driver's `×`: `close`, remembering the tab for ⌘⇧T (`reopenClosed`) — a `pty:` tab's directory
    /// read BEFORE its shell is killed. A shell that ends by itself, `closeAll` and a tmux session that ends
    /// are not remembered: nobody closed those.
    @discardableResult
    func closeRemembering(_ id: TermTabID) -> Bool {
        guard let saved = savedTab(id), close(id) else { return false }
        lock.lock(); closedTabs.push(saved); lock.unlock()
        return true
    }

    enum ReopenResult: Equatable { case reopened, nothingClosed, full }

    /// ⌘⇧T: the tab the driver closed LAST comes back as the active tab — a `pty:` tab as a NEW shell in its
    /// directory under its name (the process cannot come back), a `tmux:` tab re-attached to its session.
    /// One that cannot come back — its session ended, it is open again, tmux is gone — is skipped for the
    /// one closed before it. At the cap nothing is taken off the list.
    func reopenClosed() -> ReopenResult {
        while true {
            lock.lock()
            guard !closedTabs.isEmpty else { lock.unlock(); return .nothingClosed }
            guard pool.count < pool.maxTabs else { lock.unlock(); return .full }
            let next = closedTabs.pop()!
            let openAgain = next.tmuxSession.map { tmuxTabs[$0] != nil } ?? false
            lock.unlock()
            if openAgain { continue }
            switch next {
            case .pty(let cwd, let name):
                if openTab(directory: cwd ?? home, name: name) != nil { return .reopened }
            case .tmux(let session):
                if case .success = openTmux(session) { return .reopened }
            }
            // Refused at the cap by a race, or a session that is gone: the next one back, or the end.
        }
    }

    /// The session's tabs as the APP saves them: the pool in the bar's order, each `pty:` tab's directory
    /// read NOW, and the active one.
    func savedTabs() -> SavedTerminalTabs {
        savedTabState().0
    }

    func savedTabState() -> (SavedTerminalTabs,[String]) {
        lock.lock()
        let tabs = pool.tabs, active = pool.activeId
        let ptys = tabsById.mapValues(\.pty)
        lock.unlock()
        let saved: [SavedTerminalTab] = tabs.map { d in
            if let s = d.id.tmuxSession { return .tmux(session: s) }
            return .pty(cwd: ptys[d.id]?.currentDirectory(), name: d.name)
        }
        return (SavedTerminalTabs(tabs: saved, active: active.flatMap { a in tabs.firstIndex { $0.id == a } }),tabs.map { $0.id.wire })
    }

    /// **THE APP'S LAUNCH**: the tabs it saved come back in their order — a `pty:` tab as a new shell in its
    /// directory under its name, a `tmux:` tab re-attached if its session still exists — with the saved
    /// active tab active. Only into an EMPTY pool, before any client asks for anything: the one place a
    /// shell starts with no driver asking. Restored tmux tabs start no control client until a driver
    /// reports its grid (`awaitingGrid`). Returns how many came back.
    @discardableResult
    func restore(_ saved: SavedTerminalTabs) -> Int {
        restoreTabs(saved).count
    }

    func restoreTabs(_ saved: SavedTerminalTabs) -> [Int:String] {
        guard isEmpty, !saved.tabs.isEmpty else { return [:] }
        let live = Set((tmux?.listSessionsIfReachable() ?? []).map(\.id))
        if saved.tabs.contains(where: { $0.tmuxSession.map(live.contains) ?? false }) {
            lock.lock(); awaitingGrid = true; lock.unlock()
        }
        var opened: [Int: TermTabID] = [:]
        for (i, t) in saved.tabs.enumerated() {
            switch t {
            case .pty(let cwd, let name):
                opened[i] = openTab(directory: cwd ?? home, name: name)
            case .tmux(let session):
                guard live.contains(session), case .success = openTmux(session) else {
                    print("[term] restore: tmux session \(session) is gone"); continue
                }
                opened[i] = .tmux(session)
            }
        }
        if let a = saved.active, let id = opened[a] { _ = switchTo(id) }
        print("[term] restored \(opened.count) of \(saved.tabs.count) tab(s)")
        return opened.mapValues { $0.wire }
    }

    /// What `id` would be if it came back (`SavedTerminalTab`); nil for an unknown tab.
    private func savedTab(_ id: TermTabID) -> SavedTerminalTab? {
        lock.lock()
        guard let d = pool.tabs.first(where: { $0.id == id }) else { lock.unlock(); return nil }
        let pty = tabsById[id]?.pty
        lock.unlock()
        if let s = id.tmuxSession { return .tmux(session: s) }
        return .pty(cwd: pty?.currentDirectory(), name: d.name)
    }

    /// Make an existing tab active. False for an unknown id.
    @discardableResult
    func switchTo(_ id: TermTabID) -> Bool {
        lock.lock()
        let ok = pool.switchTo(id)
        lock.unlock()
        if ok { syncTmuxClients(); onTabsChanged?() }
        return ok
    }

    // MARK: names and the bar's order (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md)

    /// Name a `pty:` tab (`""` clears it) — `TabPool.setName`, which refuses a `tmux:` tab (renaming one
    /// renames its SESSION: `renameTmux`), an unknown tab and an invalid name. Announced only when it
    /// changed. Returns whether it did.
    @discardableResult
    func rename(_ id: TermTabID, _ name: String) -> Bool {
        lock.lock()
        let changed = pool.setName(id, name)
        lock.unlock()
        if changed { onTabsChanged?() }
        return changed
    }

    /// Rename a tmux SESSION (`rename-session`) — what renaming a `tmux:` tab means: every tmux client, the
    /// palette's list and the tab all show the new name, and it outlives a quit. OFF the caller's thread
    /// (it is a process, capped at 5 s), in order with any other rename (one serial queue). Success needs
    /// nothing more: tmux reports `%session-renamed` to the tab's control client and its title follows
    /// (`handleTmuxEvent`), as for a rename made anywhere else — so the label is tmux's, whatever tmux
    /// made of the name. A refusal (a duplicate name, a session gone, no tmux) is `onTmuxError(session,
    /// "rename-failed")`; the tab stays as it was.
    func renameTmux(_ session: String, _ name: String) {
        let tmux = self.tmux
        renameQueue.async { [weak self] in
            guard tmux?.renameSession(session, name) != true else { return }
            print("[tmux] rename \(session): refused")
            self?.onTmuxError?(session, "rename-failed")
        }
    }

    /// The pool in the bar's order (`SessionState.tabOrder`'s terminal half — `TabPool.arrange`): so a
    /// `term-list` lists the tabs as the bar shows them, and closing the active tab activates the
    /// neighbour the person SEES. Announced only when the order changed. Returns whether it did.
    @discardableResult
    func arrange(_ order: [TermTabID]) -> Bool {
        lock.lock()
        let changed = pool.arrange(order)
        lock.unlock()
        if changed { onTabsChanged?() }
        return changed
    }

    /// Move one tab within the pool — `move-tab` where there is no session state to order (the
    /// test-pattern harness: terminals only). `TabPool.move`'s refusals; announced only on a change.
    @discardableResult
    func move(_ id: TermTabID, before: TermTabID?) -> Bool {
        lock.lock()
        let changed = pool.move(id, before: before)
        lock.unlock()
        if changed { onTabsChanged?() }
        return changed
    }

    // MARK: snapshots / accessors

    /// No tabs at all — the normal state before a driver asks for one, and after it closes the last.
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return pool.count == 0 }

    /// Open tabs, of both kinds — what keeps the app alive with no window (`HostSession.tabCount`).
    var tabCount: Int { lock.lock(); defer { lock.unlock() }; return pool.count }

    func descriptors() -> (tabs: [TabDescriptor], activeId: TermTabID?) {
        lock.lock(); defer { lock.unlock() }
        return (pool.tabs, pool.activeId)
    }

    /// Tests: whether the host is leaving the active tab's device queries to the driver's xterm.js.
    var driverDecodesWireForTests: Bool { lock.lock(); defer { lock.unlock() }; return driverDecodesWire }

    /// `generation` orders the writes: the hub computes each one under its own lock and writes it after
    /// releasing that lock, so two can arrive out of order — only the newest is kept.
    ///
    /// Every NEW generation is a new wire (or none), which holds no tab's snapshot yet: every tab stops
    /// being live until its snapshot on it (the binder's `snapshotAll`) — so the window before that
    /// snapshot counts as not-live, and the host answers the active tab's device queries in it.
    func setDriverDecodesWire(_ bound: Bool, generation: UInt64) {
        lock.lock()
        if generation > driverWireGeneration {
            driverWireGeneration = generation; driverDecodesWire = bound
            // Held bytes were meant for the OLD wire's contexts: dropped, never sent after the new
            // wire's snapshot (which has them). And every credit goes: the client's instances are rebuilt
            // from the new wire's snapshots, and a reply still owed for the old one may never come (a
            // resync drops frames that already counted as reached) — a stale credit must not linger.
            for t in tabsById.values { t.stopForwarding(); t.owedReplies = 0 }
            for t in tmuxTabs.values { t.stopForwarding(); t.owedReplies = 0 }
        }
        lock.unlock()
    }

    /// Write driver input to the tab the client ADDRESSED, refusing it when that is not the active
    /// tab, and refusing input the active tab's modes cannot have asked for.
    ///
    /// **The target check and the active-tab read share ONE lock hold, and must.** Comparing the id in
    /// `ChannelHub` and calling in here afterwards would leave a switch able to land between the two —
    /// which is the race itself, reintroduced one frame narrower.
    ///
    /// What counts as deliverable is `TerminalInput.shouldDeliver` and only that — this function
    /// contributes the lock hold and the PTY, never a rule of its own.
    func write(_ data: Data, toTerminal id: TermTabID) {
        let now = clock()
        lock.lock()
        // INPUT TO THAT TAB (keystrokes, and xterm.js's mouse and wheel reports, which ride the same
        // message): its output goes out unheld for the next `TermSendBuffer.inputWindow`.
        switch id {
        case .pty: tabsById[id]?.buffer.noteInput(at: now)
        case .tmux(let s): tmuxTabs[s]?.buffer.noteInput(at: now)
        }
        if case .tmux(let s)? = pool.activeId, let t = tmuxTabs[s] {
            // A tmux tab: the same rule, then `send-keys -H` to the pane its last snapshot captured. No
            // pane yet means no snapshot has been emitted, so the client cannot be looking at this tab.
            let deliver = TerminalInput.shouldDeliver(named: id, activeTab: .tmux(s),
                                                      bytes: [UInt8](data), modes: t.modes.modes)
            let target = deliver ? t.pane : nil
            let client = t.client
            let claim = deliver && t.sizeDirty
            if claim { t.sizeDirty = false }
            lock.unlock()
            // Someone else took this window's size since: claim it BEFORE the keys, so the app redraws
            // for the terminal it is being typed into (FIFO on the client orders the two), then
            // re-snapshot what was written at the other size.
            if claim, let client { claimSize(s, via: client, resnapshot: true) }
            if let target, let client { Self.sendKeys(data, pane: target, via: client) }
            return
        }
        // No tab at all: nothing the client could have named is right, so nothing is delivered. The
        // previous signature had no way to express "wrong tab" and so no such case to get wrong.
        guard let tab = activeTabLocked() else { lock.unlock(); return }
        let deliver = TerminalInput.shouldDeliver(named: id, activeTab: tab.id,
                                                  bytes: [UInt8](data), modes: tab.term.inputModes())
        let target = deliver ? tab : nil
        lock.unlock()
        if let target { deliverInput(target, data) }
    }

    /// A DEVICE-QUERY REPLY from the client's instance of tab `id` — the tab whose bytes asked
    /// (`term-reply`, never typing). Delivered to THAT tab while the host owes it a reply, whether or not
    /// it is active; otherwise held to the keystroke rule (`TerminalInput.shouldDeliverReply`). A tmux tab
    /// owes one only for a query tmux itself does not answer (the stripper left it in); its reply goes to
    /// the pane its last snapshot captured, as typing does.
    ///
    /// Why a reply may reach a tab that is not active when a keystroke may not: a keystroke's tab is the
    /// client's claim about what the user was LOOKING AT, and acting on a stale claim puts typing into a
    /// shell nobody sees. A reply's tab is not a claim about the screen: it is the instance that parsed
    /// the query, i.e. the tab that asked. And `owedReplies` limits it to tabs the host handed a query to.
    func writeReply(_ data: Data, toTerminal id: TermTabID) {
        if case .tmux(let s) = id {
            lock.lock()
            guard let t = tmuxTabs[s] else { lock.unlock(); return }
            let deliver = TerminalInput.shouldDeliverReply(named: id, activeTab: pool.activeId, owedReplies: t.owedReplies,
                                                           bytes: [UInt8](data), modes: t.modes.modes)
            if deliver && t.owedReplies > 0 && TerminalInput.isReplyShaped([UInt8](data)) { t.owedReplies -= 1 }
            let target = deliver ? t.pane : nil
            let client = t.client
            lock.unlock()
            if let target, let client { Self.sendKeys(data, pane: target, via: client) }
            return
        }
        lock.lock()
        guard let tab = tabsById[id] else { lock.unlock(); return }
        let deliver = TerminalInput.shouldDeliverReply(named: id, activeTab: pool.activeId, owedReplies: tab.owedReplies,
                                                       bytes: [UInt8](data), modes: tab.term.inputModes())
        if deliver && tab.owedReplies > 0 && TerminalInput.isReplyShaped([UInt8](data)) { tab.owedReplies -= 1 }
        lock.unlock()
        if deliver { deliverInput(tab, data) }
    }

    /// A PASTE THE HOST TYPES — a saved file's path (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md
    /// §4.1) — into the NAMED tab, whether or not it is the active one. `write(_:toTerminal:)`'s active-tab
    /// rule is for KEYSTROKES, which claim what the screen shows; a paste names the tab it was made into,
    /// and the person may have switched tabs during a slow upload. Each piece is its own bracketed paste
    /// when THAT tab's program enabled ?2004 (`PasteTyping.asPastes`). Returns false when the tab is gone.
    /// Unlike `write`, a tmux tab's size is NOT claimed: the target may not be the one on screen.
    func typePaste(_ pieces: [String], into id: TermTabID) -> Bool {
        let now = clock()
        lock.lock()
        if case .tmux(let s) = id {
            guard let t = tmuxTabs[s], let pane = t.pane, let client = t.client else { lock.unlock(); return false }
            t.buffer.noteInput(at: now)
            let data = Data(PasteTyping.asPastes(pieces, bracketed: t.modes.modes.bracketedPaste).utf8)
            lock.unlock()
            Self.sendKeys(data, pane: pane, via: client)
            return true
        }
        guard let tab = tabsById[id] else { lock.unlock(); return false }
        tab.buffer.noteInput(at: now)
        let data = Data(PasteTyping.asPastes(pieces, bracketed: tab.term.inputModes().bracketedPaste).utf8)
        lock.unlock()
        deliverInput(tab, data)
        return true
    }

    /// The driver's xterm.js palette (`term-palette`), or xterm.js's defaults. `seq` is the hub's stamp,
    /// taken under ITS lock with the decision of whose palette this is: the hub calls in after releasing
    /// that lock, so two hand-offs (a palette message and a racing claim) can arrive out of order — only
    /// the newest is kept.
    func setTermPalette(_ p: TermPalette, seq: UInt64) {
        lock.lock()
        guard seq > paletteSeq else { lock.unlock(); return }
        paletteSeq = seq; palette = p
        // tmux answers its panes' OSC 10/11 from what this host REPORTED (`TmuxColourReport`): a theme
        // change is a new report for every pane a tab has reported.
        var sends: [(client: TmuxControlClient, session: String, commands: [String])] = []
        for t in tmuxTabs.values {
            guard let client = t.client else { continue }
            let commands = colourReportsLocked(t, panes: Set(t.reported.keys))
            if !commands.isEmpty { sends.append((client, t.session, commands)) }
        }
        lock.unlock()
        for send in sends { sendColourReports(send.commands, via: send.client, session: send.session) }
    }

    /// The `refresh-client -r` commands for `panes` whose reported colours are not the driver's palette,
    /// recorded as reported. MUST be called with `lock` held.
    private func colourReportsLocked(_ t: TmuxTab, panes: Set<String>) -> [String] {
        let want = TmuxColourReport.Colours(palette)
        var commands: [String] = []
        for pane in panes.sorted() where t.reported[pane] != want {
            guard let report = TmuxColourReport.commands(pane: pane, colours: want) else { continue }
            t.reported[pane] = want
            commands += report
        }
        return commands
    }

    /// Outside `lock`. A tmux that refuses `-r` (before 3.4) keeps answering black, as it did before.
    private func sendColourReports(_ commands: [String], via client: TmuxControlClient, session: String) {
        for command in commands {
            client.command(command) { r in
                if case .failure(let e) = r { print("[tmux] colour report for \(session): \(e)") }
            }
        }
    }

    /// Tests: the palette the host answers from.
    var termPaletteForTests: TermPalette { lock.lock(); defer { lock.unlock() }; return palette }

    /// Most bytes of host answers to left-in queries a tmux tab may have typed that tmux has not yet
    /// acknowledged (`answerLeftIn`); answers past it are dropped.
    static let maxHostAnswerBytes = 64 * 1024
    /// Most left-in queries a tmux tab may hold waiting for its answer round trip; more are dropped.
    static let maxQueuedHostQueries = 4096

    /// Most replies a tab may be owed (a client that never answers must not grow it without bound).
    static let maxOwedReplies = 64

    /// Bytes for a `pty:` tab's shell (tests observe them instead).
    private func deliverInput(_ tab: Tab, _ data: Data) {
        if let hook = ptyInputForTests { hook(tab.id, [UInt8](data)) } else { tab.pty.write(data) }
    }
    /// Tests: sees what `write`/`writeReply` deliver to a `pty:` tab's shell. Set before any input.
    var ptyInputForTests: ((TermTabID, [UInt8]) -> Void)?

    /// The driver's grid changed: EVERY tab takes it (all tabs share the terminal area on the client) —
    /// and a tab whose size CHANGED is RE-SENT, a snapshot of the host's own copy at the new size
    /// (docs/terminal.md, "A RESIZE RE-SENDS EVERY TAB"). The client reflows its copy the moment it
    /// fits, the host's (SwiftTerm, tmux) reflows by its own rules, and output written for the old size
    /// reaches the client after it resized, so without one the two drift until the next snapshot —
    /// lines drawn twice after a phone's keyboard (2026-09-29, gone on a reload), and a new driver's
    /// wire snapshot taken at the previous driver's width stretched by xterm.js to its own.
    ///
    /// `resend: false` — the caller snapshots every tab itself right after (a new driver's wire, at the grid it
    /// claimed with), so the re-sends here would only be a second snapshot of each.
    func resizeAll(cols: Int, rows: Int, resend: Bool = true) {
        lock.lock()
        let gridChanged = (cols, rows) != (gridCols, gridRows)
        gridCols = cols; gridRows = rows
        let releasedTmux = awaitingGrid
        awaitingGrid = false
        let ptys = Array(tabsById.values)
        let clients = tmuxTabs.values.compactMap { t in t.client.map { (t.session, t.token, $0) } }
        if gridChanged { for s in tmuxTabs.keys { settleMarks[.tmux(s)] = (clock(), nil) } }
        lock.unlock()
        // tmux sizes each window to its client; the app redraws on the SIGWINCH tmux delivers. A resize
        // is a BOUNDARY: what is held was written at the old size and goes out ahead of the redraw.
        for (s, token, c) in clients {
            c.asyncOnCallbackQueue { [weak self] in self?.flushTmux(s, token: token, timer: false) }
            c.command("refresh-client -C \(cols)x\(rows)") { _ in }
            // Queued BEHIND the size on the tab's own client (FIFO): taken once tmux has resized.
            if gridChanged && resend { snapshotTmux(s) }
        }
        var resized: [TermTabID] = []
        for tab in ptys {
            tab.serial.lock()
            lock.lock()
            let held = tabsById[tab.id] === tab ? tab.buffer.take() : []
            lock.unlock()
            if !held.isEmpty { _ = onEmit?(.output(tab.id, held)) }
            lock.lock()
            let changed = cols != tab.term.cols || rows != tab.term.rows
            if changed {
                tab.term.resize(cols: cols, rows: rows)
                tab.cols = cols; tab.rows = rows
                settleMarks[tab.id] = (clock(), nil)
            }
            lock.unlock()
            if changed { tab.pty.resize(cols: UInt16(cols), rows: UInt16(rows)); resized.append(tab.id) }
            tab.serial.unlock()
        }
        // After the resize, on the tab's serial path like any snapshot: output fed in between reached the
        // client's old instance too, and this snapshot, which includes it, replaces that instance.
        if resend { for id in resized { snapshot(id) } }
        // The first grid since a restore: the restored tmux tabs' clients start now, at it.
        if releasedTmux { syncTmuxClients() }
    }

    /// Tests: the next `n` tmux snapshot batches fail with a real `%error` (their first command names a
    /// pane that cannot exist). Guarded by `lock`.
    func failTmuxSnapshotsForTests(_ n: Int) { lock.lock(); failSnapshotsForTests = n; lock.unlock() }
    private var failSnapshotsForTests = 0

    /// A tmux snapshot batch's FIRST timeout (`TmuxSnapshotTimeout.base`); tests shorten it, before any
    /// tmux tab exists. Read when a tmux tab is created.
    var tmuxSnapshotTimeoutBase: TimeInterval = 5
    /// Tests: the next `n` tmux snapshot batches are STALLED — their first command is a `run-shell`
    /// that sleeps `seconds`, holding the control client's command queue past the timeout. Guarded by
    /// `lock`.
    func stallTmuxSnapshotsForTests(_ n: Int, seconds: Double) {
        lock.lock(); stallSnapshotsForTests = (n, seconds); lock.unlock()
    }
    private var stallSnapshotsForTests: (n: Int, seconds: Double) = (0, 0)
    /// Tests: the timeout each tmux snapshot batch was sent with, in order.
    func tmuxSnapshotTimeoutsForTests() -> [TimeInterval] { lock.lock(); defer { lock.unlock() }; return snapshotTimeoutLog }
    private var snapshotTimeoutLog: [TimeInterval] = []   // guarded by `lock`

    /// Tests: runs INSIDE a `pty:` tab's capture (`snapshot`), on the capturing thread, with the tab's
    /// `serial` held and `lock` not — so a test can prove what the capture does NOT hold. Set before
    /// any capture runs; never changed while one does.
    var duringCaptureForTests: ((TermTabID) -> Void)?

    /// Tests: the instance of a tmux tab's current control client.
    func tmuxClientInstanceForTests(_ session: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }; return tmuxTabs[session]?.client?.instance
    }

    /// The panes a tmux tab keeps a stream carry for. Tests only.
    func carriedPanes(_ session: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(tmuxTabs[session]?.carries.keys.map { $0 } ?? [])
    }

    // MARK: live tabs — snapshots and forwarding

    /// Serialize one tab and emit it, then forward its output from the very next byte. Nothing while
    /// paused (the resume snapshots every tab) or for an unknown id. A `tmux:` tab's snapshot is
    /// asynchronous: it is emitted from its control client's callback queue once tmux answers.
    ///
    /// CAPTURED UNDER THE TAB'S `serial` ALONE, never `lock` (final review M1): a capture walks up to
    /// 5000 lines of cells, and `lock` is every keystroke's, every other tab's feed's and the tab
    /// list's. `serial` is what orders it — `handleTabOutput` and `resizeAll` hold it around every feed
    /// and resize of this tab, so the capture sits at an exact byte position and the output after it
    /// follows it; the only other touch of the emulator, `write`'s `inputModes()`, only reads. `lock`
    /// is taken just to check the tab and the pause before, and to go live after — re-checked, so a
    /// pause or a close landing during the capture drops it.
    func snapshot(_ id: TermTabID, into target: SnapshotTarget? = nil) {
        if case .tmux(let s) = id { snapshotTmux(s, into: target); return }
        lock.lock(); let tab = tabsById[id]; lock.unlock()
        guard let tab else { return }
        tab.serial.lock(); defer { tab.serial.unlock() }
        lock.lock()
        let current = tabsById[id] === tab && !paused && isCurrentLocked(target)
        lock.unlock()
        guard current else { return }
        // SwiftTerm ends ?2026 on a MAIN-QUEUE timer: wherever the main queue is not serviced (a test
        // runner's thread, say) it never fires, so this can carry ?2026h after an app died mid-update.
        // The app and the harness both run the main run loop. Accepted (no timer of our own).
        duringCaptureForTests?(id)
        let snap = tab.term.snapshot()
        lock.lock()
        guard tabsById[id] === tab, !paused, isCurrentLocked(target) else { lock.unlock(); return }
        // A BOUNDARY: bytes held on THIS context go out ahead of the snapshot, so the stream between two
        // snapshots is exactly what was fed between them. (Bytes for an older context were dropped when
        // it ended — `stopForwarding` — so none can follow a new wire's snapshot.)
        let held = tab.buffer.take()
        tab.startForwarding()
        tab.instanceStart = tab.queryWatch.fed          // the snapshot's instance sees nothing before here
        tab.bellSent = false                            // a new instance: output reaches it from here
        lock.unlock()
        let emit = emitter(target)
        if !held.isEmpty { _ = emit(.output(id, held)) }
        Self.emitSnapshot(id, snap, bytes: { TermSnapshotEmitter.emit($0) }, emit: emit)
    }

    /// **SCROLLBACK COMES AFTER THE SCREEN** (docs/terminal.md): a tab with more than `TermSnapshot.lateHistoryLines` of
    /// history is sent as its SCREEN alone (`screenForLateHistory`) and then the FULL snapshot of that same capture as
    /// `.history`, which the pacer sends behind what the person is waiting for and the client rebuilds the tab from.
    /// Measured at 100 kbit/s, an echo in the shown tab waited ~2 s for its own snapshot's ~1900 lines of history. A
    /// smaller tab is one snapshot, as before.
    static func emitSnapshot(_ id: TermTabID, _ snap: TermSnapshot, bytes: (TermSnapshot) -> [UInt8],
                             emit: (TermEmission) -> Bool) {
        let size = TermGridSize(cols: snap.cols, rows: snap.rows)
        guard let screen = snap.screenForLateHistory else { _ = emit(.snapshot(id, size, bytes(snap))); return }
        _ = emit(.screen(id, size, bytes(screen)))
        _ = emit(.history(id, size, bytes(snap)))
    }

    // MARK: the offer's screen (docs/sources-and-focus.md, "The offer carries the tab bar")

    /// One tab's screen as a FRESH instance at its grid is written it, with no scrollback (`screenPreview`).
    struct Screen: Sendable { let size: TermGridSize; let bytes: [UInt8] }

    /// After a resize the program REDRAWS: its first byte within `previewFirstByteNanos`, then `previewQuietNanos` of
    /// quiet, `previewSettleMaxNanos` at most — the client's own wait for a snapshot's redraw (snapshot-settle.ts).
    static let previewFirstByteNanos: UInt64 = 60_000_000
    static let previewQuietNanos: UInt64 = 16_000_000
    static let previewSettleMaxNanos: UInt64 = 150_000_000
    static let previewPollNanos: UInt64 = 4_000_000

    /// **THE SCREEN AN OFFER CARRIES** (`ChannelHub.offerScreen`): tab `id`'s screen alone, captured once the redraw
    /// a RESIZE brings has settled (none when the tab was not just resized: at once) — a picture for the client to
    /// paint while WebRTC connects. Taken beside the wire, never on it: nothing of the tab's forwarding, its query
    /// tracking, its carries or its bell changes, and nothing is emitted. `completion` runs ONCE: with the screen, or
    /// with nil when `within` nanoseconds pass first, the tab is gone, or tmux's answer is not one. A `tmux:` tab's
    /// batch keeps tmux's own timeout (one of its own would kill the control client); a late answer is dropped.
    func screenPreview(_ id: TermTabID, within: UInt64, completion: @escaping @Sendable (Screen?) -> Void) {
        let once = PreviewOnce(completion)
        schedule(within) { once.fire(nil) }
        awaitSettled(id) { [weak self] in
            guard let self, !once.fired else { return once.fire(nil) }
            self.captureScreen(id) { once.fire($0) }
        }
    }

    /// Runs `then` once tab `id`'s redraw after its last resize has settled — at once without a fresh resize.
    private func awaitSettled(_ id: TermTabID, then: @escaping @Sendable () -> Void) {
        let now = clock()
        lock.lock(); let mark = settleMarks[id]; lock.unlock()
        guard let mark else { then(); return }
        let since = now &- mark.resized
        let settled = since >= Self.previewSettleMaxNanos
            || (mark.output.map { now &- $0 >= Self.previewQuietNanos } ?? (since >= Self.previewFirstByteNanos))
        if settled { then(); return }
        schedule(Self.previewPollNanos) { [weak self] in self?.awaitSettled(id, then: then) }
    }

    /// Output for tab `id`, with `lock` held: a redraw `screenPreview` may be waiting for. A mark past its window goes.
    private func noteOutputLocked(_ id: TermTabID) {
        guard var mark = settleMarks[id] else { return }
        let now = clock()
        if now &- mark.resized > Self.previewSettleMaxNanos { settleMarks[id] = nil; return }
        mark.output = now
        settleMarks[id] = mark
    }

    private func captureScreen(_ id: TermTabID, _ done: @escaping @Sendable (Screen?) -> Void) {
        switch id {
        case .pty:
            lock.lock(); let tab = tabsById[id]; lock.unlock()
            guard let tab else { return done(nil) }
            // Under the tab's `serial`, as the wire's own capture is (`snapshot`) — and nothing else of it.
            tab.serial.lock(); var snap = tab.term.snapshot(); tab.serial.unlock()
            snap.normal.lines = Array(snap.normal.lines.suffix(snap.rows))      // the screen alone
            done(Screen(size: TermGridSize(cols: snap.cols, rows: snap.rows), bytes: TermSnapshotEmitter.emit(snap)))
        case .tmux(let s):
            lock.lock()
            guard let t = tmuxTabs[s], let client = t.client else { lock.unlock(); return done(nil) }
            let timeout = t.snapshotTimeout.current, focusReporting = t.modes.modes.focusReporting
            lock.unlock()
            client.batch(TmuxSnapshot.commands(session: s, history: 0), timeout: timeout) { rs in
                guard rs.count > 5, case .success(let d) = rs[0], let state = TmuxPaneState.parse(d.first ?? ""),
                      case .success(let e) = rs[1], let extra = TmuxSnapshot.Extra.parse(e.first ?? ""),
                      case .success(let screen) = rs[3] else { return done(nil) }
                let glyphs = TmuxSnapshot.glyphOptions(variationSelectorAlwaysWide: rs.count > 7 ? try? rs[7].get() : nil,
                                                       codepointWidths: rs.count > 8 ? try? rs[8].get() : nil)
                let snap = TmuxSnapshot.build(state: state, extra: extra, history: [], screen: screen,
                                              savedNormal: state.modes.altScreen ? (try? rs[4].get()) : nil,
                                              focusReporting: focusReporting, glyphs: glyphs)
                done(Screen(size: TermGridSize(cols: snap.cols, rows: snap.rows), bytes: TmuxSnapshot.emit(snap, glyphs: glyphs)))
            }
        }
    }

    /// A wire binder's snapshots (`snapshotAll(into:)`): they go into ITS wire, and only while its
    /// generation is the newest the manager has heard of. Two rebinds racing each used to snapshot every
    /// tab into whichever wire was current by then — one more transient instance per tab on the client.
    /// The generation makes an older binder's snapshots a no-op once a newer one has been applied; the
    /// wire covers the moment before that, when the newer wire is already reachable but the manager has
    /// not been told (the older binder's snapshot then goes into its own RETIRED wire, which sends
    /// nothing, and the newer generation's `stopForwarding` and snapshot follow).
    struct SnapshotTarget: Sendable {
        let generation: UInt64
        let emit: @Sendable (TermEmission) -> Bool
    }

    /// MUST be called with `lock` held.
    private func isCurrentLocked(_ target: SnapshotTarget?) -> Bool {
        target.map { $0.generation == driverWireGeneration } ?? true
    }

    private func emitter(_ target: SnapshotTarget?) -> (TermEmission) -> Bool {
        if let target { return target.emit }
        return { [weak self] e in self?.onEmit?(e) ?? false }
    }

    /// A tmux tab's snapshot: ONE batch (`TmuxSnapshot.commands`), answered on its control client's
    /// callback queue IN ORDER with the pane's `%output` — so emitting from the completion puts the
    /// snapshot at an exact position in the tab's stream, and every `%output` after it is forwarded.
    /// The pane's output before the reply is forwarded only if the tab is already live (the snapshot
    /// then includes it too, and replaces what the client built from it); otherwise it is carried.
    private func snapshotTmux(_ s: String, into target: SnapshotTarget? = nil) {
        lock.lock()
        guard !paused, isCurrentLocked(target), let t = tmuxTabs[s], let client = t.client else { lock.unlock(); return }
        let token = t.token
        var commands = TmuxSnapshot.commands(session: s)
        if failSnapshotsForTests > 0 {
            failSnapshotsForTests -= 1
            commands[0] = "display -p -t %2147483647 'x'"
        }
        if stallSnapshotsForTests.n > 0 {
            stallSnapshotsForTests.n -= 1
            commands.insert("run-shell 'sleep \(stallSnapshotsForTests.seconds)'", at: 0)
        }
        let stalled = commands.count - TmuxSnapshot.commands(session: s).count
        let timeout = t.snapshotTimeout.current
        t.snapshotsIssued += 1
        let seq = t.snapshotsIssued
        snapshotTimeoutLog.append(timeout)
        lock.unlock()
        client.batch(commands, timeout: timeout) { [weak self] all in
            guard let self else { return }
            let rs = Array(all.dropFirst(stalled))
            guard case .success(let d) = rs[0], let state = TmuxPaneState.parse(d.first ?? ""),
                  case .success(let e) = rs[1], let extra = TmuxSnapshot.Extra.parse(e.first ?? ""),
                  case .success(let screen) = rs[3] else {
                print("[tmux] snapshot \(s) failed: \(rs)")
                let dead = rs.contains { $0 == .failure(.dead) }
                // Killed by its timeout: the host could not answer in time. The restarted client's
                // snapshot waits twice as long (TmuxSnapshotTimeout), so a starved host is not made to
                // re-attach every 5 s for as long as the starvation lasts.
                if dead, client.timedOut {
                    self.lock.lock()
                    if let t = self.tmuxTabs[s], t.token == token {
                        t.snapshotTimeout.timedOut()
                        print("[tmux] snapshot \(s) timed out; the next waits \(t.snapshotTimeout.current)s")
                    }
                    self.lock.unlock()
                }
                self.snapshotFailed(s, token: token, seq: seq, dead: dead)
                return
            }
            let history = (try? rs[2].get()) ?? []
            let savedNormal = state.modes.altScreen ? (try? rs[4].get()) : nil
            self.lock.lock()
            guard !self.paused, self.isCurrentLocked(target), let t = self.tmuxTabs[s], t.token == token else {
                self.lock.unlock(); return
            }
            if t.pane != state.pane { t.owedReplies = 0 }                // a credit is the ASKING pane's
            // A left-in query whose terminator the stripper still holds: the client's CURRENT instance saw
            // its body and never will see its end (the new instance gets the ESC, not the query) — the
            // host's, typed into the pane that asked.
            let orphaned = t.stripper.takePending().map { (query: $0, modes: t.modes.modes) }
            let askedIn = t.pane
            t.pane = state.pane
            var modes = state.modes
            modes.focusReporting = t.modes.modes.focusReporting        // tmux has no format for ?1004
            // …and the rest of what the snapshot states, so the tracker starts where the client's fresh
            // instance does (the host's DECRQM answers read it, `TermHostState`).
            modes.applicationKeypad = extra.keypad; modes.insert = extra.insert
            modes.wraparound = extra.wraparound; modes.origin = state.originMode
            t.modes = TermModeTracker(modes: modes)
            t.stripper = StreamingQueryStripper()
            t.bells = TermBellWatch()
            t.bellSent = false
            var reports: [String] = []
            if case .success(let panes) = rs[5] {
                let live = TmuxSnapshot.livePanes(panes)
                t.prune(keeping: live)
                reports = self.colourReportsLocked(t, panes: live)
            }
            t.carries[state.pane, default: PaneStreamCarry()].restart()
            // A BOUNDARY, as for a plain tab: what this context holds goes out ahead of the snapshot.
            let held = t.buffer.take()
            t.startForwarding()
            t.failedSnapshots = 0
            t.snapshotTimeout.succeeded()
            self.lock.unlock()
            let emit = self.emitter(target)
            if !held.isEmpty { _ = emit(.output(.tmux(s), held)) }
            if let askedIn { self.answerLeftIn(t, orphaned, pane: askedIn) }
            self.sendColourReports(reports, via: client, session: s)
            // The server's width options (docs/terminal.md, "TMUX TABS COUNT AS TMUX DOES"): the capture is
            // cut by them, and they go to the client in band ahead of the snapshot.
            let glyphs = TmuxSnapshot.glyphOptions(variationSelectorAlwaysWide: rs.count > 7 ? try? rs[7].get() : nil,
                                                   codepointWidths: rs.count > 8 ? try? rs[8].get() : nil)
            if rs.count > 6, let version = (try? rs[6].get())?.first { Self.noteTmuxVersion(version) }
            let snap = TmuxSnapshot.build(state: state, extra: extra, history: history, screen: screen,
                                          savedNormal: savedNormal, focusReporting: modes.focusReporting, glyphs: glyphs)
            // STILL ON THE CALLBACK QUEUE: no `%output` can be emitted between this reply and this emit. The width
            // options lead every fresh instance — the screen's and the late history's alike.
            Self.emitSnapshot(.tmux(s), snap, bytes: { TmuxSnapshot.emit($0, glyphs: glyphs) }, emit: emit)
        }
    }

    /// The glyph model is tmux 3.7c's as MEASURED (`TmuxGlyphs.measuredVersion`): a server reporting
    /// another version may count some glyphs differently. Said ONCE per version seen, nothing else changes.
    private static let versionLog = NSLock()
    nonisolated(unsafe) private static var versionsLogged: Set<String> = []
    static func noteTmuxVersion(_ version: String) {
        let v = version.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != TmuxGlyphs.measuredVersion else { return }
        versionLog.lock(); let first = versionsLogged.insert(v).inserted; versionLog.unlock()
        if first {
            print("[tmux] the server is tmux \(v); glyph widths were measured on \(TmuxGlyphs.measuredVersion) — "
                  + "a tmux tab may place some glyphs where tmux does not (re-run scripts/measure_tmux_glyphs.py)")
        }
    }

    /// A snapshot batch failed. A DEAD client needs nothing here: its exit starts a new client, which
    /// snapshots. Anything else (a `%error` on a live session, a reply of an unexpected shape) is retried
    /// ONCE, shortly; a second failure in a row CLOSES the tab and tells the driver why (`tmux-error`)
    /// — a tab left un-snapshotted is blank on open, or FROZEN while keystrokes still reach its pane.
    /// The session is untouched. On the tab's callback queue.
    ///
    /// The retry is SKIPPED when a newer snapshot (`seq`: this batch's number) was issued since — a
    /// resume, a claim, a new wire: that one is the retry, and succeeds or fails on its own account.
    private func snapshotFailed(_ s: String, token: UUID?, seq: Int, dead: Bool) {
        guard !dead else { return }
        lock.lock()
        guard let t = tmuxTabs[s], t.token == token else { lock.unlock(); return }
        t.failedSnapshots += 1
        guard t.failedSnapshots >= 2 else {
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let current = self.tmuxTabs[s].map { $0.token == token } ?? false
                // Paused: the resume snapshots every tab afresh, so this failure no longer counts.
                if current, self.paused { self.tmuxTabs[s]?.failedSnapshots = 0 }
                let newer = (self.tmuxTabs[s]?.snapshotsIssued ?? seq) != seq
                let retry = current && !self.paused && !newer
                self.lock.unlock()
                if retry { self.snapshotTmux(s) }
            }
            return
        }
        _ = pool.close(.tmux(s))
        tmuxTabs.removeValue(forKey: s)
        if claimed == s { claimed = nil }
        lock.unlock()
        print("[tmux] \(s): could not snapshot it twice; closing its tab")
        emitTmuxClosed(t, wait: true)                    // on its own queue: inline
        t.client?.stop()
        syncTmuxClients()
        onTmuxError?(s, "snapshot-failed")
        onTabsChanged?()
    }

    /// A tmux tab's `closed`, on its control client's callback queue: after every output and snapshot
    /// already dispatched for it (each of which, once the tab is gone from `tmuxTabs`, emits nothing),
    /// so nothing of the tab follows it. `wait`: before returning — the driver's `×` and a change of
    /// driver, so a reopen of the same session cannot emit ahead of it. Never waits from a callback
    /// queue (the session-ended paths), where two clients' queues could each wait on the other. A tab
    /// whose client never started has nothing to order against. Call OUTSIDE `lock`.
    private func emitTmuxClosed(_ t: TmuxTab, wait: Bool) {
        let id = TermTabID.tmux(t.session)
        // A BOUNDARY: the tab's held bytes, then `closed` — on its queue, behind everything before them.
        let emit: () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock(); let held = t.buffer.take(); self.lock.unlock()
            if !held.isEmpty { _ = self.onEmit?(.output(id, held)) }
            _ = self.onEmit?(.closed(id))
        }
        guard let client = t.client else { emit(); return }
        if wait { client.onCallbackQueue(emit) }
        else { client.asyncOnCallbackQueue { emit() } }
    }

    /// Tests: whether a `pty:` tab's serial path is held right now — by ANY thread, the caller's
    /// included (a `try` on a held NSLock fails). Called from inside `onEmit` it proves the emission is
    /// on the serial path. Takes `lock` briefly, so never call it with `lock` held.
    func serialIsHeld(_ id: TermTabID) -> Bool {
        lock.lock(); let tab = tabsById[id]; lock.unlock()
        guard let tab else { return false }
        if tab.serial.try() { tab.serial.unlock(); return false }
        return true
    }

    /// Tests: a `pty:` tab's host screen and scrollback as text, one line per row — what its emulator
    /// holds whether or not anything was forwarded.
    func hostText(_ id: TermTabID) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let tab = tabsById[id] else { return "" }
        return tab.term.snapshot().normal.lines
            .map { $0.runs.flatMap { $0.glyphs }.map { $0.text }.joined() }.joined(separator: "\n")
    }

    /// Every open tab, in tab order — a new driver, a new terminal channel, a resume. `target`: a wire
    /// binder's (`SnapshotTarget`) — its snapshots are a no-op once a newer binder has superseded it.
    func snapshotAll(into target: SnapshotTarget? = nil) {
        for id in descriptors().tabs.map(\.id) { snapshot(id, into: target) }
    }

    /// **A NEW WIRE'S SNAPSHOT OF A TAB WAITS FOR THE REDRAW A RESIZE BROUGHT** (`ChannelHub.rebindTermWire`;
    /// docs/terminal.md, "A claim says its grid"). A claim resizes every tab to the claimer's grid and binds its wire
    /// in the same breath, so the snapshots were taken before the program in the tab had answered its SIGWINCH: the
    /// new driver committed the program's picture for the PREVIOUS driver's size — reflowed by SwiftTerm, cropped by
    /// tmux — and the redraw replaced it a frame or three later (2026-10-07, "still a glitch when moving active client
    /// between devices with old screen size blinking for one frame"; measured with a program that draws its own size:
    /// every claim). A new wire forwards nothing of a tab before its snapshot (`setDriverDecodesWire`), so waiting
    /// loses nothing: the snapshot is taken once the redraw has settled (`awaitSettled`: first byte within 60 ms, then
    /// 16 ms of quiet, 150 ms at most — the client's own wait for a held resize's redraw, snapshot-settle.ts) and
    /// carries it. A tab not resized in the last 150 ms is snapshotted at once, as `snapshotAll` does.
    func snapshotAllSettled(into target: SnapshotTarget) {
        // The tab on screen FIRST: on a slow link the others' snapshots take seconds to cross, and its own is what the
        // person is waiting for (docs/terminal.md, "A slow link gets the terminal paced"; the pacer serves it first too).
        let (tabs, activeId) = descriptors()
        let ids = tabs.map(\.id)
        for id in ids.filter({ $0 == activeId }) + ids.filter({ $0 != activeId }) {
            awaitSettled(id) { [weak self] in self?.snapshot(id, into: target) }
        }
    }

    /// The driver's page has been hidden for the hold: forward nothing. The emulators keep being fed.
    func pauseForwarding() {
        lock.lock()
        paused = true
        // Held bytes are DROPPED: the page is hidden, and the resume re-serializes every tab (those
        // bytes included) into a fresh instance.
        for t in tabsById.values { t.stopForwarding() }
        // tmux keeps its own state while hidden, output still ON: its bytes are carried, not forwarded,
        // and the resume re-snapshots from tmux.
        for t in tmuxTabs.values { t.stopForwarding() }
        lock.unlock()
    }

    /// The page is visible again: every tab is re-serialized, then streams.
    func resumeForwarding() {
        clearPause()
        snapshotAll()
    }

    /// Whether a hidden driver's pause is in force (tests).
    var forwardingIsPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    /// Forget a pause without re-serializing (the driver changed; its new wire snapshots every tab).
    func clearPause() {
        lock.lock(); paused = false; lock.unlock()
    }

    // MARK: tmux tabs

    enum TmuxOpenError: Error, Equatable { case unavailable, gone, full, failed }

    func listTmux() -> (available: Bool, sessions: [TmuxSessionInfo]) {
        guard let tmux else { return (false, []) }
        return (true, tmux.listSessions())
    }

    /// Open a tab for an existing session and make it active — or, if it already has one, select it.
    ///
    /// It takes NO size: it attaches at the grid the driver last REPORTED (`resizeActive` records it
    /// even with no tab open). The hub once passed its active tab's grid `?? (80, 24)`, which is nil with an
    /// empty pool, so the first tab attached at 80x24 and was resized again a moment later — two
    /// resizes, two redraws of whatever runs in the session.
    func openTmux(_ session: String) -> Result<Void, TmuxOpenError> {
        guard let tmux else { return .failure(.unavailable) }
        lock.lock()
        if tmuxTabs[session] != nil {
            lock.unlock()
            _ = switchTo(.tmux(session))
            return .success(())
        }
        lock.unlock()
        guard let sessions = tmux.listSessionsIfReachable() else { return .failure(.failed) }
        guard let info = sessions.first(where: { $0.id == session }) else { return .failure(.gone) }
        lock.lock()
        guard pool.add(tmux: session, title: info.name) else { lock.unlock(); return .failure(.full) }
        tmuxTabs[session] = TmuxTab(session: session, snapshotTimeout: tmuxSnapshotTimeoutBase)
        lock.unlock()
        syncTmuxClients()
        onTabsChanged?()
        return .success(())
    }

    /// A new tmux session (it survives this host), opened as the active tab, in the new-tab directory
    /// (`newTabDirectory`). Returns its id.
    func newTmux() -> Result<String, TmuxOpenError> {
        guard let tmux else { return .failure(.unavailable) }
        guard let id = tmux.newSession(directory: newTabDirectory()) else { return .failure(.failed) }
        return openTmux(id).map { id }
    }

    /// End a session. Its tab, if any, closes through the same reconcile a session ending by itself
    /// takes, so the driver is told `tmux-closed` either way.
    @discardableResult
    func killTmux(_ session: String) -> Bool {
        guard let tmux else { return false }
        let ok = tmux.killSession(session)
        reconcileTmux()
        return ok
    }

    /// The session is OVER (a quit, or the harness stopping; Stop Sharing keeps it): every tab closes — a `pty:` tab's shell is KILLED, a `tmux:`
    /// tab DETACHES (its session keeps running) — each through `close`, so each one's `closed` is
    /// emitted, behind whatever its queue was delivering, before this returns. Not a change of driver:
    /// a change of driver closes nothing (the tabs are the session's).
    func closeAll() {
        for id in descriptors().tabs.map(\.id) { _ = close(id) }
    }

    // MARK: tmux internals

    /// Bring the tmux clients in line with the pool, after ANY change to it: every open tmux tab has its
    /// own client, started here if missing — sized to the grid, set to pause (not buffer) when slow,
    /// OUTPUT ON (every open tab is live on the client), then snapshotted. When the active tab changed
    /// to a tmux tab, that tab CLAIMS its window's size (`switch-client` to its own session) — a no-op
    /// resize while rdev is already tmux's latest client for it, the needed one when another client
    /// took the size meanwhile. A tab starting its client claims BEFORE its first snapshot, so that
    /// snapshot is taken at rdev's size (FIFO on the client). Called OUTSIDE `lock`.
    private func syncTmuxClients() {
        lock.lock()
        guard let tmux, !awaitingGrid else { lock.unlock(); return }
        var started: [(String, TmuxControlClient)] = []
        for (s, t) in tmuxTabs where t.client == nil {
            let token = UUID()
            guard let client = TmuxControlClient(
                runner: tmux, session: s,
                onEvent: { [weak self] e in self?.handleTmuxEvent(e, token: token) },
                onExit: { [weak self] in self?.handleControlExit(token: token) },
                clipboardChanged: { [weak self] name in self?.requestTmuxClipboard(name, token: token) }) else {
                print("[tmux] could not start a control client for \(s)")
                continue
            }
            // A timer armed on a previous client's queue carries that client's token and will find
            // nothing: forget it, or this tab's held bytes would wait for it for good.
            t.client = client; t.token = token; t.stopForwarding(); t.buffer.forgetTimer()
            t.reported = [:]
            started.append((s, client))
        }
        let active = pool.activeId?.tmuxSession
        let claim = active != claimed ? active : nil
        claimed = active
        let claimClient = claim.flatMap { tmuxTabs[$0]?.client }
        // Another client holds the size: what the tab streamed meanwhile was written for THAT size.
        let takenBack = claim.flatMap { tmuxTabs[$0]?.sizeDirty } ?? false
        if takenBack, let claim { tmuxTabs[claim]?.sizeDirty = false }
        let (c, r) = (gridCols, gridRows)
        lock.unlock()
        for (s, client) in started {
            client.command("refresh-client -C \(c)x\(r)") { _ in }
            // A slow client is PAUSED and caught up with a fresh snapshot rather than fed a backlog.
            client.command("refresh-client -f pause-after=2") { _ in }
            if s == claim { claimSize(s, via: client, resnapshot: false) }
            snapshotTmux(s)                                   // queued after the size: taken at rdev's grid
        }
        if let claim, let claimClient, !started.contains(where: { $0.0 == claim }) {
            claimSize(claim, via: claimClient, resnapshot: takenBack)
        }
    }

    /// `switch-client` to the tab's own session: its window takes rdev's size. `resnapshot`: the size
    /// was someone else's (`sizeDirty`), so output the tab streamed was written for another width and
    /// only a full-screen app would redraw it away — re-snapshot once tmux has answered the claim (by
    /// then the window is at rdev's size), on the same client, and forget `sizeDirty` there too: a
    /// `%layout-change` for the old size may have been queued behind the claim.
    private func claimSize(_ s: String, via client: TmuxControlClient, resnapshot: Bool) {
        client.command("switch-client -t \(s)") { [weak self] r in
            if case .failure(let e) = r { print("[tmux] claim \(s): \(e)") }
            guard resnapshot, let self else { return }
            self.lock.lock(); self.tmuxTabs[s]?.sizeDirty = false; self.lock.unlock()
            self.snapshotTmux(s)
        }
    }

    /// The tab a client's callbacks belong to. MUST be called with `lock` held.
    private func tabLocked(token: UUID) -> TmuxTab? { tmuxTabs.values.first { $0.token == token } }

    private func handleTmuxEvent(_ e: TmuxEvent, token: UUID) {
        if case .output(let pane, _) = e { noteTmuxPaneOutput(token: token, pane: pane) }
        lock.lock()
        guard let t = tabLocked(token: token) else { lock.unlock(); return }
        let s = t.session
        switch e {
        case .pasteBufferChanged(let name):
            lock.unlock(); requestTmuxClipboard(name, token: token)
        case .output(let pane, let bytes):
            guard t.live, !paused, t.pane == pane else {
                t.carries[pane, default: PaneStreamCarry()].skip(bytes)
                // TRACKING IS INDEPENDENT OF FORWARDING: the tab's pane is still followed while its bytes
                // are withheld (a pause, a snapshot in flight). tmux has no format for ?1004, so a mode
                // the app sets meanwhile is known only from here — skipped, the next snapshot stated the
                // stale value and the input filter dropped the tab's focus reports. A snapshot reseeds
                // the tracker (parser state included) from tmux's formats, keeping only ?1004.
                // And a query tmux leaves for the client that these WITHHELD bytes complete reaches no
                // client at all: the host answers it (`answerLeftIn`). One still unfinished is not the
                // host's — the carry puts it, whole, in front of the next snapshot's live bytes.
                // Each query answered from the modes AS OF its end in these bytes, as xterm.js would.
                var left: [(query: [UInt8], modes: TermModes)] = []
                var bell = false
                if t.pane == pane {
                    let located = t.stripper.withholdLocating(bytes)
                    left = zip(located, t.modes.modes(feeding: bytes, at: located.map(\.end))).map { (query: $0.0.query, modes: $0.1) }
                    // A BEL in withheld bytes reached no client: the host's, once per stretch.
                    if t.bells.feed(bytes) > 0 { bell = hostBellLocked(reached: false, sent: &t.bellSent) }
                }
                lock.unlock()
                answerLeftIn(t, left, pane: pane)
                if bell { onBell?(.tmux(s)) }
                return
            }
            guard let whole = t.carries[pane, default: PaneStreamCarry()].forward(bytes) else {
                // Orphan continuation bytes right after a snapshot, whose lead bytes rdev never
                // received: re-snapshot — tmux has parsed the whole character by now. They count as
                // withheld (the carry skipped them): a query they complete is the host's.
                t.stopForwarding()
                let left = t.stripper.withhold(bytes).map { (query: $0, modes: t.modes.modes) }
                let bell = t.bells.feed(bytes) > 0 && hostBellLocked(reached: false, sent: &t.bellSent)
                lock.unlock()
                answerLeftIn(t, left, pane: pane)
                if bell { onBell?(.tmux(s)) }
                print("[tmux] \(s) \(pane): output resumed mid-character; taking a fresh snapshot")
                snapshotTmux(s)
                return
            }
            // tmux answers most of its panes' device queries itself (the stripper removes those). The
            // ones it does NOT answer are left in for the client's xterm.js (`feedCounting`): bytes
            // carrying one are never held — held, a pause or a new wire could drop it — and each answer
            // xterm.js gives earns the tab a reply credit, so a BACKGROUND tab's instance can answer too.
            let (out, asks, mayAsk, located) = t.stripper.feedLocating(whole)
            // Each left-in query with the modes AS OF its end (a C1 DECRQM the host may answer): the
            // tracker follows these bytes up to each query, then on to their end.
            let left = zip(located, t.modes.modes(feeding: whole, at: located.map(\.end))).map { (query: $0.0.query, modes: $0.1) }
            // A BEL in these bytes is never held either: who rings it is this emission's real result.
            let rang = t.bells.feed(whole) > 0
            let offer = t.buffer.offer(out, at: clock(), urgent: mayAsk || rang)
            let client = t.client
            // Counted BEFORE the emit (a reply cannot overtake its credit), taken back if nothing reached.
            var owed = 0
            if case .send(let bytes) = offer, !bytes.isEmpty { owed = min(asks, Self.maxOwedReplies - t.owedReplies) }
            t.owedReplies += owed
            lock.unlock()
            // STILL ON THE CALLBACK QUEUE, in order with the snapshot replies.
            switch offer {
            case .send(let bytes):
                if !bytes.isEmpty {
                    let reached = onEmit?(.output(.tmux(s), bytes)) ?? false
                    if owed > 0 && !reached { lock.lock(); t.owedReplies = max(0, t.owedReplies - owed); lock.unlock() }
                    // Reached: the client's xterm.js answers them (the credit above). Not: nobody else will.
                    if !reached { answerLeftIn(t, left, pane: pane) }
                    // The bell, by the same rule.
                    if rang || reached {
                        lock.lock(); let ring = hostBellLocked(reached: reached, sent: &t.bellSent); lock.unlock()
                        if ring { onBell?(.tmux(s)) }
                    }
                }
            case .holdAndArm(let after): if let client { armTmuxFlush(s, token: token, client: client, after: after) }
            case .hold: break
            }
        case .pause(let pane):
            // tmux DISCARDS a paused pane's output: what follows the continue is not contiguous — for the
            // carry, and for the stripper, whose held head must not join the bytes after `%continue` into a
            // query nobody asked (the host would type its answer into the program).
            t.carries[pane]?.reset()
            if pane == t.pane { t.bells.reset() }
            // A left-in query whose terminator the stripper holds never gets it now: the host's.
            var orphaned: [(query: [UInt8], modes: TermModes)] = []
            if pane == t.pane {
                orphaned = t.stripper.takePending().map { (query: $0, modes: t.modes.modes) }
                t.stripper = StreamingQueryStripper()
            }
            t.stopForwarding()
            let client = t.client
            lock.unlock()
            answerLeftIn(t, orphaned, pane: pane)
            client?.command("refresh-client -A '\(pane):continue'") { _ in }
            snapshotTmux(s)
        case .sessionWindowChanged, .windowPaneChanged:
            t.stopForwarding()
            lock.unlock()
            snapshotTmux(s)
        case .layoutChange(_, let w, let h):
            t.sizeDirty = (w, h) != (gridCols, gridRows)
            lock.unlock()
        case .sessionRenamed(let renamed, let name):
            let changed = pool.setTitle(.tmux(renamed), name)
            lock.unlock()
            if changed { onTabsChanged?() }
            onTmuxSessionsChanged?()
        case .sessionsChanged:
            lock.unlock()
            reconcileTmux()
            onTmuxSessionsChanged?()
        case .reply, .sessionChanged, .exit:
            lock.unlock()
        }
    }

    private func requestTmuxClipboard(_ name: String, token: UUID) {
        lock.lock()
        guard driverDecodesWire, !paused, let t = tabLocked(token: token), let client = t.client,
              pool.activeId == .tmux(t.session) else { lock.unlock(); return }
        clipboardSequence &+= 1
        clipboardPending = ClipboardRequest(name: name, session: t.session, token: token,
            epoch: driverWireGeneration, selection: clipboardSelection, sequence: clipboardSequence, client: client)
        let start = !clipboardReading; clipboardReading = true
        lock.unlock()
        if start { clipboardQueue.async { [weak self] in self?.readTmuxClipboard() } }
    }
    private func clipboardCurrentLocked(_ request: ClipboardRequest) -> Bool {
        driverDecodesWire && !paused && driverWireGeneration == request.epoch && clipboardSelection == request.selection &&
            clipboardSequence == request.sequence && pool.activeId == .tmux(request.session) &&
            tmuxTabs[request.session]?.token == request.token
    }
    private func readTmuxClipboard() {
        while true {
            lock.lock()
            guard let request = clipboardPending else { clipboardReading = false; lock.unlock(); return }
            clipboardPending = nil
            let current = clipboardCurrentLocked(request), reader = readClipboardForTests, runner = tmux
            lock.unlock()
            guard current else { continue }
            let bytes = reader?(request.name, TermClipboard.maxBytes) ?? (reader == nil ? runner?.readPasteBuffer(request.name) : nil)
            guard let bytes, bytes.count <= TermClipboard.maxBytes, String(data: bytes, encoding: .utf8) != nil else { continue }
            lock.lock()
            clipboardCompleted = (request, bytes)
            let schedule = clipboardQueuedDeliveries == 0
            clipboardQueuedDeliveries = 1
            lock.unlock()
            if schedule { scheduleClipboardDelivery(request.client) }
        }
    }
    private func scheduleClipboardDelivery(_ client: TmuxControlClient) {
        // The queued closure retains no payload. A stalled callback queue holds one replaceable
        // completed copy, while the reader can continue coalescing new notifications.
        client.asyncOnCallbackQueue { [weak self] in self?.deliverClipboard(on: client) }
    }
    private func deliverClipboard(on client: TmuxControlClient) {
        lock.lock()
        guard let (request, bytes) = clipboardCompleted else {
            clipboardQueuedDeliveries = 0; lock.unlock(); return
        }
        if request.client !== client {
            lock.unlock(); scheduleClipboardDelivery(request.client); return
        }
        clipboardCompleted = nil; clipboardQueuedDeliveries = 0
        let deliver = clipboardCurrentLocked(request)
        lock.unlock()
        if deliver { onClipboard?(.tmux(request.session), request.epoch, bytes) }
    }
    func drainClipboardForTests() { clipboardQueue.sync {} }
    var clipboardDeliveryCountForTests: Int { lock.withLock { clipboardQueuedDeliveries } }
    func blockClipboardCallbackForTests(_ session: String, _ work: @escaping @Sendable () -> Void) {
        lock.lock(); let client = tmuxTabs[session]?.client; lock.unlock()
        client?.asyncOnCallbackQueue(work)
    }

    /// THE HOST ANSWERS a query tmux left for the client (OSC 4, OSC 12, multi-colour OSC 10/11, DECDSR,
    /// C1 forms) whose bytes reached NO client — a pause, a snapshot not yet delivered, no wire — as the
    /// driver's xterm.js would have (`TermHostReplies`, from `palette`), typed into the pane that asked,
    /// in the queries' order. A cursor report takes tmux's cursor for that pane (`display`, on the same
    /// control client, so after every byte tmux has already parsed — the program that asked is waiting
    /// for the answer, so that is where it stands). Every batch goes through that round trip
    /// (`answerRoundTrip`), so the answers of successive reads leave in order. A C1 DECRQM or DECRQSS is
    /// answered from the stream tracker's modes as of the query and the same `display` (tmux's region and
    /// `?2026`) — `TermHostState`; what neither can say, as xterm.js's "not recognised", never a guess.
    /// With no control client to type through, `answerRoundTrip` drops them — counted and logged, as
    /// the cap's are.
    /// Call OUTSIDE `lock`.
    /// Each query carries the stream tracker's modes as of its END in the pane's stream: what a DECRQM
    /// asks of (`TermHostState`) — xterm.js answers from the modes where it parsed the query, not after
    /// the rest of the read.
    private func answerLeftIn(_ t: TmuxTab, _ queries: [(query: [UInt8], modes: TermModes)], pane: String) {
        guard !queries.isEmpty else { return }
        lock.lock()
        let take = Array(queries.prefix(max(0, Self.maxQueuedHostQueries - t.answerQueued)))
        if !take.isEmpty { t.answerQueue.append((pane, take)); t.answerQueued += take.count }
        t.answersDropped += queries.count - take.count
        let start = !t.answerInFlight && !t.answerQueue.isEmpty
        if start { t.answerInFlight = true }
        lock.unlock()
        if start { answerRoundTrip(t) }
    }

    /// ONE `display` in flight per tab (a FLOOD of left-in queries, 2026-09-27: one round trip per read
    /// queued a `display` per read in tmux, and a 5 MB flood of OSC 4 while paused waited 5.39 s for
    /// one — past the 5 s timeout that kills the tab's control client). When it lands it answers every
    /// read queued for that pane by then — tmux sent those reads before its reply, so it had parsed them
    /// and its cursor stands after them — in order, then starts the next if more arrived. The answers
    /// typed are capped by what tmux has not yet acknowledged (`maxHostAnswerBytes`): past it the rest of
    /// the batch is DROPPED — a prefix answered, never two answers, never out of order.
    private func answerRoundTrip(_ t: TmuxTab) {
        lock.lock()
        guard let pane = t.answerQueue.first?.pane, let client = t.client else {
            // No client to type through (between its exit and the replacement): every queued query is
            // DROPPED — and counted, with any the cap dropped meanwhile, never silently.
            let panes = Set(t.answerQueue.map(\.pane))
            let dropped = t.answerQueued + t.answersDropped
            t.answerQueue = []; t.answerQueued = 0; t.answerInFlight = false; t.answersDropped = 0
            lock.unlock()
            if dropped > 0 { reportDroppedAnswers(panes.sorted().joined(separator: ","), dropped, why: "no control client") }
            return
        }
        lock.unlock()
        client.command("display -p -t \(pane) '\(TermHostState.format)'") { [weak self, weak t] r in
            guard let self, let t else { return }
            let line = (try? r.get())?.first
            self.lock.lock()
            var batch: [([UInt8], TermModes)] = []
            while let e = t.answerQueue.first, e.pane == pane { batch += e.queries.map { ($0.query, $0.modes) }; t.answerQueue.removeFirst() }
            t.answerQueued -= batch.count
            let palette = self.palette
            var bytes: [UInt8] = [], dropped = 0
            for (i, (q, modes)) in batch.enumerated() {
                let (cursor, state) = line.map { TermHostState.parse($0, tracked: modes) } ?? (nil, nil)
                let a = TermHostReplies.answer(q, palette: palette, cursor: cursor, state: state) ?? []
                if t.answerUnacked + bytes.count + a.count > Self.maxHostAnswerBytes { dropped = batch.count - i; break }
                bytes += a
            }
            t.answerUnacked += bytes.count
            dropped += t.answersDropped; t.answersDropped = 0
            let more = !t.answerQueue.isEmpty
            if !more { t.answerInFlight = false }
            self.lock.unlock()
            if dropped > 0 { self.reportDroppedAnswers(pane, dropped, why: "a flood: tmux has not caught up") }
            if !bytes.isEmpty {
                let ack: (Int) -> Void = { [weak self, weak t] n in
                    guard let self, let t else { return }
                    self.lock.lock(); t.answerUnacked = max(0, t.answerUnacked - n); self.lock.unlock()
                }
                if let hook = self.tmuxHostAnswerForTests { hook(pane, bytes); ack(bytes.count) }
                else {
                    self.tmuxHostAnswerTypedForTests?(pane, bytes)
                    Self.sendKeys(Data(bytes), pane: pane, via: client, acknowledged: ack)
                }
            }
            if more { self.answerRoundTrip(t) }
        }
    }

    /// Left-in queries the host drops unanswered: logged ONCE per occasion, with the count.
    private func reportDroppedAnswers(_ pane: String, _ n: Int, why: String) {
        print("[tmux] \(pane): \(n) left-in queries unanswered (\(why))")
        onTmuxAnswersDroppedForTests?(pane, n)
    }

    /// tmux ended one tab's control client — most often because its session ended (`detach-on-destroy`).
    /// The reconcile closes the tab if so; if the session lives on, the sync starts it a new client and
    /// snapshots it.
    private func handleControlExit(token: UUID) {
        lock.lock()
        guard let t = tabLocked(token: token) else { lock.unlock(); return }
        t.client = nil; t.token = nil; t.stopForwarding()
        if claimed == t.session { claimed = nil }
        lock.unlock()
        reconcileTmux()
        syncTmuxClients()
    }

    /// Close every tmux tab whose session no longer exists, telling the driver (`onTmuxClosed`). A
    /// listing that could not be taken (tmux hung or would not start) changes nothing: "unreachable"
    /// is not "ended", and closing tabs on it would lose them for good.
    private func reconcileTmux() {
        guard let tmux else { return }
        guard let listed = tmux.listSessionsIfReachable() else { return }
        let live = Set(listed.map(\.id))
        lock.lock()
        let gone = tmuxTabs.keys.filter { !live.contains($0) }.sorted()
        var removed: [TmuxTab] = []
        for s in gone {
            _ = pool.close(.tmux(s))
            if let t = tmuxTabs.removeValue(forKey: s) { removed.append(t) }
            if claimed == s { claimed = nil }
        }
        lock.unlock()
        // Never waits: this runs on a control client's callback queue too (`%sessions-changed`, exit).
        for t in removed { emitTmuxClosed(t, wait: false) }
        for t in removed { t.client?.stop() }
        guard !gone.isEmpty else { return }
        syncTmuxClients()
        for s in gone { onTmuxClosed?(s, "ended") }
        onTabsChanged?()
    }

    /// Raw bytes to a pane, as hex so nothing in them is ever parsed as tmux syntax. Chunked so one
    /// paste is several bounded commands rather than one unbounded line — and every chunk goes in ONE
    /// `batch` (one write under the client's write lock), so nothing else rdev sends through this client
    /// can land between two chunks: a keystroke typed while a long host answer (an OSC 4 asking ~80
    /// colours is past 2048 bytes) was being sent used to split it, and the program read its answer
    /// with the keystroke inside (docs/terminal.md, "A host answer is atomic"). tmux runs a control
    /// client's commands in order.
    /// `acknowledged` hears each chunk's byte count once tmux has answered the whole batch.
    private static func sendKeys(_ data: Data, pane: String, via client: TmuxControlClient,
                                 acknowledged: ((Int) -> Void)? = nil) {
        let bytes = [UInt8](data)
        var commands: [String] = [], sizes: [Int] = []
        var i = 0
        while i < bytes.count {
            let chunk = bytes[i..<min(i + sendKeysChunk, bytes.count)]
            commands.append("send-keys -H -t \(pane) " + chunk.map { String(format: "%02x", $0) }.joined(separator: " "))
            sizes.append(chunk.count)
            i += sendKeysChunk
        }
        guard !commands.isEmpty else { return }
        client.batch(commands) { rs in
            for (r, n) in zip(rs, sizes) {
                if case .failure(let e) = r { print("[tmux] send-keys \(pane): \(e)") }
                acknowledged?(n)
            }
        }
        sendKeysWrittenForTests?(pane, bytes.count)
    }
    /// Bytes per `send-keys` command.
    static let sendKeysChunk = 2048
    /// Tests: runs after each WRITE of keys to a control client (pane, bytes written) — once per
    /// `sendKeys`, whose chunks go out together. A test typing from here lands exactly between writes.
    nonisolated(unsafe) static var sendKeysWrittenForTests: ((String, Int) -> Void)?

    // MARK: internals

    /// MUST be called with `lock` held. Creates the Tab, wires its PTY/emulator callbacks, registers it.
    private func makeTabLocked(id: TermTabID, cols: Int, rows: Int) -> Tab {
        let tab = Tab(id: id, cols: cols, rows: rows)
        tabsById[id] = tab
        tab.pty.onOutput = { [weak self, weak tab] data in
            guard let self, let tab else { return }
            self.handleTabOutput(tab, data)
        }
        // A SHELL THAT ENDS ON ITS OWN CLOSES ITS TAB (`exit`, a crash, the last job holding its terminal
        // going) — through `close`, so the driver's wire gets its `closed` and every client its new
        // tab list. Nothing noticed before 2026-09-29, and now that the host keeps the session for
        // every client (host-session-state spec) a dead tab would have been restored to each of them.
        // On the pty's read queue, after its last output; never after a deliberate `stop()`.
        tab.pty.onExit = { [weak self, weak tab] in
            guard let self, let tab else { return }
            _ = self.close(tab.id)
        }
        // Fires synchronously inside term.feed() (below), on the thread holding `lock`. Read state
        // DIRECTLY, never re-lock. A reply produced by a feed is HELD (`answers`) and decided once that
        // feed's output has been emitted (`handleTabOutput`); one from anywhere else is the host's.
        // tmux tabs never come here: tmux answers most of its panes' queries itself, and the ones it
        // does not earn their credits on the tmux output path (`handleTmuxEvent`).
        tab.term.onRespond = { [weak tab] resp in
            guard let tab else { return }
            if tab.answers != nil { tab.answers! += [UInt8](resp) } else { tab.pty.write(resp) }
        }
        // Also fires inside feed() on the lock-holding thread — mutate the pool DIRECTLY and mark dirty;
        // the debounced broadcast is scheduled after feed releases `lock` (in handleTabOutput).
        tab.term.onTitle = { [weak self, weak tab] title in
            guard let self, let tab else { return }
            if self.pool.setTitle(tab.id, title) { self.titleDirtyDuringFeed = true }
        }
        // A BEL SwiftTerm EXECUTED — the one xterm.js rings, never an OSC's terminator. Inside feed(), on the
        // lock-holding thread, like `onTitle`: marked here, decided by `handleTabOutput` once the bytes'
        // emission says whether the driver's xterm.js rang it itself.
        tab.term.onBell = { [weak self] in self?.bellDuringFeed = true }
        return tab
    }

    /// MUST be called with `lock` held.
    private func activeTabLocked() -> Tab? { pool.activeId.flatMap { tabsById[$0] } }

    /// EXACTLY ONE SIDE ANSWERS EACH DEVICE QUERY (final review I1; 2026-09-27 N1/N2). The driver's
    /// xterm.js answers every query in bytes that REACH it — ANY tab's: each open tab has a live instance
    /// there, and whichever instance parsed the query answers with a `term-reply` naming its tab, which
    /// the host accepts for that tab while it owes one (`writeReply`). The host answers every query whose
    /// bytes go nowhere the driver decodes — a pause, the gap in a resume before this tab's own snapshot,
    /// a new wire before its snapshot (whose encoder drops them), no wire at all. "Reaches it" is the
    /// emission's own result (`onEmit` → `TermWire.emit`), and that is the WHOLE predicate: not a wire
    /// flag written after the wire became reachable, and not which tab is active — the host cannot know
    /// which tab the client SHOWS (a switch in flight, a host-opened tab before its term-list), and keying
    /// on "active" left one side answering neither and the other both. The emulator's replies are
    /// therefore HELD during the feed and written after the emit — on the serial path, so in order with
    /// the next feed, and in the order the queries came. A query xterm.js does not answer (`CSI ? u`, a
    /// window op) is the host's on every tab, reached or not (the measured set, `TermClientQueriesFixtureTests`).
    private func handleTabOutput(_ tab: Tab, _ data: Data) {
        tab.serial.lock(); defer { tab.serial.unlock() }
        lock.lock()
        guard tabsById[tab.id] === tab else { lock.unlock(); return }      // closed: nothing after `closed`
        noteOutputLocked(tab.id)
        titleDirtyDuringFeed = false
        bellDuringFeed = false
        let bytes = [UInt8](data)
        // Fed ONE QUERY AT A TIME (SwiftTerm is a stream parser; where the feed is cut changes nothing it
        // parses), so each of its answers is attributed to the query that produced it: a query the
        // client's xterm.js answers (`clientReplies > 0`, measured — `TermClientQueriesFixtureTests`)
        // is decided by the emission below; every other one — a window op, the kitty keyboard probe,
        // anything xterm.js ignores — is the HOST's, for every tab, whether or not the bytes reach the
        // client, and earns the client no credit. The cut falls just past the byte at which the parsers
        // act on a query (for a string ended by an ESC, that ESC), so its answer is in its own segment.
        // The answers IN QUERY ORDER, each marked whether it is the client's: when the host answers both
        // kinds (the bytes reached nobody) it writes them in that order — a probe's answer must precede
        // the sentinel query's after it (`CSI ? u` then DA1).
        var segments: [(bytes: [UInt8], client: Bool)] = []
        var queries = 0, at = 0
        let hits = tab.queryWatch.scan(bytes)
        for hit in hits {
            tab.answers = []
            tab.term.feed(Array(bytes[at..<hit.end]))     // onRespond / onTitle fire here (lock held, same thread)
            // TORN by a snapshot: the query began before the client's current instance of the tab did, so
            // that instance sees only its tail and answers nothing — the host's, with no credit.
            let client = hit.clientReplies > 0 && hit.start >= tab.instanceStart
            // Only a QUERY in the measured sets may have an answer typed by the host: SwiftTerm also
            // "answers" things xterm.js never would (a plain `CSI Ps y` gets a DECRQCRA report), and
            // what it sends outside a query's own segment is dropped, never typed into the program.
            // A COLOUR query's answer is the DRIVER's xterm.js's (its `term-palette`), never SwiftTerm's
            // own palette: whenever the host is the one to answer, the program reads the theme it sees —
            // and where xterm.js answers NOTHING (an index or slot it refuses, an abort, past its payload
            // limit: measured, `term-client-queries.json`), the host types nothing, never SwiftTerm's
            // answer. A colour query longer than the hold, whose bytes are gone, is answered from the
            // SHAPE the scanner kept while it streamed (`hit.query` is an equivalent short query) — never
            // from SwiftTerm, whose palette is not the theme.
            var answer = tab.answers ?? []
            if hit.queryLike, hit.osc {
                answer = hit.clientReplies == 0 ? [] : hit.query.flatMap { TermHostReplies.colourAnswer($0, palette: palette) } ?? []
            }
            if !answer.isEmpty, hit.queryLike { segments.append((answer, client)) }
            if client { queries += hit.clientReplies }
            at = hit.end
        }
        tab.answers = []
        if at < bytes.count { tab.term.feed(Array(bytes[at...])) }
        // No query of either set ended here: whatever SwiftTerm sent is not an answer to one — dropped.
        tab.answers = nil
        let hasClientAnswers = segments.contains { $0.client }, hasHostOnly = segments.contains { !$0.client }
        // Anything that COULD be a query — every sequence an xterm.js handler can answer, any DCS, an
        // OSC asking with `?` (walked from xterm.js's own handlers, `TermReplyHandlersFixtureTests`) —
        // whether or not either measured set recognises it.
        let mayAsk = !hits.isEmpty
        let forward = tab.live && !paused
        let titleChanged = titleDirtyDuringFeed
        // A BEL in these bytes: like a query, never HELD — who rings it is decided by this emission's real
        // result, and a held bell would be dropped by a pause or a new wire.
        let rang = bellDuringFeed
        // THE SEND BUFFER. Bytes carrying a device query are never HELD (`urgent`), whoever answers it:
        // when the driver's xterm.js is to answer, who answers is decided from the emission's REAL
        // result, so the bytes must be emitted now (the held ones ahead of them), never decided while
        // they sit in the buffer; when the host answers (a background tab), holding the query would let
        // a tab switch land before it arrives, and the now-visible instance answer it a second time.
        // And no sequence that could be a query is held either (`mayAsk`: one only xterm.js answers — as
        // SwiftTerm is silent on CSI 11/13 t, measured — or one neither measured set knows): held, a pause
        // or a new wire would drop it (a snapshot carries no query) and nobody would answer. Held bytes
        // never carry a query.
        var out: [UInt8] = []
        var arm: UInt64?
        if forward {
            switch tab.buffer.offer(bytes, at: clock(), urgent: hasClientAnswers || hasHostOnly || mayAsk || rang) {
            case .send(let b): out = b
            case .holdAndArm(let after): arm = after
            case .hold: break
            }
        }
        // What the client will owe: counted BEFORE the emit, so a reply can never arrive ahead of the
        // credit it spends; taken back below if the bytes reached nobody.
        let owed = out.isEmpty ? 0 : min(queries, Self.maxOwedReplies - tab.owedReplies)
        tab.owedReplies += owed
        lock.unlock()
        if let arm { armFlush(tab, after: arm) }
        // STILL ON THE SERIAL PATH: a snapshot cannot land between this feed and this emit.
        let reached = out.isEmpty ? false : (onEmit?(.output(tab.id, out)) ?? false)
        if owed > 0 && !reached {
            lock.lock(); tab.owedReplies = max(0, tab.owedReplies - owed); lock.unlock()
        }
        // The emission's own result decides, and nothing else — not which tab is ACTIVE (the host cannot
        // know which one the client SHOWS: a user switch in flight, a host-opened tab whose term-list has
        // not landed), nor a wire flag written after the wire became reachable.
        // Reached: the client answers its own; the host writes the rest, in order. Not reached: the host
        // writes every answer, in order.
        let mine = segments.filter { !reached || !$0.client }.flatMap(\.bytes)
        if !mine.isEmpty { writeHostAnswer(tab, mine) }
        // THE BELL, by the same rule: reached, the driver's xterm.js rang it; not, the host says so — once.
        if rang || reached {
            lock.lock(); let ring = hostBellLocked(reached: reached, sent: &tab.bellSent); lock.unlock()
            if ring { onBell?(tab.id) }
        }
        if titleChanged { scheduleTitleBroadcast() }
        scheduleAgentCheck(tab.id)
    }

    /// THE HOST'S BELL, decided (docs/terminal.md, "The bell"), with `lock` held. `reached`: these bytes
    /// reached the driver's xterm.js — it rang any bell in them, and the withheld stretch is over. Not reached
    /// (and they carried a bell): the host's to ring, unless it already did in this stretch. True: call
    /// `onBell`, outside `lock`.
    private func hostBellLocked(reached: Bool, sent: inout Bool) -> Bool {
        if reached { sent = false; return false }
        if sent { return false }
        sent = true
        return true
    }

    /// The host's answer to a device query in a tab's output (tests observe it).
    private func writeHostAnswer(_ tab: Tab, _ answers: [UInt8]) {
        if let hook = hostAnswerForTests { hook(tab.id, answers) } else { tab.pty.write(Data(answers)) }
    }
    /// Tests: sees the host's device-query answers instead of the pty. Set before any output.
    var hostAnswerForTests: ((TermTabID, [UInt8]) -> Void)?

    // MARK: the send buffer's timers

    /// The product's flush timers: a one-shot STRICT `DispatchSourceTimer` with zero leeway on one
    /// dedicated serial queue. MEASURED 2026-09-27 in the app with its windows hidden: a plain
    /// `asyncAfter` on a global queue fired 17 ms (p50) to 34 ms (max) LATE — App Nap's timer
    /// coalescing turned the 8 ms hold into ~25-40 ms — against ~1 ms with the dashboard visible.
    private static let timerQueue = DispatchQueue(label: "term.send-buffer", qos: .userInteractive)
    private static let flushQueue = DispatchQueue.global(qos: .userInteractive)
    private static let timerFlags: DispatchSource.TimerFlags = .strict
    private static let timerLeewayNanos = 0
    @Sendable static func strictTimer(after: UInt64, work: @escaping @Sendable () -> Void) {
        let t = DispatchSource.makeTimerSource(flags: timerFlags, queue: timerQueue)
        t.schedule(deadline: .now() + .nanoseconds(Int(after)), leeway: .nanoseconds(timerLeewayNanos))
        noteStrictSourceForTests(strict: timerFlags.contains(.strict), leewayNanos: timerLeewayNanos)
        // The handler only HANDS THE FLUSH ON: the work takes its tab's `serial`, which a big snapshot or
        // a host answer written into a pty nobody reads can hold for long, and on this one serial queue
        // that stalled EVERY tab's timer (final review M3). The strictness is the timer's, not the
        // queue's; each tab's flushes stay ordered by its own `serial` and its one live timer.
        t.setEventHandler { t.cancel(); flushQueue.async(execute: work) }
        t.resume()
    }

    /// Tests: every timer source `strictTimer` built, with its strictness and leeway — what proves the
    /// PRODUCT's default scheduler is this one (tests otherwise inject their own).
    static var strictTimerSourcesForTests: (made: Int, strict: Bool, leewayNanos: Int) {
        sourcesLock.lock(); defer { sourcesLock.unlock() }; return sources
    }
    private static let sourcesLock = NSLock()
    nonisolated(unsafe) private static var sources: (made: Int, strict: Bool, leewayNanos: Int) = (0, false, -1)
    private static func noteStrictSourceForTests(strict: Bool, leewayNanos: Int) {
        sourcesLock.lock(); sources = (sources.made &+ 1, strict, leewayNanos); sourcesLock.unlock()
    }

    /// Arm a `pty:` tab's one flush timer. The work takes the tab's `serial`, so the flush is on its
    /// serial path; it does nothing for a tab that has closed (or whose bytes a boundary already took).
    private func armFlush(_ tab: Tab, after: UInt64) {
        schedule(after) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.flushTimerFired(tab)
        }
    }

    private func flushTimerFired(_ tab: Tab) {
        tab.serial.lock(); defer { tab.serial.unlock() }
        lock.lock()
        // A closed tab's timer is spent with nothing sent: its bytes went out ahead of `closed`.
        guard tabsById[tab.id] === tab else { lock.unlock(); return }
        let fire = tab.buffer.timerFired(at: clock())
        // Belt and braces: held bytes exist only while live (`stopForwarding` drops them), but a timer
        // must never be what sends into a paused or ended context. The timer is still SPENT above.
        let forward = tab.live && !paused
        lock.unlock()
        switch fire {
        case .send(let b): if forward { _ = onEmit?(.output(tab.id, b)) }
        case .rearm(let after): armFlush(tab, after: after)
        case .idle: break
        }
    }

    /// Arm a tmux tab's one flush timer; the work runs on the tab's control-client callback queue, in
    /// order with its `%output` and its snapshot replies.
    private func armTmuxFlush(_ s: String, token: UUID?, client: TmuxControlClient, after: UInt64) {
        schedule(after) { [weak self, weak client] in
            guard let self, let client else { return }
            client.asyncOnCallbackQueue { [weak self] in self?.flushTmux(s, token: token, timer: true) }
        }
    }

    /// On a tmux tab's callback queue: the timer fired (`timer`), or a boundary takes everything held.
    /// Nothing for a tab that closed or whose client was replaced (`token`).
    private func flushTmux(_ s: String, token: UUID?, timer: Bool) {
        lock.lock()
        guard let t = tmuxTabs[s], t.token == token else { lock.unlock(); return }
        let client = t.client
        let fire: TermSendBuffer.Fire = timer ? t.buffer.timerFired(at: clock()) : .send(t.buffer.take())
        let forward = t.live && !paused                     // as for a plain tab's timer
        lock.unlock()
        switch fire {
        case .send(let b): if forward && !b.isEmpty { _ = onEmit?(.output(.tmux(s), b)) }
        case .rearm(let after): if let client { armTmuxFlush(s, token: token, client: client, after: after) }
        case .idle: break
        }
    }

    // MARK: test hooks

    /// Tests: the pid of every open `pty:` tab's shell.
    func shellPIDsForTests() -> [pid_t] {
        lock.lock(); let tabs = Array(tabsById.values); lock.unlock()
        return tabs.map(\.pty.processIDForTests).filter { $0 > 0 }
    }

    /// Tests: a `pty:` tab with NO shell behind it (its output comes from `feedForTests`), made active
    /// and snapshotted like `open`.
    func openDetachedForTests(cols: Int, rows: Int) -> TermTabID? {
        lock.lock()
        guard let id = pool.open() else { lock.unlock(); return nil }
        _ = makeTabLocked(id: id, cols: cols, rows: rows)
        lock.unlock()
        snapshot(id)
        return id
    }

    /// Tests: run tmux events for a tab on its control-client callback queue, as ONE block (nothing of
    /// tmux's own can interleave), exactly as the client's reader would deliver them.
    func injectTmuxEventsForTests(_ session: String, _ events: [TmuxEvent]) {
        lock.lock(); let t = tmuxTabs[session]; let client = t?.client, token = t?.token; lock.unlock()
        guard let client, let token else { return }
        client.onCallbackQueue { for e in events { self.handleTmuxEvent(e, token: token) } }
    }

    /// Tests: the pane a tmux tab's last snapshot captured.
    func tmuxPaneForTests(_ session: String) -> String? { lock.lock(); defer { lock.unlock() }; return tmuxTabs[session]?.pane }

    /// Tests: sees the host's answers to a tmux tab's left-in queries (pane, bytes) instead of `send-keys`.
    var tmuxHostAnswerForTests: ((String, [UInt8]) -> Void)?
    /// Tests: sees those answers as they are typed with the REAL `send-keys` (it replaces nothing).
    var tmuxHostAnswerTypedForTests: ((String, [UInt8]) -> Void)?
    /// Tests: hears every count of left-in queries dropped unanswered (pane, count), beside its log line.
    var onTmuxAnswersDroppedForTests: ((String, Int) -> Void)?

    /// Tests: the answer bytes typed into a tmux tab that tmux has not yet acknowledged.
    func tmuxAnswersUnackedForTests(_ session: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return tmuxTabs[session]?.answerUnacked ?? 0
    }

    /// Tests: `events` on the tab's control-client queue with the tab holding NO client — as between its
    /// client's exit (`handleControlExit`) and the replacement `syncTmuxClients` starts.
    func injectTmuxEventsWithoutClientForTests(_ session: String, _ events: [TmuxEvent]) {
        lock.lock(); let t = tmuxTabs[session]; let client = t?.client, token = t?.token; lock.unlock()
        guard let t, let client, let token else { return }
        client.onCallbackQueue {
            self.lock.lock(); t.client = nil; self.lock.unlock()
            for e in events { self.handleTmuxEvent(e, token: token) }
        }
    }

    /// Tests: wait for everything already queued on a tmux tab's control-client callback queue.
    func syncTmuxQueueForTests(_ session: String) {
        lock.lock(); let client = tmuxTabs[session]?.client; lock.unlock()
        client?.onCallbackQueue {}
    }

    /// Tests: bytes from a `pty:` tab's shell, exactly as its pty reader delivers them.
    func feedForTests(_ id: TermTabID, _ bytes: [UInt8]) {
        lock.lock(); let tab = tabsById[id]; lock.unlock()
        if let tab { handleTabOutput(tab, Data(bytes)) }
    }

    // MARK: an agent's activity (docs/terminal.md, "An agent's activity")

    /// **WHETHER AN AGENT IS WORKING IN A TAB, READ OFF ITS SCREEN — WHERE ONE RUNS** (`AgentActivity`; 2026-10-05, asked for, on the
    /// HOST — which follows every tab's output, forwarded or withheld, with or without a driver). Output schedules ONE
    /// read of the tab's screen `agentCheckDelay` later; output meanwhile schedules nothing more, and the first after
    /// it the next — so a busy tab is read at most twice a second and a quiet one never. Every start and end of a
    /// turn WRITES to the screen (the status line drawn, then erased), so the read after the last write sees the
    /// state that stays. A `pty:` tab reads its own emulator, on its serial path (as a snapshot does); a `tmux:` tab
    /// asks tmux (`capture-pane`), on its own control client. FIRST the tab's foreground is looked at (`foregroundAgent`):
    /// no agent there, no state — and no screen read. A change goes out in the tab list (`agent`).
    /// MUST NOT be called with `lock` held.
    private func scheduleAgentCheck(_ id: TermTabID) {
        lock.lock(); let first = agentChecks.insert(id).inserted; lock.unlock()
        guard first else { return }
        agentSchedule(Self.agentCheckDelay) { [weak self] in self?.checkAgent(id) }
    }
    /// How long after output its tab's screen is read.
    static let agentCheckDelay: TimeInterval = 0.5
    /// Where the agent checks are timed — NEVER the send buffer's strict timers (`schedule`): a read half a second
    /// late changes nothing, and they would share its zero-leeway queue. Tests replace it to run the checks.
    var agentSchedule: @Sendable (_ after: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void = { after, work in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + after, execute: work)
    }
    /// A capture's reply may wait behind a snapshot on a starved host: never long enough to kill the client over it.
    static let agentCaptureTimeout: TimeInterval = 15

    /// Output for a tmux tab's FOLLOWED pane (the one its snapshot captured) — forwarded or withheld alike.
    private func noteTmuxPaneOutput(token: UUID, pane: String) {
        lock.lock()
        let session = tabLocked(token: token).flatMap { $0.pane == pane ? $0.session : nil }
        if let session { noteOutputLocked(.tmux(session)) }
        lock.unlock()
        if let session { scheduleAgentCheck(.tmux(session)) }
    }

    /// WHERE a tab's foreground is read: a `pty:` tab's process group, a `tmux:` pane's terminal.
    enum Foreground: Sendable { case group(pid_t), terminal(String) }
    /// THE AGENT IN A TAB'S FOREGROUND (`AgentProcess`), by what the kernel says of its processes
    /// (`ForegroundProcesses`) — the gate that rules a screen's words out unless an agent runs there. Tests replace it.
    var foregroundAgent: @Sendable (Foreground) -> String? = { place in
        let procs: [ForegroundProcesses.Process]
        switch place {
        case .group(let g): procs = ForegroundProcesses.inGroup(g)
        case .terminal(let tty): procs = ForegroundProcesses.onTerminal(tty)
        }
        return procs.lazy.compactMap { AgentProcess.kind(argv: $0.argv, path: $0.path) }.first
    }

    /// One look at a tab: is an agent in its foreground — and only then, does its screen show it working.
    private func checkAgent(_ id: TermTabID) {
        lock.lock()
        agentChecks.remove(id)
        switch id {
        case .pty:
            let tab = tabsById[id]
            let title = pool.tabs.first { $0.id == id }?.title
            lock.unlock()
            guard let tab else { return }
            guard let kind = foregroundAgent(.group(tab.pty.foregroundGroup() ?? 0)) else {
                applyAgent(id, kind: nil, working: false); return
            }
            tab.serial.lock()
            let rows = tab.term.screenRows(last: tab.term.rows)
            tab.serial.unlock()
            applyAgent(id, kind: kind, working: AgentActivity.working(screen: rows, agent: kind, title: title))
        case .tmux(let session):
            let t = tmuxTabs[session]
            let client = t?.client, pane = t?.pane
            let known = t?.paneTTY.flatMap { $0.pane == pane ? $0.tty : nil }
            lock.unlock()
            guard let client, let pane else { return }
            let look: @Sendable (String) -> Void = { [weak self] tty in
                guard let self else { return }
                guard let kind = self.foregroundAgent(.terminal(tty)) else { self.applyAgent(id, kind: nil, working: false); return }
                // The pane's title with its screen, in one write: what the program set (OSC 0/2 — Codex's spinner), not
                // the tab's label, which is the session's name.
                client.batch(["display -p -t \(pane) '#{pane_title}'", "capture-pane -p -t \(pane)"],
                             timeout: Self.agentCaptureTimeout) { [weak self] rs in
                    guard rs.count == 2, case .success(let lines) = rs[1] else { return }
                    let title: String? = if case .success(let t) = rs[0] { t.first } else { nil }
                    self?.applyAgent(id, kind: kind, working: AgentActivity.working(screen: lines, agent: kind, title: title))
                }
            }
            if let known { look(known); return }
            client.command("display -p -t \(pane) '#{pane_tty}'", timeout: Self.agentCaptureTimeout) { [weak self] r in
                guard let self, case .success(let lines) = r,
                      let tty = lines.first?.trimmingCharacters(in: .whitespaces), tty.hasPrefix("/dev/") else { return }
                self.lock.lock()
                if let t = self.tmuxTabs[session], t.pane == pane { t.paneTTY = (pane, tty) }
                self.lock.unlock()
                look(tty)
            }
        }
    }

    private func applyAgent(_ id: TermTabID, kind: String?, working: Bool) {
        lock.lock()
        var changed = false
        switch id {
        case .pty:
            if let tab = tabsById[id] {
                _ = tab.agent.observe(agent: kind != nil, working: working)
                changed = pool.setAgent(id, tab.agent.state, kind: kind)
            }
        case .tmux(let session):
            if let t = tmuxTabs[session] {
                _ = t.agent.observe(agent: kind != nil, working: working)
                changed = pool.setAgent(id, t.agent.state, kind: kind)
            }
        }
        lock.unlock()
        if changed { scheduleTitleBroadcast() }
    }

    private func scheduleTitleBroadcast() {
        titleQueue.async { [weak self] in
            guard let self else { return }
            self.titleWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.onTabsChanged?() }
            self.titleWork = w
            self.titleQueue.asyncAfter(deadline: .now() + 0.1, execute: w)
        }
    }
}

/// `screenPreview`'s completion, run once whichever comes first — the screen, or the deadline.
private final class PreviewOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let completion: @Sendable (TerminalManager.Screen?) -> Void
    init(_ completion: @escaping @Sendable (TerminalManager.Screen?) -> Void) { self.completion = completion }
    var fired: Bool { lock.withLock { done } }
    func fire(_ screen: TerminalManager.Screen?) {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        if first { completion(screen) }
    }
}
