import Foundation

/// Nearest-rank percentiles over a millisecond sample set. Nearest-rank rather than interpolated
/// so a reported value is always a value that actually occurred — the same convention
/// StageStats uses, and what LLV's recorded reports contain.
public struct ViewerDistribution: Codable, Equatable {
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let p99Milliseconds: Double
    public let minimumMilliseconds: Double
    public let maximumMilliseconds: Double
    public let count: Int

    // The Swift property stays `count` (matching what every call site and test in this task
    // reads), but the WIRE key is `sampleCount` -- the name LLV's recorded reports use for this
    // same field (verified against `host/streaming-engine/results/20260807/…/report.json`,
    // 534 occurrences of "sampleCount", zero of "count"). Matching the wire name is what makes a
    // later comparison a direct diff instead of a mapping exercise.
    private enum CodingKeys: String, CodingKey {
        case p50Milliseconds, p95Milliseconds, p99Milliseconds
        case minimumMilliseconds, maximumMilliseconds
        case count = "sampleCount"
    }

    /// Returns nil for an empty sample set: a distribution over nothing is not zero, it is absent,
    /// and encoding it as zero would read as a perfect result.
    public init?(samplesMs: [Double]) {
        guard !samplesMs.isEmpty else { return nil }
        let s = samplesMs.sorted()
        func rank(_ q: Double) -> Double {
            let i = Int((q * Double(s.count)).rounded(.up)) - 1
            return s[min(max(i, 0), s.count - 1)]
        }
        p50Milliseconds = rank(0.50)
        p95Milliseconds = rank(0.95)
        p99Milliseconds = rank(0.99)
        minimumMilliseconds = s.first!
        maximumMilliseconds = s.last!
        count = s.count
    }
}

public enum ViewerMetrics {
    /// The longest gap between consecutive decoded frames. Matches the definition behind
    /// `longestFreezeProxyMilliseconds` in LLV's recorded reports, so the two are comparable.
    public static func freezeProxy(interarrivalMs: [Double]) -> Double {
        interarrivalMs.max() ?? 0
    }

    /// Consecutive differences, in ms, from monotonic nanosecond timestamps.
    public static func interarrivalMs(nanoseconds: [UInt64]) -> [Double] {
        guard nanoseconds.count >= 2 else { return [] }
        return zip(nanoseconds.dropFirst(), nanoseconds).map { Double($0 &- $1) / 1_000_000 }
    }

    /// FAULT INJECTION, and the two forms a timing instrument can actually be wrong in:
    /// `scale` is a clock-RATE error (every gap multiplied) and `offsetMs` is a per-frame
    /// constant added to every gap. `(scale: 1, offsetMs: 0)` — the defaults — is the identity,
    /// so an uninjected run does not go through a different code path from an injected one.
    ///
    /// IT IS APPLIED TO THE INTERARRIVAL SERIES, NOT TO THE TIMESTAMPS, AND THAT IS FORCED
    /// RATHER THAN CHOSEN. A constant offset added to every decode TIMESTAMP is invisible in
    /// this metric — `t(n)+c − (t(n−1)+c)` is the original gap — so "shift the clock" is not a
    /// bias the instrument's derived quantities can express. The two forms here are: they move
    /// `decoderInterarrival`'s percentiles and `longestFreezeProxy` together, which is exactly
    /// what a real timestamping bias would do and exactly what an external check must catch.
    ///
    /// Clamped at 0: a gap is a duration, and a negative one would make `freezeProxy` describe
    /// an ordering that did not happen. A large negative `offsetMs` therefore floors the series
    /// rather than inverting it.
    public static func biasedInterarrivalMs(
        _ interarrivalMs: [Double], offsetMs: Double, scale: Double
    ) -> [Double] {
        guard offsetMs != 0 || scale != 1 else { return interarrivalMs }
        return interarrivalMs.map { max(0, $0 * scale + offsetMs) }
    }

    /// The bitrate `bitrate-controlled` is judged on: bytes over the seconds they arrived in.
    ///
    /// THE WINDOW IS THE CALLER'S AND IT IS MEASURED FROM NEGOTIATION, NOT FROM PROCESS START —
    /// `bytesReceived` only begins accumulating once the connection is up, so dividing by the
    /// whole wall clock would charge the measured bitrate for ICE gathering and the signaling
    /// round trip (roughly a 10% understatement on a 20 s run, entirely inside the assertion's
    /// band). What is testable here is the arithmetic and the guard.
    ///
    /// `seconds <= 0` returns 0 rather than dividing: `Double.infinity` converted to `Int` is a
    /// TRAP, so a run that ended in the same instant it negotiated would crash the instrument
    /// instead of reporting a bitrate it has no window for.
    public static func bitrateBps(bytes: Int, seconds: Double) -> Int {
        guard seconds > 0 else { return 0 }
        return Int(Double(bytes) * 8 / seconds)
    }

    /// Milliseconds from the host STAMPING a frame to the viewer DECODING it — one glass-to-glass
    /// sample, minus the display.
    ///
    /// THE SUBTRACTION IS 32-BIT AND WRAPPING, AND THAT IS THE WHOLE REASON THIS IS A FUNCTION.
    /// The host paints `UInt32(truncatingIfNeeded: unix epoch ms)` (`FrameOverlaySink` via
    /// `LatencyTimecode`), so the stamp is the LOW 32 BITS of a clock, not a clock. Two things
    /// follow, and both are silent when got wrong:
    ///
    ///  * `nowUnixMilliseconds` must be truncated the same way before comparing. A real epoch
    ///    millisecond has been above 2^32 since 1970 + 49.7 days, so this is not an edge case —
    ///    every single sample depends on it.
    ///  * The difference must WRAP (`&-`). The counter rolls over every ~49.7 days; a frame
    ///    stamped just before the rollover and decoded just after it has a numerically SMALLER
    ///    `now`, and a non-wrapping subtraction reports roughly minus fifty days of latency for
    ///    that frame. Fed into a percentile distribution, that one sample poisons the minimum and
    ///    is entirely plausible-looking in a p50.
    ///
    /// It lived inline in `ViewerRun.handleVideoFrame` — a file that shares a module with
    /// `main.swift` and is therefore unreachable from any test binary — where it was also DEAD:
    /// LLV's host paints no rdev stamp, so the llv arm decodes zero stamps and never ran it. The
    /// rdev arm is the first that does.
    public static func stampToDecodeMs(nowUnixMilliseconds: Int64, stamp: UInt32) -> Double {
        Double(UInt32(truncatingIfNeeded: nowUnixMilliseconds) &- stamp)
    }
}

/// "No frame has arrived for too long" — the condition that ends a run early.
public enum ViewerWatchdog {
    /// LOAD-BEARING: the clock starts at the LATER of the last decoded frame and NEGOTIATION.
    ///
    /// Two things follow from that `max`, and each is a bug without it. Arming on the first frame
    /// instead would make "no frame ever arrived" — the failure this exists to catch — wait out
    /// the whole run duration before being reported. And measuring from `lastFrameNanoseconds`
    /// alone would compare `now` against 0 before any frame has been decoded, which on a
    /// monotonic clock that has been running since boot is an enormous interval: the watchdog
    /// would fire on its first tick of every run, ending it before the connection could produce
    /// anything.
    ///
    /// Nanosecond subtraction wraps (`&-`) because `DispatchTime.uptimeNanoseconds` is unsigned
    /// and a caller may hand in timestamps taken in either order across threads.
    public static func expired(
        nowNanoseconds: UInt64, lastFrameNanoseconds: UInt64,
        negotiatedNanoseconds: UInt64, watchdogNanoseconds: UInt64
    ) -> Bool {
        let last = max(lastFrameNanoseconds, negotiatedNanoseconds)
        return nowNanoseconds &- last > watchdogNanoseconds
    }

    /// WHAT A TIMED-OUT RUN HAS TO SAY, all of it, in one place.
    ///
    /// "No frames arrived" has half a dozen causes that are indistinguishable from the report
    /// alone — ICE never connected, ICE connected and the control channel never opened, the
    /// channel opened and the claim was refused, everything worked and the host negotiated a
    /// codec we cannot decode — and the run is over by the time anyone reads it. So the failure
    /// carries every one of those readings rather than the caller remembering to print them.
    ///
    /// It is a FUNCTION so that "the dump lost a field" is a test failure. A message assembled by
    /// string concatenation at the throw site is exactly the kind of thing that quietly loses its
    /// most useful half in a later edit, and it is only ever read on a day nobody can reproduce.
    public static func failureDiagnostic(
        reason: String, connectionState: Int32, openChannels: [String],
        negotiatedCodec: String, controlState: ViewerControlState?, statsJSON: String
    ) -> String {
        let codec = negotiatedCodec.isEmpty ? "<none negotiated>" : negotiatedCodec
        let channels = openChannels.isEmpty ? "<none opened>" : openChannels.joined(separator: ",")
        let control = controlState.map { "active=\($0.active) clients=\($0.clients)" }
            ?? "<no control-state received>"
        return """
        \(reason)
          connectionState: \(connectionState)
          openChannels: \(channels)
          negotiatedCodec: \(codec)
          controlState: \(control)
          stats: \(statsJSON.isEmpty ? "<unavailable>" : statsJSON)
        """
    }
}

public enum ViewerAccounting {

    /// THREE OUTCOMES, NOT A BOOL — and the third is why.
    ///
    /// `encoded` is a LOWER BOUND (`HostStageLog`, and see its doc comment), so the two
    /// directions of a mismatch are not two magnitudes of one thing. A shortfall is a statement
    /// about the MEDIA; an overage is a statement about the READER, and reporting them through
    /// one boolean made a self-evident reader artifact present as fifteen lost frames.
    public enum Outcome: Equatable, Sendable {
        /// Within tolerance. The only outcome that reconciles.
        case reconciled
        /// `encoded - (decoded + dropped)` exceeds the tolerance: frames the sender counted that
        /// the receiver never accounted for. A real measurement, and a real failure.
        case unaccounted(Int)
        /// `decoded + dropped` EXCEEDS the sender's count. Physically impossible as frame loss —
        /// a receiver cannot decode what was never sent — so it is the lower bound being low,
        /// which is the ordinary end-of-run state (see `HostStageLog`). Not a failure, and not a
        /// pass either: the inputs for an accounting check simply were not available.
        case senderCountBelowDecoded(by: Int)
    }

    /// Every frame the host encoded must be accounted for as decoded or dropped, within a
    /// tolerance for frames still in flight when the run ended. This is a FRAME equation —
    /// `packetsLost` (RTP packets, not frames, and routinely repaired by NACK/RTX before the
    /// frame they belong to ever fails to decode) deliberately does not appear here; it stays a
    /// reported recovery metric (`ViewerReport.packetsLost`), not an accounting term.
    ///
    /// THE TOLERANCE IS ONE-DIRECTIONAL and applies to the SHORTFALL only: `encoded - (decoded +
    /// dropped)` reconciles anywhere in `[0, tolerance]`. Going the other way is
    /// `.senderCountBelowDecoded` at ANY tolerance — widening the band must never be able to
    /// convert a reader artifact into a pass, or a genuine over-count would hide behind it.
    public static func reconcile(
        encoded: Int, decoded: Int, dropped: Int, tolerance: Int
    ) -> Outcome {
        let diff = encoded - (decoded + dropped)
        if diff < 0 { return .senderCountBelowDecoded(by: -diff) }
        return diff <= tolerance ? .reconciled : .unaccounted(diff)
    }
}
