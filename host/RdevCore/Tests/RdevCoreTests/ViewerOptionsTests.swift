import XCTest
@testable import RdevCore

/// The flag → ABI mapping, and the assertion that defends it.
///
/// This file exists because of one failure shape: a flag the CLI accepts, parses into a
/// variable, and never writes into `rdev_viewer_configuration`. The run then measures a
/// configuration nobody chose while reporting the one that was typed — every number in the
/// results file agreeing with every other, and all of them describing the wrong run.
final class ViewerOptionsTests: XCTestCase {

    private static let minimal = [
        "--arm", "llv", "--host", "127.0.0.1", "--port", "45001",
        "--duration", "20", "--out", "/tmp/x.json",
    ]

    // MARK: - the ABI numbering

    /// `RDEV_VIEWER_RECOVERY_*` is `nack-rtx = 1, nack-rtx-flexfec = 2, off = 3` — neither
    /// alphabetical nor declaration order. An ordinal derived from `allCases` would give
    /// off = 0, which the C++ validator refuses outright, and any other renumbering would
    /// silently negotiate a mode nobody asked for.
    func testRecoveryWireValuesMatchTheABIConstants() {
        XCTAssertEqual(ViewerRecoveryMode.nackRtx.wireValue, 1)
        XCTAssertEqual(ViewerRecoveryMode.nackRtxFlexfec.wireValue, 2)
        XCTAssertEqual(ViewerRecoveryMode.off.wireValue, 3)
        // No mode may map to 0: that is the value a zero-filled configuration carries, and it
        // is exactly what the ABI refuses rather than defaulting.
        XCTAssertFalse(ViewerRecoveryMode.allCases.contains { $0.wireValue == 0 })
    }

    /// The command-line spelling and the string the session reports under `recovery` are the
    /// SAME string (C++ `RecoveryModeName`). `recoveryConfigured` compares them directly, so a
    /// divergence here would make every echo check fail — or, worse, need a translation table,
    /// which is where a dropped flag hides.
    func testRecoverySpellingMatchesTheStatsName() {
        XCTAssertEqual(ViewerRecoveryMode.off.rawValue, "off")
        XCTAssertEqual(ViewerRecoveryMode.nackRtx.rawValue, "nack-rtx")
        XCTAssertEqual(ViewerRecoveryMode.nackRtxFlexfec.rawValue, "nack-rtx-flexfec")
    }

    // MARK: - parsing

    func testDefaultsArePinnedSpecControls() throws {
        let a = try ViewerArguments.parse(Self.minimal)
        XCTAssertEqual(a.arm, .llv)
        XCTAssertEqual(a.host, "127.0.0.1")
        XCTAssertEqual(a.port, 45001)
        XCTAssertEqual(a.durationSeconds, 20)
        // The brief: "--recovery defaults to nack-rtx". Task 12 pins 60 fps and 8 Mbit/s, and
        // the recorded baselines were produced at rtxMaxAgeMilliseconds = 30.
        XCTAssertEqual(a.recovery, .nackRtx)
        XCTAssertEqual(a.rtxMaxAgeMilliseconds, 30)
        XCTAssertEqual(a.framesPerSecond, 60)
        XCTAssertEqual(a.targetBitrateBitsPerSecond, 8_000_000)
    }

    /// `--input-stamps` turns on a SECOND stamp row read and a per-frame series file. Its default
    /// is nil, and that is not a formality: with it unset the decode path does no extra work at
    /// all, which is what lets C1's recorded thresholds keep describing the runs its gates make.
    /// A flag whose default silently changed would invalidate them without failing anything.
    func testInputStampsIsOffByDefaultAndParsesAPath() throws {
        XCTAssertNil(try ViewerArguments.parse(Self.minimal).inputStampsPath)
        XCTAssertEqual(
            try ViewerArguments.parse(Self.minimal + ["--input-stamps", "/tmp/s.jsonl"])
                .inputStampsPath,
            "/tmp/s.jsonl")
    }

    func testRecoveryFlagSelectsEachMode() throws {
        for mode in ViewerRecoveryMode.allCases {
            let a = try ViewerArguments.parse(Self.minimal + ["--recovery", mode.rawValue])
            XCTAssertEqual(a.recovery, mode)
        }
    }

    /// Task 12 needs `--recovery nack-rtx-flexfec` to be a real lever; the brief calls this out
    /// by name.
    func testFlexfecIsSelectableAndCarriesTheFlexfecWireValue() throws {
        let a = try ViewerArguments.parse(Self.minimal + ["--recovery", "nack-rtx-flexfec"])
        XCTAssertEqual(a.recovery.wireValue, 2)
    }

    func testRtxMaxAgeIsCarriedAndRangeChecked() throws {
        XCTAssertEqual(try ViewerArguments.parse(Self.minimal + ["--rtx-max-age", "7"])
            .rtxMaxAgeMilliseconds, 7)
        XCTAssertEqual(try ViewerArguments.parse(Self.minimal + ["--rtx-max-age", "1000"])
            .rtxMaxAgeMilliseconds, 1000)
        // ZERO IS REFUSED, not defaulted — the ABI's own rule. Refusing it here too means the
        // failure names the flag instead of surfacing as a bare INVALID_ARGUMENT from
        // rdev_viewer_create, which says nothing about which of eight fields was wrong.
        XCTAssertThrowsError(try ViewerArguments.parse(Self.minimal + ["--rtx-max-age", "0"]))
        XCTAssertThrowsError(try ViewerArguments.parse(Self.minimal + ["--rtx-max-age", "1001"]))
    }

    /// An unrecognised flag on a measurement instrument means the run is configured differently
    /// from how its operator believes it is. Dropping it silently is the `default: break` this
    /// repo has already paid for once in `web/src/lib/signaling.ts`.
    func testUnknownFlagIsRefused() {
        XCTAssertThrowsError(try ViewerArguments.parse(Self.minimal + ["--recovery-mode", "off"])) {
            XCTAssertEqual($0 as? ViewerArguments.Failure, .unknown("--recovery-mode"))
        }
    }

    func testInvalidRecoveryValueIsRefused() {
        XCTAssertThrowsError(try ViewerArguments.parse(Self.minimal + ["--recovery", "nack"]))
    }

    func testRequiredFlagsAreEnforced() {
        XCTAssertThrowsError(try ViewerArguments.parse(["--arm", "llv", "--out", "/tmp/x"])) {
            XCTAssertEqual($0 as? ViewerArguments.Failure, .missing("--duration"))
        }
        // The llv arm needs a signaling endpoint; without one the run cannot even be attempted.
        XCTAssertThrowsError(try ViewerArguments.parse(
            ["--arm", "llv", "--duration", "5", "--out", "/tmp/x"])) {
            XCTAssertEqual($0 as? ViewerArguments.Failure, .missing("--host"))
        }
    }

    /// A trailing flag with no value must report the MISSING VALUE, not "unknown option" —
    /// naming the wrong one turns a one-line fix into a hunt.
    func testTrailingFlagWithoutAValueIsReportedAsMissing() {
        XCTAssertThrowsError(try ViewerArguments.parse(Self.minimal + ["--recovery"])) {
            XCTAssertEqual($0 as? ViewerArguments.Failure, .missing("--recovery <value>"))
        }
    }

    func testZeroDurationIsRefused() {
        XCTAssertThrowsError(try ViewerArguments.parse(
            ["--arm", "llv", "--host", "127.0.0.1", "--port", "1",
             "--duration", "0", "--out", "/tmp/x"]))
    }

    // MARK: - the echo assertion

    func testRecoveryConfiguredPassesWhenTheSessionEchoesTheRequest() {
        let a = ViewerAssertions.recoveryConfigured(
            requested: .nackRtxFlexfec, requestedRtxMaxAgeMilliseconds: 30,
            reported: "nack-rtx-flexfec", reportedRtxMaxAgeMilliseconds: 30)
        XCTAssertTrue(a.evaluated)
        XCTAssertTrue(a.passed)
    }

    /// The bug this assertion exists for: the flag was parsed, and the session was configured
    /// with the DEFAULT anyway.
    func testRecoveryConfiguredFailsWhenTheModeNeverCrossedTheABI() {
        let a = ViewerAssertions.recoveryConfigured(
            requested: .nackRtxFlexfec, requestedRtxMaxAgeMilliseconds: 30,
            reported: "nack-rtx", reportedRtxMaxAgeMilliseconds: 30)
        XCTAssertTrue(a.evaluated)
        XCTAssertFalse(a.passed)
        XCTAssertTrue(a.detail.contains("nack-rtx-flexfec"), "detail must name what was asked")
    }

    /// The same bug in the OTHER field. Checking only the mode would leave `--rtx-max-age`
    /// undefended, and it is the field a full-recovery baseline reproduction actually varies.
    func testRecoveryConfiguredFailsWhenOnlyTheRtxAgeWasDropped() {
        let a = ViewerAssertions.recoveryConfigured(
            requested: .nackRtx, requestedRtxMaxAgeMilliseconds: 7,
            reported: "nack-rtx", reportedRtxMaxAgeMilliseconds: 30)
        XCTAssertFalse(a.passed)
    }

    func testRecoveryConfiguredIsUnevaluatedWithoutStats() {
        let a = ViewerAssertions.recoveryConfigured(
            requested: .nackRtx, requestedRtxMaxAgeMilliseconds: 30,
            reported: nil, reportedRtxMaxAgeMilliseconds: nil)
        XCTAssertFalse(a.evaluated)
        XCTAssertFalse(a.passed, "an unevaluated assertion must never read as a pass")
    }

    // MARK: - the source-prefs echo assertion

    // THE FINDING: `--fps` and `--bitrate` were documented as CONFIGURING the rdev arm. They are
    // a REQUEST. `set-source-prefs` is routed to `SimManager`, which does not exist on the
    // headless `RDEV_TEST_PATTERN=1` path, so on the only path ever smoked the message is parsed,
    // accepted and dropped — and the smoke passed `--bitrate 2000000`, which happens to equal
    // rdev's own default, so the host log agreed with both readings. Same shape as
    // `recovery-configured`: assert the ECHO, because a request that reached nothing is otherwise
    // indistinguishable from one that applied.

    func testSourcePrefsConfirmedPassesWhenTheHostEchoesTheRequest() {
        let a = ViewerAssertions.sourcePrefsConfirmed(
            requestedFps: 60, requestedBitrateBps: 8_000_000,
            echo: ViewerSourcePrefsEcho(fps: 60, bitrateBps: 8_000_000))
        XCTAssertTrue(a.evaluated)
        XCTAssertTrue(a.passed)
    }

    /// The measured case: the host accepted the message and kept its own prefs.
    func testSourcePrefsConfirmedFailsWhenTheHostKeptItsOwn() {
        let a = ViewerAssertions.sourcePrefsConfirmed(
            requestedFps: 60, requestedBitrateBps: 8_000_000,
            echo: ViewerSourcePrefsEcho(fps: 60, bitrateBps: 2_000_000))
        XCTAssertTrue(a.evaluated)
        XCTAssertFalse(a.passed)
        XCTAssertTrue(a.detail.contains("8000000"), "detail must name what was asked: \(a.detail)")
        XCTAssertTrue(a.detail.contains("2000000"), "and what came back: \(a.detail)")
    }

    /// fps alone is not the whole request — checking only the bitrate would leave `--fps`
    /// undefended, which is the same one-field hole `testRecoveryConfiguredFailsWhenOnlyTheRtxAge
    /// WasDropped` closes above.
    func testSourcePrefsConfirmedFailsWhenOnlyTheFpsWasDropped() {
        let a = ViewerAssertions.sourcePrefsConfirmed(
            requestedFps: 60, requestedBitrateBps: 8_000_000,
            echo: ViewerSourcePrefsEcho(fps: 30, bitrateBps: 8_000_000))
        XCTAssertFalse(a.passed)
    }

    /// THE HEADLESS CASE, and the whole point. No `view-set` for this source ever arrived, so the
    /// request is UNCONFIRMED. It must not read as a pass — that would be claiming a
    /// configuration the instrument cannot demonstrate — and it must say so, because
    /// `framesPerSecond` and `bitrateBitsPerSecond` in the report state the REQUEST either way.
    func testSourcePrefsAreUnconfirmedWithoutAnEcho() {
        let a = ViewerAssertions.sourcePrefsConfirmed(
            requestedFps: 60, requestedBitrateBps: 8_000_000, echo: nil)
        XCTAssertFalse(a.evaluated)
        XCTAssertFalse(a.passed, "an unevaluated assertion must never read as a pass")
        XCTAssertTrue(a.detail.localizedCaseInsensitiveContains("unconfirmed"),
                       "detail must say the request is unconfirmed: \(a.detail)")
        XCTAssertTrue(a.detail.contains("view-set"),
                       "detail must name what was missing: \(a.detail)")
    }

    /// A partial echo confirms only what it states. Treating an absent field as agreement would
    /// let half a dropped request pass.
    func testAPartialEchoLeavesTheMissingFieldUnconfirmed() {
        let a = ViewerAssertions.sourcePrefsConfirmed(
            requestedFps: 60, requestedBitrateBps: 8_000_000,
            echo: ViewerSourcePrefsEcho(fps: 60, bitrateBps: nil))
        XCTAssertFalse(a.evaluated)
        XCTAssertFalse(a.passed)
        XCTAssertTrue(a.detail.contains("bitrateBps"),
                       "detail must name WHICH field went unstated: \(a.detail)")
    }

    // MARK: - the rdev arm's own flags

    /// Everything the rdev arm needs EXCEPT a source. Kept separate because "exactly one of
    /// `--source` / `--source-name`" is itself a rule under test, and a fixture that satisfied it
    /// silently would make the rule untestable from the outside.
    private static let minimalRdevNoSource = [
        "--arm", "rdev", "--pairing-code", "AAAAAAAAAAAAAAAAAAAAAA",
        "--signaling", "http://127.0.0.1:8787",
        "--duration", "20", "--out", "/tmp/x.json",
    ]

    private static let minimalRdev = minimalRdevNoSource + ["--source", "test"]

    /// THE MAPPING THIS FILE EXISTS FOR, applied to the pairing code: the flag is a packed
    /// 30-char blob and what crosses the wire is the pair inside it. Splitting it in `parse`
    /// rather than in the run loop is what makes that testable at all.
    func testRdevSplitsThePairingCode() throws {
        let a = try ViewerArguments.parse(Self.minimalRdev)
        XCTAssertEqual(a.sessionCode, "1DB6haeo")
        XCTAssertEqual(a.sessionToken, "0d002ad3-28b2-4e70-b483-8fae577d1756")
        XCTAssertEqual(a.signalingOrigin, "http://127.0.0.1:8787")
    }

    /// A pasted connect URL is what an operator has to hand when the host banner scrolled past;
    /// `parsePairing` accepts it, so this arm does too.
    func testRdevAcceptsAPastedConnectURLAsThePairingCode() throws {
        let a = try ViewerArguments.parse(
            Self.minimalRdev.map {
                $0 == "AAAAAAAAAAAAAAAAAAAAAA"
                    ? "http://x/?code=rm5skaUZ&token=d5a9507e-22e8-49e7-8a9d-045c82960c23" : $0
            })
        XCTAssertEqual(a.sessionCode, "rm5skaUZ")
    }

    /// Reported as a bad FLAG, before any socket exists. A code that reaches the control plane
    /// undecoded comes back as `bad-token`, which reads as a host problem.
    func testRdevRejectsAnUndecodablePairingCode() {
        XCTAssertThrowsError(try ViewerArguments.parse(
            Self.minimalRdev.map { $0 == "AAAAAAAAAAAAAAAAAAAAAA" ? "nope" : $0 }))
    }

    /// Validated by BUILDING the session URL: a scheme the derivation cannot map would
    /// otherwise surface as a socket that never opens.
    func testRdevRejectsASignalingOriginItCannotDerive() {
        XCTAssertThrowsError(try ViewerArguments.parse(
            Self.minimalRdev.map { $0 == "http://127.0.0.1:8787" ? "127.0.0.1:8787" : $0 }))
    }

    func testRdevRequiresPairingCodeAndSignaling() {
        XCTAssertThrowsError(try ViewerArguments.parse(
            ["--arm", "rdev", "--duration", "5", "--out", "/tmp/x.json"]))
        XCTAssertThrowsError(try ViewerArguments.parse(
            ["--arm", "rdev", "--pairing-code", "AAAAAAAAAAAAAAAAAAAAAA",
             "--duration", "5", "--out", "/tmp/x.json"]))
    }

    /// The llv arm must not have acquired new required flags.
    func testLLVArmNeedsNoPairingCode() throws {
        let a = try ViewerArguments.parse(Self.minimal)
        XCTAssertEqual(a.sessionCode, "")
        XCTAssertEqual(a.sessionToken, "")
        XCTAssertEqual(a.signalingOrigin, "")
    }

    /// `--source` and `--host-log-source` NAME THE SAME THING — the host labels its `[latency]`
    /// lines with the source id — so an absent `--host-log-source` follows `--source`. Defaulted
    /// independently, `--source win:42` alone produced `accounting-reconciled` UNEVALUATED, which
    /// on this arm is a gate failure whose cause is a flag nobody was told to pass.
    func testHostLogSourceFollowsSource() throws {
        let a = try ViewerArguments.parse(Self.minimalRdevNoSource + ["--source", "win:42"])
        XCTAssertEqual(a.sourceIDs, ["win:42"])
        XCTAssertEqual(a.hostLogSource, "win:42")
    }

    // MARK: - more than one source

    /// `--source` REPEATS, and the first is the primary. Attributing a frame to the window it came
    /// from cannot be checked with one window subscribed — a resolution returning the first MSID
    /// for everything is indistinguishable from a correct one — so the plural is what makes the
    /// gate's attribution assertions falsifiable.
    func testSourceRepeatsAndTheFirstIsPrimary() throws {
        let a = try ViewerArguments.parse(
            Self.minimalRdevNoSource + ["--source", "win:42", "--source", "win:7"])
        XCTAssertEqual(a.sourceIDs, ["win:42", "win:7"])
    }

    /// The sender count on a multi-source run is the SUM over every subscribed source, so an
    /// unstated `--host-log-source` stays "" — the run substitutes the whole resolved list. Left
    /// following the FIRST source it would compare a total against one window's part, which
    /// surfaces as `accounting-reconciled` UNEVALUATED with no cause anywhere in the report.
    func testMultipleSourcesLeaveTheLogLabelToTheRun() throws {
        let a = try ViewerArguments.parse(
            Self.minimalRdevNoSource + ["--source", "win:42", "--source", "win:7"])
        XCTAssertEqual(a.hostLogSource, "")
    }

    /// ...and an explicit one still wins over the list.
    func testExplicitHostLogSourceOverridesAMultiSourceRun() throws {
        let a = try ViewerArguments.parse(
            Self.minimalRdevNoSource
                + ["--source", "win:42", "--source", "win:7", "--host-log-source", "win:7"])
        XCTAssertEqual(a.hostLogSource, "win:7")
    }

    /// A REPEATED id is refused rather than deduplicated: subscribing one source twice is a no-op
    /// on the host, so the run would report ONE row for what was asked for as two — which is
    /// exactly the reading a broken MSID resolution produces.
    func testARepeatedSourceIsRefused() {
        XCTAssertThrowsError(try ViewerArguments.parse(
            Self.minimalRdevNoSource + ["--source", "win:42", "--source", "win:42"]))
    }

    // MARK: - decode fault injection

    func testDecodeFaultDefaultsToOff() throws {
        XCTAssertEqual(try ViewerArguments.parse(Self.minimalRdev).decodeFaultAtFrame, 0)
    }

    func testDecodeFaultAtFrameIsParsed() throws {
        let a = try ViewerArguments.parse(Self.minimalRdev + ["--decode-fault-at", "300"])
        XCTAssertEqual(a.decodeFaultAtFrame, 300)
    }

    /// Refused rather than clamped to the OFF value: `--decode-fault-at -1` is an operator who
    /// meant something, and a silent 0 produces a clean run proving the opposite of what was asked.
    func testANegativeDecodeFaultIsRefused() {
        XCTAssertThrowsError(try ViewerArguments.parse(
            Self.minimalRdev + ["--decode-fault-at", "-1"]))
    }

    /// The timing-bias defaults are the identity, so an ordinary measurement run is never
    /// silently biased.
    func testInterarrivalBiasDefaultsToOff() throws {
        let a = try ViewerArguments.parse(Self.minimalRdev)
        XCTAssertEqual(a.interarrivalBiasMilliseconds, 0)
        XCTAssertEqual(a.interarrivalBiasScale, 1)
    }

    func testInterarrivalBiasIsParsed() throws {
        let a = try ViewerArguments.parse(Self.minimalRdev
            + ["--interarrival-bias-ms", "4.5", "--interarrival-bias-scale", "1.25"])
        XCTAssertEqual(a.interarrivalBiasMilliseconds, 4.5)
        XCTAssertEqual(a.interarrivalBiasScale, 1.25)
    }

    /// A non-positive scale is REFUSED rather than clamped to 1. Silently substituting the OFF
    /// value would let a fault-injection run report "green under an injected fault", which is
    /// the exact false result the gate exists to prevent.
    func testANonPositiveInterarrivalBiasScaleIsRefused() {
        XCTAssertThrowsError(try ViewerArguments.parse(
            Self.minimalRdev + ["--interarrival-bias-scale", "0"]))
        XCTAssertThrowsError(try ViewerArguments.parse(
            Self.minimalRdev + ["--interarrival-bias-scale", "-2"]))
    }

    /// ...and an explicit one still wins, in either order.
    func testExplicitHostLogSourceOverridesSource() throws {
        let a = try ViewerArguments.parse(
            Self.minimalRdevNoSource + ["--source", "win:42", "--host-log-source", "other"])
        XCTAssertEqual(a.hostLogSource, "other")
        let b = try ViewerArguments.parse(
            Self.minimalRdevNoSource + ["--host-log-source", "other", "--source", "win:42"])
        XCTAssertEqual(b.hostLogSource, "other")
    }

    // MARK: - naming the source

    /// THE DEFAULT IS GONE, DELIBERATELY. `--source` used to default to `test`, the headless
    /// pattern. Once the rdev arm captures a real window, that default is the difference between
    /// measuring rdev's production capture path and measuring a synthetic timer — and the run
    /// reports the same shape of result either way, which is why it must be typed.
    func testTheRdevArmRefusesToGuessASource() {
        XCTAssertThrowsError(try ViewerArguments.parse(Self.minimalRdevNoSource)) {
            XCTAssertEqual($0 as? ViewerArguments.Failure, .missing("--source or --source-name"))
        }
    }

    /// Both is a contradiction the run would otherwise have to resolve silently.
    func testSourceAndSourceNameAreMutuallyExclusive() {
        XCTAssertThrowsError(try ViewerArguments.parse(
            Self.minimalRdevNoSource + ["--source", "win:42", "--source-name", "Motion"]))
    }

    /// `--source-name` leaves the ID unknown until the host answers, and `hostLogSource` empty
    /// with it — "" is the RUN's signal to substitute the id it resolved. Both flags refuse an
    /// empty value, so "" can never be an operator's string.
    func testSourceNameLeavesTheIdAndLogLabelToBeResolvedAtRunTime() throws {
        let a = try ViewerArguments.parse(
            Self.minimalRdevNoSource + ["--source-name", "Software Motion"])
        XCTAssertEqual(a.sourceName, "Software Motion")
        XCTAssertEqual(a.sourceIDs, [])
        XCTAssertEqual(a.hostLogSource, "")
    }

    func testEmptySourceNamesAreRefused() {
        XCTAssertThrowsError(try ViewerArguments.parse(
            Self.minimalRdevNoSource + ["--source-name", ""]))
        XCTAssertThrowsError(try ViewerArguments.parse(
            Self.minimalRdevNoSource + ["--source", ""]))
        XCTAssertThrowsError(try ViewerArguments.parse(
            Self.minimalRdev + ["--host-log-source", ""]))
    }

    /// An explicit `--host-log-source` still wins under `--source-name`, for the case where the
    /// host labels its `[latency]` lines with something other than the id.
    func testExplicitHostLogSourceSurvivesSourceName() throws {
        let a = try ViewerArguments.parse(
            Self.minimalRdevNoSource + ["--source-name", "Motion", "--host-log-source", "win:9"])
        XCTAssertEqual(a.hostLogSource, "win:9")
    }

    /// The provenance strings default PER ARM; the rdev arm names rdev's own encoder.
    func testRdevArmProvenanceDefaults() throws {
        let a = try ViewerArguments.parse(Self.minimalRdev)
        XCTAssertEqual(a.encoderIdentity, "rdev-host-svt-av1")
        XCTAssertEqual(a.hostDescription, "RdevHostHarness")
    }
}
