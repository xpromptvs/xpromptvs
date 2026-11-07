import ShellstormCore

/// `connectClient` from the retired Electron `index.ts` (`docs/desktop-app.md`): a pending attempt owns a HIDDEN client window
/// and settles exactly once — connected (reveal), error (reveal, reject with the client's own
/// sentence), load failure, close, or process death. A FAILURE CARRIES ITS REASON: the rejection
/// message IS the dashboard's error line.
@MainActor
final class ConnectAttempts {
    private final class Attempt {
        let key: String
        // WEAK: `AppWindows.clients` is the window's sole owner. A strong reference here would close
        // a cycle through the window's own callbacks (`client.onClosed` etc. capture `attempt`
        // strongly, on purpose — see below) — attempt → client → closures → attempt — which nothing
        // upstream ever breaks, leaking the NSWindow/WKWebView for the life of the process.
        weak var client: ClientWindow?
        var settled = false
        var continuation: CheckedContinuation<Void, any Error>?
        init(key: String) { self.key = key }
    }

    private let windows: AppWindows
    private let notifyClosed: (String) -> Void
    private var localPending = false
    private var attempts: [String: Attempt] = [:]
    /// Called after EVERY settlement. An attempt still resolving its pairing keeps the app alive
    /// with no window (`AppLifecycle`), so when it fails there is no window left to close and AppKit
    /// never asks the last-window rule again — the delegate re-asks it here.
    var onSettled: (() -> Void)?

    /// Attempts not yet settled — including one still resolving its pairing, which has no window.
    var pendingCount: Int { attempts.count }

    #if RDEV_DEV_BUILD
    /// AUTOMATION ONLY: awaited before an attempt resolves its pairing, so a check can hold an attempt
    /// in the state a person cannot reliably reach by hand — pending, with no client window yet
    /// (`e2e/app-lifecycle-check.mjs` arm 3).
    var beforePairing: (() async -> Void)?
    #endif

    init(windows: AppWindows, notifyClosed: @escaping (String) -> Void) {
        self.windows = windows; self.notifyClosed = notifyClosed
    }

    func connect(requestId: String?, motion: Motion?, pairing: @escaping () async throws -> String?) async throws {
        try await run(requestId: requestId, prepare: pairing) { [windows] value, show in
            windows.openClient(pairing: value, showWhenReady: show, motion: motion)
        }
    }

    /// "This Mac" — the ONE local window (docs/desktop-app.md, "The local window").
    /// - A press while an attempt is PENDING is that same request: it settles at once, opens nothing and
    ///   reveals nothing. Two attempts sharing one window would each re-point its callbacks, and the
    ///   first would never settle.
    /// - Open already: brought to the front, and this request settles at once — unless its page died, then it is replaced.
    func connectLocal(requestId: String?, motion: Motion?) async throws {
        guard !localPending else { return }
        // A local window whose page DIED is absent: closing it settles its old request through the
        // existing callbacks, and a fresh window follows. Otherwise the row read "Connected" over a blank page.
        if let open = windows.local, open.pageGone { open.close() }
        if let open = windows.local { open.show(); return }
        localPending = true
        defer { localPending = false }
        try await run(requestId: requestId, prepare: { nil }) { [windows] _, show in
            windows.openLocal(showWhenReady: show, motion: motion)
        }
    }

    private func run(requestId: String?, prepare: @escaping () async throws -> String?,
                     open: @escaping @MainActor (String?, Bool) -> ClientWindow) async throws {
        // No request id: open and show; NOTHING is returned (the Electron version once returned a
        // window and broke structured clone in the caller).
        guard let requestId, !requestId.isEmpty else {
            let value = try await prepare()
            _ = open(value, true)
            return
        }
        cancel(requestId: requestId)
        let attempt = Attempt(key: requestId)
        attempts[requestId] = attempt
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
            attempt.continuation = k
            Task { @MainActor [self] in
                do {
                    #if RDEV_DEV_BUILD
                    if let hold = self.beforePairing { await hold() }
                    #endif
                    let value = try await prepare()
                    // A late listing must never open a cancelled session.
                    guard !attempt.settled else { return }
                    let client = open(value, false)
                    attempt.client = client
                    client.onClosed = { [weak self] in
                        self?.notifyClosed(requestId)
                        self?.settle(attempt, BridgeError(ConnectError.message(.closed)))
                    }
                    // The page DYING unlights its row at that moment (and ends "Connected over a blank
                    // window"). Left to the later close, a press that REPLACES a dead This Mac window
                    // closes the old one while the NEW attempt animates the same row: the old id's
                    // notify then unlit the new attempt mid-connect and the row ended dark. The
                    // close's duplicate notify finds no row, the renderer having deleted it here.
                    client.onGone = { [weak self] in
                        self?.notifyClosed(requestId)
                        self?.settle(attempt, BridgeError(ConnectError.message(.gone)))
                    }
                    client.onLoadFailed = { [weak self] failure in self?.fail(attempt, failure) }
                    client.onConnectionState = { [weak self] state, text in
                        // Only the initial attempt owns a reveal. Recovery reports keep arriving
                        // after settlement; showing then steals focus from another Mac's window.
                        guard !attempt.settled else { return }
                        guard state == "connected" || state == "error" else { return }
                        if state == "error" { self?.fail(attempt, .client(text: text)); return }
                        attempt.client?.show()
                        self?.settle(attempt, nil)
                    }
                } catch {
                    self.settle(attempt, error)
                }
            }
        }
    }

    /// Resolves the attempt (no error — the person cancelled) and closes its exact window.
    func cancel(requestId: String) {
        guard let a = attempts[requestId] else { return }
        settle(a, nil)
        a.client?.close()
    }

    private func fail(_ a: Attempt, _ failure: ConnectFailure) {
        guard !a.settled else { return }
        a.client?.show()   // errors expose the client so pairing stays editable
        settle(a, BridgeError(ConnectError.message(failure)))
    }

    private func settle(_ a: Attempt, _ error: (any Error)?) {
        guard !a.settled else { return }
        a.settled = true
        if attempts[a.key] === a { attempts[a.key] = nil }
        if let error { a.continuation?.resume(throwing: error) } else { a.continuation?.resume() }
        a.continuation = nil
        onSettled?()
    }
}
