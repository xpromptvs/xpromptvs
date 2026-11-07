/// A source-scoped input lease is usable only after its current focus intent commits. This model
/// neither raises windows nor posts input: the host must serialize those operations and validate
/// `permits` around each final nonblocking post, not merely when a message enters a queue.
public struct SourceInputRoute: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let owner: String
        public let source: String?
        public let revision: UInt64
        public let request: String?
        fileprivate let ownerGeneration: UInt64
    }
    public private(set) var current: Ticket?
    public private(set) var lease: String?
    private var owner: String?
    private var ownerGeneration: UInt64 = 0
    private var exhausted = false
    private var issued = Set<String>()

    public init() {}

    /// `owner` identifies the actual admission/ownership lifetime, not a user-supplied hello field.
    /// Keep an internal generation too: A→B→A must not make an old captured ticket current again.
    public mutating func setOwner(_ value: String?) {
        let value = value.flatMap { $0.isEmpty ? nil : $0 }
        guard !exhausted, value != owner else { return }
        let (next, overflow) = ownerGeneration.addingReportingOverflow(1)
        exhausted = overflow; owner = overflow ? nil : value; ownerGeneration = next
        current = nil; lease = nil
    }

    /// Host revisions order focus intents published after a manager lock is released. A new native
    /// activation nonce may refresh the same source at the same revision; a stream/codec re-commit
    /// without a new nonce is idempotent and must not drain a live window's held keys.
    public mutating func intend(source: String?, revision: UInt64, request: String? = nil) -> Ticket? {
        guard let owner, !exhausted, source?.isEmpty != true, request?.isEmpty != true else { return nil }
        if let current {
            guard revision >= current.revision else { return nil }
            if revision == current.revision {
                guard source == current.source else { return nil }
                if request == nil || request == current.request { return current }
            }
        }
        let ticket = Ticket(owner: owner, source: source, revision: revision, request: request, ownerGeneration: ownerGeneration)
        current = ticket; lease = nil
        return ticket
    }

    /// Called only after the current source's injector/raise is ready. The caller generates a fresh
    /// opaque lease when the target changes; recommitting the same target can keep its existing lease.
    @discardableResult
    public mutating func commit(_ ticket: Ticket, lease proposed: String) -> Bool {
        guard ticket == current, owner == ticket.owner, ticket.ownerGeneration == ownerGeneration,
              ticket.source != nil, !proposed.isEmpty, !exhausted else { return false }
        if proposed == lease { return true }
        guard !issued.contains(proposed) else { return false }
        issued.insert(proposed); lease = proposed
        return true
    }

    public func permits(owner: String, source: String, lease proposed: String) -> Bool {
        guard let current, let lease, !exhausted else { return false }
        return self.owner == owner && current.owner == owner && current.ownerGeneration == ownerGeneration
            && current.source == source && lease == proposed
    }
}
