/// A native source view is owned by one connection lifetime and one source incarnation.
/// The bridge validates source identifiers; this model deliberately treats them as opaque keys.
public struct NativeSourceWindowKey: Hashable, Sendable {
    public let owner: Int
    public let generation: UInt64
    public let source: String
    public let incarnation: UInt64

    public init(owner: Int, generation: UInt64, source: String, incarnation: UInt64) {
        self.owner = owner; self.generation = generation
        self.source = source; self.incarnation = incarnation
    }
}

/// One-use internal popup permits. Retire before closing a native view, so delayed page/native
/// callbacks cannot consume an old ticket or remove a newer window with the same source ID.
public struct NativeSourceWindowTickets: Sendable {
    private struct Source: Hashable, Sendable { let owner: Int; let id: String }
    private struct Owner: Sendable { let generation: UInt64; let retired: Bool }
    private struct Entry: Sendable { let key: NativeSourceWindowKey; var pending: String? }
    private var owners: [Int: Owner] = [:]
    private var entries: [Source: Entry] = [:]
    private var pending: [String: NativeSourceWindowKey] = [:]
    private var issued = Set<String>()
    private var incarnations: [Source: UInt64] = [:]

    public init() {}

    public mutating func prepare(owner: Int, generation: UInt64, source: String, ticket: String) -> NativeSourceWindowKey? {
        guard !source.isEmpty, !ticket.isEmpty, !issued.contains(ticket) else { return nil }
        if let current = owners[owner] {
            guard generation >= current.generation else { return nil }
            if generation == current.generation {
                guard !current.retired else { return nil }
            } else {
                retireEntries(owner: owner)
                owners[owner] = Owner(generation: generation, retired: false)
            }
        } else { owners[owner] = Owner(generation: generation, retired: false) }
        let id = Source(owner: owner, id: source)
        guard entries[id] == nil else { return nil }
        let (next, overflow) = (incarnations[id] ?? 0).addingReportingOverflow(1)
        guard !overflow else { return nil }
        let key = NativeSourceWindowKey(owner: owner, generation: generation, source: source, incarnation: next)
        incarnations[id] = next
        issued.insert(ticket); pending[ticket] = key
        entries[id] = Entry(key: key, pending: ticket)
        return key
    }

    public mutating func consume(ticket: String, owner: Int, generation: UInt64) -> NativeSourceWindowKey? {
        guard let key = pending[ticket], key.owner == owner, key.generation == generation,
              let current = owners[owner], current.generation == generation, !current.retired else { return nil }
        let id = Source(owner: owner, id: key.source)
        guard var entry = entries[id], entry.key == key, entry.pending == ticket else { return nil }
        pending.removeValue(forKey: ticket)
        entry.pending = nil; entries[id] = entry
        return key
    }

    public func contains(_ key: NativeSourceWindowKey) -> Bool {
        guard let owner = owners[key.owner], owner.generation == key.generation, !owner.retired,
              let entry = entries[Source(owner: key.owner, id: key.source)] else { return false }
        return entry.key == key && entry.pending == nil
    }

    public mutating func retire(owner: Int, generation: UInt64) {
        if let current = owners[owner], generation < current.generation { return }
        retireEntries(owner: owner)
        owners[owner] = Owner(generation: generation, retired: true)
    }

    public mutating func retire(key: NativeSourceWindowKey) {
        let id = Source(owner: key.owner, id: key.source)
        guard let entry = entries[id], entry.key == key else { return }
        if let ticket = entry.pending { pending.removeValue(forKey: ticket) }
        entries.removeValue(forKey: id)
    }

    private mutating func retireEntries(owner: Int) {
        for id in entries.keys.filter({ $0.owner == owner }) {
            if let ticket = entries[id]?.pending { pending.removeValue(forKey: ticket) }
            entries.removeValue(forKey: id)
        }
    }
}
