import Foundation
import RdevCore
import RdevHostKit

public struct AddDeviceStatus: Equatable, Sendable {
    /// `idle`, `waiting`, `confirm`, `issuing`, `finishing` (the chain sent, the new Mac's word awaited), `added` or
    /// `failed`.
    public let phase: String
    /// §10.1's readable code of the identity the new Mac will join — `confirm` only.
    public let identity: String?
    public let reason: String?
    /// §12.2's word for this Mac's own listing — `added` only (`rejected` has required wording).
    public let publication: String?
}

/// **ADD DEVICE BY CODE: this Mac adds a new one to its identity** (`AddDeviceByCode`; docs/pairing.md, "Add
/// device by code"). The dashboard's Add device dialog drives it — `addDeviceStart`, `addDeviceConfirm`,
/// `addDeviceCancel` — and follows its phase in the pushed state, as the Devices row follows `AdoptHost`'s.
///
/// One at a time: the dialog is one, and so is the passkey prompt.
public final class AddDeviceHost: @unchecked Sendable {
    public static let shared = AddDeviceHost()
    private let lock = NSLock()
    private var running = false
    private var phase: AddDeviceByCode.Phase = .idle
    private var session: AddDeviceByCode?

    /// Start adding the Mac showing `carrier`. False when one is already running or this Mac holds no
    /// identity to add it to (the phase then says why). Non-blocking: the phase is polled into the state.
    public func start(base: String, carrier: String, authenticator: PasskeyAuthenticator) -> Bool {
        lock.lock()
        if running { lock.unlock(); return false }
        guard let identity = E2EHost.shared.service(base: base).identity else {
            phase = .failed(reason: "no-identity")
            lock.unlock()
            return false
        }
        let add = AddDeviceByCode(identity: identity, authenticator: authenticator)
        running = true
        phase = .waiting
        session = add
        lock.unlock()

        // Detached; nothing here hops to the main queue synchronously (the bridge calls in on it).
        Task { [weak self] in
            let outcome = await add.start(carrier: carrier, signalingBase: base)
            self?.settle(add, outcome)
        }
        Task { [weak self] in
            while let self, self.isCurrent(add) {
                self.observe(add, await add.phase)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return true
    }

    /// The person's answer to "Add this Mac?". Returns false when nothing is waiting for one.
    public func confirm(_ add: Bool) -> Bool {
        lock.lock(); let current = session; lock.unlock()
        guard let current else { return false }
        Task { [weak self] in
            await current.decide(add)
            self?.observe(current, await current.phase)
        }
        return true
    }

    /// The dialog closed: stop a run under way, and forget a finished one, so the state reads `idle` and the
    /// next dialog opens on its form. Returns true when one was running.
    public func cancel() -> Bool {
        lock.lock()
        let current = session
        session = nil
        running = false
        phase = .idle
        lock.unlock()
        guard let current else { return false }
        Task { await current.cancel() }
        return true
    }

    public func status() -> AddDeviceStatus {
        lock.lock(); let current = phase; lock.unlock()
        switch current {
        case .idle: return AddDeviceStatus(phase: "idle", identity: nil, reason: nil, publication: nil)
        case .waiting: return AddDeviceStatus(phase: "waiting", identity: nil, reason: nil, publication: nil)
        case .confirm(let code): return AddDeviceStatus(phase: "confirm", identity: code, reason: nil, publication: nil)
        case .issuing: return AddDeviceStatus(phase: "issuing", identity: nil, reason: nil, publication: nil)
        case .finishing: return AddDeviceStatus(phase: "finishing", identity: nil, reason: nil, publication: nil)
        case .added(let publication):
            return AddDeviceStatus(phase: "added", identity: nil, reason: nil, publication: Self.word(publication))
        case .failed(let reason): return AddDeviceStatus(phase: "failed", identity: nil, reason: reason, publication: nil)
        }
    }

    private static func word(_ p: E2EWire.PublicationStatus) -> String {
        switch p {
        case .confirmed: return "confirmed"
        case .unconfirmed: return "unconfirmed"
        case .rejected: return "rejected"
        }
    }

    private func isCurrent(_ add: AddDeviceByCode) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && session === add
    }

    private func observe(_ add: AddDeviceByCode, _ live: AddDeviceByCode.Phase) {
        lock.lock()
        if session === add { phase = live }
        lock.unlock()
    }

    private func settle(_ add: AddDeviceByCode, _ outcome: AddDeviceByCode.Phase) {
        lock.lock()
        guard session === add else { lock.unlock(); return }
        phase = outcome
        running = false
        session = nil
        lock.unlock()
    }
}
