import Foundation

/// One wire, one compressor. Only the final selected raw record enters the codec.
/// Admission and retirement are called under the wire lock; timer drains take only
/// this lock. Transport send must be nonblocking and must not reenter the pacer.
public final class SharedTermPacer: @unchecked Sendable {
    public enum Lane: Sendable { case regular, snapshot, closed, history }
    public enum Failure: Sendable { case overloaded, transport, codec }
    public struct Deps: Sendable {
        public var send: @Sendable (Data) -> Void
        /// Unacknowledged transport bytes; nil retires the wire before further compression.
        public var buffered: @Sendable () -> Int?
        public var now: @Sendable () -> UInt64
        /// Run the drain after this many nanoseconds.
        public var schedule: @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void
        /// The tab on screen (its wire id), read OUTSIDE this pacer's lock.
        public var activeTab: @Sendable () -> String?
        public init(send: @escaping @Sendable (Data) -> Void, buffered: @escaping @Sendable () -> Int?,
                    now: @escaping @Sendable () -> UInt64,
                    schedule: @escaping @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void,
                    activeTab: @escaping @Sendable () -> String?) {
            self.send = send; self.buffered = buffered; self.now = now; self.schedule = schedule; self.activeTab = activeTab
        }
    }
    public static let activeRun = 4
    public static let historyEvery = 8
    private struct Record {
        let batch: TermRawBatch
        let index: Int
        let snapshot: Bool
    }
    // Nil consumed slots release backing immediately; no removeFirst payload shifts.
    private final class FIFO {
        var entries: [Record?] = []
        var head = 0
        var first: Record? { head < entries.count ? entries[head] : nil }
        var isEmpty: Bool { head == entries.count }
        func append(_ r: Record) { entries.append(r) }
        func pop() -> Record? {
            guard let r = first else { return nil }
            entries[head] = nil; head += 1
            if head >= 1024 && head * 2 >= entries.count { entries.removeFirst(head); head = 0 }
            return r
        }
    }
    private enum Pick { case tab(String), history(String) }
    private enum Share { case regular, due, spare }
    private let lock = NSLock()
    private let path: TermPath
    private let d: Deps
    private let capacity: Int
    private let messageCeiling: Int
    private let epoch: UInt64
    private let failed: @Sendable (Failure) -> Void
    private let queue: TermRawQueue
    private var encoder: TermZstdEncoder?
    private var sequence: UInt64 = 0
    private var started = false
    private var begun = false
    private var retired = false
    private var draining = false
    private var tabFrames: [String: FIFO] = [:]
    private var historyFrames: [String: FIFO] = [:]
    private var turn: [String] = []
    private var historyTurn: [String] = []
    private var snapshotsQueued: [String: Int] = [:]
    private var activeStreak = 0
    private var sinceHistory = 0
    private var lastActive: String?

    public init(path: TermPath, deps: Deps, epoch: UInt64, messageCeiling: Int,
                capacity: Int = TermPath.ceilingBytes,
                maximumBytes: Int = 64 * 1024 * 1024, maximumRecords: Int = 65_536,
                failed: @escaping @Sendable (Failure) -> Void) {
        precondition(epoch > 0 && messageCeiling > 128 && messageCeiling <= TermWireMessage.maximumBytes)
        precondition(capacity >= messageCeiling && maximumBytes >= messageCeiling)
        self.path = path; d = deps; self.epoch = epoch; self.messageCeiling = messageCeiling
        self.capacity = capacity; self.failed = failed
        // Include the selected record's temporary contiguous raw copy in the limit.
        queue = TermRawQueue(maximumBytes: maximumBytes - messageCeiling, maximumRecords: maximumRecords)
    }
    public var queuedBytes: Int { lock.lock(); defer { lock.unlock() }; return queue.retainedBytes }
    public var allocatedCodecBytes: Int { lock.lock(); defer { lock.unlock() }; return encoder?.allocatedBytes ?? 0 }
    public func begin() {
        lock.lock(); defer { lock.unlock() }
        begun = true; drainLocked(active: lastActive)
    }
    public func admit(tab: String, lane: Lane, rawBytes: Int, recordCount: Int,
                      build: () -> TermRawBatch?) -> TermAdmission {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { return .retired }
        if lane == .snapshot || lane == .closed { cancelHistory(tab) }
        let (result, batch) = queue.admit(rawBytes: rawBytes, recordCount: recordCount, build: build)
        guard result == .accepted, let batch else {
            if result == .overloaded { failLocked(.overloaded) }
            return result
        }
        guard batch.tab == tab else { failLocked(.codec); return .invalid }
        if lane == .history {
            if historyFrames[tab] == nil { historyFrames[tab] = FIFO(); historyTurn.append(tab) }
            for i in 0..<batch.recordCount { historyFrames[tab]!.append(Record(batch: batch, index: i, snapshot: false)) }
        } else {
            if tabFrames[tab] == nil { tabFrames[tab] = FIFO(); turn.append(tab) }
            for i in 0..<batch.recordCount { tabFrames[tab]!.append(Record(batch: batch, index: i, snapshot: lane == .snapshot)) }
            if lane == .snapshot { snapshotsQueued[tab, default: 0] += batch.recordCount }
        }
        begun = true; drainLocked(active: lastActive)
        // Admission is irrevocable: a partial handoff may already contain a query.
        // Retirement can void its credit, but must never invite a second host reply.
        return .accepted
    }
    public func retire() { lock.lock(); defer { lock.unlock() }; retireLocked() }
    private func retireLocked() {
        retired = true; encoder = nil; queue.retire()
        tabFrames.removeAll(); historyFrames.removeAll(); turn.removeAll(); historyTurn.removeAll(); snapshotsQueued.removeAll()
    }
    private func failLocked(_ failure: Failure) {
        guard !retired else { return }
        retireLocked()
        // Never call into the owner on a drain/emit stack. The owner's epoch fence
        // additionally serializes with its wire before entering the hub.
        let callback = failed
        DispatchQueue.global().async { [self] in
            lock.lock(); lock.unlock()
            callback(failure)
        }
    }
    private func cancelHistory(_ tab: String) {
        if let frames = historyFrames.removeValue(forKey: tab) {
            while let r = frames.pop() { queue.releaseRecord(of: r.batch) }
            historyTurn.removeAll { $0 == tab }
            if historyFrames.isEmpty { sinceHistory = 0 }
        }
    }
    private func drain() {
        let active = d.activeTab()
        lock.lock(); defer { lock.unlock() }
        draining = false
        guard !retired else { return }
        guard let held = d.buffered(), held >= 0 else { failLocked(.transport); return }
        // This is a scheduled observation, not a later enqueue after an idle gap.
        // Sample even the final ACK: otherwise only congested partial ACKs teach
        // the base delay, and the next burst inherits an inflated queue budget.
        _ = path.budget(now: d.now(), buffered: held)
        lastActive = active; drainLocked(active: active)
    }
    private func drainLocked(active: String?) {
        guard begun && !retired else { return }
        if !started, let held = fits(.regular) {
            do {
                let codec = try TermZstdEncoder()
                let message = TermWireMessage.start(epoch: epoch, compressed: try codec.flush(Data(0..<32))).encoded()
                guard message.count <= messageCeiling else { throw TermWireMessage.Failure.malformed }
                encoder = codec; started = true
                path.handed(message.count, now: d.now(), heldBefore: held); d.send(message)
            } catch { failLocked(.codec) }
        }
        while !retired && started, let (pick, record) = peek(active: active) {
            let share: Share
            if case .history = pick { share = historyDue ? .due : .spare } else { share = .regular }
            guard let held = fits(share) else { break }
            do {
                let raw = record.batch.record(at: record.index)
                guard let encoder, sequence < UInt64.max else { throw TermWireMessage.Failure.malformed }
                let message = TermWireMessage.data(epoch: epoch, sequence: sequence, rawLength: UInt32(raw.count),
                                                  compressed: try encoder.flush(raw)).encoded()
                guard message.count <= messageCeiling else { throw TermWireMessage.Failure.malformed }
                sequence += 1
                path.handed(message.count, now: d.now(), heldBefore: held); d.send(message)
                pop(pick, active: active)
            } catch { failLocked(.codec) }
        }
        guard !retired else { return }
        guard let held = d.buffered(), held >= 0 else { failLocked(.transport); return }
        // Keep observing until transport acknowledgement, then stop completely.
        // Empty sockets never arm this timer; retirement fences any pending poll.
        if (!started || !tabFrames.isEmpty || !historyFrames.isEmpty || held > 0) && !draining {
            draining = true; d.schedule(path.pollNanos) { [weak self] in self?.drain() }
        }
    }
    private func fits(_ share: Share) -> Int? {
        guard let held = d.buffered(), held >= 0 else { failLocked(.transport); return nil }
        if held == 0 { path.drained(now: d.now()); return 0 }
        let budget = min(capacity, path.budget(now: d.now(), buffered: held))
        let allowed = share == .spare ? budget / 2 : budget
        return held <= allowed - messageCeiling ? held : nil
    }
    private var historyDue: Bool { sinceHistory >= Self.historyEvery - 1 && !tabFrames.isEmpty }
    private func peek(active: String?) -> (Pick, Record)? {
        let h = nextHistory(active: active)
        if let h, historyDue { return (.history(h.0), h.1) }
        let other = turn.first { $0 != active }
        if let active, let r = tabFrames[active]?.first, activeStreak < Self.activeRun || other == nil { return (.tab(active), r) }
        if let other, let r = tabFrames[other]?.first { return (.tab(other), r) }
        if let active, let r = tabFrames[active]?.first { return (.tab(active), r) }
        if let h { return (.history(h.0), h.1) }
        return nil
    }
    private func nextHistory(active: String?) -> (String, Record)? {
        if let active, (snapshotsQueued[active] ?? 0) == 0, let r = historyFrames[active]?.first { return (active,r) }
        for t in historyTurn where (snapshotsQueued[t] ?? 0) == 0 { if let r = historyFrames[t]?.first { return (t,r) } }
        return nil
    }
    private func pop(_ pick: Pick, active: String?) {
        switch pick {
        case .history(let tab):
            sinceHistory = 0
            if let r = historyFrames[tab]?.pop() { queue.releaseRecord(of: r.batch) }
            historyTurn.removeAll { $0 == tab }
            if historyFrames[tab]?.isEmpty ?? true { historyFrames[tab] = nil } else { historyTurn.append(tab) }
        case .tab(let tab):
            if !historyFrames.isEmpty { sinceHistory += 1 }
            activeStreak = tab == active ? min(Self.activeRun, activeStreak + 1) : 0
            if let r = tabFrames[tab]?.pop() {
                queue.releaseRecord(of: r.batch)
                if r.snapshot { snapshotsQueued[tab, default: 1] -= 1; if snapshotsQueued[tab] == 0 { snapshotsQueued[tab] = nil } }
            }
            turn.removeAll { $0 == tab }
            if tabFrames[tab]?.isEmpty ?? true { tabFrames[tab] = nil } else { turn.append(tab) }
        }
    }
}
