import Foundation

/// The recovery configuration a run ASKS FOR — the value that has to reach
/// `rdev_viewer_configuration.recovery_mode`, not a label for one.
///
/// `rawValue` is BOTH the command-line spelling AND the string the session reports back under
/// `recovery` in its stats (C++ `RecoveryModeName`), and that coincidence is deliberate: it is
/// what lets `ViewerAssertions.recoveryConfigured` compare a request against its echo without a
/// translation table in between. A table is where "the flag was parsed but never crossed the
/// ABI" hides.
public enum ViewerRecoveryMode: String, CaseIterable, Sendable {
    case off = "off"
    case nackRtx = "nack-rtx"
    case nackRtxFlexfec = "nack-rtx-flexfec"

    /// `RDEV_VIEWER_RECOVERY_*` verbatim (include/CRdevViewer.h). Not an ordinal — the ABI's
    /// numbering is `nack-rtx = 1, nack-rtx-flexfec = 2, off = 3`, which is neither
    /// alphabetical nor declaration order, and a zero is REFUSED by the C++ validator rather
    /// than defaulted. Anything that renumbers these silently reconfigures every run.
    public var wireValue: UInt8 {
        switch self {
        case .nackRtx: return 1
        case .nackRtxFlexfec: return 2
        case .off: return 3
        }
    }
}

/// One run's inputs. Pure: parsing is separated from the sockets and the run loop so the
/// mapping from a flag to the value that crosses the ABI is unit-testable, which is the
/// mapping this project has got wrong most often.
public struct ViewerArguments: Equatable, Sendable {
    public enum Arm: String, Sendable { case llv, rdev }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case unknown(String)
        case invalid(flag: String, value: String, expected: String)

        public var description: String {
            switch self {
            case let .missing(flag): return "missing required option \(flag)"
            case let .unknown(flag): return "unknown option \(flag)"
            case let .invalid(flag, value, expected):
                return "invalid value \"\(value)\" for \(flag) (expected \(expected))"
            }
        }
    }

    public var arm: Arm
    public var host: String
    public var port: Int
    public var durationSeconds: Double
    public var outputPath: String

    /// rdev arm. The 30-char opaque code the host prints, already SPLIT — so "the flag reached
    /// the value that crosses the wire" is a property of `parse` rather than of the run loop.
    /// Both are "" on the llv arm.
    public var sessionCode: String
    public var sessionToken: String
    /// rdev arm. The control plane's HTTP origin; the WebSocket URL is derived from it by
    /// `RdevViewerSignaling.sessionURL`.
    public var signalingOrigin: String
    /// rdev arm. The source ids to subscribe (`test` on the headless `RDEV_TEST_PATTERN=1` path,
    /// `win:<cgWindowID>` for a real window). EMPTY when the run names its source by
    /// `--source-name` instead, in which case the id is only known once the host's `source-list`
    /// arrives.
    ///
    /// REPEATABLE, and the reason is an assertion rather than a convenience: attributing a frame
    /// to the window it came from cannot be checked with one window subscribed, because a
    /// resolution that returned the first MSID for everything — or the empty string — would be
    /// indistinguishable from a correct one. `--source A --source B` is what makes that
    /// falsifiable, so the plural is load-bearing.
    ///
    /// THE FIRST ONE IS THE PRIMARY, and the asymmetry is real: it is the source that gets
    /// `focus-source` (so it streams at full rate while the rest are host-throttled), the one whose
    /// preference echo is read, the one `sourceId` names in the report, and the one whose decode
    /// timestamps `decoderInterarrival` is computed from. Interleaving two sources' arrival times
    /// into one distribution would produce a number describing neither.
    public var sourceIDs: [String]
    /// rdev arm. A substring of the source NAME, resolved against the host's own `source-list` at
    /// run time. Exactly one of this and `sourceID` is set; "" here means `--source` was used.
    ///
    /// This exists because a window id cannot be known in advance for the one target that matters
    /// (`llv presentation-motion`, frozen by G1, prints none) — see `ViewerSourceList`.
    public var sourceName: String

    public var hostLogPath: String?
    /// The `[latency] <source>` label to look for in `--host-log`.
    ///
    /// "" means "follow the source id", which under `--source-name` is only knowable at run time —
    /// `--source` and `--host-log-source` both REFUSE an empty value, so "" here is unambiguous
    /// and never an operator's string.
    public var hostLogSource: String

    public var recovery: ViewerRecoveryMode
    public var rtxMaxAgeMilliseconds: Int

    public var framesPerSecond: Int
    public var targetBitrateBitsPerSecond: Int

    public var impairmentProfile: String
    public var impairmentSeed: UInt64

    public var stampCoverageFloor: Double
    public var accountingTolerance: Int
    public var bitrateBand: Double
    public var watchdogSeconds: Double

    /// Where to write ONE decoded frame as a greyscale PNG, or nil for the default: write none.
    ///
    /// It answers the one question no counter in the report can: whether the two arms decoded the
    /// SAME SCENE. Two arms measuring different content is invisible in frame counts, interarrival,
    /// stamp coverage and bitrate — every one of which reads perfectly on a run that captured the
    /// wrong window — so a cross-arm comparison that cannot check this is trusting a coincidence.
    public var frameDumpPath: String?

    /// Where to write ONE LINE PER DECODED FRAME that carried an INPUT stamp — `ordinal`,
    /// `stampMs` and `decodedMs` as JSON — or nil for the default: write none, read no second
    /// stamp row, and copy no extra rows off the decode path.
    ///
    /// This is what makes `tools/InputLatencyTarget` measurable. That target paints TWO stamp
    /// rows (row 0 the wall clock, row 1 the input ordinal) and `ViewerStampDecode.readInputStamp`
    /// reads both, but nothing in this repo consumed it: every other consumer here reads row 0
    /// alone, through `ViewerStampDecode.read`, and reports a DISTRIBUTION rather than a series.
    /// An input-to-decode measurement needs the series, because each sample has to be paired back
    /// to the specific input that produced it (`InputToDecode.pair`).
    ///
    /// OFF BY DEFAULT, and the default is the pre-existing behaviour BYTE FOR BYTE — no second
    /// decode, no larger luma copy, no file. C1's thresholds were measured on that path and its
    /// gates still run on it, so an instrument change that applied to every run would silently
    /// invalidate them.
    public var inputStampsPath: String?

    /// FAULT INJECTION: make the Nth `on_video_frame` invocation return
    /// `RDEV_VIEWER_DECODE_FAILED`. 0 (the default) injects nothing at all.
    ///
    /// THIS SEAM IS DELIBERATELY ON THE SWIFT SIDE. Task 8 designed and rejected a C++
    /// frame-injection seam: a synthetic buffer is not an AV1 bitstream, so it would have proved
    /// only that our half of the mechanism works while leaving libwebrtc's half — the part that
    /// can actually fail — untested. Here the frame is a real AV1 access unit on a real receive
    /// stream, and the only thing manufactured is this decoder's ANSWER. It needs no ABI change.
    ///
    /// The injected frame is NOT decoded, on purpose. Returning failure after quietly decoding
    /// would leave the VideoToolbox session's reference chain intact and test only the counter;
    /// what the assertion is actually about is that a real mid-stream decode failure leaves the
    /// session open and recovers, which is a property of libwebrtc's keyframe request and the
    /// host's response to it.
    public var decodeFaultAtFrame: Int

    /// FAULT INJECTION for the TIMING path, and the reason it exists is that nothing else on
    /// this branch can falsify it. `--decode-fault-at` proves a COUNTING check can disagree;
    /// these two prove the timing cross-check can. `scripts/gate-viewer-timing-equivalence.sh`
    /// is the only caller, and it uses both — a clock-RATE error (`scale`) and a per-frame
    /// constant (`offsetMs`) — because an external check that cannot go red for either is not a
    /// check. Defaults `0` / `1` inject nothing and take the identity path in `ViewerMetrics`.
    ///
    /// TEST-ONLY. A run using either produces a report whose `decoderInterarrival` and
    /// `longestFreezeProxyMilliseconds` are DELIBERATELY WRONG, and the viewer says so loudly on
    /// stderr for exactly that reason.
    public var interarrivalBiasMilliseconds: Double
    public var interarrivalBiasScale: Double

    public var encoderIdentity: String
    public var libwebrtcRevision: String
    public var hostDescription: String
    public var hostUptimeSeconds: Int

    public static let usage = """
    Usage:
      RdevViewer --arm llv  --host IPv4 --port PORT --duration SECONDS --out PATH [common]
      RdevViewer --arm rdev --pairing-code CODE30 --signaling ORIGIN --duration SECONDS
                 --out PATH (--source ID [--source ID…] | --source-name SUBSTRING) [common]

      common:
        [--host-log PATH] [--host-log-source ID] [--decode-fault-at N]
        [--interarrival-bias-ms MS] [--interarrival-bias-scale X]   (TEST-ONLY fault injection)
        [--recovery off|nack-rtx|nack-rtx-flexfec] [--rtx-max-age MS]
        [--fps N] [--bitrate BITS_PER_SECOND]
        [--impairment-profile NAME] [--impairment-seed N]
        [--stamp-coverage-floor F] [--accounting-tolerance N] [--bitrate-band F]
        [--watchdog SECONDS] [--frame-dump PATH.png] [--input-stamps PATH.jsonl]
        [--encoder-identity S] [--libwebrtc-revision S]
        [--host-description S] [--host-uptime-seconds N]
    """

    /// Defaults are the SPEC CONTROLS Task 12 pins, not conveniences: 60 fps, 8,000,000 bit/s
    /// (LLV's per-source budget, and what the recorded baselines were produced at) and a 30 ms
    /// RTX age (`rtxMaxAgeMilliseconds` in those same baselines). `--recovery` defaults to
    /// `nack-rtx` for the same reason.
    public static func parse(_ arguments: [String]) throws -> ViewerArguments {
        var arm: Arm?
        var host: String?
        var port: Int?
        var duration: Double?
        var out: String?
        var pairingCode: String?
        var signaling: String?
        // BOTH nil-by-default, and neither has a fallback: `--source` used to default to "test",
        // and a default source on a MEASUREMENT INSTRUMENT is the wrong shape of convenience. A
        // run that meant to capture a window and silently captured the headless test pattern
        // instead produces a full, self-consistent report of the wrong thing — the same class of
        // failure `--source-name`'s ambiguity check exists to prevent, one flag earlier.
        var sources: [String] = []
        var sourceName: String?
        var decodeFaultAtFrame = 0
        var interarrivalBiasMs = 0.0
        var interarrivalBiasScale = 1.0
        var hostLog: String?
        // nil means "not given", which is NOT the same as the default: an explicit
        // --host-log-source must win, and an absent one follows --source. See the guard below.
        var hostLogSource: String?
        var recovery = ViewerRecoveryMode.nackRtx
        var rtxMaxAge = 30
        var fps = 60
        var bitrate = 8_000_000
        var impairmentProfile = "none"
        var impairmentSeed: UInt64 = 0
        var stampCoverageFloor = 0.9
        var accountingTolerance = 3
        var bitrateBand = 0.1
        var watchdog = 10.0
        var frameDump: String?
        var inputStamps: String?
        var encoderIdentity = ""
        var libwebrtcRevision = ""
        var hostDescription = ""
        var hostUptimeSeconds = 0

        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            // Every option takes exactly one value, so a flag with nothing after it is a
            // MISSING VALUE rather than an unknown flag — naming the right one is the
            // difference between a one-line fix and a hunt.
            guard index + 1 < arguments.count else { throw Failure.missing("\(flag) <value>") }
            let value = arguments[index + 1]
            index += 2

            func number<T: FixedWidthInteger>(_ expected: String) throws -> T {
                guard let parsed = T(value) else {
                    throw Failure.invalid(flag: flag, value: value, expected: expected)
                }
                return parsed
            }
            func real(_ expected: String) throws -> Double {
                guard let parsed = Double(value) else {
                    throw Failure.invalid(flag: flag, value: value, expected: expected)
                }
                return parsed
            }

            switch flag {
            case "--arm":
                guard let parsed = Arm(rawValue: value) else {
                    throw Failure.invalid(flag: flag, value: value, expected: "llv or rdev")
                }
                arm = parsed
            case "--host": host = value
            case "--port": port = try number("a TCP port")
            case "--duration": duration = try real("seconds")
            case "--out": out = value
            case "--pairing-code": pairingCode = value
            case "--signaling": signaling = value
            case "--source": sources.append(value)
            case "--source-name": sourceName = value
            case "--decode-fault-at": decodeFaultAtFrame = try number("a frame number, or 0")
            case "--interarrival-bias-ms": interarrivalBiasMs = try real("milliseconds, or 0")
            case "--interarrival-bias-scale":
                interarrivalBiasScale = try real("a positive multiplier, or 1")
            case "--host-log": hostLog = value
            case "--host-log-source": hostLogSource = value
            case "--recovery":
                guard let parsed = ViewerRecoveryMode(rawValue: value) else {
                    throw Failure.invalid(
                        flag: flag, value: value,
                        expected: ViewerRecoveryMode.allCases.map(\.rawValue).joined(separator: ", "))
                }
                recovery = parsed
            case "--rtx-max-age": rtxMaxAge = try number("1..1000 milliseconds")
            case "--fps": fps = try number("frames per second")
            case "--bitrate": bitrate = try number("bits per second")
            case "--impairment-profile": impairmentProfile = value
            case "--impairment-seed": impairmentSeed = try number("an unsigned integer")
            case "--stamp-coverage-floor": stampCoverageFloor = try real("a fraction 0..1")
            case "--accounting-tolerance": accountingTolerance = try number("a frame count")
            case "--bitrate-band": bitrateBand = try real("a fraction 0..1")
            case "--watchdog": watchdog = try real("seconds")
            case "--frame-dump": frameDump = value
            case "--input-stamps": inputStamps = value
            case "--encoder-identity": encoderIdentity = value
            case "--libwebrtc-revision": libwebrtcRevision = value
            case "--host-description": hostDescription = value
            case "--host-uptime-seconds": hostUptimeSeconds = try number("seconds")
            default:
                // Never silently ignored. An unrecognised flag on a measurement instrument is
                // a run configured differently from how its operator believes it was.
                throw Failure.unknown(flag)
            }
        }

        guard let arm else { throw Failure.missing("--arm") }
        guard let out else { throw Failure.missing("--out") }
        guard let duration else { throw Failure.missing("--duration") }
        guard duration > 0 else {
            throw Failure.invalid(flag: "--duration", value: "\(duration)", expected: "> 0")
        }
        // Refused HERE as well as by the C++ validator, so the failure names the flag rather
        // than surfacing as a bare RDEV_VIEWER_INVALID_ARGUMENT from rdev_viewer_create. Zero
        // is the value a zero-filled configuration carries, which is exactly why the ABI
        // refuses it instead of defaulting.
        // Frames are counted from 1, so a negative is meaningless and 0 is the OFF value. Refused
        // rather than clamped: `--decode-fault-at -1` is an operator who meant something, and a
        // silent 0 would produce a clean run that proves the opposite of what was asked for.
        guard decodeFaultAtFrame >= 0 else {
            throw Failure.invalid(flag: "--decode-fault-at", value: "\(decodeFaultAtFrame)",
                                  expected: "a frame number >= 1, or 0 to inject nothing")
        }
        // REFUSED, NOT CLAMPED, for the same reason `--decode-fault-at -1` is: a scale of 0 or
        // less is an operator who meant something, and silently substituting 1 would produce a
        // clean run that proves the OPPOSITE of what was asked for — a fault-injection gate
        // would then report "the check went green under an injected fault" as a real result.
        guard interarrivalBiasScale > 0 else {
            throw Failure.invalid(flag: "--interarrival-bias-scale",
                                  value: "\(interarrivalBiasScale)",
                                  expected: "a positive multiplier (1 injects nothing)")
        }
        guard (1 ... 1000).contains(rtxMaxAge) else {
            throw Failure.invalid(flag: "--rtx-max-age", value: "\(rtxMaxAge)",
                                  expected: "1..1000 milliseconds")
        }
        if arm == .llv {
            guard let hostValue = host else { throw Failure.missing("--host") }
            guard let portValue = port, (1 ... 65535).contains(portValue) else {
                throw Failure.missing("--port")
            }
            host = hostValue
            port = portValue
        }

        var sessionCode = ""
        var sessionToken = ""
        if arm == .rdev {
            guard let code = pairingCode else { throw Failure.missing("--pairing-code") }
            // SPLIT HERE, not in the run loop. A code that does not decode is an operator typo,
            // and it must be reported as one -- naming the flag -- before a socket is opened and
            // the control plane answers `bad-token`, which reads as a host problem.
            guard let pairing = parsePairing(code) else {
                throw Failure.invalid(
                    flag: "--pairing-code", value: code,
                    expected: "the 22-character pairing code the host prints, or a connect URL")
            }
            sessionCode = pairing.code
            sessionToken = pairing.token
            guard let origin = signaling else { throw Failure.missing("--signaling") }
            // Validated by BUILDING the URL, not by inspecting the string: the derivation is the
            // thing that has to work, and a scheme this cannot map (`ftp://`, a bare host:port)
            // would otherwise surface as a socket that never opens.
            guard RdevViewerSignaling.sessionURL(signaling: origin, code: pairing.code) != nil
            else {
                throw Failure.invalid(
                    flag: "--signaling", value: origin,
                    expected: "an http(s):// or ws(s):// origin, e.g. http://127.0.0.1:8787")
            }
            signaling = origin
            // EXACTLY ONE OF THE TWO, and neither is optional. Both is a contradiction the run
            // would have to resolve silently; neither used to mean `test`, which is the headless
            // pattern — a run that meant a window and got that instead measures a different
            // engine path and says so nowhere.
            switch (sources.isEmpty, sourceName == nil) {
            case (true, true): throw Failure.missing("--source or --source-name")
            case (false, false):
                throw Failure.invalid(
                    flag: "--source-name", value: sourceName ?? "",
                    expected: "not to be combined with --source — give exactly one")
            default: break
            }
            if let empty = sources.first(where: \.isEmpty) {
                throw Failure.invalid(flag: "--source", value: empty,
                                      expected: "a source id, e.g. test or win:1234")
            }
            // A REPEATED id is refused rather than deduplicated. Subscribing the same source
            // twice is a no-op on the host, so the run would proceed and report ONE row for what
            // the operator asked to measure as two — which is exactly the reading a broken MSID
            // resolution produces, from a cause the report cannot show.
            if Set(sources).count != sources.count {
                throw Failure.invalid(
                    flag: "--source", value: sources.joined(separator: ", "),
                    expected: "distinct source ids — a repeat cannot be a second source")
            }
            if let sourceName, sourceName.isEmpty {
                throw Failure.invalid(
                    flag: "--source-name", value: sourceName,
                    expected: "a substring of a source name, e.g. \"Software Motion\"")
            }
        }
        if let hostLogSource, hostLogSource.isEmpty {
            throw Failure.invalid(flag: "--host-log-source", value: hostLogSource,
                                  expected: "a source id, e.g. test or win:1234")
        }

        return ViewerArguments(
            arm: arm, host: host ?? "", port: port ?? 0,
            durationSeconds: duration, outputPath: out,
            sessionCode: sessionCode, sessionToken: sessionToken,
            signalingOrigin: signaling ?? "", sourceIDs: sources,
            sourceName: sourceName ?? "",
            hostLogPath: hostLog,
            // AN ABSENT --host-log-source FOLLOWS --source, because they name the SAME thing:
            // the host's `[latency]` lines are labelled with the source id
            // (`LatencyStages.record(… source: sourceID …)`). Defaulting it independently to
            // "test" meant `--source win:42` alone produced `accounting-reconciled` UNEVALUATED
            // -- which on this arm is a gate failure whose cause is a flag nobody was told to
            // pass. An explicit value still wins, for the case where they genuinely differ.
            //
            // Under `--source-name` there is no id yet, so this stays "" and the RUN substitutes
            // the id it resolved. Both flags refuse an empty value, so "" cannot be a request.
            //
            // On a MULTI-source run it stays "" too, even though ids are known: the sender count
            // is the SUM over every subscribed source, and a single label would silently make it
            // one window's count. "" hands the whole list to the run, which is the only place the
            // resolved set exists.
            hostLogSource: hostLogSource ?? (sources.count == 1 ? sources[0] : ""),
            recovery: recovery, rtxMaxAgeMilliseconds: rtxMaxAge,
            framesPerSecond: fps, targetBitrateBitsPerSecond: bitrate,
            impairmentProfile: impairmentProfile, impairmentSeed: impairmentSeed,
            stampCoverageFloor: stampCoverageFloor, accountingTolerance: accountingTolerance,
            bitrateBand: bitrateBand, watchdogSeconds: watchdog, frameDumpPath: frameDump,
            inputStampsPath: inputStamps,
            decodeFaultAtFrame: decodeFaultAtFrame,
            interarrivalBiasMilliseconds: interarrivalBiasMs,
            interarrivalBiasScale: interarrivalBiasScale,
            // The two provenance strings default PER ARM rather than to one placeholder: they
            // name which encoder produced the pixels, and "unknown" in a parity report is the
            // one answer that makes the comparison unreadable afterwards.
            encoderIdentity: encoderIdentity.isEmpty
                ? (arm == .llv ? "llv-capture-host-libaom-av1" : "rdev-host-svt-av1")
                : encoderIdentity,
            libwebrtcRevision: libwebrtcRevision,
            hostDescription: hostDescription.isEmpty
                ? (arm == .llv ? "llv capture-host" : "RdevHostHarness")
                : hostDescription,
            hostUptimeSeconds: hostUptimeSeconds)
    }
}
