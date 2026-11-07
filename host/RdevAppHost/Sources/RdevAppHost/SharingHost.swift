import CoreGraphics
import Foundation
import RdevCore
import RdevHostKit

/// Negative values are failures. `rdev_host_status()` mirrors this now, not the other way round.
public enum HostStatus: Int32, Sendable {
    case idle = 0, starting = 1, running = 2, failedAlreadyRunning = -1, failedBadArguments = -2
}

/// §12.2's listing, as the app reads it. FIVE answers — see the moved comment on `Publication`.
public enum Publication: String, Sendable { case off, pending, confirmed, unconfirmed, rejected }

/// Permission bits, shared by `requestPermissions`'s argument and its return value. A bitfield
/// rather than one call per permission because the two are always shown together and a single
/// round trip cannot leave the UI holding a half-refreshed pair.
public struct PermissionSet: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public static let screenRecording = PermissionSet(rawValue: 1)
    public static let accessibility = PermissionSet(rawValue: 2)
}

public struct OpenedPairing: Equatable, Sendable { public let code, token, carrier: String }
public enum PairingOutcome: Equatable, Sendable { case opened(OpenedPairing), failed(String) }

/// Process-global, matching what is already true of the things it owns
/// (`CurtainController.shared`, `PionBridge.start()`). That is why no handle is threaded
/// through the ABI.
public final class SharingHost: @unchecked Sendable {
    public static let shared = SharingHost()
    private let lock = NSLock()
    /// **THE APP'S SESSION** — its tabs, its window state, its local window — created at launch
    /// (`beginSession`) and ended at quit (`endSession`). Sharing comes and goes around it.
    private var session: HostSession?
    /// Sharing: the door other devices come in by, from Start to Stop.
    private var room: SharingRoom?
    private var statusValue: HostStatus = .idle
    /// The profile's paste folder (`beginSession`). Guarded by `lock`.
    private var pasteDirectory: URL?

    /// Create the app's session if there is none — at launch. Cheap: no capture and no shell until asked.
    /// `pasteDirectory`: the PROFILE's paste folder (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md
    /// §6), so one profile's launch never empties another running profile's; nil keeps the process default.
    public var hostUpdates: HostUpdates { currentSession().hostUpdates }

    public func beginSession(pasteDirectory: URL? = nil) {
        lock.withLock { self.pasteDirectory = pasteDirectory }
        _ = currentSession()
    }

    private func currentSession() -> HostSession {
        lock.lock(); defer { lock.unlock() }
        if let session { return session }
        var config = HostConfig.from(environment: ProcessInfo.processInfo.environment)
        // `RDEV_PASTE_DIR` (tests) still wins over the profile's.
        config.pasteDirectory = config.pasteDirectory ?? pasteDirectory?.path
        let s = HostSession(config: config)
        session = s
        return s
    }

    /// §9.1: open a pairing window. The psk stays in `PairingWindowBox`; only the public values return.
    public func openPairing(base: String, restoringCarrier: String? = nil) async -> PairingOutcome {
        switch await PairingWindowOpener.open(signalingBase: base, restoringCarrier: restoringCarrier) {
        case .success(let opened):
            PairingWindowBox.shared.remember(opened)
            return .opened(OpenedPairing(code: opened.material.code, token: opened.material.token,
                                         carrier: opened.carrier))
        case .failure(let failure):
            return .failed(failure.rawValue)
        }
    }

    public func start(base: String, code: String, token: String) -> HostStatus {
        guard !base.isEmpty, !code.isEmpty, !token.isEmpty else { return .failedBadArguments }
        let session = currentSession()
        lock.lock()
        if room != nil { lock.unlock(); return .failedAlreadyRunning }
        var config = HostConfig.from(environment: ProcessInfo.processInfo.environment)
        config.signalingBase = base
        // **The psk comes from the window this process opened, never from the caller.** It never
        // crossed the C boundary in either direction, so the app cannot supply one and cannot leak
        // one — which is the property `PairingWindowBox` exists to hold.
        let r = SharingRoom(session: session, config: config, code: code, token: token,
                            pairingPSK: PairingWindowBox.shared.psk)
        room = r
        statusValue = .starting
        lock.unlock()

        // Outside the lock: start() opens a WebSocket. It does not block on it, but holding a lock
        // across it would be the kind of thing that only shows up under a concurrent stop().
        r.start()

        lock.lock(); statusValue = .running; lock.unlock()
        return .running
    }

    /// Stop Sharing: the door closes (`SharingRoom.stop` — the curtain first, every relay client out).
    /// The SESSION stays: its tabs and the local window live until quit.
    /// The Mac just became ready (`StatePublisher`): a room already sharing starts its listing now
    /// (`SharingRoom.publishIfReady`).
    public func publishIfReady() {
        lock.lock(); let r = room; lock.unlock()
        r?.publishIfReady()
    }

    public func stop() {
        lock.lock()
        let r = room
        room = nil
        statusValue = .idle
        lock.unlock()
        r?.stop()
    }

    /// Quit: sharing stops, then the session ENDS — every shell killed, every tmux tab detached, every
    /// socket client closed. Only a quit (or a crash) empties the session.
    public func restoreWorkspace(forQuit:Bool=false,completion:@escaping @Sendable(String?)->Void) {
        lock.lock();let current=session;lock.unlock()
        guard let current else{completion(nil);return}
        current.restoreWorkspace(forQuit:forQuit,completion:completion)
    }
    public func endSession() {
        stop()
        lock.lock(); let s = session; session = nil; lock.unlock()
        s?.end()
    }

    /// The app's local window: a bridge socket into the session. Closed at once when there is none (a quit
    /// has begun).
    @discardableResult
    public func acceptLocal(_ socket: MessageSocket) -> LocalSimulatorSession? {
        lock.lock(); let s = session; lock.unlock()
        guard let s else { socket.close(reason: "no session"); return nil }
        return s.acceptLocal(socket)
    }

    /// Open terminal tabs in the session — what keeps the app alive with no window (`AppLifecycle`).
    public var tabCount: Int {
        lock.lock(); let s = session; lock.unlock()
        return s?.tabCount ?? 0
    }

    /// The session's terminal tabs as the app saves them (docs/terminal.md, "Tabs that come back"); nil once
    /// the session has ended — a quit saves BEFORE it ends the session, or there would be nothing to save.
    public func savedTerminalTabs() -> SavedTerminalTabs? {
        lock.lock(); let s = session; lock.unlock()
        return s?.savedTerminalTabs()
    }

    /// At launch, after `beginSession`: the saved tabs come back. Returns how many did.
    @discardableResult
    public func restoreTerminalTabs(_ saved: SavedTerminalTabs) -> Int {
        currentSession().restoreTerminalTabs(saved)
    }

    public var status: HostStatus {
        lock.lock(); defer { lock.unlock() }
        return statusValue
    }

    public func setCurtain(_ on: Bool) {
        lock.lock(); let r = room; lock.unlock()
        r?.setCurtain(on)
    }

    public var curtainIsUp: Bool {
        lock.lock(); let r = room; lock.unlock()
        return r?.curtainIsUp ?? false
    }

    public var publication: Publication {
        lock.lock(); let r = room; lock.unlock()
        guard let state = r?.publicationState(), state.publishing else { return .off }
        switch state.status {
        case nil: return .pending
        case .confirmed: return .confirmed
        case .unconfirmed: return .unconfirmed
        case .rejected: return .rejected
        }
    }

    /// Body of `rdev_host_request_permissions`, typed. Returns what is GRANTED afterwards.
    ///
    /// THE PROMPT IS ONE-SHOT PER APP IDENTITY, FOREVER. macOS shows each dialog the first time this
    /// signature asks and never again — after that both APIs return their answer with no UI. There is
    /// no way to tell "never asked" from "asked and declined" (both preflight false), so the caller
    /// cannot branch on it: it must ask once and, if the bit is still clear, offer System Settings
    /// from then on. That is the whole reason this is a deliberate button press rather than something
    /// fired at launch, where the one chance would be spent before the user wanted anything.
    ///
    /// **A clear bit does not mean refused.** Screen Recording also needs a relaunch to take effect in
    /// this process, and the Accessibility dialog never grants inline — it only offers Settings. Both
    /// arrive later through the caller's existing status poll.
    ///
    /// Preflight precedes each request so an already-granted app spends nothing, and so a repeat click
    /// is free. No main-queue hop here, like everything else on this surface: the app's bridge
    /// (`UIBridge`, `@MainActor`) calls in on the AppKit main thread and both APIs are safe to call
    /// there directly.
    public func requestPermissions(_ which: PermissionSet) -> PermissionSet {
        var granted: PermissionSet = []
        if which.contains(.screenRecording),
           CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() { granted.insert(.screenRecording) }
        if which.contains(.accessibility), WindowInputInjector.requestAccessibility() { granted.insert(.accessibility) }
        return granted
    }
}
