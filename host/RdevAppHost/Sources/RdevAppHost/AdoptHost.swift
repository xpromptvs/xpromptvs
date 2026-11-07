import Foundation
import RdevHostKit

public struct AdoptStatus: Equatable, Sendable {
    public let phase: String, carrier: String?, code: String?, reason: String?
}

/// **ADOPT BY CODE: show a code, and let a device that holds the passkey add this Mac.**
///
/// §12.1's ceremony needs a browser ON THIS MAC and a passkey reachable from it. This is the other
/// route: the Mac shows §9.1's carrier, somebody scans it with a browser that already holds the
/// root, and what comes back is a capability-2 grant — share only.
///
/// One adoption at a time, because there is one device.
public final class AdoptHost: @unchecked Sendable {
    public static let shared = AdoptHost()
    private let lock = NSLock()
    private var running = false
    private var phase: AdoptByCode.Phase = .idle
    private var session: AdoptByCode?
    /// The base this adoption was started against, so `settle` can reach the same service instance.
    private var currentBase: String?

    /// **Non-blocking, and the status is POLLED**, the same shape §12.1's rendezvous already has: a
    /// window lasts 120 seconds and no `@_cdecl` may sit on the main thread for that long. Returns
    /// true once an attempt is running, false if one already is.
    public func start(base: String) -> Bool {
        lock.lock()
        if running { lock.unlock(); return false }
        guard let identity = E2EHost.shared.service(base: base).identity else {
            phase = .failed(reason: "library")
            lock.unlock()
            return false
        }
        running = true
        phase = .idle
        currentBase = base
        // §12.2's job belongs to whichever endpoint committed, and that is this Mac — the same
        // registration `enroll` uses, so `retryRegistration` drains whatever an outage leaves.
        let adopt = AdoptByCode(manager: identity.manager, policy: identity.policy,
                                publish: { operationID in
                                    _ = await identity.registerGrant(operationID: operationID)
                                })
        session = adopt
        lock.unlock()

        // Detached, and nothing here hops to the main queue SYNCHRONOUSLY: the bridge calls IN on
        // it, so a `DispatchQueue.main.sync` would deadlock (under koffi it trapped as a bare SIGTRAP).
        Task { [weak self] in
            let outcome = await adopt.start(signalingBase: base)
            self?.settle(outcome)
        }
        // The phase is polled while the window opens; `waiting` and its carrier arrive there.
        Task { [weak self] in
            while self?.isRunning == true {
                if let live = await self?.session?.phase { self?.observe(live) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return true
    }

    /// Stop showing the code — or, mid-handshake, stop waiting (2026-10-07: "Adding this Mac…" offered no way out
    /// when the other device's last message never came). Returns true if there was one to stop. It cannot take
    /// back a chain the other device already signed; nothing is committed HERE unless that chain arrived
    /// (`AdoptByCode.cancel`).
    public func cancel() -> Bool {
        lock.lock()
        let had = running
        let stopping = session
        if had { phase = .failed(reason: "cancelled"); running = false; session = nil }
        lock.unlock()
        if let stopping { Task { await stopping.cancel() } }
        return had
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func observe(_ live: AdoptByCode.Phase) {
        lock.lock()
        let newlyEnrolled: Bool
        if case .enrolled = live, running { if case .enrolled = phase { newlyEnrolled = false } else { newlyEnrolled = true } } else { newlyEnrolled = false }
        if running { phase = live }
        let base = currentBase
        lock.unlock()
        // COMMITTED: the status says so now, not after the registration that follows (`settle`) — the e2e status is
        // what takes the Devices row off "Adding this Mac…".
        if newlyEnrolled, let base { E2EIdentityService.shared(signalingBase: base).invalidateStatus() }
    }

    private func settle(_ outcome: AdoptByCode.Phase) {
        lock.lock()
        phase = outcome
        running = false
        session = nil
        let base = currentBase
        lock.unlock()
        // **TELL THE SERVICE ITS ANSWER IS STALE.** An adoption commits through
        // `E2EIdentityManager` directly, so `E2EIdentityService`'s cached status never hears about
        // it — and a renderer that has been polling since launch holds `unenrolled` forever. Done on
        // EVERY outcome, not just success: `adoptRoot` can persist a root before a commit fails, so
        // a refusal changes storage too. Same reasoning as `end()` after a ceremony.
        if let base { E2EIdentityService.shared(signalingBase: base).invalidateStatus() }
    }

    public func status() -> AdoptStatus {
        lock.lock(); let current = phase; lock.unlock()
        switch current {
        case .idle: return AdoptStatus(phase: "idle", carrier: nil, code: nil, reason: nil)
        case .waiting(let carrier, let code): return AdoptStatus(phase: "waiting", carrier: carrier, code: code, reason: nil)
        case .handshaking: return AdoptStatus(phase: "handshaking", carrier: nil, code: nil, reason: nil)
        case .enrolled: return AdoptStatus(phase: "enrolled", carrier: nil, code: nil, reason: nil)
        case .failed(let reason): return AdoptStatus(phase: "failed", carrier: nil, code: nil, reason: reason)
        }
    }
}
