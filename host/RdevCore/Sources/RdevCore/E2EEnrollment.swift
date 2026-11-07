import Foundation

/// §12.3's commit order, as a pure reducer over the Issuer's durable journal.
///
/// > "The Issuer's reservation, grant, and registration **job** are one atomic local transaction,
/// > and **that transaction — not a Worker round trip — is what gates the acknowledgement.**"
///
/// **THE ORDERING IS THE FEATURE**, and it is: durable local commit → publication attempt → outcome
/// → acknowledgement → background retries. An Issuer that acknowledged first and committed after
/// would hand a device a grant it might not hold on restart; one that waited for the Worker would
/// let a silent Control Plane hold enrollment open forever, which §12.2 refuses in as many words.
///
/// **A REDUCER, so a crash is a test rather than a scenario.** §17.2 asks for exactly this: "Use
/// injectable delivery, clocks, and crashes; restart from serialized durable state only." A crash
/// here is dropping the returned value on the floor; a restart is calling `apply` against the last
/// journal that was actually written.
public enum E2EEnrollment {

    /// §12.3's pairing window, from the Issuer's side.
    public enum WindowState: Equatable, Sendable {
        /// Open and waiting; the pairing secret is live.
        case open
        /// **Reserved to exactly one device and operation.** §12.3: "Only one request wins a window;
        /// all other handshakes are aborted." Reservation is durable and happens INSIDE the
        /// transaction, so two handshakes racing cannot both believe they won.
        case reserved(deviceID: [UInt8], operationID: [UInt8])
        /// The transaction committed: the grant exists, the job is recorded, the secret is gone.
        case committed(deviceID: [UInt8], operationID: [UInt8])
        /// Expired, or closed without a commit. §14: "pairing window expires — erase secret and
        /// abort unreserved handshakes; preserve established routes."
        case closed

        /// §12.3: the secret is destroyed as part of the committing transaction, and §14 erases it
        /// on expiry. A window that still holds a live secret after either is one an attacker can
        /// still pair against.
        public var secretIsLive: Bool { self == .open || isReserved }

        var isReserved: Bool { if case .reserved = self { return true }; return false }
    }

    /// A registration job. §12.2: "a retry obtains another challenge but preserves the operation ID
    /// and payload", so BOTH are stored — a job that re-serialized its payload could produce
    /// different bytes and turn an idempotent retry into a `409`.
    public struct Job: Equatable, Sendable {
        public let operationID: [UInt8]
        public let grantID: [UInt8]
        public let deviceID: [UInt8]
        public let bundle: [UInt8]
        public var status: E2EWire.PublicationStatus
        public var attempts: Int
        /// §12.2: a terminal rejection is "paused, pending corrective action" — not retried in a
        /// loop, and not abandoned either. The job stays durable.
        public var paused: Bool
        /// §12.2: "stop pending jobs whose subject or ancestor has been revoked." Distinct from
        /// paused: a paused job resumes on user action, a stopped one never does.
        public var stopped: Bool

        public var retriesNow: Bool {
            !paused && !stopped && status == .unconfirmed
        }
    }

    public struct Journal: Equatable, Sendable {
        public var window: WindowState
        public var jobs: [Job]
        /// §10.5's tombstones, applied to jobs as they arrive.
        public var revokedDeviceIDs: Set<[UInt8]>

        public init(window: WindowState = .open, jobs: [Job] = [],
                    revokedDeviceIDs: Set<[UInt8]> = []) {
            self.window = window
            self.jobs = jobs
            self.revokedDeviceIDs = revokedDeviceIDs
        }

        /// §12.3: "that transaction — not a Worker round trip — is what gates the acknowledgement."
        ///
        /// **The publication status is NOT consulted here.** An unconfirmed or rejected job is still
        /// an enrolled device, and §12.2 is explicit that publication "is not a hard precondition"
        /// for access.
        public func mayAcknowledge(operationID: [UInt8]) -> Bool {
            if case .committed(_, let op) = window { return op == operationID }
            return false
        }

        public var pendingJobs: [Job] { jobs.filter(\.retriesNow) }

        public func job(operationID: [UInt8]) -> Job? {
            jobs.first { $0.operationID == operationID }
        }
    }

    public enum Failure: String, Error, Equatable, Sendable {
        /// Another device already won this window.
        case windowTaken = "window-taken"
        /// The window is closed or already committed.
        case windowUnavailable = "window-unavailable"
        /// A commit arrived with no reservation behind it.
        case notReserved = "not-reserved"
        /// A commit for a device or operation other than the reserved one.
        case wrongReservation = "wrong-reservation"
        case unknownOperation = "unknown-operation"
    }

    public enum Event: Equatable, Sendable {
        /// A `client-confirm` passed §11.2's gate and is asking for the window.
        case reserve(deviceID: [UInt8], operationID: [UInt8])
        /// **The atomic transaction.** Reservation, grant and job become durable together, and the
        /// secret is destroyed in the same step.
        case commit(deviceID: [UInt8], operationID: [UInt8], grantID: [UInt8], bundle: [UInt8])
        /// A publication attempt resolved, one way or another.
        case publicationAttempt(operationID: [UInt8], response: E2EDirectory.Response)
        /// A revocation arrived. §12.2: stop pending jobs whose subject or ancestor is revoked.
        case revoked(deviceID: [UInt8])
        /// §14: the window expired — erase the secret, abort unreserved handshakes.
        case expire
        /// §12.2: a paused job resumes "only on explicit operator or user action".
        case resume(operationID: [UInt8])
    }

    /// Apply one event. **PURE**: the caller writes the returned journal durably and only then acts
    /// on it — which is what makes "the transaction gates the acknowledgement" a property of the
    /// code rather than of the specification.
    public static func apply(_ journal: Journal, _ event: Event) -> Result<Journal, Failure> {
        var next = journal
        switch event {
        case .reserve(let deviceID, let operationID):
            switch journal.window {
            case .open:
                next.window = .reserved(deviceID: deviceID, operationID: operationID)
            case .reserved(let held, let heldOp):
                // IDEMPOTENT FOR THE SAME REQUEST, and refused for any other. A retry of the same
                // handshake must not lose the window it already holds; a different device must not
                // take it. §12.3: "Only one request wins a window."
                guard held == deviceID, heldOp == operationID else { return .failure(.windowTaken) }
            case .committed, .closed:
                return .failure(.windowUnavailable)
            }

        case .commit(let deviceID, let operationID, let grantID, let bundle):
            guard case .reserved(let held, let heldOp) = journal.window else {
                // §12.3 puts the reservation INSIDE the transaction, so a commit without one is not
                // a commit — it is a grant nobody reserved a window for.
                if case .committed(let d, let o) = journal.window, d == deviceID, o == operationID {
                    return .success(journal)      // replay of the same transaction
                }
                return .failure(.notReserved)
            }
            guard held == deviceID, heldOp == operationID else {
                return .failure(.wrongReservation)
            }
            // ALL THREE, OR NONE. The caller writes this journal in one durable write; there is no
            // intermediate state in which the grant exists and its job does not, which is what
            // "one atomic local transaction" means in practice.
            next.window = .committed(deviceID: deviceID, operationID: operationID)
            next.jobs.append(Job(operationID: operationID, grantID: grantID, deviceID: deviceID,
                                 bundle: bundle, status: .unconfirmed, attempts: 0,
                                 paused: false,
                                 // A device already tombstoned at commit time gets a job that never
                                 // runs, rather than one that runs and is then stopped.
                                 stopped: journal.revokedDeviceIDs.contains(deviceID)))

        case .publicationAttempt(let operationID, let response):
            guard let index = next.jobs.firstIndex(where: { $0.operationID == operationID }) else {
                return .failure(.unknownOperation)
            }
            var job = next.jobs[index]
            job.attempts += 1
            let status = E2EDirectory.classify(response)
            // §12.2: "`confirmed` is terminal. A later `unconfirmed` from any peer MUST NOT reset
            // it." This endpoint HOLDS the job, so it is the one allowed to move the value — and
            // still not backwards out of confirmed.
            if job.status != .confirmed { job.status = status }
            job.paused = job.status == .rejected
            next.jobs[index] = job

        case .revoked(let deviceID):
            next.revokedDeviceIDs.insert(deviceID)
            // §12.2: "stop pending jobs whose subject or ancestor has been revoked." Stopping is
            // irreversible here because a tombstone is (§10.5: "there is no unrevoke operation").
            next.jobs = next.jobs.map { job in
                guard job.deviceID == deviceID else { return job }
                var stopped = job
                stopped.stopped = true
                return stopped
            }

        case .expire:
            switch journal.window {
            // §14: "erase secret and abort unreserved handshakes; PRESERVE ESTABLISHED ROUTES."
            // A committed window is not reopened or torn down by an expiry — the device it enrolled
            // is enrolled, and its job is still owed a publication.
            case .open, .reserved: next.window = .closed
            case .committed, .closed: break
            }

        case .resume(let operationID):
            guard let index = next.jobs.firstIndex(where: { $0.operationID == operationID }) else {
                return .failure(.unknownOperation)
            }
            var job = next.jobs[index]
            // A STOPPED job does not resume. §10.5 has no unrevoke, so "resume" on a revoked
            // device's job would be the one path that manufactures one.
            guard !job.stopped else { return .success(journal) }
            job.paused = false
            job.status = .unconfirmed
            next.jobs[index] = job
        }
        return .success(next)
    }
}
