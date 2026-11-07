// host/RdevCore/Sources/RdevCore/InputToDecode.swift

/// Turns a run's raw records — what the harness SENT, and what the receiver DECODED — into latency
/// samples, each split at the moment the application itself reacted.
///
/// WHY THE SPLIT IS THE POINT. `tools/InputLatencyTarget` repaints only in response to input, and
/// stamps the frame with both a wall clock and the ordinal of the input that caused the repaint. So
/// a decoded frame carries the moment the APP reacted to input N, and one measured interval becomes
/// two:
///
///     send -> stamp     the INPUT path   (harness -> window server -> app -> pixels)
///     stamp -> decode   the MEDIA path   (capture -> encode -> transport -> decode)
///
/// A later phase of this project replaces only the media half. One combined number could not
/// attribute the change: a media-path win and an input-path regression of the same size are
/// indistinguishable in a total, and would read as "no change".
///
/// ---
///
/// ORDINAL N IS NOT SEND N, AND RECONCILING THEM IS NOT THIS FUNCTION'S JOB.
///
/// macOS caps mouse-move DELIVERY at roughly one event per display refresh and MERGES the surplus
/// (last position wins). Measured on a 120 Hz display: 376 Hz posted delivered 38 of 120, and even
/// well under the cap an 81 Hz run delivered 59 of 60. The target's ordinal therefore counts what
/// the app SAW, not what the harness SENT, and the two drift apart by an amount no downstream code
/// can infer from the ordinals alone.
///
/// The reconciliation is done by the CALLER (task 4), on POSITION: a delivered event carries the
/// position of the LAST post in its merge group, so against a deterministic driver the target's
/// `--events` log identifies exactly which send produced each repaint. `sends` is expected to be
/// already reconciled — one entry per ordinal the app actually observed, carrying the send time of
/// the post that produced it.
///
/// That is what makes an ordinal-keyed function correct in a world where ordinals and sends do not
/// correspond 1:1: by the time the records reach here, they do. Do not add position handling here,
/// and do not try to infer coalescing — a second, weaker reconciliation living downstream of the
/// real one is how two disagreeing answers to the same question get shipped.
///
/// ---
///
/// TWO THINGS THIS DELIBERATELY DOES NOT DO, both of which belong to the caller:
///
///  * ORDINAL 0 IS RESERVED and means "no input observed yet" — the target's window is ordered front
///    and painted before any input can arrive, so warm-up frames legitimately carry it. It never
///    appears in `sends` (the first delivered input is ordinal 1), so those frames land in
///    `unmatchedDecodes`. That is honest but it is not LOSS, and a caller that has not trimmed the
///    warm-up will see a large `unmatchedDecodes` that reads as a lossy run. Trim before calling.
///  * CONTAMINATION — anything else on the machine that moves the real cursor over the target's
///    window advances the ordinal past what was sent, after which every ordinal maps to a different
///    send and the mis-pairing is systematic, silent and entirely plausible. This function cannot
///    see it: contaminated records pair perfectly. The harness must refuse any run whose maximum
///    decoded ordinal exceeds the number of inputs it sent.
public enum InputToDecode {

    /// One input, paired with the frame that carried its reaction.
    public struct Sample {
        /// The ordinal both records agreed on — kept so a caller can tie a sample back to the
        /// `--events` line and the send that produced it.
        public let ordinal: UInt32
        /// send -> the app reacted.
        public let inputPathMs: Double
        /// the app reacted -> decoded.
        public let mediaPathMs: Double
        /// Their sum. Derived rather than measured, so it can never disagree with the halves.
        public var totalMs: Double { inputPathMs + mediaPathMs }
    }

    /// The paired samples AND what could not be paired. The counts are not diagnostics — they are
    /// the difference between a run that measured 600 of 600 inputs and one that measured 600 of
    /// 6,000, which are the same `paired` array.
    public struct Result {
        public let paired: [Sample]
        /// Inputs that produced no sample. THREE causes, and they are not one diagnosis: draw-level
        /// coalescing and encoder drops or loss (the run is well-formed, it just lost frames), and —
        /// distinct from both — a REPEATED ordinal in `sends`, which is an upstream reconciliation
        /// bug rather than loss, since the target's ordinal is monotonic and cannot legitimately
        /// repeat. A caller diagnosing a nonzero count should rule the third out first: it means the
        /// RECORDS are broken, not the run, and no amount of re-running will change it.
        public let unmatchedSends: Int
        /// Decoded frames that produced no sample: repaints carrying an already-paired ordinal,
        /// warm-up frames at ordinal 0, and — the one that means something is WRONG — ordinals that
        /// were never sent at all.
        public let unmatchedDecodes: Int
    }

    /// Pairs each decode to the send with the same ordinal. First decode wins; everything else is
    /// counted rather than dropped.
    ///
    /// FIRST DECODE WINS because a repaint with no new input legally re-paints the ordinal it
    /// already had (the target's contract permits it, and draw-level coalescing produces it). Its
    /// media path is real, but its input path would be the ORIGINAL input's — a sample that is half
    /// true and reads as a stall, since the older the ordinal the longer the invented interval.
    ///
    /// COUNTED RATHER THAN DROPPED because a silently shrinking sample set is how a lossy run reads
    /// as a healthy one: every percentile over the survivors stays perfect while most of the run
    /// vanished.
    ///
    /// BOTH SUBTRACTIONS ARE 32-BIT AND WRAPPING. The stamp is the low 32 bits of an epoch
    /// millisecond, not a clock, and it rolls over every ~49.7 days. A frame stamped just before a
    /// rollover and decoded just after it has a numerically SMALLER `decodedMs`; subtracting as
    /// `Int64` reports about minus fifty days, and the same arithmetic on the input path reports
    /// about plus fifty days — ~4.29e9 ms, which reads as a catastrophic stall rather than as an
    /// arithmetic error. Same handling as `ViewerMetrics.stampToDecodeMs`, which the media half
    /// calls directly.
    ///
    /// THE RESIDUAL THAT IDIOM LEAVES: unsigned wrapping cannot represent a NEGATIVE interval, so a
    /// stamp EARLIER than its send — clock skew, or a mis-reconciled `sends` entry — comes out as
    /// ~4.29e9 ms rather than as a negative a caller could reject as impossible on sight. That is
    /// inherent to a 32-bit wrapping counter (the two cases are indistinguishable in the bits, which
    /// is why the rollover is handled this way at all), not a defect of this function. The mitigation
    /// is a caller-side plausibility bound on `inputPathMs`: nothing near 2^31 ms is a latency.
    public static func pair(sends: [(ordinal: UInt32, sentMs: Int64)],
                            decodes: [(ordinal: UInt32, stampMs: UInt32, decodedMs: Int64)]) -> Result {
        // First send wins for a repeated ordinal. The target's ordinal is monotonic, so a duplicate
        // here is a reconciliation bug upstream — it can never pair, so it is counted as an
        // unmatched send rather than silently discarded.
        var sentByOrdinal = [UInt32: Int64]()
        sentByOrdinal.reserveCapacity(sends.count)
        var duplicateSends = 0
        for s in sends {
            if sentByOrdinal[s.ordinal] == nil {
                sentByOrdinal[s.ordinal] = s.sentMs
            } else {
                duplicateSends += 1
            }
        }

        var paired = [Sample]()
        paired.reserveCapacity(min(sends.count, decodes.count))
        var unmatchedDecodes = 0

        for d in decodes {
            // CONSUMING the entry is what makes first-decode-wins true: a repaint carrying an
            // already-paired ordinal finds nothing and is counted. It also leaves `sentByOrdinal`
            // holding exactly the sends that never paired, so the tally below needs no second
            // container to keep in step with this one.
            guard let sentMs = sentByOrdinal.removeValue(forKey: d.ordinal) else {
                unmatchedDecodes += 1
                continue
            }
            paired.append(Sample(
                ordinal: d.ordinal,
                inputPathMs: Double(d.stampMs &- UInt32(truncatingIfNeeded: sentMs)),
                mediaPathMs: ViewerMetrics.stampToDecodeMs(nowUnixMilliseconds: d.decodedMs,
                                                          stamp: d.stampMs)))
        }

        return Result(paired: paired,
                      unmatchedSends: sentByOrdinal.count + duplicateSends,
                      unmatchedDecodes: unmatchedDecodes)
    }
}
