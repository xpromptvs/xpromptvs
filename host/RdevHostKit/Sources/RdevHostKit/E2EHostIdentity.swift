import Foundation
import RdevCore
import RdevE2E

/// **The one place that knows how this host's E2E identity is assembled.**
///
/// Four decisions travel together and are wrong if they disagree: private keys in a file (§10.2),
/// the trust record beside it, the ceremony origin from `RDEV_SIGNALING`, and §10.1's policy derived
/// from that same origin. The harness, the C ABI and `RdevHostRuntime` all
/// need the same four, and each one re-deriving them is how a host ends up verifying a return
/// against a different origin than the one it opened.
///
/// **Assembling one persists nothing.** The first write happens at `load()`, which is also the only
/// thing that can create keys — so a host that is merely started, or is misconfigured, leaves no
/// trace. The ordering that guarantees it is asserted, not assumed: the origin resolves before the
/// trust store is even constructed, and constructing that store creates a directory.
public struct E2EHostIdentity {

    public enum Failure: Error, Equatable {
        /// `RDEV_SIGNALING` cannot host a ceremony. Carries the reason, because the two that matter
        /// — a plaintext LAN origin and a path-mounted deployment — have completely different fixes.
        case origin(E2EOrigin.Failure)
        /// Nowhere durable to write. §12.3: "an unsuccessful durable write grants no authority",
        /// and a device that cannot write at all has none to begin with.
        case storageUnavailable
    }

    /// Where the Control Plane is: `/directory` and `/credential`.
    public let origin: E2EOrigin.Resolved
    /// **Where the CEREMONY ran, when that is not the Control Plane.** Nil in production, where one
    /// origin serves the client and the control plane and is the passkeys' relying party — see `live`.
    public let ceremonyOrigin: E2EOrigin.Resolved?
    public let manager: E2EIdentityManager
    /// **A passkey this Mac created and never finished** (`createPasskey`, `docs/e2e.md`): its root
    /// descriptor, the one value a registration hands out and nothing can rebuild. Beside the keys.
    let pendingRoot: InstallationStore.Backend

    public init(origin: E2EOrigin.Resolved, manager: E2EIdentityManager,
                pendingRoot: InstallationStore.Backend = MemoryRecord(),
                ceremonyOrigin: E2EOrigin.Resolved? = nil) {
        self.origin = origin
        self.ceremonyOrigin = ceremonyOrigin
        self.manager = manager
        self.pendingRoot = pendingRoot
    }

    /// **§10.3's capability on this device's own leaf grant**, or nil when there is no chain to read
    /// one from — no root, no bundle, or a chain that does not verify.
    ///
    /// Read by VERIFYING rather than parsing: a capability taken out of a chain this device would
    /// refuse is not a fact about this device, and the two callers (the upgrade rule and the app's
    /// own Settings) both act on it.
    public func leafCapabilities() -> E2EIdentity.Capabilities? {
        guard case .success(let loaded) = manager.load(),
              let bundle = loaded.record.bundle,
              let rootID = loaded.trustedRootID,
              case .success(let chain) = E2EVerify.verifyBundle(
                  bundle, trustedRootID: rootID, policy: policy,
                  revokedDeviceIDs: loaded.record.revokedDeviceIDs)
        else { return nil }
        return chain.capabilities
    }

    /// §10.1's policy — the relying party and the one accepted ceremony origin — for verifying what
    /// a ceremony returns and what a peer presents. **It is about where the CEREMONY ran**, which is
    /// the Control Plane's origin unless something says otherwise.
    public var policy: E2EVerify.Policy { (ceremonyOrigin ?? origin).policy }

    /// The real host: `~/Library/Application Support/dev.rdev.host/` — keys, trust record and a
    /// retained passkey alike.
    ///
    /// **`RDEV_E2E_STORE` names the directory holding BOTH records** — this device's keys and its
    /// trust record. Anything automated names its own: two runs sharing one store are two hosts
    /// fighting over one identity, and a run holding another's trust file would present a chain for
    /// keys it does not have.
    public static func live(
        signalingBase: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<E2EHostIdentity, Failure> {
        // **`RDEV_E2E_ORIGIN` names where the CEREMONY ran, when that is not the Control Plane.**
        //
        // The two coincide in production: one origin serves the client and the control plane. A DEV
        // SPLIT is the only reason they differ — `scripts/smoke-*.sh` serve the client from vite on
        // :5173 and proxy `/session` to the Worker on :8787, so a browser's `location.origin` is
        // vite's while the host's signalling base is the Worker's. §10.1's policy is about the origin
        // the ceremony ran on, and BOTH ends must agree or neither can verify the other's chain.
        //
        // It affects the POLICY only. `/directory` and `/credential` still go to `signalingBase`,
        // which is the one thing this must not move.
        var ceremonyOrigin: E2EOrigin.Resolved?
        if let named = processEnvironment["RDEV_E2E_ORIGIN"]?
            .trimmingCharacters(in: .whitespaces).nonEmpty {
            switch E2EOrigin.resolve(named) {
            case .success(let r): ceremonyOrigin = r
            case .failure(let f): return .failure(.origin(f))
            }
        }

        // A PREPARED IDENTITY, for tests. The file is minted for the ceremony origin, so §10.1's
        // policy is still configuration rather than something a test relaxes.
        if let seeded = E2ETestIdentity.stores(processEnvironment: processEnvironment) {
            return assemble(signalingBase: signalingBase, installations: seeded.installations,
                            trust: { seeded.trust }, pendingRoot: { MemoryRecord() },
                            ceremonyOrigin: ceremonyOrigin)
        }

        let override = processEnvironment["RDEV_E2E_STORE"]?
            .trimmingCharacters(in: .whitespaces)
            .nonEmpty
        // **BOTH RECORDS ARE FILES, IN ONE DIRECTORY.** The keys were in the login keychain and are
        // not any more: it never protected them from a same-user process (measured — see
        // `FileRecordStore.installationName`), while costing a prompt on every re-signed build and,
        // measured, an indefinite hang inside `SecItemCopyMatching` after a rebuild.
        //
        // The trust record moving WITH the keys stops being a convention and becomes a fact of where
        // they live: two runs sharing a trust file while holding different keys would be a device
        // presenting a chain for keys it does not have.
        guard let installations = FileRecordStore(directory: override,
                                                  name: FileRecordStore.installationName)
        else { return .failure(.storageUnavailable) }
        return assemble(
            signalingBase: signalingBase,
            installations: installations,
            trust: { FileRecordStore(directory: override) },
            pendingRoot: { FileRecordStore(directory: override, name: FileRecordStore.pendingRootName) },
            ceremonyOrigin: ceremonyOrigin)
    }

    /// **`trust` is a closure rather than a value so the order is a fact rather than a comment.**
    /// Constructing the real one creates a directory; a host whose origin cannot host a ceremony
    /// must not leave that behind.
    static func assemble(signalingBase: String, installations: InstallationStore.Backend,
                         trust: () -> InstallationStore.Backend?,
                         pendingRoot: () -> InstallationStore.Backend? = { MemoryRecord() },
                         ceremonyOrigin: E2EOrigin.Resolved? = nil)
        -> Result<E2EHostIdentity, Failure> {
        let resolved: E2EOrigin.Resolved
        switch E2EOrigin.resolve(signalingBase) {
        case .success(let r): resolved = r
        case .failure(let f): return .failure(.origin(f))
        }
        guard let trustStore = trust(), let pending = pendingRoot() else {
            return .failure(.storageUnavailable)
        }
        return .success(E2EHostIdentity(
            origin: resolved,
            manager: E2EIdentityManager(installations: installations, trust: trustStore),
            pendingRoot: pending,
            ceremonyOrigin: ceremonyOrigin))
    }

    /// Who this device is and what it should do next. Creates keys if and only if none exist.
    public func load() -> Result<E2EIdentityManager.Loaded, E2EIdentityManager.Failure> {
        manager.load()
    }

    /// **§10.3's `root → A → B`: issue a connect-only grant over `device`.**
    ///
    /// The caller is the native app's own client window, which lives at `app://client/` and can
    /// run no passkey ceremony of its own (§2, profile P-A). This device already holds the
    /// authority — a direct grant carries `enroll` — so the renderer becomes a device like any
    /// other rather than a special case in the session machine.
    ///
    /// Returns the FULL bundle the subordinate stores: root, this device's certificates, and the
    /// new one. `operationID` and `randomness` are fresh per call and never reused.
    ///
    /// **The caller supplies KEYS, not a descriptor, and this side names the root.** A §10.2
    /// descriptor names the root it belongs to, and the renderer cannot know that value before it
    /// has a chain — it would have to be told, and then it would be trusting the same answer with
    /// an extra round trip. So the descriptor is assembled HERE, and the renderer's check is the
    /// one that matters anyway: the leaf of the returned chain must carry the two public keys it
    /// generated. A root it did not expect changes nothing it can use.
    public func issueSubordinateGrant(signingPublicKey: [UInt8], noisePublicKey: [UInt8],
                                      capabilities: E2EIdentity.Capabilities = .connectOnly)
        -> Result<[UInt8], E2ESubordinateGrant.Failure> {
        guard case .success(let loaded) = manager.load(),
              let root = loaded.record.root, let bundle = loaded.record.bundle else {
            return .failure(.notEnrolled)
        }
        guard let device = E2EIdentity.device(rootID: E2EIdentity.rootID(root),
                                              signingPublicKey: signingPublicKey,
                                              noisePublicKey: noisePublicKey) else {
            return .failure(.malformedDevice)
        }
        return E2ESubordinateGrant.issue(
            to: device, ownRoot: root, ownBundle: bundle,
            signingPrivateKey: loaded.installation.keys.signingPrivateKey,
            operationID: E2EOperation.newID(),
            randomness: DeviceIdentity.systemRandom(E2EIdentity.idLength),
            policy: policy, capabilities: capabilities)
    }

    /// **§12.2's publication, attempted once for a grant this device just committed.**
    ///
    /// Publication is best-effort with a bounded wait, so this returns a status and never an error:
    /// §12.2 changed that deliberately from an earlier revision where a completed registration was a
    /// precondition for access, because an honest Worker outage would otherwise leave a correctly
    /// enrolled device unusable. **Nothing here can fail an enrollment.**
    ///
    /// `reporterHoldsPublicationJob: true` when storing the result, because this device IS the
    /// endpoint holding the job — which is exactly the case §12.2 says may lower the stored value.
    @discardableResult
    public func registerGrant(operationID: [UInt8],
                              transport: E2EDirectoryClient.Transport = LiveDirectoryTransport())
        async -> E2EWire.PublicationStatus {
        guard case .success(let loaded) = manager.load(),
              let root = loaded.record.root, let bundle = loaded.record.bundle else {
            // Nothing committed is nothing to publish. Not a failure — there is no job.
            return .unconfirmed
        }
        let status = await E2EDirectoryClient(origin: origin.url, transport: transport)
            .registerGrant(bundle: bundle, operationID: operationID,
                           rootID: E2EIdentity.rootID(root),
                           signingPrivateKey: loaded.installation.keys.signingPrivateKey)
        _ = manager.recordPublicationStatus(status, reporterHoldsPublicationJob: true,
                                            in: loaded.record)
        return status
    }

    /// **§12.2's transient retry, which this host did not have.**
    ///
    /// The spec's table is explicit that a transient failure — "timeout, connection refused, DNS or
    /// TLS failure, `5xx`, `429`, `404` (a deployment may be in progress), and any reply that did
    /// not arrive" — retries **"automatic, idempotent, across restarts"**. `registerGrant` above
    /// runs ONCE, after an enrollment, and returns `.unconfirmed` when it fails. Nothing drained
    /// that. So a Mac enrolled while the Worker was unreachable stayed unpublished for the life of
    /// the installation, while the browser side healed itself on every dashboard visit
    /// (`registerWithDirectory`).
    ///
    /// **That is what makes a legitimate identity look stranded**, and it is why `docs/e2e.md`
    /// forbids reading a `404` from the credential index as evidence that a passkey is unused: an
    /// unretried registration answers exactly as a genuinely abandoned passkey does.
    ///
    /// **Idempotent means the GRANT'S OWN operation id.** §12.2 keys idempotence on
    /// `(root_id, operation_id)`, so reusing the operation the grant was issued under makes a retry
    /// free; minting a fresh one would open a second operation for the same grant. The browser does
    /// the same thing for the same reason.
    ///
    /// Nil means there was nothing to do — no committed chain, already `confirmed`, or `rejected`,
    /// which §12.2 separates from `unconfirmed` by RETRY POLICY rather than by meaning: a refusal is
    /// permanent and needs a person, and retrying it would hammer the Worker while hiding the one
    /// status somebody is required to be shown.
    @discardableResult
    public func retryRegistration(transport: E2EDirectoryClient.Transport = LiveDirectoryTransport())
        async -> E2EWire.PublicationStatus? {
        guard case .success(let loaded) = manager.load(),
              loaded.record.root != nil, let bundle = loaded.record.bundle else { return nil }
        switch loaded.record.publicationStatus {
        case .confirmed, .rejected: return nil
        // Absent counts as outstanding: a process that died between committing the chain and
        // recording a status has a job nobody has done.
        case .unconfirmed, nil: break
        }
        guard case .success(let parsed) = E2ECertificate.parseBundle(bundle),
              let leaf = parsed.certificates.last,
              let grant = E2EIdentity.parseGrant(leaf.grant) else { return nil }
        return await registerGrant(operationID: grant.operationID, transport: transport)
    }

    /// **Announce this Mac's live room under the root it belongs to.**
    ///
    /// This is what replaced `PUT /account/sessions` and its bearer token
    /// (`docs/superpowers/specs/2026-09-13-passkey-only-identity.md`). The authorisation is the same
    /// one `registerGrant` uses — a one-use Worker challenge and a body signed by this device's
    /// certified key — so there is no token to steal and the Worker learns a root id rather than a
    /// person. **A Mac with no committed chain publishes nothing**, which is not a failure: an
    /// unenrolled Mac has no identity to be listed under.
    ///
    /// **Nothing here can fail sharing.** The status is returned for a person to read, never for a
    /// caller to gate on; that rule came from the account implementation and is why the publisher
    /// never throws.
    public func publishSession(_ session: E2EDirectory.Session, operationID: [UInt8],
                               transport: E2EDirectoryClient.Transport = LiveDirectoryTransport())
        async -> E2EWire.PublicationStatus {
        guard case .success(let loaded) = manager.load(),
              let root = loaded.record.root, let bundle = loaded.record.bundle else {
            return .unconfirmed
        }
        return await E2EDirectoryClient(origin: origin.url, transport: transport)
            .publishSession(session, bundle: bundle, operationID: operationID,
                            rootID: E2EIdentity.rootID(root),
                            signingPrivateKey: loaded.installation.keys.signingPrivateKey)
    }

    /// Everything `/watch` needs, from the SAME record `listSessions` signs with — so the stream and
    /// the poll can never ask under different identities. Nil without a committed chain.
    public func directoryWatch() -> (url: URL, credentials: E2EDirectoryWatch.Credentials)? {
        guard case .success(let loaded) = manager.load(),
              let root = loaded.record.root, let bundle = loaded.record.bundle,
              case .success(let parsed) = E2ECertificate.parseBundle(bundle),
              let leaf = parsed.certificates.last,
              let grant = E2EIdentity.parseGrant(leaf.grant) else { return nil }
        let rootID = E2EIdentity.rootID(root)
        var components = URLComponents(url: origin.url, resolvingAgainstBaseURL: false)
        components?.scheme = origin.url.scheme == "https" ? "wss" : "ws"
        guard let base = components?.url else { return nil }
        let url = base.appendingPathComponent("directory")
            .appendingPathComponent(base64urlEncode(Data(rootID)))
            .appendingPathComponent("watch")
        return (url, .init(bundle: bundle, rootID: rootID,
                           signingPrivateKey: loaded.installation.keys.signingPrivateKey,
                           ownDeviceID: base64urlEncode(Data(E2EIdentity.deviceID(grant.device)))))
    }

    /// The other Macs in this identity, as the directory reports them.
    ///
    /// **THIS MAC'S OWN ROOM IS FILTERED OUT HERE, not by the caller.** It is in the listing — this
    /// device published it — and "connect to this Mac" is not an offer any interface should make.
    /// The device id is derived from the chain this device actually holds, so the filter cannot be
    /// fooled by a Worker labelling someone else's room with our id.
    ///
    /// Nil means the directory did not answer, which is a different thing to show a person than an
    /// empty identity.
    public func listSessions(operationID: [UInt8],
                             transport: E2EDirectoryClient.Transport = LiveDirectoryTransport())
        async -> [E2EDirectory.Session]? {
        guard case .success(let loaded) = manager.load(),
              let root = loaded.record.root, let bundle = loaded.record.bundle else { return nil }
        let rows = await E2EDirectoryClient(origin: origin.url, transport: transport)
            .listSessions(bundle: bundle, operationID: operationID,
                          rootID: E2EIdentity.rootID(root),
                          signingPrivateKey: loaded.installation.keys.signingPrivateKey)
        guard let rows else { return nil }

        guard case .success(let parsed) = E2ECertificate.parseBundle(bundle),
              let leaf = parsed.certificates.last,
              let grant = E2EIdentity.parseGrant(leaf.grant) else { return rows }
        let ours = base64urlEncode(Data(E2EIdentity.deviceID(grant.device)))
        return rows.filter { $0.deviceID != ours }
    }

    /// Withdraw this Mac's room. Best effort, like everything else here: the 90 s TTL reaps it
    /// anyway, so quitting must never wait on a network round trip.
    @discardableResult
    public func unpublishSession(code: String, operationID: [UInt8],
                                 transport: E2EDirectoryClient.Transport = LiveDirectoryTransport())
        async -> E2EWire.PublicationStatus {
        guard case .success(let loaded) = manager.load(),
              let root = loaded.record.root, let bundle = loaded.record.bundle else {
            return .unconfirmed
        }
        return await E2EDirectoryClient(origin: origin.url, transport: transport)
            .unpublishSession(code: code, bundle: bundle, operationID: operationID,
                              rootID: E2EIdentity.rootID(root),
                              signingPrivateKey: loaded.installation.keys.signingPrivateKey)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A record kept in memory — a seeded test identity's retained passkey, which nothing must persist.
public final class MemoryRecord: InstallationStore.Backend, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]?
    public init() {}
    public func read() -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return bytes }
    public func write(_ b: [UInt8]) -> Bool { lock.lock(); bytes = b; lock.unlock(); return true }
    public func delete() -> Bool { lock.lock(); bytes = nil; lock.unlock(); return true }
}
