// host/RdevCore/Sources/RdevCore/StageStats.swift

/// A fixed-capacity ring of latency samples (milliseconds) with nearest-rank percentiles.
///
/// PERCENTILES, not means, because the tail is the interesting part: a p95 spike in `deliver`
/// against a flat p50 is a pacing or interceptor stall, and a mean hides it entirely.
///
/// Capacity bounds memory when a stage is recorded far faster than it is reported — 600 covers a
/// 5-second window at 60 fps with headroom, and dropping the oldest is the right loss (the
/// reporter clears after every window anyway).
public struct StageStats: Sendable {
    private var buf: [Double] = []
    private var next = 0
    private let capacity: Int

    public init(capacity: Int = 600) {
        self.capacity = max(1, capacity)
        buf.reserveCapacity(self.capacity)
    }

    public mutating func record(_ ms: Double) {
        if buf.count < capacity {
            buf.append(ms)
        } else {
            buf[next] = ms
            next = (next + 1) % capacity
        }
    }

    /// Samples currently HELD — capped at `capacity`, not a lifetime total.
    public var count: Int { buf.count }

    /// Nearest-rank percentile: the smallest sample at or above rank `ceil(p * n)`. nil when empty.
    public func percentile(_ p: Double) -> Double? {
        guard !buf.isEmpty else { return nil }
        let sorted = buf.sorted()
        let clamped = min(max(p, 0), 1)
        let rank = Int((clamped * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    public mutating func reset() {
        buf.removeAll(keepingCapacity: true)
        next = 0
    }
}
