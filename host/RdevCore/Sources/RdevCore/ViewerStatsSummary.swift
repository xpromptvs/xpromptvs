import Foundation

/// One SOURCE's row of `decodeBySource`, i.e. what became of every frame the decoder was handed
/// that was attributed to that MSID.
///
/// WHY IT IS REPORTED PER SOURCE AT ALL. The aggregate counts cannot distinguish "both windows
/// delivered" from "every frame was attributed to the first window", and the second is exactly
/// what an `EncodedImage`→MSID resolution that stopped working would look like: total frames
/// unchanged, every assertion green. `ViewerSession::StatsJSON` sums the top-level totals FROM
/// these rows, so the two can never disagree about the total — only about who it belonged to,
/// which is the question.
///
/// The timing pair is on `CLOCK_UPTIME_RAW`, the same clock `on_video_frame` receives in
/// `decoder_invoked_nanoseconds`. `invocationRegressions` counts invocations whose timestamp did
/// not advance past the previous one for that SSRC — counted at every frame by the C++ rather
/// than inferred from polled samples, because a poll cannot see between its own reads.
public struct ViewerSourceDecode: Codable, Equatable, Sendable {
    public let framesDecoded: Int
    public let decodesSkipped: Int
    public let decodeErrors: Int
    public let firstDecoderInvokedUptimeNs: UInt64
    public let lastDecoderInvokedUptimeNs: UInt64
    public let decoderInvocationRegressions: Int

    public init(framesDecoded: Int, decodesSkipped: Int, decodeErrors: Int,
                firstDecoderInvokedUptimeNs: UInt64, lastDecoderInvokedUptimeNs: UInt64,
                decoderInvocationRegressions: Int) {
        self.framesDecoded = framesDecoded
        self.decodesSkipped = decodesSkipped
        self.decodeErrors = decodeErrors
        self.firstDecoderInvokedUptimeNs = firstDecoderInvokedUptimeNs
        self.lastDecoderInvokedUptimeNs = lastDecoderInvokedUptimeNs
        self.decoderInvocationRegressions = decoderInvocationRegressions
    }

    /// The span between this source's first and last decoder invocation, in milliseconds. 0 when
    /// fewer than two invocations were recorded (both stamps are then the same instant, or zero).
    ///
    /// A gate reads this to check the DOMAIN as well as the ordering: a field that was silently
    /// microseconds, or a clock that never advanced, produces a span that bears no relation to
    /// the run's own duration while `decoderInvocationRegressions == 0` still reads perfectly.
    public var invocationSpanMilliseconds: Double {
        guard lastDecoderInvokedUptimeNs > firstDecoderInvokedUptimeNs else { return 0 }
        return Double(lastDecoderInvokedUptimeNs - firstDecoderInvokedUptimeNs) / 1_000_000
    }
}

/// One session's stats JSON, read once into typed fields.
///
/// WHY THIS IS A TYPE IN RdevCore AND NOT A HANDFUL OF SUBSCRIPTS AT THE CALL SITE. Every field
/// below is reached by a STRING LITERAL that has to match what `ViewerSession::StatsJSON`
/// (`host/rdev-viewer-webrtc/viewer_session.cc`) writes, and the failure mode of a literal that
/// drifts is silence: a renamed key, or the right name read from the wrong container, yields 0,
/// and 0 is a legal value for every count here. The report is then internally consistent, every
/// assertion still evaluates, and the number is simply wrong. Reading them in one place that a
/// test can reach is what makes that drift detectable — `ViewerStatsSummaryTests` feeds this a
/// fixture whose values are all DISTINCT and non-zero, so a key read from the wrong place
/// produces a value belonging to something else rather than a plausible zero.
///
/// The two containers are not interchangeable, and one name appears in BOTH:
///
///  * TOP LEVEL is the viewer's own decoder accounting — `framesDecoded` there counts decoder
///    invocations that produced a picture, and is the number `framesDropped` and
///    `accounting-reconciled` are defined against.
///  * `receive` is libwebrtc's inbound-rtp report, which ALSO carries a `framesDecoded`
///    (libwebrtc's own count, from a different vantage point). Reading that one instead would
///    change what the accounting equation means without changing anything a reader could see.
public struct ViewerStatsSummary: Equatable {

    /// "" when the session has not settled a codec (the C++ writes JSON null then, not ""), which
    /// is also what `codec-as-expected` compares against.
    public let negotiatedCodec: String

    // The decoder's own accounting. Top level, NOT `receive` — see the note above.
    public let framesDecoded: Int
    public let decodesSkipped: Int
    public let decodeErrors: Int
    /// Summed over every source. `decoderInvocationRegressions == 0` is the whole of the
    /// "`decoder_invoked_nanoseconds` is monotonic" claim, measured at every frame rather than
    /// sampled — so it is one number and not a distribution.
    public let decoderInvocationRegressions: Int
    /// The same three counts plus timing, PER MSID. Empty when the session decoded nothing, and
    /// carrying a "" key for frames the decoder could not attribute to any track — which rdev
    /// source ids can never be, so it cannot collide with a real one.
    public let decodeBySource: [String: ViewerSourceDecode]

    // libwebrtc's inbound-rtp report, under `receive`.
    /// KEYFRAMES ASSEMBLED FROM RTP, not keyframes this viewer's decoder produced — despite
    /// libwebrtc's spelling. It is incremented in `ReceiveStatisticsProxy::OnCompleteFrame`,
    /// before any decoder is invoked, so it describes the STREAM rather than the instrument.
    ///
    /// That is precisely what makes it the one number in this report directly comparable with a
    /// browser's: Chrome reads the same field out of the same library. `scripts/
    /// gate-viewer-browser-parity.sh` compares the two to within one keyframe, and asserts BOTH
    /// are non-zero first — a counter that never populated would otherwise satisfy "agrees within
    /// one" by reading 0 on both sides, which is a cross-check that cannot disagree.
    public let keyFramesDecoded: Int
    public let packetsLost: Int
    public let pliCount: Int
    public let firCount: Int
    public let bytesReceived: Int
    public let retransmittedBytesReceived: Int
    public let fecBytesReceived: Int

    /// The REQUEST, echoed back out of the session. nil means the key was absent, which is a
    /// different reading from "off"/0: `recovery-configured` reports nil as UNEVALUATED, because
    /// stats that could not be read at all say nothing about whether the flag reached the ABI.
    public let recovery: String?
    public let rtxMaxAgeMilliseconds: Int?
    /// The OUTCOME. Null until an answer exists, and null when the answer agreed no RTX age.
    public let negotiatedRecovery: String?
    public let negotiatedRTXTimeMilliseconds: Int?

    /// THE ACCOUNTING MAPPING, and it is a decision rather than a copy.
    ///
    /// The decoder is invoked once per assembled frame and every invocation lands in exactly one
    /// of `framesDecoded`, `decodesSkipped` or `decodeErrors`. `ViewerAccounting` reconciles
    /// `encoded - (decoded + dropped)` into `[0, tolerance]`, so DROPPED here means "the decoder
    /// was invoked and no picture came out" — which is skips PLUS errors.
    ///
    /// Skips are the ones that matter in practice: a run that joins mid-stream skips every frame
    /// until the first keyframe, and leaving those out of `dropped` would fail
    /// `accounting-reconciled` for a bookkeeping reason indistinguishable from real frame loss.
    /// Errors are folded in for the same reason, and are ALSO reported on their own
    /// (`decodeErrors`, asserted zero by the gates) so each signal still fails for its own cause
    /// instead of two assertions firing on one fault.
    ///
    /// Frames the sender encoded that never reached the decoder at all are in neither bucket;
    /// they appear as the shortfall the tolerance covers, which is precisely what Task 12's null
    /// run fixes that tolerance from.
    public var framesDropped: Int { decodesSkipped + decodeErrors }

    /// Reads the object `JSONSerialization` produced from `rdev_viewer_copy_stats`. An empty
    /// dictionary — which is what the caller passes when the copy or the parse failed — gives
    /// every count 0 and every optional nil, so a broken stats read is reported as "unavailable"
    /// by the assertions rather than as a clean zero run.
    public init(stats: [String: Any]) {
        let receive = stats["receive"] as? [String: Any] ?? [:]
        func number(_ container: [String: Any], _ key: String) -> Int? {
            (container[key] as? NSNumber)?.intValue
        }
        func count(_ container: [String: Any], _ key: String) -> Int {
            number(container, key) ?? 0
        }

        negotiatedCodec = stats["negotiatedVideoCodec"] as? String ?? ""
        framesDecoded = count(stats, "framesDecoded")
        decodesSkipped = count(stats, "decodesSkipped")
        decodeErrors = count(stats, "decodeErrors")
        decoderInvocationRegressions = count(stats, "decoderInvocationRegressions")

        // The per-source rows. A row whose object cannot be read at all is DROPPED rather than
        // defaulted to zeros: an MSID present with every count zero is a real reading (a track
        // that was announced and delivered nothing), so manufacturing one would be indistinguishable
        // from it — and that is precisely the reading the multi-source assertions turn on.
        var rows: [String: ViewerSourceDecode] = [:]
        for (msid, value) in (stats["decodeBySource"] as? [String: Any] ?? [:]) {
            guard let row = value as? [String: Any] else { continue }
            func unsigned(_ key: String) -> UInt64 {
                (row[key] as? NSNumber)?.uint64Value ?? 0
            }
            rows[msid] = ViewerSourceDecode(
                framesDecoded: count(row, "framesDecoded"),
                decodesSkipped: count(row, "decodesSkipped"),
                decodeErrors: count(row, "decodeErrors"),
                firstDecoderInvokedUptimeNs: unsigned("firstDecoderInvokedUptimeNs"),
                lastDecoderInvokedUptimeNs: unsigned("lastDecoderInvokedUptimeNs"),
                decoderInvocationRegressions: count(row, "decoderInvocationRegressions"))
        }
        decodeBySource = rows

        keyFramesDecoded = count(receive, "keyFramesDecoded")
        packetsLost = count(receive, "packetsLost")
        pliCount = count(receive, "pliCount")
        firCount = count(receive, "firCount")
        bytesReceived = count(receive, "bytesReceived")
        retransmittedBytesReceived = count(receive, "retransmittedBytesReceived")
        fecBytesReceived = count(receive, "fecBytesReceived")

        recovery = stats["recovery"] as? String
        rtxMaxAgeMilliseconds = number(stats, "rtxMaxAgeMilliseconds")
        negotiatedRecovery = stats["negotiatedRecovery"] as? String
        negotiatedRTXTimeMilliseconds = number(stats, "negotiatedRTXTimeMilliseconds")
    }
}
