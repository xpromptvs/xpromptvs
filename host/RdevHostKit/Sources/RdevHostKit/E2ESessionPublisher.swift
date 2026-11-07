import Foundation
import RdevCore

/// **Announce this Mac's live room to the directory, and keep announcing it.**
///
/// This is what replaced `PUT /account/sessions` and its bearer token
/// (`docs/superpowers/specs/2026-09-13-passkey-only-identity.md`). The endpoint moved, and so did
/// the PROCESS: publication is signed by the device's certified Ed25519 key, which lives in the
/// installation store behind `E2EHostIdentity`, so it cannot be done from a web page at all. The
/// app's dashboard reads the state; the host does the work.
///
/// **NOTHING HERE MAY FAIL SHARING.** That rule survives the move unchanged: sharing works without
/// an identity, so a Control Plane outage must not take down the primary feature. Every outcome is a
/// §12.2 `PublicationStatus` a person can read, never an error a caller gates on, and the loop keeps
/// running because retrying is the only thing that re-lists this Mac when the network returns.
///
/// Lock-based rather than an `actor`, deliberately: the app's bridge reads this state SYNCHRONOUSLY
/// from a 2 Hz poll on the main thread (the retired C ABI did the same on koffi's), and an actor
/// cannot be read without a suspension.
public final class E2ESessionPublisher: @unchecked Sendable {

    /// §12.2's cadence, carried over from the account implementation: a 30 s heartbeat against the
    /// directory's 90 s TTL, so two misses are survivable and a crashed Host disappears rather than
    /// lingering as a room nobody is in.
    public static let heartbeatSeconds: Double = 30

    /// What a reader should say about this Mac's listing.
    ///
    /// `status` is nil until the first beat has come back — **which is not the same as "confirmed"
    /// and not the same as "failing"**, and collapsing the three is exactly how the old
    /// implementation came to claim "Published to your account." while the Control Plane held no
    /// session for it.
    public struct State: Equatable, Sendable {
        public let publishing: Bool
        public let status: E2EWire.PublicationStatus?
        public init(publishing: Bool, status: E2EWire.PublicationStatus?) {
            self.publishing = publishing
            self.status = status
        }
    }

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var current = State(publishing: false, status: nil)
    private var publishedCode: String?
    private let interval: Double
    private let transport: E2EDirectoryClient.Transport

    public init(intervalSeconds: Double = E2ESessionPublisher.heartbeatSeconds,
                transport: E2EDirectoryClient.Transport = LiveDirectoryTransport()) {
        self.interval = intervalSeconds
        self.transport = transport
    }

    public func state() -> State {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Start announcing `session`. Returns immediately: **a slow Control Plane must not delay the
    /// Share panel painting a pairing code**, which is why the first beat runs in the task rather
    /// than being awaited here.
    ///
    /// A Mac with no committed chain is not an error and not a failure — it has no identity to be
    /// listed under, so there is no job. It reports `publishing: false`, which is the truth.
    public func start(identity: E2EHostIdentity, session: E2EDirectory.Session) {
        stopTimer()
        // ONE operation id for the whole announcement, not one per beat. Publication is idempotent
        // on the room code, so every beat is the SAME statement repeated — a fresh id each time
        // would say four different things about one room.
        let operationID = E2EOperation.newID()
        lock.lock()
        current = State(publishing: true, status: nil)
        publishedCode = session.code
        let transport = self.transport
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                let status = await identity.publishSession(session, operationID: operationID,
                                                           transport: transport)
                guard let self else { return }
                // **NOT GUARDED ON `Task.isCancelled` HERE, deliberately.** That check and
                // `record`'s are the same property enforced twice, and only one of them is atomic
                // with respect to `stop`: a beat can pass an `isCancelled` check and still be
                // inside `record` when the withdrawal lands. The lock-held check is the real one, so
                // this calls straight into it rather than pretending a second, racy guard helps.
                self.record(status)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        lock.unlock()
    }

    /// Stop announcing, and withdraw the room if one is listed.
    ///
    /// **FIRE AND FORGET.** The 90 s TTL reaps the entry anyway, and quitting must not wait on a
    /// network round trip — `before-quit` reaches this synchronously.
    public func stop(identity: E2EHostIdentity?) {
        stopTimer()
        lock.lock()
        let code = publishedCode
        publishedCode = nil
        current = State(publishing: false, status: nil)
        let transport = self.transport
        lock.unlock()

        guard let identity, let code else { return }
        Task.detached {
            await identity.unpublishSession(code: code,
                                            operationID: E2EOperation.newID(),
                                            transport: transport)
        }
    }

    private func record(_ status: E2EWire.PublicationStatus) {
        lock.lock(); defer { lock.unlock() }
        // **ONLY WHILE THE JOB IS STILL OURS.** A beat that lands after `stop` describes a request
        // about a room that has been withdrawn — recording it would leave the app claiming a listing
        // for a session that no longer exists, which is the exact failure the old boolean allowed.
        // Checked UNDER THE LOCK, so it is atomic with respect to `stop`.
        guard current.publishing else { return }
        current = State(publishing: true, status: status)
    }

    private func stopTimer() {
        lock.lock()
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
    }
}
