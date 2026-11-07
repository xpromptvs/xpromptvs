import Foundation

/// The one place that answers **"who is this device, and what should it do next?"** from durable
/// state, and the adapter between that state and `E2ESession`.
///
/// Everything under it already exists and is separately tested: `DeviceIdentity` makes the keys,
/// `InstallationStore` puts them somewhere, `E2ETrustStore` holds the root and the chain, and
/// `E2EDirectory.nextAction` is §12.4's table. What was missing is the thing that reads both records
/// and produces ONE answer — because the two are stored apart on purpose (§10.2 binds the keys to
/// the rendezvous seed; the trust is learned later), and a caller that consulted them separately
/// would have to re-derive the relationship between them at every call site.
///
/// **STORAGE-AGNOSTIC.** Both backends are injected: the host puts its keys in the Keychain and its
/// trust record in a file, a test uses two in-memory stores, and neither choice is visible here.
public struct E2EIdentityManager {

    /// What this device should do next. §12.4's table, resolved against what is actually stored.
    public enum State: Equatable, Sendable {
        /// Keys exist and no chain does. Run an enrollment.
        case unenrolled
        /// An enrollment was started and never committed. §12.4: `resume` to that responder rather
        /// than starting a fresh ceremony, which would reserve a second window.
        case resumable(E2ETrustStore.PendingOperation)
        /// Ready to serve and to connect. `cleanupPending` carries §12.4's second column: the chain
        /// is committed and some tidying did not finish.
        case ready(cleanupPending: Bool)
        /// **A person has to decide.** Something is stored and cannot be read, and overwriting it
        /// would silently abandon an identity — `InstallationStore.Failure.unreadableRecord` says
        /// why at length. Never resolved automatically.
        case blocked(Failure)
    }

    public enum Failure: String, Error, Equatable, Sendable {
        case unreadableInstallation = "unreadable-installation"
        case unreadableTrust = "unreadable-trust"
        case writeFailed = "write-failed"
        case generationFailed = "generation-failed"
        /// A commit whose chain does not verify, or does not describe this device.
        case chainMismatch = "chain-mismatch"
        case noRoot = "no-root"
        /// §10.1: adopting a root the device has never seen needs a person, and the caller did not
        /// say how one chose it. Not an error in the bundle — a refusal to decide on a human's behalf.
        case rootNotConfirmed = "root-not-confirmed"
        /// The return did not satisfy §10.4's bindings. Carries no detail: §14 gives one action.
        case returnRejected = "return-rejected"
    }

    /// What accepting a return actually did.
    public enum Acceptance: Equatable, Sendable {
        /// A grant under the root this device already trusted. Nothing new was adopted.
        case verified
        /// **A NEW ROOT WAS ADOPTED**, and the caller said how a person chose it.
        case adoptedNewRoot(rootID: [UInt8])
    }

    /// **How a person chose the root a device with none is about to adopt** — §10.1's two routes, the
    /// only two that may adopt one without a confirmation step (the browser's rule since 2026-09-14,
    /// the Mac's since 2026-10-06): the person CREATED it on this device, or the AUTHENTICATOR offered
    /// it and the person picked it (discovery with an empty `allowCredentials`, which no directory
    /// steers). §10.1's Residual is about a candidate the directory named, and no route here takes one.
    /// Either way the identity is stated afterwards, with sign-out beside it.
    public enum NewRoot: Equatable, Sendable { case created, discovered }

    private let installations: InstallationStore.Backend
    private let trust: InstallationStore.Backend
    private let randomBytes: (Int) -> [UInt8]

    public init(installations: InstallationStore.Backend,
                trust: InstallationStore.Backend,
                randomBytes: @escaping (Int) -> [UInt8] = DeviceIdentity.systemRandom) {
        self.installations = installations
        self.trust = trust
        self.randomBytes = randomBytes
    }

    /// Everything a session needs, loaded together.
    public struct Loaded: Equatable, Sendable {
        public let installation: DeviceIdentity.Installation
        public let record: E2ETrustStore.Record
        public let state: State

        /// This device's §10.2 descriptor under its trusted root. Nil before a root is adopted —
        /// a descriptor names its root, so there is no such thing as one without.
        public var deviceDescriptor: [UInt8]? {
            record.root.map { installation.keys.descriptor(rootID: E2EIdentity.rootID($0)) } ?? nil
        }

        public var trustedRootID: [UInt8]? { record.root.map(E2EIdentity.rootID) }
    }

    /// Read both records, creating an installation if and only if none exists.
    ///
    /// **The trust record is read even when it is empty**, and a failure to read one that EXISTS is
    /// `blocked`, not "no trust yet". The difference is a device that has never enrolled against one
    /// that has and cannot say so, and only the first should quietly start a ceremony.
    public func load() -> Result<Loaded, Failure> {
        let installation: DeviceIdentity.Installation
        switch InstallationStore.loadOrCreate(installations, randomBytes: randomBytes) {
        case .success(.created(let made)), .success(.loaded(let made)):
            installation = made
        case .failure(.unreadableRecord):
            return .failure(.unreadableInstallation)
        case .failure(.writeFailed):
            return .failure(.writeFailed)
        case .failure(.generationFailed):
            return .failure(.generationFailed)
        }

        var record = E2ETrustStore.Record()
        if let stored = trust.read() {
            guard let decoded = E2ETrustStore.decode(stored) else {
                return .success(Loaded(installation: installation, record: record,
                                       state: .blocked(.unreadableTrust)))
            }
            record = decoded
        }

        let state: State
        switch E2ETrustStore.nextAction(record, hasKeys: true) {
        case .freshEnrollment: state = .unenrolled
        case .resume:
            // `nextAction` only answers `resume` when a pending operation exists, so this is total —
            // but it is written as a fallback rather than a force-unwrap, because a future change to
            // that table must not become a crash here.
            state = record.pending.map(State.resumable) ?? .unenrolled
        case .auth(let repeatCleanup): state = .ready(cleanupPending: repeatCleanup)
        case .generateNewKeysAndEnroll: state = .unenrolled
        }
        return .success(Loaded(installation: installation, record: record, state: state))
    }

    /// Adopt a root learned through an authenticated route — §10.1's three: a local passkey, a
    /// verified assertion, or a PSK-authenticated code exchange.
    ///
    /// Refuses to replace one. §10.1: "Switching identity requires an explicit local
    /// reset/re-registration; possession of a new passkey cannot remotely replace a Host's existing
    /// root."
    public func adoptRoot(_ root: [UInt8], into record: E2ETrustStore.Record)
        -> Result<E2ETrustStore.Record, Failure> {
        switch E2ETrustStore.adoptRoot(record, root: root) {
        case .success(let next): return persist(next)
        case .failure: return .failure(.chainMismatch)
        }
    }

    /// Commit this device's own chain, with the status §11.2 delivered beside it.
    ///
    /// **The chain must verify AND describe this device.** A bundle that verifies for someone else
    /// is a perfectly valid grant this device cannot use, and persisting it would leave a host
    /// presenting a chain whose keys it does not hold — which fails at the first `client-confirm`,
    /// far from the cause.
    public func commit(bundle: [UInt8], status: E2EWire.PublicationStatus,
                       into loaded: Loaded, policy: E2EVerify.Policy)
        -> Result<E2ETrustStore.Record, Failure> {
        guard let rootID = loaded.trustedRootID else { return .failure(.noRoot) }
        guard let descriptor = loaded.deviceDescriptor else { return .failure(.noRoot) }

        switch E2EVerify.verifyBundle(bundle, trustedRootID: rootID, policy: policy,
                                      revokedDeviceIDs: loaded.record.revokedDeviceIDs) {
        case .failure:
            return .failure(.chainMismatch)
        case .success(let chain):
            guard chain.leafDevice.bytes == descriptor else { return .failure(.chainMismatch) }
        }

        switch E2ETrustStore.commitOwnChain(loaded.record, bundle: bundle, status: status,
                                            rootID: rootID) {
        case .success(let next): return persist(next)
        case .failure: return .failure(.chainMismatch)
        }
    }

    /// Accept a grant returned from an enrollment ceremony, adopt its root if this device has none,
    /// and commit the chain — in one step, because the three are one decision.
    ///
    /// **`newRoot` MAKES §10.1'S OBLIGATION STRUCTURAL.** A device with no prior knowledge of a root
    /// "genuinely cannot distinguish" a legitimate one from a substituted one, so this adopts one only
    /// when the caller states HOW a person chose it — one of §10.1's two routes that need no
    /// confirmation (`NewRoot`). Nil refuses to adopt. A caller naming a route its ceremony did not
    /// take has written a lie into its own source rather than forgotten a guideline.
    ///
    /// It is only consulted when a root is actually being adopted. A grant under the root already
    /// trusted needs nothing — nothing is being decided.
    public func acceptEnrollmentReturn(bundle: [UInt8], pendingOperationID: [UInt8]?,
                                       loaded: Loaded, policy: E2EVerify.Policy,
                                       newRoot: NewRoot?)
        -> Result<(record: E2ETrustStore.Record, acceptance: Acceptance), Failure> {

        // Which root is this checked against? An enrolled device has one and an incoming chain may
        // never replace it (§10.1). A device with none takes the bundle's own — which is the moment
        // that needs a person, and nothing else in this protocol does.
        let trustedRootID: [UInt8]
        let acceptance: Acceptance
        if let existing = loaded.trustedRootID {
            trustedRootID = existing
            acceptance = .verified
        } else {
            guard case .success(let parsed) = E2ECertificate.parseBundle(bundle),
                  let root = E2EIdentity.parseRoot(parsed.root) else {
                return .failure(.returnRejected)
            }
            guard newRoot != nil else { return .failure(.rootNotConfirmed) }
            trustedRootID = root.id
            acceptance = .adoptedNewRoot(rootID: root.id)
        }

        // The descriptor this device would present under that root. Derived here rather than taken
        // from `loaded`, which has none before a root exists.
        guard let descriptor = loaded.installation.keys.descriptor(rootID: trustedRootID) else {
            return .failure(.chainMismatch)
        }

        // §10.4's two bindings plus the whole chain, in the one place that knows both.
        guard case .success = E2ENativeReturn.accept(
            bundle: bundle, pendingOperationID: pendingOperationID,
            deviceDescriptor: descriptor, trustedRootID: trustedRootID, policy: policy,
            revokedDeviceIDs: loaded.record.revokedDeviceIDs) else {
            return .failure(.returnRejected)
        }

        var record = loaded.record
        if case .adoptedNewRoot = acceptance {
            guard case .success(let parsed) = E2ECertificate.parseBundle(bundle) else {
                return .failure(.returnRejected)
            }
            switch E2ETrustStore.adoptRoot(record, root: parsed.root) {
            case .success(let next): record = next
            case .failure: return .failure(.chainMismatch)
            }
        }

        // §12.2: a newly issued grant carries its own status, and the endpoint that issued it is the
        // one that knows. A native return comes from a ceremony this device drove, so nothing here
        // has been published yet — `unconfirmed` is the truth until a publication says otherwise.
        switch E2ETrustStore.commitOwnChain(record, bundle: bundle, status: .unconfirmed,
                                            rootID: trustedRootID) {
        case .success(let next):
            return persist(next).map { (record: $0, acceptance: acceptance) }
        case .failure:
            return .failure(.chainMismatch)
        }
    }

    /// §12.2's publication status, merged into what is stored and persisted.
    ///
    /// **`reporterHoldsPublicationJob` is the parameter that stops every unrelated connection from
    /// erasing this.** `publication_status` rides in EVERY `session-start`, including an ordinary
    /// `auth` to a Host that never participated in the publication and reports `unconfirmed` because
    /// that is the truth — it does not know. Only the endpoint HOLDING the job may lower the value.
    public func recordPublicationStatus(_ reported: E2EWire.PublicationStatus,
                                        reporterHoldsPublicationJob: Bool,
                                        in record: E2ETrustStore.Record)
        -> Result<E2ETrustStore.Record, Failure> {
        let next = E2ETrustStore.mergePublicationStatus(
            record, reported: reported, reporterHoldsPublicationJob: reporterHoldsPublicationJob)
        // Nothing changed: §12.2's merge is monotonic toward `confirmed`, and a write that stores
        // the same bytes is a write that can still fail.
        guard next.publicationStatus != record.publicationStatus else { return .success(record) }
        return persist(next)
    }

    /// §10.5: an irreversible tombstone, persisted before it is acted on. §12.2 requires an endpoint
    /// to "persist before acknowledgement".
    public func revoke(deviceID: [UInt8], in record: E2ETrustStore.Record)
        -> Result<E2ETrustStore.Record, Failure> {
        persist(E2ETrustStore.revoke(record, deviceID: deviceID))
    }

    /// §10.1's "explicit local reset/re-registration". **Discards the trust record only** — the keys
    /// survive, because a reset is a change of IDENTITY and not of device. `InstallationStore
    /// .destroy` is the other operation, and a caller that wants both calls both, deliberately.
    public func resetTrust() -> Result<E2ETrustStore.Record, Failure> {
        persist(E2ETrustStore.reset())
    }

    /// **Log out: delete this device's KEYS as well as its trust record.**
    ///
    /// Not `resetTrust()`, which is §10.1's local reset and deliberately keeps the keys, because a
    /// reset is a change of IDENTITY and not of device. This is the browser's
    /// `ClientE2EIdentity.forget()` by another name, and it deletes both for the reason that one
    /// does: keeping the keys would leave one Noise static certified under two roots, a stable
    /// correlator any peer on either side can see (`docs/e2e.md`).
    ///
    /// **KEYS FIRST, and the trust record is not touched if they survive.** The orders fail
    /// differently and only one failure is safe: keys gone and the record left is §12.4's
    /// `keys-lost` — a chain for keys that no longer exist, which nothing can use — while the
    /// record gone and the keys left is a device still holding the material a person believes they
    /// deleted. So a failure here changes nothing at all, and a partial success is the harmless one.
    ///
    /// **IT REVOKES NOTHING.** §10.5 needs the root passkey; a device cannot revoke its own grant,
    /// and anything holding a copy of these keys keeps the access they carried. Every interface
    /// offering this has to say so.
    public func forget() -> Bool {
        guard InstallationStore.destroy(installations) else { return false }
        return trust.delete()
    }

    private func persist(_ record: E2ETrustStore.Record) -> Result<E2ETrustStore.Record, Failure> {
        guard let bytes = E2ETrustStore.encode(record), trust.write(bytes) else {
            // §12.3: "unsuccessful durable write grants no authority." The caller gets nothing back
            // to act on, which is the point — a record that was not written is not a record.
            return .failure(.writeFailed)
        }
        return .success(record)
    }
}
