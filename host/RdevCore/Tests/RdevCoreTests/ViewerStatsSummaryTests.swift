import XCTest
@testable import RdevCore

/// The mapping from the session's stats JSON to the numbers a report states — and the three other
/// pure decisions the run loop makes.
///
/// WHY THESE EXIST. Until now every one of them lived in `tools/RdevViewer/ViewerRun.swift`,
/// which sits in the same Swift module as `main.swift` and is therefore unreachable from any test
/// binary (a second `main` cannot be linked in). The consequence was not theoretical: the
/// accounting mapping below ran in a real 1151-frame smoke with `decodesSkipped == 0` and
/// `decodeErrors == 0`, so it produced the right answer no matter what it computed, and every
/// stats key was a bare string literal whose only proof of correctness was that someone had read
/// the C++ once.
///
/// So every fixture here uses DISTINCT NON-ZERO values. A key that drifts reads 0, and 0 is a
/// legal value for every count in this schema — it is only distinguishable from a real reading
/// when the expected value is something else.
final class ViewerStatsSummaryTests: XCTestCase {

    /// Parsed the way the viewer parses it — `JSONSerialization` over the bytes
    /// `rdev_viewer_copy_stats` returns — so the test sees the same `NSNumber`/`NSNull` bridging
    /// the runtime does, not a hand-built Swift dictionary that would paper over it.
    private func stats(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The full-fidelity fixture: every field distinct, and every value one that no other field
    /// carries. Written in the layout `ViewerSession::StatsJSON` produces — the decoder's own
    /// counts at the TOP LEVEL, libwebrtc's inbound-rtp report under `receive`.
    private static let fixture = """
    {
      "negotiatedVideoCodec": "AV1",
      "framesDecoded": 1151,
      "decodesSkipped": 17,
      "decodeErrors": 3,
      "recovery": "nack-rtx",
      "rtxMaxAgeMilliseconds": 250,
      "negotiatedRecovery": "nack-rtx-flexfec",
      "negotiatedRTXTimeMilliseconds": 194,
      "receive": {
        "framesDecoded": 999999,
        "keyFramesDecoded": 11,
        "packetsLost": 41,
        "pliCount": 5,
        "firCount": 7,
        "bytesReceived": 20480,
        "retransmittedBytesReceived": 512,
        "fecBytesReceived": 64
      }
    }
    """

    // MARK: - the mapping

    /// THE ACCOUNTING DECISION: `framesDropped == decodesSkipped + decodeErrors`.
    ///
    /// The three inputs are 1151 / 17 / 3, so every plausible wrong mapping produces a different
    /// number: skips-only is 17, errors-only is 3, and folding decoded in is 1171. At the smoke's
    /// own values (17 and 3 both zero) all four agree on 0, which is why this could not be
    /// checked by running the instrument.
    func testFramesDroppedIsSkipsPlusErrors() throws {
        let s = ViewerStatsSummary(stats: try stats(Self.fixture))
        XCTAssertEqual(s.decodesSkipped, 17)
        XCTAssertEqual(s.decodeErrors, 3)
        XCTAssertEqual(s.framesDropped, 20)
        // And the two are still reported separately, so `decodeErrors` (which the gates assert is
        // zero) fails for its own cause rather than only through the dropped total.
        XCTAssertEqual(s.framesDecoded, 1151)
    }

    /// Every key, at its own value. A literal that drifts in `ViewerStatsSummary` — renamed,
    /// mis-cased, or read from the wrong container — makes exactly the line for that field fail,
    /// which is what turns "someone read the C++ once" into a standing check.
    func testEveryStatsKeyIsReadFromTheContainerTheSessionWritesIt() throws {
        let s = ViewerStatsSummary(stats: try stats(Self.fixture))
        XCTAssertEqual(s.negotiatedCodec, "AV1")
        XCTAssertEqual(s.framesDecoded, 1151)
        XCTAssertEqual(s.decodesSkipped, 17)
        XCTAssertEqual(s.decodeErrors, 3)
        XCTAssertEqual(s.packetsLost, 41)
        // The browser cross-check's ONLY number (scripts/gate-viewer-browser-parity.sh). It is
        // read from `receive`, where libwebrtc writes it, and 11 is distinct from every other
        // value in this fixture — including the 999999 decoy `receive.framesDecoded` beside it,
        // which is the neighbour a mis-typed literal would most plausibly land on.
        XCTAssertEqual(s.keyFramesDecoded, 11)
        XCTAssertEqual(s.pliCount, 5)
        XCTAssertEqual(s.firCount, 7)
        XCTAssertEqual(s.bytesReceived, 20480)
        XCTAssertEqual(s.retransmittedBytesReceived, 512)
        XCTAssertEqual(s.fecBytesReceived, 64)
        XCTAssertEqual(s.recovery, "nack-rtx")
        XCTAssertEqual(s.rtxMaxAgeMilliseconds, 250)
        XCTAssertEqual(s.negotiatedRecovery, "nack-rtx-flexfec")
        XCTAssertEqual(s.negotiatedRTXTimeMilliseconds, 194)
    }

    // MARK: - the per-source rows

    /// `decodeBySource` is what makes "both windows delivered" distinguishable from "every frame
    /// was attributed to the first". The fixture gives the two sources DIFFERENT counts and an
    /// unattributed row, so a mapping that read one row for all of them, or dropped the empty
    /// key, produces a different answer rather than a plausible one.
    func testDecodeBySourceIsReadPerMsidIncludingTheUnattributedRow() throws {
        let s = ViewerStatsSummary(stats: try stats("""
        {
          "framesDecoded": 1300, "decodesSkipped": 4, "decodeErrors": 1,
          "decoderInvocationRegressions": 0,
          "decodeBySource": {
            "win:7": {"framesDecoded": 1100, "decodesSkipped": 3, "decodeErrors": 1,
                       "firstDecoderInvokedUptimeNs": 1000000000,
                       "lastDecoderInvokedUptimeNs": 31000000000,
                       "decoderInvocationRegressions": 0},
            "win:9": {"framesDecoded": 200, "decodesSkipped": 1, "decodeErrors": 0,
                       "firstDecoderInvokedUptimeNs": 1200000000,
                       "lastDecoderInvokedUptimeNs": 30900000000,
                       "decoderInvocationRegressions": 2},
            "": {"framesDecoded": 0, "decodesSkipped": 0, "decodeErrors": 0,
                  "firstDecoderInvokedUptimeNs": 0, "lastDecoderInvokedUptimeNs": 0,
                  "decoderInvocationRegressions": 0}
          }
        }
        """))
        XCTAssertEqual(Set(s.decodeBySource.keys), ["win:7", "win:9", ""])
        XCTAssertEqual(s.decodeBySource["win:7"]?.framesDecoded, 1100)
        XCTAssertEqual(s.decodeBySource["win:9"]?.framesDecoded, 200)
        XCTAssertEqual(s.decodeBySource["win:9"]?.decoderInvocationRegressions, 2)
        // 64-bit uptime nanoseconds, NOT truncated through an Int32 or read as a Double: 31 s of
        // nanoseconds is 3.1e10, which overflows a 32-bit field and would read as a wrong number
        // rather than as a failure.
        XCTAssertEqual(s.decodeBySource["win:7"]?.lastDecoderInvokedUptimeNs, 31_000_000_000)
        XCTAssertEqual(s.decodeBySource["win:7"]?.invocationSpanMilliseconds ?? 0, 30_000,
                       accuracy: 0.001)
        // The unattributed row survives as its own key rather than being folded into a neighbour.
        XCTAssertEqual(s.decodeBySource[""]?.framesDecoded, 0)
    }

    /// The monotonicity claim is ONE number and the gate asserts it is zero. Read from the top
    /// level, where the C++ sums it — a mapping that read a per-source row instead would report a
    /// part as the whole.
    func testInvocationRegressionsAreReadFromTheTopLevelTotal() throws {
        let s = ViewerStatsSummary(stats: try stats("""
        {
          "decoderInvocationRegressions": 5,
          "decodeBySource": {"win:7": {"decoderInvocationRegressions": 2},
                              "win:9": {"decoderInvocationRegressions": 3}}
        }
        """))
        XCTAssertEqual(s.decoderInvocationRegressions, 5)
    }

    /// A run whose stats could not be read at all reports EMPTY rows, not fabricated ones — the
    /// same rule the rest of this type follows. An empty map is what makes a gate's "both sources
    /// are present" assertion fail rather than pass vacuously.
    func testAbsentPerSourceRowsAreEmptyRatherThanInvented() {
        let s = ViewerStatsSummary(stats: [:])
        XCTAssertEqual(s.decodeBySource, [:])
        XCTAssertEqual(s.decoderInvocationRegressions, 0)
    }

    /// `framesDecoded` EXISTS IN BOTH CONTAINERS and they mean different things: the top-level one
    /// counts decoder invocations that produced a picture (what `framesDropped` and
    /// `accounting-reconciled` are defined against), while `receive.framesDecoded` is libwebrtc's
    /// own inbound-rtp count. The fixture sets the decoy to 999999, so reading the wrong one is
    /// not a subtle drift.
    func testFramesDecodedComesFromTheDecoderNotFromInboundRTP() throws {
        let s = ViewerStatsSummary(stats: try stats(Self.fixture))
        XCTAssertEqual(s.framesDecoded, 1151)
        XCTAssertNotEqual(s.framesDecoded, 999999)
    }

    /// The counterpart: the RECOVERY counters must come from `receive` and not from the top
    /// level. This fixture puts a decoy at the top level for each of them, so a mapping that
    /// looked one container too high reads the decoy rather than 0 — a wrong answer that a
    /// zero-valued fixture could not distinguish from a missing key.
    func testReceiveCountersAreNotReadFromTheTopLevel() throws {
        let s = ViewerStatsSummary(stats: try stats("""
        {
          "packetsLost": 111, "pliCount": 222, "firCount": 333, "keyFramesDecoded": 888,
          "bytesReceived": 444, "retransmittedBytesReceived": 555, "fecBytesReceived": 666,
          "receive": {
            "packetsLost": 41, "pliCount": 5, "firCount": 7, "keyFramesDecoded": 11,
            "bytesReceived": 20480, "retransmittedBytesReceived": 512, "fecBytesReceived": 64
          }
        }
        """))
        XCTAssertEqual(s.packetsLost, 41)
        XCTAssertEqual(s.keyFramesDecoded, 11)
        XCTAssertEqual(s.pliCount, 5)
        XCTAssertEqual(s.firCount, 7)
        XCTAssertEqual(s.bytesReceived, 20480)
        XCTAssertEqual(s.retransmittedBytesReceived, 512)
        XCTAssertEqual(s.fecBytesReceived, 64)
    }

    /// The other direction of drift: a NEAR-MISS spelling must read as absent, not be accepted.
    /// Together with the fixture above this pins the names from both sides — renaming a key in
    /// the source fails the positive tests, and loosening the lookup to tolerate a variant fails
    /// this one.
    func testNearMissSpellingsAreNotAccepted() throws {
        let s = ViewerStatsSummary(stats: try stats("""
        {
          "negotiatedCodec": "AV1",
          "decodeSkipped": 17,
          "decodeError": 3,
          "framesDropped": 20,
          "rtxMaxAgeMs": 250,
          "negotiatedRtxTimeMilliseconds": 194,
          "receive": { "pliCounts": 5, "bytesRecieved": 20480 }
        }
        """))
        XCTAssertEqual(s.negotiatedCodec, "", "`negotiatedVideoCodec` is the wire name")
        XCTAssertEqual(s.decodesSkipped, 0)
        XCTAssertEqual(s.decodeErrors, 0)
        XCTAssertEqual(s.framesDropped, 0, "framesDropped is DERIVED, never read from the wire")
        XCTAssertNil(s.rtxMaxAgeMilliseconds)
        XCTAssertNil(s.negotiatedRTXTimeMilliseconds)
        XCTAssertEqual(s.pliCount, 0)
        XCTAssertEqual(s.bytesReceived, 0)
    }

    /// JSON `null` — which the session writes for a codec it has not settled, and for an
    /// rtx-time no answer agreed — must read as ABSENT, not as a number. `NSNull` is not an
    /// `NSNumber`, and this is the case where a report would otherwise state `0 ms` for
    /// "the exchange named no rtx-time".
    func testNullsReadAsAbsentNotAsZero() throws {
        let s = ViewerStatsSummary(stats: try stats("""
        {
          "negotiatedVideoCodec": null,
          "negotiatedRecovery": null,
          "negotiatedRTXTimeMilliseconds": null,
          "recovery": "off",
          "rtxMaxAgeMilliseconds": 0
        }
        """))
        XCTAssertEqual(s.negotiatedCodec, "")
        XCTAssertNil(s.negotiatedRecovery)
        XCTAssertNil(s.negotiatedRTXTimeMilliseconds)
        // "off"/0 are MEASUREMENTS and must survive as themselves — the distinction
        // `recovery-configured` needs to tell a configured-off session from an unreadable one.
        XCTAssertEqual(s.recovery, "off")
        XCTAssertEqual(s.rtxMaxAgeMilliseconds, 0)
    }

    /// An empty dictionary is what the viewer passes when the stats copy or the JSON parse
    /// failed. Every count reads 0 and every optional nil, so `recovery-configured` reports
    /// UNEVALUATED rather than comparing a request against a fabricated echo.
    func testEmptyStatsAreUnavailableRatherThanZeroed() {
        let s = ViewerStatsSummary(stats: [:])
        XCTAssertEqual(s.framesDecoded, 0)
        XCTAssertEqual(s.framesDropped, 0)
        XCTAssertNil(s.recovery)
        XCTAssertNil(s.rtxMaxAgeMilliseconds)
        let a = ViewerAssertions.recoveryConfigured(
            requested: .nackRtx, requestedRtxMaxAgeMilliseconds: 250,
            reported: s.recovery, reportedRtxMaxAgeMilliseconds: s.rtxMaxAgeMilliseconds)
        XCTAssertEqual(a.evaluated, false)
    }

    // MARK: - the watchdog

    /// The clock runs from NEGOTIATION until the first frame, and from the last frame after that.
    func testWatchdogRunsFromNegotiationBeforeAnyFrame() {
        let negotiated: UInt64 = 500_000_000_000        // an uptime clock, not zero-based
        let watchdog: UInt64 = 10_000_000_000
        XCTAssertFalse(ViewerWatchdog.expired(
            nowNanoseconds: negotiated + 5_000_000_000, lastFrameNanoseconds: 0,
            negotiatedNanoseconds: negotiated, watchdogNanoseconds: watchdog))
        XCTAssertTrue(ViewerWatchdog.expired(
            nowNanoseconds: negotiated + 11_000_000_000, lastFrameNanoseconds: 0,
            negotiatedNanoseconds: negotiated, watchdogNanoseconds: watchdog))
    }

    /// THE `max` IS THE MECHANISM. `lastFrameNanoseconds` is 0 until a frame is decoded, and the
    /// clock is `DispatchTime.uptimeNanoseconds` — hundreds of billions on any machine that has
    /// been up a few minutes. Comparing `now` against that 0 makes the interval enormous, so a
    /// watchdog without the `max` fires on its FIRST tick of every run: 50 ms after negotiating,
    /// before the connection could possibly have delivered a frame, reporting "watchdog expired"
    /// on a session that was working.
    func testWatchdogDoesNotFireImmediatelyBecauseNoFrameHasArrivedYet() {
        XCTAssertFalse(ViewerWatchdog.expired(
            nowNanoseconds: 500_000_050_000_000, lastFrameNanoseconds: 0,
            negotiatedNanoseconds: 500_000_000_000_000, watchdogNanoseconds: 10_000_000_000))
    }

    /// After a frame the clock restarts from it, however long ago negotiation was.
    func testWatchdogRestartsFromTheLastFrame() {
        let negotiated: UInt64 = 500_000_000_000
        XCTAssertFalse(ViewerWatchdog.expired(
            nowNanoseconds: negotiated + 30_000_000_000,
            lastFrameNanoseconds: negotiated + 29_000_000_000,
            negotiatedNanoseconds: negotiated, watchdogNanoseconds: 10_000_000_000))
        XCTAssertTrue(ViewerWatchdog.expired(
            nowNanoseconds: negotiated + 45_000_000_000,
            lastFrameNanoseconds: negotiated + 29_000_000_000,
            negotiatedNanoseconds: negotiated, watchdogNanoseconds: 10_000_000_000))
    }

    // MARK: - the bitrate window

    func testBitrateIsBytesTimesEightOverTheWindow() {
        XCTAssertEqual(ViewerMetrics.bitrateBps(bytes: 1_000_000, seconds: 1), 8_000_000)
        XCTAssertEqual(ViewerMetrics.bitrateBps(bytes: 1_000_000, seconds: 2), 4_000_000)
        // The window is measured from NEGOTIATION, not from process start. A 20 s run whose first
        // 2 s went on ICE and signaling reports 8 Mbps over the 18 s the bytes actually arrived
        // in; charging it the whole clock would report 7.2 Mbps for the same stream — a ~10%
        // understatement, inside `bitrate-controlled`'s own band and therefore invisible.
        XCTAssertEqual(ViewerMetrics.bitrateBps(bytes: 18_000_000, seconds: 18), 8_000_000)
        XCTAssertEqual(ViewerMetrics.bitrateBps(bytes: 18_000_000, seconds: 20), 7_200_000)
    }

    /// The zero guard is not defensive tidiness: `Double.infinity` converted to `Int` TRAPS, so
    /// without it a run that ended in the same instant it negotiated would crash the instrument
    /// rather than report a run with no window.
    func testBitrateOverAZeroWindowIsZeroRatherThanATrap() {
        XCTAssertEqual(ViewerMetrics.bitrateBps(bytes: 20480, seconds: 0), 0)
        XCTAssertEqual(ViewerMetrics.bitrateBps(bytes: 20480, seconds: -1), 0)
    }

    // MARK: - the host log

    func testHostLogNotRequested() {
        let outcome = HostStageLog.load(path: nil, source: "test") { _ in
            XCTFail("nothing to read when no --host-log was given")
            return ""
        }
        XCTAssertEqual(outcome, .notRequested)
        XCTAssertNil(outcome.framesEncodedLowerBound)
        XCTAssertTrue(outcome.unavailableDetail.contains("--host-log"))
    }

    /// THE FINDING: an unreadable path used to be indistinguishable from a readable file with no
    /// `[latency]` lines — both were `try?` collapsing to nil, and both printed
    /// "sender frame count unavailable". On the rdev arm, where every assertion must be evaluated
    /// and passed, that presents as a gate failure with no cause in the report.
    func testUnreadableHostLogIsDistinctFromAnEmptyOne() {
        struct NoSuchFile: Error, CustomStringConvertible {
            var description: String { "No such file or directory" }
        }
        let unreadable = HostStageLog.load(path: "/tmp/typo.log", source: "test") { _ in
            throw NoSuchFile()
        }
        XCTAssertEqual(unreadable, .unreadable(path: "/tmp/typo.log",
                                                reason: "No such file or directory"))
        XCTAssertNil(unreadable.framesEncodedLowerBound)
        XCTAssertTrue(unreadable.unavailableDetail.contains("/tmp/typo.log"))
        XCTAssertTrue(unreadable.unavailableDetail.contains("could not be read"))

        let empty = HostStageLog.load(path: "/tmp/host.log", source: "test") { _ in
            "[window] capturing window 7\n"
        }
        XCTAssertEqual(empty, .noMatchingLines(
            path: "/tmp/host.log", sources: ["test"], missing: ["test"]))
        XCTAssertNil(empty.framesEncodedLowerBound)
        XCTAssertTrue(empty.unavailableDetail.contains("[latency]"))
        XCTAssertNotEqual(unreadable.unavailableDetail, empty.unavailableDetail,
                          "the two must not present as the same failure")
    }

    /// A MULTI-SOURCE run's sender count is the SUM over its sources, because `framesDecoded` is
    /// likewise the total over every track. 300 + 40 distinguishes the sum from either part and
    /// from a max.
    func testTheSenderFrameCountSumsOverEverySubscribedSource() {
        let log = """
        [latency] win:7 n=300 overlay p50=0.2 p95=0.4 · encode p50=3.1 p95=4.8 · deliver p50=0.3 p95=0.9 ms
        [latency] win:9 n=40 overlay p50=0.1 p95=0.2 · encode p50=2.0 p95=9.5 · deliver p50=0.1 p95=0.4 ms
        """
        let outcome = HostStageLog.load(path: "/tmp/host.log", sources: ["win:7", "win:9"]) { _ in log }
        XCTAssertEqual(outcome.framesEncodedLowerBound, 340)
        // The p95s are the WORST window across every source, not a sum and not the primary's:
        // percentiles do not add, and the tail is the interesting part. 9.5 belongs to win:9.
        XCTAssertEqual(outcome.stages?.encodeP95Milliseconds, 9.5)
    }

    /// A log holding lines for ONE of two subscribed sources is NOT a partial count that may be
    /// used. It would under-state the lower bound by a whole track, which reads as
    /// `senderCountBelowDecoded` — UNEVALUATED — rather than as the missing input it is. The
    /// detail names WHICH label was not found.
    func testAPartialMultiSourceLogIsUnavailableRatherThanUnderCounted() {
        let outcome = HostStageLog.load(path: "/tmp/host.log", sources: ["win:7", "win:9"]) { _ in
            "[latency] win:7 n=300 overlay p50=0.2 p95=0.4 · encode p50=3.1 p95=4.8 "
                + "· deliver p50=0.3 p95=0.9 ms\n"
        }
        XCTAssertNil(outcome.framesEncodedLowerBound)
        XCTAssertTrue(outcome.unavailableDetail.contains("'win:9'"),
                      "got: \(outcome.unavailableDetail)")
        XCTAssertFalse(outcome.unavailableDetail.contains("'win:7'"),
                       "the source that WAS found must not be named as missing")
    }

    func testParsedHostLogCarriesTheSenderFrameCount() {
        let outcome = HostStageLog.load(path: "/tmp/host.log", source: "win:7") { _ in
            "[latency] win:7 n=300 overlay p50=0.2 p95=0.4 · encode p50=3.1 p95=4.8 "
                + "· deliver p50=0.3 p95=0.9 ms\n"
        }
        XCTAssertEqual(outcome.framesEncodedLowerBound, 300)
        XCTAssertEqual(outcome.unavailableDetail, "")
    }

    /// The reason has to REACH the report, not merely exist — `accounting-reconciled` is the one
    /// assertion that carries it, and it is the string a gate operator reads.
    func testTheReasonReachesTheAccountingAssertion() {
        let outcome = HostStageLog.load(path: "/tmp/typo.log", source: "test") { _ in
            struct E: Error, CustomStringConvertible { var description: String { "boom" } }
            throw E()
        }
        let a = ViewerAssertions.evaluate(
            setupError: nil, watchdogExpired: false, negotiatedCodec: "AV1",
            framesEncodedLowerBound: outcome.framesEncodedLowerBound,
            senderFrameCountDetail: outcome.unavailableDetail,
            framesDecoded: 180, framesDropped: 0,
            accountingTolerance: 3, stampsDecoded: 180, stampCoverageFloor: 0.9,
            measuredBitrateBps: 8_000_000, targetBitrateBps: 8_000_000, bitrateBand: 0.1,
            cleanShutdown: true)
        let acc = a.first { $0.name == "accounting-reconciled" }
        XCTAssertEqual(acc?.evaluated, false)
        XCTAssertTrue(acc?.detail.contains("/tmp/typo.log") == true,
                       "got: \(acc?.detail ?? "<none>")")
    }

    // MARK: - the report's key set

    /// A `ViewerReport`'s KEY SET DOES NOT DEPEND ON ITS CONTENTS.
    ///
    /// Synthesized `Codable` uses `encodeIfPresent`, so `framesEncoded`, `negotiatedRecovery`,
    /// `negotiatedRTXTimeMilliseconds` and both distributions simply vanished from the JSON when
    /// nil — a gate doing `report["negotiatedRecovery"]` got a KeyError where the field's own
    /// doc comment promised null. An absent key and a null value are different claims, and
    /// "the answer named no rtx-time" is a measurement the gates should be able to read
    /// positively.
    func testEveryFieldIsEmittedEvenWhenNil() throws {
        let sparse = try encodedKeys(Self.report(populated: false))
        let full = try encodedKeys(Self.report(populated: true))
        XCTAssertEqual(sparse, full, "an absent value must not remove its key")
        XCTAssertEqual(sparse, Set(ViewerReport.CodingKeys.allCases.map(\.rawValue)))
    }

    func testAbsentValuesAreEncodedAsNull() throws {
        let object = try encodedObject(Self.report(populated: false))
        for key in ["framesEncoded", "negotiatedRecovery", "negotiatedRTXTimeMilliseconds",
                    "stampToDecode", "decoderInterarrival",
                    // The llv arm has no rdev source at all — `capture-host` captures a DISPLAY.
                    // Null says that; an absent key would say the schema never knew.
                    "sourceId",
                    // The rdev arm's unconfirmed-prefs pair. An ABSENT key here would read as a
                    // schema that never had the field, when what it means is that the host never
                    // echoed a `view-set` for this source.
                    "effectiveFramesPerSecond", "effectiveBitrateBitsPerSecond"] {
            XCTAssertTrue(object[key] is NSNull, "\(key) must be JSON null, got \(object[key] ?? "absent")")
        }
    }

    /// THE INJECTED FAULT MUST REACH THE ARTIFACT, not merely have a key.
    ///
    /// `testEveryFieldIsEmittedEvenWhenNil` proves the two keys are present; it cannot see the
    /// two being swapped, or either being written from the wrong option. That distinction is the
    /// whole subject of this pair of fields: a fault run and a real run write to the SAME work
    /// directory, so a report whose bias fields are wrong is a report that lies about whether it
    /// is a measurement — the one thing they exist to make impossible.
    func testTheInjectedTimingBiasIsRecordedInTheReport() throws {
        let injected = try encodedObject(Self.report(populated: true))
        XCTAssertEqual(injected["interarrivalBiasMilliseconds"] as? Double, 8)
        XCTAssertEqual(injected["interarrivalBiasScale"] as? Double, 1.4)
        // And a run with no fault records the IDENTITY rather than nothing — absent would be
        // indistinguishable from an older schema that never knew.
        let clean = try encodedObject(Self.report(populated: false))
        XCTAssertEqual(clean["interarrivalBiasMilliseconds"] as? Double, 0)
        XCTAssertEqual(clean["interarrivalBiasScale"] as? Double, 1)
    }

    /// The frozen names, restated as literals. `CodingKeys.allCases` above proves the JSON
    /// matches the enum; this proves the enum still spells what the recorded baselines do, which
    /// no amount of self-consistency can.
    func testFrozenFieldNames() throws {
        let keys = try encodedKeys(Self.report(populated: true))
        for name in [
            "schemaVersion", "arm", "negotiatedCodec", "libwebrtcRevision",
            "framesEncoded", "framesDecoded", "framesDropped", "decodeErrors", "stampsDecoded",
            "packetsLost", "pliCount", "firCount", "bytesReceived",
            "retransmittedBytesReceived", "fecBytesReceived",
            "recovery", "rtxMaxAgeMilliseconds",
            "negotiatedRecovery", "negotiatedRTXTimeMilliseconds",
            "stampToDecode", "decoderInterarrival", "longestFreezeProxyMilliseconds",
        ] {
            XCTAssertTrue(keys.contains(name), "missing inherited field \(name)")
        }
    }

    private func encodedObject(_ report: ViewerReport) throws -> [String: Any] {
        let data = try JSONEncoder().encode(report)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encodedKeys(_ report: ViewerReport) throws -> Set<String> {
        Set(try encodedObject(report).keys)
    }

    static func report(populated: Bool) -> ViewerReport {
        ViewerReport(
            schemaVersion: 1, arm: "llv", rdevRevision: "abc1234", rdevDirty: false,
            encoderIdentity: "libaom", negotiatedCodec: "AV1", libwebrtcRevision: "def5678",
            impairmentProfile: "delay-000ms", impairmentSeed: 1741,
            // The `populated` case carries an INJECTED bias, so `testTheInjectedTimingBiasIs
            // RecordedInTheReport` below can read a non-identity value back out; the sparse case
            // carries the identity, which is what a real measurement writes.
            interarrivalBiasMilliseconds: populated ? 8 : 0,
            interarrivalBiasScale: populated ? 1.4 : 1,
            sourceId: populated ? "win:501" : nil,
            sourceWidth: 1280, sourceHeight: 720, framesPerSecond: 60,
            bitrateBitsPerSecond: 8_000_000,
            effectiveFramesPerSecond: populated ? 60 : nil,
            effectiveBitrateBitsPerSecond: populated ? 8_000_000 : nil,
            hostUptimeSeconds: 12, hostDescription: "Darwin",
            startedAtUtc: "2026-08-13T00:00:00Z", finishedAtUtc: "2026-08-13T00:00:30Z",
            stampToDecode: populated ? ViewerDistribution(samplesMs: [10, 11, 12]) : nil,
            decoderInterarrival: populated ? ViewerDistribution(samplesMs: [16.6, 16.7]) : nil,
            longestFreezeProxyMilliseconds: 16.7,
            framesEncoded: populated ? 180 : nil,
            framesDecoded: 180, framesDropped: 0, decodeErrors: 0, stampsDecoded: 180,
            decodeBySource: populated
                ? ["win:501": ViewerSourceDecode(
                    framesDecoded: 180, decodesSkipped: 0, decodeErrors: 0,
                    firstDecoderInvokedUptimeNs: 1_000, lastDecoderInvokedUptimeNs: 2_000,
                    decoderInvocationRegressions: 0)]
                : [:],
            callbackFramesBySource: populated ? ["win:501": 180] : [:],
            decoderInvocationRegressions: 0,
            packetsLost: 0, keyFramesDecoded: 1, pliCount: 0, firCount: 0,
            bytesReceived: 1024, retransmittedBytesReceived: 0, fecBytesReceived: 0,
            recovery: "nack-rtx", rtxMaxAgeMilliseconds: 250,
            negotiatedRecovery: populated ? "nack-rtx" : nil,
            negotiatedRTXTimeMilliseconds: populated ? 194 : nil,
            assertions: [ViewerAssertion(name: "clean-shutdown", passed: true, detail: "ok")])
    }

    // MARK: - which slot an inbound SDP lands in

    /// THE FINDING: `on_answer` was wired to the offer handler, so a remote ANSWER was stored as
    /// though this session had produced an OFFER. Inert on the llv arm — the viewer offers there,
    /// so `on_answer` never fires — and precisely wrong on the arm Task 11 adds, where the
    /// viewer answers and that slot is what gets sent back out.
    func testAnAnswerNeverLandsInTheOfferSlot() {
        var inbox = ViewerSDPInbox()
        inbox.receiveAnswer("v=0\r\na=answer\r\n")
        XCTAssertNil(inbox.offer, "an answer is not something this session generated")
        XCTAssertEqual(inbox.answer, "v=0\r\na=answer\r\n")
    }

    func testAnOfferNeverLandsInTheAnswerSlot() {
        var inbox = ViewerSDPInbox()
        inbox.receiveOffer("v=0\r\na=offer\r\n")
        XCTAssertEqual(inbox.offer, "v=0\r\na=offer\r\n")
        XCTAssertNil(inbox.answer)
    }

    /// Both roles exist in one process across Tasks 10 and 11, so the slots must coexist rather
    /// than overwrite: whichever arrived last cannot be allowed to become "the" description.
    func testBothSlotsCoexist() {
        var inbox = ViewerSDPInbox()
        inbox.receiveOffer("offer")
        inbox.receiveAnswer("answer")
        XCTAssertEqual(inbox.offer, "offer")
        XCTAssertEqual(inbox.answer, "answer")
    }
}
