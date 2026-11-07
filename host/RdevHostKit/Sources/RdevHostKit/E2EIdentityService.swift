import Foundation
import RdevCore
import RdevE2E

/// **The device's E2E identity as a live object**: the assembly, the cached status, and the one
/// ceremony that may be in flight.
///
/// Separate from `RdevHostRuntime` because the two questions are independent. A runtime exists only
/// between `start()` and `stop()`, while "is this Mac enrolled?" is what the app asks BEFORE any
/// session exists — it is the question that decides whether Share is even offered.
///
/// **PROCESS-GLOBAL, and keyed by the ceremony origin**, matching what is already true of the things
/// it owns: one Keychain item, one trust file, one `CurtainController.shared`. Two services over one
/// store would be two caches of one answer, and they would disagree the moment either enrolled.
public final class E2EIdentityService: @unchecked Sendable {

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: E2EIdentityService] = [:]

    public static func shared(signalingBase: String) -> E2EIdentityService {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[signalingBase] { return existing }
        let made = E2EIdentityService(e2e: E2EHostIdentity.live(signalingBase: signalingBase))
        registry[signalingBase] = made
        // **§12.2's "automatic, idempotent, ACROSS RESTARTS".** A registration that failed when this
        // Mac enrolled is a job nothing else will ever do — `registerGrant` runs once and the host
        // had no drain, so a Mac enrolled during a Worker outage stayed unpublished for the life of
        // the installation and a browser discovering its passkey got 404 forever.
        //
        // This is the Mac's version of what the browser does on every dashboard visit: once per
        // process, at the first question anybody asks about this identity. Detached and
        // fire-and-forget because publication can fail NOTHING (§12.2), and `retryRegistration`
        // returns nil without a request whenever there is no outstanding job — which is almost
        // always, so this costs nothing in the ordinary case.
        made.retryRegistrationInBackground()
        return made
    }

    /// Drain an outstanding publication job, if there is one. See the call in `shared`.
    ///
    /// **Deliberately not awaited and deliberately not observable.** A caller that could wait on it
    /// would be a caller that could gate on it, and §12.2 is explicit that publication is never a
    /// precondition for access. `E2EHostStatus` is where the outcome surfaces, as it already did.
    private func retryRegistrationInBackground() {
        guard case .success(let identity) = e2e else { return }
        Task.detached { [weak self] in
            _ = await identity.retryRegistration()
            // The cached status may have been `unconfirmed`; let the next poll re-read it.
            self?.invalidateCachedStatus()
        }
    }

    public enum CeremonyFailure: Error, Equatable {
        case unavailable(E2EHostIdentity.Failure)
        case alreadyEnrolling
        /// A ceremony is not the next step. Carries what the next step actually is.
        case notApplicable(E2EHostStatus)
        case ceremony(E2EPasskeyFailure)
    }

    /// The assembly, or why there is none. A `Result` rather than an optional so the reason survives
    /// to the status line: a misconfigured origin and a read-only home directory need completely
    /// different fixes, and neither is fixed by retrying.
    private let e2e: Result<E2EHostIdentity, E2EHostIdentity.Failure>
    private let lock = NSLock()
    /// Nil means "ask storage". Cleared whenever something could have changed it, which is how a
    /// poll stays honest without re-reading storage at 2 Hz forever.
    private var cachedStatus: E2EHostStatus?
    /// The same bargain for `trustedRootID()`, which the app polls beside the status. A separate
    /// flag rather than an optional-of-optional, because "no root" is an answer worth caching too.
    private var rootIDCached = false
    private var cachedRootID: [UInt8]?
    /// Not a stored state — this process's own. It is what makes a second ceremony a refusal rather
    /// than a second passkey prompt over the first.
    private var enrolling = false

    /// The Worker, for a discovery's credential lookup and the publication after a ceremony. A
    /// parameter so a test can be the Worker; the app's is the network.
    private let directory: E2EDirectoryClient.Transport

    init(e2e: Result<E2EHostIdentity, E2EHostIdentity.Failure>,
         directory: E2EDirectoryClient.Transport = LiveDirectoryTransport()) {
        self.e2e = e2e
        self.directory = directory
    }

    /// This device's identity, for the parts of the host that have to present it. Nil exactly when
    /// `status()` is `.unavailable`.
    public var identity: E2EHostIdentity? { try? e2e.get() }

    /// **§11's configuration for this host, AS OF NOW.** Nil when the host is not enrolled.
    ///
    /// Deliberately not cached at startup: a host that enrols while running must be able to serve
    /// without a restart, and the first version of this read it once in `start()` — which made every
    /// session after an enrollment refuse, with `[e2e] refusing a session: this Mac is not enrolled`
    /// for a Mac that plainly was. It is read once per NEW PEER, which is rare enough that a
    /// Keychain read costs nothing.
    /// `pairingPSK` is the window this Host is showing RIGHT NOW, and it is passed per call rather
    /// than stored beside the identity because a pairing window is a live thing with a lifetime.
    /// Nil refuses `pair` — §9.1: only an Issuer with a window open can answer one, and a Host
    /// without the key cannot complete the handshake anyway.
    public func gateConfig(pairingPSK: [UInt8]? = nil) -> E2ESignallingGate.Config? {
        guard case .success(let identity) = e2e,
              case .success(let loaded) = identity.load() else { return nil }
        return E2ESignallingGate.Config(loaded: loaded, policy: identity.policy,
                                        pairingPSK: pairingPSK)
    }

    /// **The root this Mac belongs to**, or nil when it belongs to none.
    ///
    /// Deliberately NOT part of `E2EHostStatus`. That type answers "what should happen next", and
    /// the root is not a state — it is the one value a person is shown to recognise their identity
    /// by. Folding it into `ready`'s payload would also give the C ABI's single `detail` string a
    /// second meaning under the same status: it already carries the §10.2 DEVICE id there, and
    /// §10.1's readable code and a device id are two formats that exist precisely so that a person
    /// cannot mistake one for the other (`docs/e2e.md`).
    public func trustedRootID() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        if rootIDCached { return cachedRootID }
        guard case .success(let identity) = e2e,
              case .success(let loaded) = identity.load() else {
            // Cached as "none" like any other answer: a Mac whose storage cannot be read has no
            // identity to show, and re-reading it every 500 ms would not change that.
            rootIDCached = true
            cachedRootID = nil
            return nil
        }
        rootIDCached = true
        cachedRootID = loaded.trustedRootID
        return cachedRootID
    }

    /// **Log out this Mac** — delete its keys and its trust record. True when it is afterwards
    /// unenrolled.
    ///
    /// **REFUSED WHILE A CEREMONY IS IN FLIGHT.** One is writing the very records this deletes, and
    /// the two interleaving would leave a device holding half of an identity nobody asked for. That
    /// is the same reason a second ceremony is refused rather than raising a second prompt.
    ///
    /// A passkey created here and never finished goes too, as the browser's `forget()` clears its
    /// retained entry: "Finish setting up" adopts with no confirmation, so it must not outlive a sign-out.
    public func forget() -> Bool {
        lock.lock()
        let busy = enrolling
        lock.unlock()
        guard !busy, case .success(let identity) = e2e else { return false }
        let gone = identity.manager.forget()
        _ = identity.pendingRoot.delete()
        // Whatever happened, what is stored has changed. The next poll reads rather than believes.
        invalidateCachedStatus()
        return gone
    }

    public func status() -> E2EHostStatus {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked()
    }

    /// **Sign in with a passkey** (`E2EHostIdentity.signIn`): ONE prompt, the identity the person picks.
    /// Also §10.3's upgrade for a Mac adopted by code, which asks only for its own root's credential.
    public func signIn(authenticator: PasskeyAuthenticator)
        async -> Result<E2EIdentityManager.Acceptance, CeremonyFailure> {
        let directory = directory
        return await ceremony(allowsUpgrade: true) {
            await $0.signIn(authenticator: authenticator, transport: directory)
        }
    }

    /// **Create a passkey** — a new identity — and retain it: prompt one of two. `authorise` is two.
    public func createPasskey(authenticator: PasskeyAuthenticator) async -> Result<Void, CeremonyFailure> {
        let identity: E2EHostIdentity
        switch begin(allowsUpgrade: false) {
        case .success(let assembled): identity = assembled
        case .failure(let refusal): return .failure(refusal)
        }
        let result = await identity.createPasskey(authenticator: authenticator)
        end()
        return result.mapError(CeremonyFailure.ceremony)
    }

    /// **Let the retained passkey authorise this Mac**: create's second prompt, and "Finish setting up".
    public func authorise(authenticator: PasskeyAuthenticator)
        async -> Result<E2EIdentityManager.Acceptance, CeremonyFailure> {
        await ceremony(allowsUpgrade: false) { await $0.authorise(authenticator: authenticator) }
    }

    /// A passkey this Mac created and never finished.
    public var hasPendingRoot: Bool { identity?.hasPendingRoot ?? false }

    /// One ceremony that ends in a grant: claimed, run, then §12.2's publication. **Publication cannot
    /// fail the ceremony** — best-effort, deliberately, because an honest Worker outage would otherwise
    /// leave a correctly enrolled device unusable; its status is stored and `E2EHostStatus` surfaces
    /// anything other than `confirmed`. It also fills the Worker's credential index, which is what lets
    /// another device discover the identity this Mac just created.
    private func ceremony(allowsUpgrade: Bool,
                          _ run: (E2EHostIdentity) async -> Result<E2EIdentityManager.Acceptance, E2EPasskeyFailure>)
        async -> Result<E2EIdentityManager.Acceptance, CeremonyFailure> {
        let identity: E2EHostIdentity
        switch begin(allowsUpgrade: allowsUpgrade) {
        case .success(let assembled): identity = assembled
        case .failure(let refusal): return .failure(refusal)
        }
        let result = await run(identity)
        if case .success = result { _ = await identity.retryRegistration(transport: directory) }
        end()
        return result.mapError(CeremonyFailure.ceremony)
    }

    /// **The claim and the refusals are one atomic step, in a SYNCHRONOUS function.** Splitting them
    /// around an `await` is what would let two clicks both find `.unenrolled` and raise two passkey
    /// prompts — and `NSLock` is unavailable across a suspension in the Swift 6 language mode for
    /// exactly that class of reason.
    private func begin(allowsUpgrade: Bool) -> Result<E2EHostIdentity, CeremonyFailure> {
        lock.lock()
        defer { lock.unlock() }
        let identity: E2EHostIdentity
        switch e2e {
        case .success(let assembled): identity = assembled
        case .failure(let failure): return .failure(.unavailable(failure))
        }
        if enrolling { return .failure(.alreadyEnrolling) }
        let status = statusLocked()
        // **§10.3's upgrade is the one exception to "one ceremony per unenrolled device".** A Mac
        // adopted by code holds capability 2 and asking a passkey is how it becomes a full device:
        // "a code-enrolled B requesting passkey authorization receives a new DIRECT grant… its new
        // direct chain does not depend on A". Only SIGNING IN may upgrade — creating would make a
        // second identity for a device that already has one.
        //
        // The SAME-ROOT rule is not checked here and must not be: `acceptEnrollmentReturn` keeps an
        // enrolled device's existing root and verifies the incoming chain against it, so a grant
        // under another root fails there (§10.1). Answering "may this start" is a different question
        // from "may this be adopted", and merging them is how the second comes to be skipped.
        guard status == .unenrolled
                || allowsUpgrade && E2EUpgrade.mayUpgrade(capabilities: identity.leafCapabilities())
        else { return .failure(.notApplicable(status)) }
        enrolling = true
        return .success(identity)
    }

    private func end() {
        lock.lock()
        defer { lock.unlock() }
        enrolling = false
        // A ceremony changed storage whether it succeeded or not — a failed one may still have
        // created the installation. The next poll reads rather than believes.
        cachedStatus = nil
        rootIDCached = false
    }

    /**
     * **ANY PATH THAT CHANGES STORED IDENTITY OUTSIDE THIS SERVICE MUST CALL THIS.**
     *
     * `cachedStatus` exists so a 2 Hz poll does not re-read storage forever, and it is correct only
     * while every writer announces itself. A ceremony does (through `end`), `forget` does, and the
     * registration retry does — but **adopt-by-code commits through `E2EIdentityManager` directly**,
     * and for a while nothing told the cache. The Mac was enrolled, held capability 2, and its own
     * Devices row went on saying "This Mac has no encryption identity yet" for the rest of the
     * session. Reported by a person; `adopt-by-code-check` had missed it because the service's
     * detached `retryRegistration` happens to invalidate the cache mid-run, so a check that never
     * polls beforehand reads fresh storage by luck.
     */
    public func invalidateStatus() { invalidateCachedStatus() }

    /// Drop the cached answer so the next poll reads storage. Its own method because the retry in
    /// `shared` runs off any caller's thread and must take the lock like everything else here.
    private func invalidateCachedStatus() {
        lock.lock()
        defer { lock.unlock() }
        cachedStatus = nil
        rootIDCached = false
    }

    /// The lock is held. `load()` is the only thing here that touches storage, which is why the
    /// answer is cached at all.
    private func statusLocked() -> E2EHostStatus {
        if enrolling { return .enrolling }
        if let cached = cachedStatus { return cached }
        let status: E2EHostStatus
        switch e2e {
        case .failure(let failure):
            status = .unavailable(failure)
        case .success(let identity):
            switch identity.load() {
            case .success(let loaded): status = E2EHostStatus.of(loaded)
            case .failure(let failure): status = .blocked(failure)
            }
        }
        cachedStatus = status
        return status
    }
}
