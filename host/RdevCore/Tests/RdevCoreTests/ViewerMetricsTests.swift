import XCTest
@testable import RdevCore

final class ViewerMetricsTests: XCTestCase {

    func testNearestRankPercentiles() {
        // Force-unwrap: this input is never empty, and the nil case is covered separately by
        // testEmptyDistributionIsNil. `init?` (failable by design -- see design rule 1) means the
        // brief's original `let d = ViewerDistribution(...)` does not compile against `d.count`
        // et al. without unwrapping.
        let d = ViewerDistribution(samplesMs: (1...100).map(Double.init))!
        XCTAssertEqual(d.count, 100)
        XCTAssertEqual(d.minimumMilliseconds, 1)
        XCTAssertEqual(d.maximumMilliseconds, 100)
        XCTAssertEqual(d.p50Milliseconds, 50)
        XCTAssertEqual(d.p95Milliseconds, 95)
        XCTAssertEqual(d.p99Milliseconds, 99)
    }

    func testSingleSample() {
        let d = ViewerDistribution(samplesMs: [7])!
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.p50Milliseconds, 7)
        XCTAssertEqual(d.p99Milliseconds, 7)
    }

    func testEmptyDistributionIsNil() {
        XCTAssertNil(ViewerDistribution(samplesMs: []))
    }

    func testUnsortedInput() {
        let d = ViewerDistribution(samplesMs: [9, 1, 5, 3, 7])!
        XCTAssertEqual(d.minimumMilliseconds, 1)
        XCTAssertEqual(d.maximumMilliseconds, 9)
        XCTAssertEqual(d.p50Milliseconds, 5)
    }

    /// The freeze proxy is the longest gap between consecutive decoded frames — the same
    /// definition `longestFreezeProxyMilliseconds` carries in LLV's recorded reports.
    func testFreezeProxyIsTheLongestGap() {
        XCTAssertEqual(ViewerMetrics.freezeProxy(interarrivalMs: [16.6, 16.7, 133.3, 16.6]), 133.3)
        XCTAssertEqual(ViewerMetrics.freezeProxy(interarrivalMs: []), 0)
    }

    /// The DEFAULTS must take the identity path, or an ordinary run would go through different
    /// arithmetic from an injected one and the fault-injection gate would be exercising a code
    /// path no real measurement uses.
    func testTimingBiasDefaultsAreTheIdentity() {
        let series = [16.6, 16.7, 133.3, 16.6]
        XCTAssertEqual(
            ViewerMetrics.biasedInterarrivalMs(series, offsetMs: 0, scale: 1), series)
        XCTAssertEqual(ViewerMetrics.biasedInterarrivalMs([], offsetMs: 5, scale: 2), [])
    }

    /// The two forms an instrument's timing can be wrong in, and BOTH must move the freeze proxy
    /// as well as the percentiles — a bias that moved only one of them would be caught by only
    /// half the cross-check.
    func testTimingBiasAppliesOffsetAndScale() {
        let series = [10.0, 20.0]
        XCTAssertEqual(
            ViewerMetrics.biasedInterarrivalMs(series, offsetMs: 5, scale: 1), [15.0, 25.0])
        XCTAssertEqual(
            ViewerMetrics.biasedInterarrivalMs(series, offsetMs: 0, scale: 1.5), [15.0, 30.0])
        // Scale is applied BEFORE the offset, so the two compose predictably.
        XCTAssertEqual(
            ViewerMetrics.biasedInterarrivalMs(series, offsetMs: 1, scale: 2), [21.0, 41.0])
        XCTAssertEqual(
            ViewerMetrics.freezeProxy(
                interarrivalMs: ViewerMetrics.biasedInterarrivalMs(
                    series, offsetMs: 5, scale: 1)),
            25.0)
    }

    /// A gap is a duration. A large negative offset FLOORS the series instead of producing
    /// negative gaps, which would make `freezeProxy` describe an ordering that never happened.
    func testTimingBiasClampsAtZero() {
        XCTAssertEqual(
            ViewerMetrics.biasedInterarrivalMs([10.0, 20.0], offsetMs: -15, scale: 1),
            [0.0, 5.0])
    }

    func testAccountingReconciles() {
        XCTAssertEqual(
            ViewerAccounting.reconcile(encoded: 180, decoded: 179, dropped: 1, tolerance: 0),
            .reconciled)
        XCTAssertEqual(
            ViewerAccounting.reconcile(encoded: 180, decoded: 99, dropped: 1, tolerance: 0),
            .unaccounted(80))
    }

    func testAccountingTolerance() {
        // A run ends mid-flight, so a small SHORTFALL is expected; the tolerance is fixed
        // empirically from the null run and must never be widened to make a comparison pass.
        XCTAssertEqual(
            ViewerAccounting.reconcile(encoded: 180, decoded: 177, dropped: 0, tolerance: 3),
            .reconciled)
        XCTAssertEqual(
            ViewerAccounting.reconcile(encoded: 180, decoded: 176, dropped: 0, tolerance: 3),
            .unaccounted(4))
    }

    /// The tolerance is one-directional: a SHORTFALL inside it reconciles, a shortfall beyond it
    /// does not, and the two are never mixed by an `abs(...)`.
    func testAccountingToleranceIsOneDirectional() {
        // Shortfall of 2, tolerance 3: reconciles.
        XCTAssertEqual(
            ViewerAccounting.reconcile(encoded: 180, decoded: 178, dropped: 0, tolerance: 3),
            .reconciled)
        // A tolerance of 0 still permits an exact match (diff == 0 is in [0, tolerance]).
        XCTAssertEqual(
            ViewerAccounting.reconcile(encoded: 180, decoded: 180, dropped: 0, tolerance: 0),
            .reconciled)
    }

    /// THE FINDING (rdev-arm smoke, `encoded=184 decoded=199`). More frames decoded than the
    /// sender is KNOWN to have encoded is not frame loss and is not a counting bug — it is the
    /// READER. `HostStageLog` sums the `[latency] <source> n=NN` windows PRESENT IN THE LOG when
    /// it is read, and the host's reporter prints one only every 5 s, so every run loses up to a
    /// full window off its tail. The count is therefore a LOWER BOUND, and this direction is
    /// self-evidently that lower bound being low.
    ///
    /// So it gets its OWN outcome rather than sharing `.unaccounted` with a real shortfall. It
    /// must NOT read as an accounting failure — that is the misreading this exists to prevent —
    /// and it must not be reconciled either, which would let a genuine over-count hide behind it.
    func testDecodedAboveTheSenderCountIsTheReaderNotFrameLoss() {
        XCTAssertEqual(
            ViewerAccounting.reconcile(encoded: 184, decoded: 199, dropped: 0, tolerance: 3),
            .senderCountBelowDecoded(by: 15))
        // Overage split across decoded+dropped is the same reading.
        XCTAssertEqual(
            ViewerAccounting.reconcile(encoded: 180, decoded: 181, dropped: 1, tolerance: 3),
            .senderCountBelowDecoded(by: 2))
        // And it is NOT swallowed by a tolerance large enough to cover it: the tolerance is for
        // the shortfall direction only, so the outcome is the same at tolerance 100.
        XCTAssertEqual(
            ViewerAccounting.reconcile(encoded: 184, decoded: 199, dropped: 0, tolerance: 100),
            .senderCountBelowDecoded(by: 15))
    }

    func testReportEncodesInheritedFieldNames() throws {
        let report = ViewerReport(
            schemaVersion: 1, arm: "llv", rdevRevision: "abc1234", rdevDirty: false,
            encoderIdentity: "libaom", negotiatedCodec: "AV1", libwebrtcRevision: "def5678",
            impairmentProfile: "delay-000ms", impairmentSeed: 1741,
            interarrivalBiasMilliseconds: 0, interarrivalBiasScale: 1, sourceId: nil,
            sourceWidth: 1280, sourceHeight: 720, framesPerSecond: 60, bitrateBitsPerSecond: 8_000_000,
            effectiveFramesPerSecond: 60, effectiveBitrateBitsPerSecond: 8_000_000,
            hostUptimeSeconds: 12, hostDescription: "Darwin",
            startedAtUtc: "2026-08-13T00:00:00Z", finishedAtUtc: "2026-08-13T00:00:30Z",
            stampToDecode: ViewerDistribution(samplesMs: [10, 11, 12]),
            decoderInterarrival: ViewerDistribution(samplesMs: [16.6, 16.7]),
            longestFreezeProxyMilliseconds: 16.7,
            framesEncoded: 180, framesDecoded: 180, framesDropped: 0, decodeErrors: 0,
            stampsDecoded: 180,
            decodeBySource: [:], callbackFramesBySource: [:], decoderInvocationRegressions: 0,
            packetsLost: 0, keyFramesDecoded: 1, pliCount: 0, firCount: 0,
            bytesReceived: 1024, retransmittedBytesReceived: 0, fecBytesReceived: 0,
            // Stated rather than defaulted: the four recovery fields have no defaults any more,
            // precisely so a caller cannot omit them and emit `recovery: ""` unnoticed.
            recovery: "nack-rtx", rtxMaxAgeMilliseconds: 250,
            negotiatedRecovery: "nack-rtx", negotiatedRTXTimeMilliseconds: 194,
            assertions: [ViewerAssertion(name: "clean-shutdown", passed: true, detail: "ok")]
        )
        let data = try JSONEncoder().encode(report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        // Names inherited from results/20260807/libwebrtc-viewer-receiver -- a rename here turns
        // trust-ladder step 2 from a diff into a mapping exercise, where a unit error can hide.
        for name in ["longestFreezeProxyMilliseconds", "decoderInterarrival", "pliCount", "firCount"] {
            XCTAssertTrue(text.contains("\"\(name)\""), "missing inherited field \(name)")
        }
    }

    // MARK: the six assertions

    func testAllSixAssertionsAreAlwaysEmitted() {
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "AV1",
            framesEncodedLowerBound: 180, senderFrameCountDetail: "",
            framesDecoded: 180, framesDropped: 0,
            accountingTolerance: 3, stampsDecoded: 180, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true
        )
        XCTAssertEqual(a.map(\.name), [
            "execution-valid", "codec-as-expected", "accounting-reconciled",
            "stamp-coverage", "bitrate-controlled", "clean-shutdown",
        ])
        XCTAssertTrue(a.allSatisfy(\.passed))
    }

    func testCodecAssertionFailsOnFallback() {
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "H265",
            framesEncodedLowerBound: 180, senderFrameCountDetail: "",
            framesDecoded: 180, framesDropped: 0,
            accountingTolerance: 3, stampsDecoded: 180, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true
        )
        let codec = a.first { $0.name == "codec-as-expected" }
        XCTAssertEqual(codec?.passed, false)
        XCTAssertTrue(codec?.detail.contains("H265") == true)
    }

    /// FINDING A, branch 3 (the ordinary case): full coverage, both counts present. This
    /// must be EVALUATED and PASS, so a broken branch 1/2 fix that swallowed the ordinary
    /// case too (e.g. always reporting evaluated:false) is caught here.
    func testStampCoverageEvaluatedAndPassedWhenBothPresent() {
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "AV1",
            framesEncodedLowerBound: 180, senderFrameCountDetail: "",
            framesDecoded: 180, framesDropped: 0,
            accountingTolerance: 3, stampsDecoded: 180, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true
        )
        let sc = a.first { $0.name == "stamp-coverage" }
        XCTAssertEqual(sc?.evaluated, true)
        XCTAssertEqual(sc?.passed, true)
    }

    /// FINDING A, branch 2: an unstamped source (LLV's host paints no rdev stamp) is a
    /// LEGITIMATE escape -- zero of zero is not a shortfall -- but it must be UNEVALUATED,
    /// not reported as PASSED. `passed: true` here is indistinguishable from a real pass,
    /// which is exactly the collapse `ViewerAssertion.evaluated`'s doc comment exists to
    /// prevent. (This replaces the old `testStampCoverageIgnoresUnstampedSources`, which
    /// asserted the pre-fix `passed == true` behaviour.)
    func testStampCoverageUnevaluatedForUnstampedSource() {
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "AV1",
            framesEncodedLowerBound: 180, senderFrameCountDetail: "",
            framesDecoded: 180, framesDropped: 0,
            accountingTolerance: 3, stampsDecoded: 0, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true
        )
        let sc = a.first { $0.name == "stamp-coverage" }
        XCTAssertEqual(sc?.evaluated, false)
        XCTAssertEqual(sc?.passed, false)
    }

    /// FINDING A, branch 1 (the real defect): a run that decoded ZERO frames must not
    /// report stamp-coverage as PASSED. Pre-fix, `framesDecoded == 0` hit the same
    /// `stampsDecoded == 0` escape as the legitimate unstamped-source case and reported
    /// `passed: true, detail: "0/0 = 1.000"` -- which reads as healthy when nothing worked
    /// at all. This is the assertion the whole parity claim rests on, so it must come back
    /// UNEVALUATED instead.
    func testStampCoverageUnevaluatedWhenNoFramesDecoded() {
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "AV1",
            framesEncodedLowerBound: 180, senderFrameCountDetail: "",
            framesDecoded: 0, framesDropped: 180,
            accountingTolerance: 3, stampsDecoded: 0, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true
        )
        let sc = a.first { $0.name == "stamp-coverage" }
        XCTAssertEqual(sc?.evaluated, false, "0/0 must not read as a clean pass")
        XCTAssertEqual(sc?.passed, false)
        XCTAssertTrue(sc?.detail.localizedCaseInsensitiveContains("decoded") == true,
                       "detail should say no frames were decoded, got: \(sc?.detail ?? "")")
    }

    func testStampCoverageFailsOnPartialDecode() {
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "AV1",
            framesEncodedLowerBound: 180, senderFrameCountDetail: "",
            framesDecoded: 180, framesDropped: 0,
            accountingTolerance: 3, stampsDecoded: 90, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true
        )
        let sc = a.first { $0.name == "stamp-coverage" }
        XCTAssertEqual(sc?.passed, false)
        // Evaluated: both inputs were present, coverage was just too low -- distinct from
        // the two unevaluated branches above.
        XCTAssertEqual(sc?.evaluated, true)
    }

    /// LOAD-BEARING. LLV's host prints no [latency] lines, so the llv arm has no sender frame
    /// count. That assertion must be visibly UNEVALUATED, never reported as passing — a run whose
    /// accounting was never checked must not look like one whose accounting reconciled.
    func testMissingSenderFrameCountIsUnevaluatedNotPassed() {
        // stampsDecoded is 180 (full coverage), NOT 0 -- deliberately, so stamp-coverage
        // falls in its own always-checkable branch here (see FINDING A above: stamp-coverage
        // can ALSO come back unevaluated, on inputs this test does not exercise) and this
        // test stays focused on accounting-reconciled being the one unevaluated assertion.
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "AV1",
            framesEncodedLowerBound: nil,
            senderFrameCountDetail: "sender frame count unavailable (no --host-log)",
            framesDecoded: 180, framesDropped: 0,
            accountingTolerance: 3, stampsDecoded: 180, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true
        )
        XCTAssertEqual(a.count, 6, "all six are emitted even when one cannot be checked")
        let acc = a.first { $0.name == "accounting-reconciled" }
        XCTAssertEqual(acc?.evaluated, false)
        XCTAssertEqual(acc?.passed, false)

        // The OTHER five assertions are checkable on THESE inputs and must come back
        // `evaluated == true` — undefended before this test, since `ViewerAssertion.init`'s
        // `evaluated: Bool = true` default could be flipped to `false` and every other test
        // in this file (none of which reads `.evaluated` on a passing assertion) would still
        // pass.
        let others = a.filter { $0.name != "accounting-reconciled" }
        XCTAssertEqual(others.count, 5)
        XCTAssertTrue(others.allSatisfy(\.evaluated),
                       "the five always-checkable assertions must report evaluated == true")
    }

    /// The detail string a gate operator reads must not claim a number the reader cannot supply.
    /// `encoded=184` invites the reading that the host encoded exactly 184; it encoded AT LEAST
    /// that many. `>=` is the whole fix, and it is asserted on the PASSING case because that is
    /// the one nobody looks at twice.
    func testAccountingDetailNamesTheSenderCountAsALowerBound() {
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "AV1",
            framesEncodedLowerBound: 180, senderFrameCountDetail: "",
            framesDecoded: 180, framesDropped: 0,
            accountingTolerance: 3, stampsDecoded: 180, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true
        )
        let acc = try? XCTUnwrap(a.first { $0.name == "accounting-reconciled" })
        XCTAssertEqual(acc?.passed, true)
        XCTAssertEqual(acc?.evaluated, true)
        XCTAssertTrue(acc?.detail.contains("encoded>=180") == true,
                       "the sender count must be stated as a lower bound, got: \(acc?.detail ?? "")")
    }

    /// THE FINDING, at the assertion level. The rdev-arm smoke reported
    /// `accounting-reconciled: FAIL — encoded=184 decoded=199`, which reads as fifteen frames
    /// lost. Nothing was lost: `decoded > encoded` is impossible for a real shortfall, so it can
    /// only be the reader's 5 s-window truncation.
    ///
    /// It must therefore come back UNEVALUATED (the input — an exact sender count — was not
    /// available, which is exactly what `ViewerAssertion.evaluated` means) and SAY SO in the
    /// detail. It is deliberately NOT widened into a pass: the tolerance is Task 12/13's to set,
    /// and passing here would let a genuine over-count hide behind the artifact.
    func testDecodedAboveTheSenderCountIsUnevaluatedNotAFailure() {
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "AV1",
            framesEncodedLowerBound: 184, senderFrameCountDetail: "",
            framesDecoded: 199, framesDropped: 0,
            accountingTolerance: 3, stampsDecoded: 199, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true
        )
        let acc = a.first { $0.name == "accounting-reconciled" }
        XCTAssertEqual(acc?.evaluated, false, "a reader artifact must not read as frame loss")
        XCTAssertEqual(acc?.passed, false, "nor may it be waved through as a pass")
        let detail = acc?.detail ?? ""
        XCTAssertTrue(detail.localizedCaseInsensitiveContains("lower bound"),
                       "detail must name the cause, got: \(detail)")
        XCTAssertTrue(detail.contains("199"), "detail must carry the numbers, got: \(detail)")
    }

    /// The guard against over-applying the branch above: a genuine shortfall beyond the tolerance
    /// is still an EVALUATED FAILURE. Without this, "treat the overage direction as unevaluated"
    /// could be widened to "treat every mismatch as unevaluated" and no test would notice.
    func testARealShortfallStillFailsEvaluated() {
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "AV1",
            framesEncodedLowerBound: 180, senderFrameCountDetail: "",
            framesDecoded: 100, framesDropped: 0,
            accountingTolerance: 3, stampsDecoded: 100, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true
        )
        let acc = a.first { $0.name == "accounting-reconciled" }
        XCTAssertEqual(acc?.evaluated, true)
        XCTAssertEqual(acc?.passed, false)
        XCTAssertTrue(acc?.detail.contains("unaccounted=80") == true,
                       "got: \(acc?.detail ?? "")")
    }

    // MARK: host stage log

    func testParsesLatencyLinesAndSumsEncodedFrames() throws {
        let log = """
        [window] capturing window 7
        [latency] test n=300 overlay p50=0.2 p95=0.4 · encode p50=3.1 p95=4.8 · deliver p50=0.3 p95=0.9 ms
        [latency] other n=99 overlay p50=1.0 p95=1.0 · encode p50=1.0 p95=1.0 · deliver p50=1.0 p95=1.0 ms
        [latency] test n=299 overlay p50=0.2 p95=0.5 · encode p50=3.0 p95=5.1 · deliver p50=0.3 p95=1.0 ms
        """
        let s = try XCTUnwrap(HostStageLog.parse(log, source: "test"))
        XCTAssertEqual(s.framesEncodedLowerBound, 599)          // summed: each line is its own 5s window
        XCTAssertEqual(s.encodeP95Milliseconds, 5.1)  // worst window, not an average of percentiles
    }

    func testParseReturnsNilForAnUnseenSource() {
        let log = "[latency] test n=10 overlay p50=0.2 p95=0.4 · encode p50=3.1 p95=4.8 · deliver p50=0.3 p95=0.9 ms"
        XCTAssertNil(HostStageLog.parse(log, source: "missing"))
    }

    func testParseReturnsNilWhenTheProbeWasOff() {
        XCTAssertNil(HostStageLog.parse("no latency lines here", source: "test"))
    }

    // MARK: stamp -> decode

    /// The ordinary case: the stamp is a low-32 epoch-millisecond value from a moment ago.
    func testStampToDecodeIsTheOrdinaryDifference() {
        let stamp: UInt32 = 1_000_000
        XCTAssertEqual(
            ViewerMetrics.stampToDecodeMs(nowUnixMilliseconds: 1_000_042, stamp: stamp), 42)
    }

    /// THE CASE THE `&-` EXISTS FOR. `LatencyTimecode` carries the LOW 32 BITS of an epoch
    /// millisecond, which wraps every ~49.7 days — so a frame stamped just before the rollover
    /// and decoded just after it has a `now` NUMERICALLY SMALLER than its stamp. Wrapping
    /// subtraction gives the true 356 ms; an ordinary one gives roughly minus fifty days.
    ///
    /// Note the `now` argument: 0x1_0000_0064 is a real epoch millisecond ABOVE 2^32, and it is
    /// passed unmodified precisely because truncating it is the function's job. A test that
    /// pre-truncated would be testing its own arithmetic.
    func testStampToDecodeWrapsAcrossThe32BitRollover() {
        let stamp: UInt32 = 0xFFFF_FF00                 // 256 ms before the rollover
        let now: Int64 = 0x1_0000_0064                  // 100 ms after it
        XCTAssertEqual(ViewerMetrics.stampToDecodeMs(nowUnixMilliseconds: now, stamp: stamp), 356)
    }

    /// A real epoch millisecond is far larger than 2^32 (it passed that in 1970 + 49.7 days), so
    /// the truncation is not an edge case — it is what EVERY sample does. This pins that a
    /// present-day clock against a present-day stamp still reads as a small positive latency.
    func testStampToDecodeTruncatesARealEpochMillisecond() {
        let now: Int64 = 1_786_000_000_000              // ~2026, far above 2^32
        let stamp = UInt32(truncatingIfNeeded: now - 33)
        XCTAssertEqual(ViewerMetrics.stampToDecodeMs(nowUnixMilliseconds: now, stamp: stamp), 33)
    }

    /// Zero, not a negative number and not a wrapped ~49.7 days: identical values are the same
    /// instant. Guards a `-1`/off-by-one slipping into the subtraction.
    func testStampToDecodeIsZeroForTheSameInstant() {
        let now: Int64 = 1_786_000_000_000
        XCTAssertEqual(
            ViewerMetrics.stampToDecodeMs(
                nowUnixMilliseconds: now, stamp: UInt32(truncatingIfNeeded: now)), 0)
    }
}
