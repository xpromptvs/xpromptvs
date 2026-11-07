import AppKit
import RdevAppHost
import ShellstormCore

/// Pushes the dashboard's state instead of the dashboard polling for it (spec 2026-09-26).
/// One main-queue timer; push only on change; nudge() runs a tick now.
///
/// The timer runs for the LIFE OF THE APP, not only while a dashboard exists: the client windows hear
/// sharing change and the last-window rule is re-asked from here. So a STEADY-STATE TICK MUST TOUCH NO
/// STORAGE: `e2eState()` and `state()` read cached values; everything that loads the installation or
/// verifies a chain is recomputed only when e2e's (status, detail) changes (below).
@MainActor
final class StatePublisher {
    private let host: HostController
    private weak var windows: AppWindows?
    private var timer: Timer?
    private var last: StateSnapshot?
    /// e2e's (status, detail) the caches below were computed under.
    private var e2eKey: String?
    /// `capabilities()` loads the installation and verifies the whole chain — never per tick.
    private var capabilities = 0
    /// The last listing read, and whether it must be read again. An ENROLLED Mac re-reads every tick
    /// (a cheap in-memory read once its watcher runs — unchanged behaviour). Any other Mac re-reads
    /// only when told something moved: its every read retries the `/watch` start, which loads the
    /// installation from disk, and without a chain that retry cannot succeed until e2e changes.
    private var listing: [String: Any] = [:]
    private var listingStale = true
    private static let readyStatuses = AppLifecycle.readyStatuses   // E2EStatusCode.ready…
    /// Fired on the tick that sees a passkey ceremony SETTLE (`AppLifecycle.ceremonySettled`): an app
    /// kept alive only by the ceremony must re-ask the last-window rule then (`AppDelegate`).
    var onCeremonySettled: (() -> Void)?
    private var lastE2EStatus: Int?
    /// Fired on the tick that sees the session's LAST tab go (`AppLifecycle.sessionEmptied`): an app kept
    /// alive only by its tabs must re-ask the last-window rule then (`AppDelegate`).
    var onSessionEmptied: (() -> Void)?
    private var lastTabs: Int?
    /// Sharing, as the client windows were last told (`__rdevSharing`).
    private var lastSharing: Bool?

    init(host: HostController, windows: AppWindows) {
        self.host = host; self.windows = windows
        // Fires OUTSIDE E2EHost's lock, from any thread: hop to main before touching anything.
        E2EHost.shared.onListingChange = { [weak self] in
            DispatchQueue.main.async { self?.listingStale = true; self?.nudge() }
        }
    }

    func start() {
        guard timer == nil else { return }
        // Scheduled on the main run loop, so the block runs on the main thread. `.common` modes too,
        // or pushes stall while a menu is open or a window is dragged.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Lets the system coalesce the wake-ups of a timer that runs for the life of the app.
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func nudge() { listingStale = true; tick() }

    /// A page that (re)subscribes gets the current state now, and the next change is delivered
    /// even if it equals something pushed before the page existed.
    func subscribe() -> Any? {
        last = nil
        listingStale = true
        guard let s = build(e2e: host.e2eState()) else { return nil }
        last = s
        return try? JSONSerialization.jsonObject(with: Data(s.json.utf8))
    }

    /// `listing` is `sessions(refresh: false)` — names and codes only, so THE TOKEN IS NEVER PUSHED.
    private func build(e2e: [String: Any]) -> StateSnapshot? {
        let status = e2e["status"] as? Int ?? -1
        let key = "\(status)|\(e2e["detail"] as? String ?? "")"
        if key != e2eKey {
            e2eKey = key
            capabilities = Int(E2EHost.shared.capabilities())
            listingStale = true
        }
        if listingStale || Self.readyStatuses.contains(status) {
            listing = host.sessions(refresh: false)
            listingStale = false
        }
        // `adopt` is read (and its QR rendered) only while unenrolled; the snapshot drops it otherwise.
        return StateSnapshot(state: host.state(), account: host.accountState(), e2e: e2e,
                             capabilities: capabilities,
                             adopt: status == 1 ? host.adoptStatus() : nil, addDevice: host.addDeviceStatus(),
                             listing: listing)
    }

    private func tick() {
        let e2e = host.e2eState()
        let status = e2e["status"] as? Int ?? -1
        if AppLifecycle.ceremonySettled(from: lastE2EStatus, to: status) { onCeremonySettled?() }
        // ENROLLED WHILE RUNNING: a room already sharing is listed now, not at the next Share.
        if AppLifecycle.becameReady(from: lastE2EStatus, to: status) { SharingHost.shared.publishIfReady() }
        lastE2EStatus = status
        let tabs = host.sessionTabs
        if AppLifecycle.sessionEmptied(from: lastTabs, to: tabs) { onSessionEmptied?() }
        lastTabs = tabs
        // THE CLIENT WINDOWS HEAR SHARING START AND STOP — This Mac's status bar says "remote access enabled" while
        // it is on (2026-10-04). Whichever way it changed (the dashboard, auto share, the status item), this tick
        // sees it; a window opening later asks (`ClientBridge` "sharing").
        let sharing = host.isSharing
        if sharing != lastSharing {
            lastSharing = sharing
            for c in windows?.clients ?? [] { c.webView.evaluateJavaScript("window.__rdevSharing?.(\(sharing ? "true" : "false"))") }
        }
        guard let windows, windows.home != nil || windows.sharing != nil,
              let s = build(e2e: e2e), s != last else { return }
        last = s
        for page in [windows.home, windows.sharing].compactMap({ $0 }) {
            page.webView.evaluateJavaScript("window.__rdevAppState?.(\(s.json))")
        }
    }
}
