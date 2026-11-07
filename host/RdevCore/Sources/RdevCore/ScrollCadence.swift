import Foundation

/// How evenly scroll events reach the host — the instrument behind `RDEV_SCROLL_PROBE=1`.
///
/// WHY THIS EXISTS. A trackpad swipe is mostly OS-generated deceleration: measured 2026-09-03 in
/// real Safari, one swipe produced 146 wheel events of which 137 were the coast, and those events
/// reach the PAGE with a median interval of 9.0 ms but a p95 deviation of 9.0 ms — i.e. macOS
/// delivers its own momentum unevenly, before the network is involved at all. rdev forwards each
/// event as it arrives and the host posts each as it arrives, so that unevenness is reproduced on
/// the remote machine plus whatever the wire adds.
///
/// The proposed fix is to feed the host's EXISTING 1/120 s momentum tick from arrivals rather than
/// only from a fling, so the app receives a smooth cadence. That costs latency on the most
/// latency-sensitive input path there is, and rdev has been here before: the video playout
/// controller was rebuilt six times because it measured its own OUTPUT instead of its INPUT. This
/// measures the input, and it commits to nothing.
///
/// PURE and testable: every value is a function of the timestamps handed in.
public struct ScrollCadence: Sendable {
    /// An interval longer than this ends a gesture rather than counting as jitter.
    ///
    /// LOAD-BEARING. A user pausing between two swipes is not a delivery problem, and counting the
    /// pause would make every window's spread a function of how long they paused — a number that is
    /// a property of nothing. 250 ms is far above a coast's own worst interval (67 ms measured) and
    /// far below any deliberate pause.
    public static let defaultGestureGap: TimeInterval = 0.25

    public struct Stats: Sendable, Equatable {
        /// Intervals measured — one fewer than the events in a gesture, summed across gestures.
        public let samples: Int
        public let gestures: Int
        public let medianMs: Double
        public let p95Ms: Double
        /// p95 of |interval − median|: HOW MUCH OF THE STREAM IS UNEVEN, which is what a buffer
        /// would have to absorb. Deliberately not the range — one hiccup should not stand in for
        /// the shape of a whole window.
        public let spreadMs: Double
        public let minMs: Double
        public let maxMs: Double
    }

    private let gestureGap: TimeInterval
    private var intervals: [Double] = []
    private var gestures = 0
    private var last: TimeInterval?

    public init(gestureGap: TimeInterval = ScrollCadence.defaultGestureGap) {
        self.gestureGap = gestureGap
    }

    public mutating func record(at t: TimeInterval) {
        defer { last = t }
        guard let prev = last else { gestures = 1; return }
        let dt = t - prev
        if dt > gestureGap { gestures += 1; return }   // a new gesture: the pause is not a sample
        intervals.append(dt * 1000)
    }

    /// Take the window's statistics and CLEAR, so each report describes its own window rather than
    /// an ever-growing average that stops responding to change. nil when nothing was measured —
    /// **a quiet window must print nothing, never zeroes**, which would claim a smooth stream about
    /// a host that saw no scrolling at all.
    public mutating func drain() -> Stats? {
        guard !intervals.isEmpty else { intervals = []; gestures = 0; return nil }
        let sorted = intervals.sorted()
        let median = ScrollCadence.percentile(sorted, 0.5)
        let devs = sorted.map { abs($0 - median) }.sorted()
        let s = Stats(
            samples: sorted.count,
            gestures: max(gestures, 1),
            medianMs: median,
            p95Ms: ScrollCadence.percentile(sorted, 0.95),
            spreadMs: ScrollCadence.percentile(devs, 0.95),
            minMs: sorted.first!,
            maxMs: sorted.last!)
        intervals = []
        gestures = 0
        return s
    }

    /// The report line, or nil for a quiet window. RETURNS rather than prints, so stdio can never
    /// block whichever queue is recording — the rule `recordOutput` already follows.
    public mutating func report(source: String) -> String? {
        guard let s = drain() else { return nil }
        return String(format:
            "[scroll] %@ n=%d gestures=%d p50=%.1f p95=%.1f spread=%.1f min=%.1f max=%.1f ms",
            source, s.samples, s.gestures, s.medianMs, s.p95Ms, s.spreadMs, s.minMs, s.maxMs)
    }

    /// Nearest-rank, matching `StageStats.percentile` so two instruments in one log agree.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(1, Int((p * Double(sorted.count)).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }
}
