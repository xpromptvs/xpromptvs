import Foundation

/// **A SLOW LINK GETS THE TERMINAL PACED** (docs/terminal.md). pion queues every message it is handed, unbounded, and
/// its SCTP send queue is ONE first-in-first-out for every channel on the association (`lane`, `bulk`; the SCTP
/// baseline's four). Handed straight to it, a burst of terminal frames — every tab re-sent after a re-declaration, a
/// claim, a grid change, a resume — sat in front of everything sent after it: a new wire's start, the echo of a
/// keystroke, a `control-state`. Measured at 100 kbit/s with five tabs of ~1900 lines (2026-10-11,
/// `scripts/term-slow-link-check.sh`): 9.4 s to a second wire's start, 15.7 s to a typed key's echo, 9.4 s to a control
/// answer — and what pion has been handed cannot be taken back.
///
/// So the host hands pion only what the path can deliver soon, and holds the rest where it CAN be reordered and
/// dropped: `TermPath` is the budget of one connection's terminal channel, `TermPacer` one wire's queue.

/// THE BUDGET OF ONE TERMINAL CHANNEL: how many unacknowledged bytes it may hold — the path's delivery rate times
/// (its base delay + `headroomNanos`), at least `floorBytes`. pion's `bufferedAmount` counts bytes handed and not yet
/// acknowledged, so `handed − buffered` is what the peer has acknowledged.
///
/// - **The base delay comes only from PRISTINE handoffs** — a frame handed to an empty channel — so it is the path's
///   round trip and the frame's own time on the wire, never time spent queued in pion. Sampled from every frame, it
///   RATCHETED under sustained load (review, 2026-10-11): each sample carried the queue the budget allowed, the next
///   budget grew by it, and pion's queue crept back to the defect. The least pristine sample in `baseWindowNanos`;
///   with none there (a long saturated stretch) the last one stands, never zero — zero collapsed a long-RTT path's
///   budget to rate × headroom.
/// - **The delivery rate** is acknowledged bytes over a span — half a second, or less once 256 KB have been
///   acknowledged (a fast path need not wait) — taken only while bytes wait: an idle path delivers what it is offered,
///   not what it can carry. The most of the samples within `rateWindowNanos` of the NEWEST one, so idle time does not
///   age it out and the next burst starts at the rate the path had.
/// - The base delay is IN the budget, so a long-RTT path is not held to a trickle; the headroom bounds how long anything
///   handed after a burst waits behind it.
///
/// Per CONNECTION, not per wire: a new wire's frames share the channel with what the old one already handed.
/// Thread-safe.
public final class TermPath: @unchecked Sendable {
    public static let headroomNanos: UInt64 = 250_000_000
    public static let floorBytes = 16 * 1024
    /// Before any rate is known: the floor. A fresh connection's first burst is its wire's snapshots of every tab, and
    /// at 64 KB a slow link held 5 s of them in pion before the rate was learned.
    public static let initialBytes = floorBytes
    public static let ceilingBytes = 4 * 1024 * 1024
    static let baseWindowNanos: UInt64 = 10_000_000_000
    static let rateWindowNanos: UInt64 = 5_000_000_000
    static let rateSampleNanos: UInt64 = 100_000_000
    /// A rate is measured over this long (acknowledgements come in lumps — a frame, a delayed SACK — and over 100 ms
    /// one lump read as many times the link's rate)…
    static let rateSpanNanos: UInt64 = 500_000_000
    /// …or over a shorter span once this much has been acknowledged in it: lumps are a small part of that.
    static let rateQuickBytes: UInt64 = 256 * 1024
    static let readingNanos: UInt64 = 10_000_000

    private let lock = NSLock()
    private var handedTotal: UInt64 = 0
    /// Handoffs not yet acknowledged, oldest first from `outstandingHead`: the cumulative byte count each ends at, when
    /// it was handed, and whether it found the channel empty (its ack delay is then the path's, not the queue's).
    private var outstanding: [(end: UInt64, at: UInt64, pristine: Bool)] = []
    private var outstandingHead = 0
    /// The least PRISTINE ack delay seen in each second of the window — a dozen entries at most, however many frames.
    private var baseSamples: [(second: UInt64, nanos: UInt64)] = []
    private var lastBase: UInt64?
    /// What had been acknowledged when, for a rate: a reading at most every `readingNanos`.
    private var readings: [(at: UInt64, acked: UInt64)] = []
    private var rates: [(at: UInt64, bytesPerSecond: Double)] = []
    /// Spans started again because the acknowledged count went BACKWARDS — a transport breaking the contract (pion's
    /// count only falls). Counted and logged (at most once per `resetLogNanos`): the crash this guards against left
    /// every counter reading healthy until the host died.
    private var spanResets = 0
    private var lastResetLogAt: UInt64?
    static let resetLogNanos: UInt64 = 10_000_000_000

    /// Transport-specific startup floor; measured capacity can still grow it to the common ceiling.
    private let minimumBytes: Int
    public init(minimumBytes: Int = TermPath.floorBytes) {
        precondition(minimumBytes > 0 && minimumBytes <= Self.ceilingBytes)
        self.minimumBytes = minimumBytes
    }

    /// `n` bytes went to pion at `now`, which held `heldBefore` unacknowledged.
    public func handed(_ n: Int, now: UInt64, heldBefore: Int) {
        lock.lock(); defer { lock.unlock() }
        handedTotal += UInt64(n)
        outstanding.append((handedTotal, now, heldBefore == 0))
    }

    /// The channel holds nothing: everything handed has been acknowledged — when, unknown, so no delay is sampled. A
    /// channel that never holds anything (a socket's) would otherwise keep an entry per frame for its whole life.
    public func drained(now: UInt64) {
        lock.lock(); defer { lock.unlock() }
        _ = settle(now: now, buffered: 0, sample: false)   // says nothing: only a sample reads the count going backwards
    }

    /// The bytes the channel may hold unacknowledged now, given that it holds `buffered`.
    ///
    /// Bounded as a Double BEFORE the Int conversion: `Int(_:)` TRAPS on a value past `Int.max` (or NaN), and a
    /// transport whose `buffered` did not keep `handed − buffered` from stepping back once made the rate 9e20 B/s —
    /// the host crashed (2026-10-12, the lane at 100 kbit/s). Whatever a reading says, the budget is at most the ceiling.
    public func budget(now: UInt64, buffered: Int) -> Int {
        lock.lock()
        let said = settle(now: now, buffered: buffered, sample: true)
        let rate = rates.map(\.bytesPerSecond).max(), base = lastBase
        lock.unlock()
        // Printed outside TermPath's lock, which `handed` takes too — though still inside the pacer's, whose drain asks
        // for the budget; at most once per `resetLogNanos`.
        if let said { print(said) }
        guard let rate, rate > 0 else { return minimumBytes }
        return Self.bounded(rate * Double((base ?? 0) + Self.headroomNanos) / 1e9, minimumBytes: minimumBytes)
    }

    /// A budget in bytes from a Double that may be anything a broken reading produced — NaN, infinite, past `Int.max` or
    /// `Int.min` — clamped to `floorBytes…ceilingBytes` BEFORE the conversion (`Int(_:)` traps outside Int's range and
    /// on NaN; the host died that way, 2026-10-12). NaN reads as the ceiling; −infinity, below the floor, as the floor.
    /// Static so a test can feed it the values no public path can reach any more.
    static func bounded(_ bytes: Double, minimumBytes: Int = floorBytes) -> Int {
        guard !bytes.isNaN else { return ceilingBytes }
        return Int(min(max(bytes, Double(minimumBytes)), Double(ceilingBytes)))
    }

    /// How soon a waiting queue should look again: half the base delay, 1–8 ms (2 ms before one is known) — a LAN's
    /// acknowledgements come back in a millisecond, and polling at 8 ms held a fast path to the floor per poll.
    public var pollNanos: UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard let base = lastBase else { return 2_000_000 }
        return min(8_000_000, max(1_000_000, base / 2))
    }

    /// For tests and logs.
    public var baseDelayNanos: UInt64? { lock.lock(); defer { lock.unlock() }; return lastBase }
    public var outstandingCount: Int { lock.lock(); defer { lock.unlock() }; return outstanding.count - outstandingHead }
    /// How often the acknowledged count went backwards (a transport that broke `handed − buffered`'s monotonicity).
    public var spanResetCount: Int { lock.lock(); defer { lock.unlock() }; return spanResets }

    /// Called under `lock`. Returns the span-reset log line, if one is due, for the caller to print once it has unlocked.
    private func settle(now: UInt64, buffered: Int, sample: Bool) -> String? {
        let held = UInt64(max(0, buffered))
        let acked = handedTotal > held ? handedTotal - held : 0
        let second = now / 1_000_000_000
        while outstandingHead < outstanding.count, outstanding[outstandingHead].end <= acked {
            let entry = outstanding[outstandingHead]
            if sample, entry.pristine {
                let delay = now &- entry.at
                if let last = baseSamples.last, last.second == second {
                    baseSamples[baseSamples.count - 1].nanos = min(last.nanos, delay)
                } else {
                    baseSamples.append((second, delay))
                }
            }
            outstandingHead += 1
        }
        if outstandingHead > 1024 || outstandingHead == outstanding.count {
            outstanding.removeFirst(outstandingHead); outstandingHead = 0
        }
        let windowSeconds = Self.baseWindowNanos / 1_000_000_000
        baseSamples.removeAll { second &- $0.second > windowSeconds }
        if let base = baseSamples.map(\.nanos).min() { lastBase = base }    // none in the window: the last stands

        guard sample else { return nil }
        // A gap with no reading (an idle channel nobody asked about) measures nothing: start the span again. So does
        // an acknowledged count that went BACKWARDS — not pion's (its count only falls), and a span across it would
        // read as 2⁶⁴ bytes delivered (the lane's buffered amount once counted a frame prefix it had not been handed).
        var said: String?
        if let last = readings.last, acked < last.acked {
            spanResets += 1
            if lastResetLogAt.map({ now &- $0 >= Self.resetLogNanos }) ?? true {
                lastResetLogAt = now
                said = "[pacer] the channel's acknowledged count went backwards (\(last.acked) → \(acked), handed \(handedTotal), buffered \(buffered)); the rate span starts again (\(spanResets) so far) — the transport's bufferedAmount is not pion's"
            }
            readings.removeAll()
        } else if let last = readings.last, now &- last.at > 2 * Self.rateSpanNanos {
            readings.removeAll()
        }
        if readings.last.map({ now &- $0.at >= Self.readingNanos }) ?? true { readings.append((now, acked)) }
        readings.removeAll { now &- $0.at > Self.rateSpanNanos + Self.rateSampleNanos }
        if outstandingHead < outstanding.count, let first = readings.first, let last = readings.last,
           rates.last.map({ now &- $0.at >= Self.rateSampleNanos }) ?? true {
            let span = last.at &- first.at, got = last.acked &- first.acked
            if span >= Self.rateSpanNanos || (span >= 2 * Self.readingNanos && got >= Self.rateQuickBytes) {
                rates.append((now, Double(got) / (Double(span) / 1e9)))
            }
        }
        // Within the window of the NEWEST sample, not of now: idle time does not age the rate out.
        if let newest = rates.last?.at { rates.removeAll { newest &- $0.at > Self.rateWindowNanos } }
        return said
    }
}
