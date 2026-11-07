import Foundation

/// §10.2's durable trust state: "Store the trusted root, own grant chain, revocation tombstones,
/// pending operations, and committed registration records durably."
///
/// Separate from `DeviceIdentity`'s installation record on purpose. **The keys and the trust are
/// different things with different lifetimes**: §10.2 binds the keys and the rendezvous seed into
/// one record because "reinstallation generates both anew", while the root, the chain and the
/// tombstones are learned afterwards and survive everything except a reinstall. Keeping them apart
/// means losing trust state cannot cost the device its identity, and rotating keys cannot silently
/// keep a chain that no longer describes it.
///
/// **LOCAL ONLY.** No peer parses these bytes.
public enum E2ETrustStore {

    /// §12.4's "durable newcomer state", as it actually exists on disk.
    public struct Record: Equatable, Sendable {
        /// The §10.1 root descriptor this device trusts. **Nil means no identity yet**, and §10.1 is
        /// emphatic that an incoming chain may never replace one that is present: "Switching
        /// identity requires an explicit local reset/re-registration."
        public var root: [UInt8]?
        /// This device's own §10.4 bundle.
        public var bundle: [UInt8]?
        /// §12.2's status for the grant in `bundle`. Meaningless without one.
        public var publicationStatus: E2EWire.PublicationStatus?
        /// §10.5 tombstones this device has been told about. Applied to BOTH peers' chains before
        /// activating a session (§12.2), and irreversible.
        public var revokedDeviceIDs: Set<[UInt8]>
        /// An enrollment that was started and has not committed. §12.4: this is what makes `resume`
        /// possible rather than a fresh ceremony.
        public var pending: PendingOperation?

        public init(root: [UInt8]? = nil, bundle: [UInt8]? = nil,
                    publicationStatus: E2EWire.PublicationStatus? = nil,
                    revokedDeviceIDs: Set<[UInt8]> = [], pending: PendingOperation? = nil) {
            self.root = root
            self.bundle = bundle
            self.publicationStatus = publicationStatus
            self.revokedDeviceIDs = revokedDeviceIDs
            self.pending = pending
        }
    }

    /// §12.3: "persist trusted root + issuer ID + durable route + pending request" — everything a
    /// `resume` needs to find the same responder and finish the same operation.
    public struct PendingOperation: Equatable, Sendable {
        public let operationID: [UInt8]
        public let responderDeviceID: [UInt8]
        public let route: RendezvousRoute

        public init?(operationID: [UInt8], responderDeviceID: [UInt8], route: RendezvousRoute) {
            guard operationID.count == E2EWire.idLength,
                  responderDeviceID.count == E2EWire.idLength else { return nil }
            self.operationID = operationID
            self.responderDeviceID = responderDeviceID
            self.route = route
        }
    }

    /// §12.4's table, answered from what is actually stored rather than from a flag someone set.
    ///
    /// **`hasKeys` is a separate argument because it lives in a separate record.** A device whose
    /// installation is gone has lost its identity whatever its trust state says, and §10.2 gives
    /// that exactly one answer: "generating new keys and enrolling again".
    public static func nextAction(_ record: Record,
                                  hasKeys: Bool) -> E2EDirectory.NextAction {
        guard hasKeys else { return .generateNewKeysAndEnroll }
        if record.bundle != nil {
            // §12.4 distinguishes "committed chain, cleanup pending" from "committed and clean", and
            // a pending operation beside a committed chain is exactly that cleanup.
            return .auth(repeatCleanup: record.pending != nil)
        }
        if record.pending != nil { return .resume }
        return .freshEnrollment
    }

    // MARK: - encoding

    static let recordLabel = "rdev-e2e/trust/v1"
    /// No status stored. Outside `PublicationStatus`'s range on purpose — §7 rejects an unsupported
    /// enum value, so "absent" must not be spelled as one of the three that mean something.
    static let statusAbsent: UInt8 = 0xFF

    public static func encode(_ record: Record) -> [UInt8]? {
        guard let root = E2EWire.lengthPrefixed(record.root ?? []),
              let bundle = E2EWire.lengthPrefixed(record.bundle ?? []) else { return nil }

        var out = E2EWire.lp(recordLabel) + root + bundle
        out.append(record.publicationStatus?.rawValue ?? statusAbsent)

        if let pending = record.pending {
            guard let rcode = E2EWire.lengthPrefixed(Array(pending.route.rcode.utf8)),
                  let rtoken = E2EWire.lengthPrefixed(Array(pending.route.rtoken.utf8))
            else { return nil }
            out += [1] + pending.operationID + pending.responderDeviceID + rcode + rtoken
        } else {
            out += [0]
        }

        // Sorted, so the same set always encodes to the same bytes. A record that re-serialised
        // differently every time would make "did anything change?" unanswerable by comparison, which
        // is the cheapest check a caller has before a durable write.
        let tombstones = record.revokedDeviceIDs.sorted { $0.lexicographicallyPrecedes($1) }
        guard tombstones.count <= 0xFFFF else { return nil }
        out += [UInt8(tombstones.count >> 8), UInt8(tombstones.count & 0xFF)]
        for id in tombstones {
            guard id.count == E2EWire.idLength else { return nil }
            out += id
        }
        return out
    }

    public static func decode(_ bytes: [UInt8]) -> Record? {
        var r = E2EWire.Reader(bytes)
        guard r.expectLabel(recordLabel),
              let root = r.lengthPrefixed(),
              let bundle = r.lengthPrefixed(),
              let rawStatus = r.takeByte() else { return nil }

        let status: E2EWire.PublicationStatus?
        if rawStatus == statusAbsent {
            status = nil
        } else if let parsed = E2EWire.PublicationStatus(rawValue: rawStatus) {
            status = parsed
        } else {
            return nil          // §7: an unsupported enum value is a rejection
        }

        guard let hasPending = r.takeByte() else { return nil }
        var pending: PendingOperation?
        switch hasPending {
        case 0: break
        case 1:
            guard let operationID = r.take(E2EWire.idLength),
                  let responder = r.take(E2EWire.idLength),
                  let rcode = r.lengthPrefixed(),
                  let rcodeText = String(bytes: rcode, encoding: .utf8),
                  let rtoken = r.lengthPrefixed(),
                  let rtokenText = String(bytes: rtoken, encoding: .utf8),
                  let parsed = PendingOperation(
                      operationID: operationID, responderDeviceID: responder,
                      route: RendezvousRoute(rcode: rcodeText, rtoken: rtokenText))
            else { return nil }
            pending = parsed
        default:
            return nil
        }

        guard let countHigh = r.takeByte(), let countLow = r.takeByte() else { return nil }
        var revoked = Set<[UInt8]>()
        for _ in 0 ..< (Int(countHigh) << 8 | Int(countLow)) {
            guard let id = r.take(E2EWire.idLength) else { return nil }
            revoked.insert(id)
        }
        guard r.atEnd else { return nil }

        return Record(root: root.isEmpty ? nil : root,
                      bundle: bundle.isEmpty ? nil : bundle,
                      publicationStatus: status, revokedDeviceIDs: revoked, pending: pending)
    }

    // MARK: - the transitions that are rules

    public enum Failure: String, Error, Equatable, Sendable {
        /// §10.1: "An incoming chain is never allowed to replace an already trusted root."
        case rootAlreadyTrusted = "root-already-trusted"
        /// A chain was offered for a root this device does not trust.
        case rootMismatch = "root-mismatch"
        case noRoot = "no-root"
    }

    /// Adopt a root. **Only from nothing.** §10.1: "Switching identity requires an explicit local
    /// reset/re-registration; possession of a new passkey cannot remotely replace a Host's existing
    /// root." Replacing one is `reset`, which discards everything and says so.
    public static func adoptRoot(_ record: Record, root: [UInt8]) -> Result<Record, Failure> {
        if let existing = record.root {
            return existing == root ? .success(record) : .failure(.rootAlreadyTrusted)
        }
        var next = record
        next.root = root
        return .success(next)
    }

    /// Record this device's own committed chain, with the status §11.2 delivered beside it.
    public static func commitOwnChain(_ record: Record, bundle: [UInt8],
                                      status: E2EWire.PublicationStatus,
                                      rootID: [UInt8]) -> Result<Record, Failure> {
        guard let root = record.root else { return .failure(.noRoot) }
        guard E2EIdentity.rootID(root) == rootID else { return .failure(.rootMismatch) }
        var next = record
        next.bundle = bundle
        next.publicationStatus = status
        // §12.3: "persist committed chain; erase pairing secret and PENDING-ONLY state." The pending
        // operation is what the commit was for; keeping it would make §12.4 answer `resume` forever.
        next.pending = nil
        return .success(next)
    }

    /// §12.2's monotonic merge, applied to what is stored.
    public static func mergePublicationStatus(_ record: Record,
                                              reported: E2EWire.PublicationStatus,
                                              reporterHoldsPublicationJob: Bool) -> Record {
        var next = record
        next.publicationStatus = E2EDirectory.merge(
            stored: record.publicationStatus, reported: reported,
            reporterHoldsPublicationJob: reporterHoldsPublicationJob)
        return next
    }

    /// §10.5: an irreversible tombstone. Nothing here removes one.
    public static func revoke(_ record: Record, deviceID: [UInt8]) -> Record {
        guard deviceID.count == E2EWire.idLength else { return record }
        var next = record
        next.revokedDeviceIDs.insert(deviceID)
        return next
    }

    /// §10.1's "explicit local reset/re-registration". **Everything goes**, because a root is the
    /// anchor for all of it: a chain under the old root, a pending operation against the old
    /// Issuer, and tombstones naming devices of an identity this one no longer has.
    ///
    /// Tombstones going is worth stating rather than assuming: they are irreversible WITHIN an
    /// identity (§10.5), and this is the operation that ends the identity.
    public static func reset() -> Record { Record() }
}
