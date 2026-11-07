import Foundation
import RdevCore

/// Host-side stage timings for the latency probe (`RDEV_LATENCY_PROBE=1`).
///
/// Three spans per source:
///
///   overlay  buffer arrival -> forwarded to the encoder   the instrument's OWN cost, so it can be
///                                                          subtracted honestly rather than assumed
///                                                          negligible
///   encode   submit -> encoder callback                    VideoToolbox or SVT-AV1
///   deliver  callback -> writeTrackVideo returned          PION: packetize, interceptors, SRTP,
///                                                          socket write
///
/// `deliver` is the one that does not exist in any other form. Client-side `receiverStats` already
/// breaks out jitter buffer and decode, and encode has been measured before — but the span between
/// the encoder's callback and bytes reaching the socket has never been observed, and that is
/// precisely the pion part. `TrackSink.writeVideo` is a SYNCHRONOUS cgo call into `WriteSample`, so
/// timing the fan-out captures it whole with no Go-side instrumentation and no new ABI.
///
/// PERCENTILES, and PERIODIC. Percentiles because the tail is the interesting part — a p95 spike in
/// `deliver` against a flat p50 is a pacing or interceptor stall, and a mean hides it. Periodic
/// because at 60 fps a per-frame log would itself perturb what it measures.
///
/// Reads the environment directly rather than taking a `HostConfig`, matching `AV1Encoder`
/// (`RDEV_AV1_PRESET`): the encoders that record `encode` and `deliver` have no config to thread.
final class LatencyStages: @unchecked Sendable {
    enum Stage: String, CaseIterable { case overlay, encode, deliver }

    static let enabled = ProcessInfo.processInfo.environment["RDEV_LATENCY_PROBE"] == "1"
    static let shared = LatencyStages()

    private let lock = NSLock()
    private var stats: [String: [Stage: StageStats]] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "rdev.latency.stages")

    func record(_ stage: Stage, source: String, ms: Double) {
        guard LatencyStages.enabled else { return }
        lock.lock()
        var bySource = stats[source] ?? [:]
        var s = bySource[stage] ?? StageStats()
        s.record(ms)
        bySource[stage] = s
        stats[source] = bySource
        let needsTimer = timer == nil
        lock.unlock()
        if needsTimer { startReporting() }
    }

    /// Started lazily on the first sample, so a host that never encodes never arms a timer.
    private func startReporting() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }   // re-checked under the lock: two threads can race here
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        t.setEventHandler { [weak self] in self?.report() }
        timer = t
        lock.unlock()
        t.resume()
    }

    /// Print one line per source and CLEAR, so each line describes its own 5-second window rather
    /// than an ever-growing average that stops responding to change.
    private func report() {
        lock.lock(); let snapshot = stats; stats = [:]; lock.unlock()
        for (source, bySource) in snapshot.sorted(by: { $0.key < $1.key }) {
            let n = bySource[.encode]?.count ?? 0
            let parts = Stage.allCases.map { st -> String in
                guard let s = bySource[st], let p50 = s.percentile(0.5), let p95 = s.percentile(0.95) else {
                    return "\(st.rawValue) -"
                }
                return String(format: "%@ p50=%.1f p95=%.1f", st.rawValue, p50, p95)
            }
            print("[latency] \(source) n=\(n) \(parts.joined(separator: " · ")) ms")
        }
    }
}
