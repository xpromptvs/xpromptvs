import Foundation

public struct ViewerAssertion: Codable, Equatable {
    public let name: String
    public let passed: Bool
    /// False when the inputs for this assertion were not available. LOAD-BEARING: an assertion
    /// that could not be checked must be distinguishable from one that passed. Collapsing the two
    /// — reporting `passed: true` for something never evaluated — is precisely the silently
    /// degraded run the whole failure policy exists to prevent.
    public let evaluated: Bool
    public let detail: String

    public init(name: String, passed: Bool, evaluated: Bool = true, detail: String) {
        self.name = name
        self.passed = passed
        self.evaluated = evaluated
        self.detail = detail
    }
}

/// One run's output. Field names that already exist in
/// `host/streaming-engine/results/20260807/libwebrtc-viewer-receiver/*/report.json` keep their
/// names and units, so trust-ladder step 2 is a direct diff rather than a mapping exercise.
public struct ViewerReport: Codable, Equatable {
    public let schemaVersion: Int
    public let arm: String                       // "llv" | "rdev-llv"
    public let rdevRevision: String
    public let rdevDirty: Bool
    public let encoderIdentity: String
    public let negotiatedCodec: String
    public let libwebrtcRevision: String
    public let impairmentProfile: String
    public let impairmentSeed: UInt64
    /// THE TEST-ONLY TIMING FAULT THIS RUN WAS INJECTED WITH, `0` / `1` when it was not.
    ///
    /// IN THE REPORT, NOT ONLY ON STDERR, AND THAT IS THE WHOLE POINT. `ViewerRun` already warns
    /// loudly when either is set, but a warning is on a stream nobody keeps: the gate's fault
    /// runs and its real runs write to the SAME work directory, so a `viewer-3.json` found there
    /// later is indistinguishable from a measurement unless it says so itself. That is exactly
    /// the misreading the warning names — "a biased report being read later as if it were a
    /// measurement" — and a warning cannot prevent it.
    ///
    /// The precedent is `impairmentProfile` / `impairmentSeed` directly above: a condition the
    /// run was placed under, recorded in the artifact rather than only in the console. The
    /// sibling fault `--decode-fault-at` needs none of this because its fault surfaces in
    /// `decodeErrors` as `"INJECTED fault at frame N"` — it is already self-describing.
    ///
    /// Identity values, like `impairmentProfile: "none"`: `0` ms and `1`x inject nothing.
    public let interarrivalBiasMilliseconds: Double
    public let interarrivalBiasScale: Double
    /// WHICH rdev source this run captured — `test`, or the `win:<cgWindowID>` the run resolved.
    /// nil on the llv arm, which has no rdev source at all (`capture-host` captures a display).
    ///
    /// It is in the report rather than only in the gate's shell variables because under
    /// `--source-name` the id is decided AT RUN TIME, and it is the key the host's `[latency]`
    /// lines are labelled with — so an analysis that has the report but not the console output
    /// cannot otherwise say what was measured, nor find the sender's frame count.
    public let sourceId: String?
    public let sourceWidth: Int
    public let sourceHeight: Int
    /// THE REQUEST, not the outcome — what `--fps` / `--bitrate` ASKED the source to be. On the
    /// llv arm they configure the sender directly; on the rdev arm they are the `client-hello`'s preferences,
    /// the host may accept, clamp, or (on the headless path) discard entirely. Read them beside
    /// `effectiveFramesPerSecond` / `effectiveBitrateBitsPerSecond` and `source-prefs-confirmed`,
    /// never alone.
    public let framesPerSecond: Int
    public let bitrateBitsPerSecond: Int
    /// THE OUTCOME, as the host echoed it in `view-set` — nil when it never echoed one for this
    /// source, which is the llv arm always and the headless rdev path today. nil is "the host
    /// said nothing", NOT "the host said the request was refused"; `source-prefs-confirmed`
    /// reports that difference as unevaluated rather than as a failure.
    public let effectiveFramesPerSecond: Int?
    public let effectiveBitrateBitsPerSecond: Int?
    public let hostUptimeSeconds: Int
    public let hostDescription: String
    public let startedAtUtc: String
    public let finishedAtUtc: String

    public let stampToDecode: ViewerDistribution?
    public let decoderInterarrival: ViewerDistribution?
    public let longestFreezeProxyMilliseconds: Double

    /// A LOWER BOUND on what the sender encoded, not an exact count — see `HostStageLog`. nil
    /// when the sender publishes no frame count at all (LLV's host prints no [latency] lines).
    ///
    /// The wire NAME is kept because the recorded baselines' comparison scripts key on it; the
    /// Swift type it comes from is `framesEncodedLowerBound` precisely so nothing INSIDE this
    /// program can read it as exact, and `framesEncoded > framesDecoded` in a report is expected
    /// rather than alarming. `accounting-reconciled`'s detail states the `>=` explicitly.
    public let framesEncoded: Int?
    public let framesDecoded: Int
    public let framesDropped: Int
    public let decodeErrors: Int
    public let stampsDecoded: Int

    /// WHAT THE DECODER'S OWN BOOKKEEPING SAYS, PER SOURCE — from the session's stats, keyed by
    /// the MSID each frame was attributed to.
    public let decodeBySource: [String: ViewerSourceDecode]
    /// WHAT THE FRAME CALLBACK ACTUALLY RECEIVED, PER SOURCE — counted on THIS side of the ABI,
    /// one increment per `on_video_frame` invocation, keyed by the `msid` argument.
    ///
    /// THE TWO MAPS ARE NOT REDUNDANT AND MUST NOT BE MERGED. `decodeBySource` is written by the
    /// C++ from the same local it passes to the callback, so it proves the resolution happened;
    /// only this one proves the resolved value CROSSED THE ABI. The Swift trampoline used to
    /// discard the `msid` parameter outright (`{ context, _, frame, … }`) — an omission that
    /// nothing on either side could see, because each half was independently correct.
    public let callbackFramesBySource: [String: Int]
    /// Decoder invocations whose `decoder_invoked_nanoseconds` did not advance past the previous
    /// one for their SSRC, summed over every source. Zero is the assertion; a non-zero count is a
    /// genuine defect rather than a scheduling artefact (libwebrtc decodes each receive stream on
    /// its own serialized queue).
    public let decoderInvocationRegressions: Int

    public let packetsLost: Int
    /// KEYFRAMES ASSEMBLED FROM RTP — libwebrtc's `keyFramesDecoded`, which despite its name is
    /// incremented at frame assembly (`ReceiveStatisticsProxy::OnCompleteFrame`) and not by any
    /// decoder. It therefore describes the stream this session received rather than this
    /// viewer's decode path, which is what makes it the ONE field in this report a browser can
    /// be compared against directly: Chrome reads the same name out of the same library.
    ///
    /// DO NOT READ IT AS A SUBSET OF `framesDecoded`. That one is the viewer's OWN accounting
    /// (decoder invocations that produced a picture); this one is libwebrtc's, from a different
    /// vantage point and a different clock. They are not two slices of one count.
    public let keyFramesDecoded: Int
    public let pliCount: Int
    public let firCount: Int
    public let bytesReceived: Int
    public let retransmittedBytesReceived: Int
    public let fecBytesReceived: Int

    /// THE REQUEST, echoed back out of the session's own stats rather than restated from the
    /// command line — so this pair says the flag reached `rdev_viewer_configuration`, not merely
    /// that it was typed. `recovery` and `rtxMaxAgeMilliseconds` are the names the recorded
    /// baselines already use for exactly these two numbers.
    public let recovery: String
    public let rtxMaxAgeMilliseconds: Int
    /// THE OUTCOME. Null until an answer exists, and null when the answer agreed no RTX age at
    /// all. `negotiatedRecovery` being nil is a different reading from `"off"`: "off" is a
    /// measurement, nil is the absence of one.
    public let negotiatedRecovery: String?
    public let negotiatedRTXTimeMilliseconds: Int?

    public let assertions: [ViewerAssertion]

    /// Spelled out rather than synthesized, for two reasons that both concern the READER of a
    /// report rather than this type.
    ///
    ///  * It is the one authoritative list of the wire names, and those names are FROZEN: every
    ///    key already in `host/streaming-engine/results/20260807/libwebrtc-viewer-receiver/*/
    ///    report.json` keeps its name and unit, so trust-ladder step 2 is a direct diff rather
    ///    than a mapping exercise.
    ///  * `CaseIterable` lets a test assert that the emitted JSON's key set is EXACTLY this list.
    ///    That is what defends the hand-written `encode(to:)` below: a field forgotten there
    ///    would otherwise vanish from every report silently, which is a worse failure than the
    ///    omitted-optionals one it exists to fix.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, arm, rdevRevision, rdevDirty, encoderIdentity, negotiatedCodec
        case libwebrtcRevision, impairmentProfile, impairmentSeed
        case interarrivalBiasMilliseconds, interarrivalBiasScale
        case sourceId, sourceWidth, sourceHeight, framesPerSecond, bitrateBitsPerSecond
        case effectiveFramesPerSecond, effectiveBitrateBitsPerSecond
        case hostUptimeSeconds, hostDescription, startedAtUtc, finishedAtUtc
        case stampToDecode, decoderInterarrival, longestFreezeProxyMilliseconds
        case framesEncoded, framesDecoded, framesDropped, decodeErrors, stampsDecoded
        case decodeBySource, callbackFramesBySource, decoderInvocationRegressions
        case packetsLost, keyFramesDecoded, pliCount, firCount
        case bytesReceived, retransmittedBytesReceived, fecBytesReceived
        case recovery, rtxMaxAgeMilliseconds
        case negotiatedRecovery, negotiatedRTXTimeMilliseconds
        case assertions
    }

    /// EVERY FIELD IS WRITTEN, INCLUDING THE NIL ONES, WHICH IS WHY THIS IS HAND-WRITTEN.
    ///
    /// Synthesized `Codable` emits optionals with `encodeIfPresent`, so a nil `framesEncoded`,
    /// `negotiatedRecovery`, `negotiatedRTXTimeMilliseconds`, `stampToDecode` or
    /// `decoderInterarrival` simply VANISHED from the JSON. An absent key and a null value are
    /// different claims: a gate reading `report["negotiatedRecovery"]` got a KeyError where it
    /// expected None, and "the answer named no rtx-time" — which is a real measurement, and one
    /// the gates should be able to read positively — was indistinguishable from a schema that
    /// never had the field.
    ///
    /// So the rule this encoder holds is: a `ViewerReport`'s key set does not depend on its
    /// contents. Every report carries every key, and an unavailable value is `null`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(arm, forKey: .arm)
        try c.encode(rdevRevision, forKey: .rdevRevision)
        try c.encode(rdevDirty, forKey: .rdevDirty)
        try c.encode(encoderIdentity, forKey: .encoderIdentity)
        try c.encode(negotiatedCodec, forKey: .negotiatedCodec)
        try c.encode(libwebrtcRevision, forKey: .libwebrtcRevision)
        try c.encode(impairmentProfile, forKey: .impairmentProfile)
        try c.encode(impairmentSeed, forKey: .impairmentSeed)
        try c.encode(interarrivalBiasMilliseconds, forKey: .interarrivalBiasMilliseconds)
        try c.encode(interarrivalBiasScale, forKey: .interarrivalBiasScale)
        try c.encodeOrNull(sourceId, forKey: .sourceId)
        try c.encode(sourceWidth, forKey: .sourceWidth)
        try c.encode(sourceHeight, forKey: .sourceHeight)
        try c.encode(framesPerSecond, forKey: .framesPerSecond)
        try c.encode(bitrateBitsPerSecond, forKey: .bitrateBitsPerSecond)
        try c.encodeOrNull(effectiveFramesPerSecond, forKey: .effectiveFramesPerSecond)
        try c.encodeOrNull(effectiveBitrateBitsPerSecond, forKey: .effectiveBitrateBitsPerSecond)
        try c.encode(hostUptimeSeconds, forKey: .hostUptimeSeconds)
        try c.encode(hostDescription, forKey: .hostDescription)
        try c.encode(startedAtUtc, forKey: .startedAtUtc)
        try c.encode(finishedAtUtc, forKey: .finishedAtUtc)
        try c.encodeOrNull(stampToDecode, forKey: .stampToDecode)
        try c.encodeOrNull(decoderInterarrival, forKey: .decoderInterarrival)
        try c.encode(longestFreezeProxyMilliseconds, forKey: .longestFreezeProxyMilliseconds)
        try c.encodeOrNull(framesEncoded, forKey: .framesEncoded)
        try c.encode(framesDecoded, forKey: .framesDecoded)
        try c.encode(framesDropped, forKey: .framesDropped)
        try c.encode(decodeErrors, forKey: .decodeErrors)
        try c.encode(stampsDecoded, forKey: .stampsDecoded)
        try c.encode(decodeBySource, forKey: .decodeBySource)
        try c.encode(callbackFramesBySource, forKey: .callbackFramesBySource)
        try c.encode(decoderInvocationRegressions, forKey: .decoderInvocationRegressions)
        try c.encode(packetsLost, forKey: .packetsLost)
        try c.encode(keyFramesDecoded, forKey: .keyFramesDecoded)
        try c.encode(pliCount, forKey: .pliCount)
        try c.encode(firCount, forKey: .firCount)
        try c.encode(bytesReceived, forKey: .bytesReceived)
        try c.encode(retransmittedBytesReceived, forKey: .retransmittedBytesReceived)
        try c.encode(fecBytesReceived, forKey: .fecBytesReceived)
        try c.encode(recovery, forKey: .recovery)
        try c.encode(rtxMaxAgeMilliseconds, forKey: .rtxMaxAgeMilliseconds)
        try c.encodeOrNull(negotiatedRecovery, forKey: .negotiatedRecovery)
        try c.encodeOrNull(negotiatedRTXTimeMilliseconds, forKey: .negotiatedRTXTimeMilliseconds)
        try c.encode(assertions, forKey: .assertions)
    }

    /// NO DEFAULTS. Each of these four was defaulted once, and the shape of what that permits is
    /// the reason they are not: a caller that forgot all four still compiled, emitted
    /// `recovery: ""`, and produced a `recovery-configured` assertion comparing a request nobody
    /// made against an echo nobody checked. The compiler is a better reviewer than a reviewer.
    public init(
        schemaVersion: Int, arm: String, rdevRevision: String, rdevDirty: Bool,
        encoderIdentity: String, negotiatedCodec: String, libwebrtcRevision: String,
        impairmentProfile: String, impairmentSeed: UInt64,
        interarrivalBiasMilliseconds: Double, interarrivalBiasScale: Double,
        sourceId: String?,
        sourceWidth: Int, sourceHeight: Int, framesPerSecond: Int, bitrateBitsPerSecond: Int,
        effectiveFramesPerSecond: Int?, effectiveBitrateBitsPerSecond: Int?,
        hostUptimeSeconds: Int, hostDescription: String,
        startedAtUtc: String, finishedAtUtc: String,
        stampToDecode: ViewerDistribution?, decoderInterarrival: ViewerDistribution?,
        longestFreezeProxyMilliseconds: Double,
        framesEncoded: Int?, framesDecoded: Int, framesDropped: Int, decodeErrors: Int,
        stampsDecoded: Int,
        decodeBySource: [String: ViewerSourceDecode],
        callbackFramesBySource: [String: Int],
        decoderInvocationRegressions: Int,
        packetsLost: Int, keyFramesDecoded: Int, pliCount: Int, firCount: Int,
        bytesReceived: Int, retransmittedBytesReceived: Int, fecBytesReceived: Int,
        recovery: String, rtxMaxAgeMilliseconds: Int,
        negotiatedRecovery: String?, negotiatedRTXTimeMilliseconds: Int?,
        assertions: [ViewerAssertion]
    ) {
        self.schemaVersion = schemaVersion; self.arm = arm
        self.rdevRevision = rdevRevision; self.rdevDirty = rdevDirty
        self.encoderIdentity = encoderIdentity; self.negotiatedCodec = negotiatedCodec
        self.libwebrtcRevision = libwebrtcRevision
        self.impairmentProfile = impairmentProfile; self.impairmentSeed = impairmentSeed
        self.interarrivalBiasMilliseconds = interarrivalBiasMilliseconds
        self.interarrivalBiasScale = interarrivalBiasScale
        self.sourceId = sourceId
        self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        self.framesPerSecond = framesPerSecond; self.bitrateBitsPerSecond = bitrateBitsPerSecond
        self.effectiveFramesPerSecond = effectiveFramesPerSecond
        self.effectiveBitrateBitsPerSecond = effectiveBitrateBitsPerSecond
        self.hostUptimeSeconds = hostUptimeSeconds; self.hostDescription = hostDescription
        self.startedAtUtc = startedAtUtc; self.finishedAtUtc = finishedAtUtc
        self.stampToDecode = stampToDecode; self.decoderInterarrival = decoderInterarrival
        self.longestFreezeProxyMilliseconds = longestFreezeProxyMilliseconds
        self.framesEncoded = framesEncoded; self.framesDecoded = framesDecoded
        self.framesDropped = framesDropped; self.decodeErrors = decodeErrors
        self.stampsDecoded = stampsDecoded
        self.decodeBySource = decodeBySource
        self.callbackFramesBySource = callbackFramesBySource
        self.decoderInvocationRegressions = decoderInvocationRegressions
        self.packetsLost = packetsLost
        self.keyFramesDecoded = keyFramesDecoded
        self.pliCount = pliCount; self.firCount = firCount
        self.bytesReceived = bytesReceived
        self.retransmittedBytesReceived = retransmittedBytesReceived
        self.fecBytesReceived = fecBytesReceived
        self.recovery = recovery
        self.rtxMaxAgeMilliseconds = rtxMaxAgeMilliseconds
        self.negotiatedRecovery = negotiatedRecovery
        self.negotiatedRTXTimeMilliseconds = negotiatedRTXTimeMilliseconds
        self.assertions = assertions
    }
}

private extension KeyedEncodingContainer {
    /// `encode` for a value that may be absent, writing JSON `null` rather than dropping the key.
    /// Spelled out with `encodeNil` instead of relying on `Optional`'s own Encodable conformance,
    /// because the overload that would be chosen for an optional argument is a detail of
    /// resolution rules and the one that is easy to reach by accident (`encodeIfPresent`) is
    /// exactly the behaviour this exists to avoid.
    mutating func encodeOrNull<T: Encodable>(_ value: T?, forKey key: K) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

/// The six assertions the spec requires on every run. A run failing any of them is NOT
/// COMPARABLE, which is a different outcome from a bad result — so all six are always emitted,
/// including the ones that passed, and no caller may skip one it expects to hold.
public enum ViewerAssertions {
    /// `senderFrameCountDetail` is the reason `framesEncoded` is nil, and it is a REQUIRED
    /// argument because the three reasons are not interchangeable: no `--host-log` was given, the
    /// path could not be read, or it was read and held no `[latency]` line for this source. On
    /// the llv arm the first is expected and unevaluated is the right answer; on the rdev arm,
    /// where Task 13 requires every assertion evaluated and passed, the other two present as the
    /// same gate failure with no cause. `HostStageOutcome.unavailableDetail` supplies it.
    public static func evaluate(
        setupError: String?, watchdogExpired: Bool, negotiatedCodec: String,
        framesEncodedLowerBound: Int?, senderFrameCountDetail: String,
        framesDecoded: Int, framesDropped: Int,
        accountingTolerance: Int, stampsDecoded: Int, stampCoverageFloor: Double,
        measuredBitrateBps: Int, targetBitrateBps: Int, bitrateBand: Double,
        cleanShutdown: Bool
    ) -> [ViewerAssertion] {
        var out: [ViewerAssertion] = []

        let executionOK = setupError == nil && !watchdogExpired
        out.append(ViewerAssertion(
            name: "execution-valid", passed: executionOK,
            detail: setupError ?? (watchdogExpired ? "watchdog expired" : "no setup or watchdog error")))

        out.append(ViewerAssertion(
            name: "codec-as-expected", passed: negotiatedCodec == "AV1",
            detail: "negotiated \(negotiatedCodec)"))

        // The sender's frame count is not always available: it comes from rdev's [latency] lines,
        // which LLV's host does not print. Emit the assertion UNEVALUATED rather than passing it,
        // so a gate can decide per arm whether that is acceptable.
        if let framesEncodedLowerBound {
            // `encoded>=`, NOT `encoded=`. The number is a lower bound (`HostStageLog`), and the
            // detail string is the only thing a gate operator reads — stating it as an exact
            // count is what made a truncated read present as fifteen lost frames.
            let counts = "encoded>=\(framesEncodedLowerBound) decoded=\(framesDecoded) "
                + "dropped=\(framesDropped) tol=\(accountingTolerance)"
            switch ViewerAccounting.reconcile(
                encoded: framesEncodedLowerBound, decoded: framesDecoded,
                dropped: framesDropped, tolerance: accountingTolerance) {
            case .reconciled:
                out.append(ViewerAssertion(
                    name: "accounting-reconciled", passed: true, detail: counts))
            case let .unaccounted(missing):
                out.append(ViewerAssertion(
                    name: "accounting-reconciled", passed: false,
                    detail: counts + " unaccounted=\(missing)"))
            case let .senderCountBelowDecoded(by):
                // UNEVALUATED, and this is the honest reading rather than a lenience. Decoding
                // more frames than the sender is KNOWN to have encoded says nothing about the
                // media — it says the sender's count was read before its last window was
                // printed. The input this assertion needs (an exact sender count) was not
                // available, which is precisely what `evaluated: false` means everywhere else in
                // this file.
                out.append(ViewerAssertion(
                    name: "accounting-reconciled", passed: false, evaluated: false,
                    detail: counts + " — the sender count is a LOWER BOUND and decoded+dropped "
                        + "exceeds it by \(by); the host's [latency] reporter prints every 5s, so "
                        + "a run's final window is routinely unpublished when the log is read"))
            }
        } else {
            out.append(ViewerAssertion(
                name: "accounting-reconciled", passed: false, evaluated: false,
                detail: senderFrameCountDetail))
        }

        // Two escapes, both UNEVALUATED rather than passed -- "0/0 = 1.000" reads as a
        // clean pass, which is exactly the collapse ViewerAssertion.evaluated exists to
        // prevent (see its doc comment). A run that decoded zero frames proves nothing
        // about the instrument -- that is the assertion the whole parity claim rests on,
        // so it must not read as healthy. Zero STAMPS out of a real decode is the
        // legitimate case: LLV's host paints no rdev stamp, so that arm has no stamps to
        // find and must not fail an assertion about an instrument its sender never used --
        // but "never used" is still not "checked and found fine".
        let coverageEvaluated: Bool
        let coverageOK: Bool
        let coverageDetail: String
        if framesDecoded == 0 {
            coverageEvaluated = false
            coverageOK = false
            coverageDetail = "0 frames decoded"
        } else if stampsDecoded == 0 {
            coverageEvaluated = false
            coverageOK = false
            coverageDetail = "sender paints no stamp (0/\(framesDecoded) decoded frames stamped)"
        } else {
            let coverage = Double(stampsDecoded) / Double(framesDecoded)
            coverageEvaluated = true
            coverageOK = coverage >= stampCoverageFloor
            coverageDetail = String(format: "%d/%d = %.3f, floor %.3f",
                                     stampsDecoded, framesDecoded, coverage, stampCoverageFloor)
        }
        out.append(ViewerAssertion(
            name: "stamp-coverage", passed: coverageOK, evaluated: coverageEvaluated,
            detail: coverageDetail))

        let drift = targetBitrateBps == 0 ? 0
            : abs(Double(measuredBitrateBps - targetBitrateBps)) / Double(targetBitrateBps)
        out.append(ViewerAssertion(
            name: "bitrate-controlled", passed: drift <= bitrateBand,
            detail: String(format: "measured=%d target=%d drift=%.3f band=%.3f",
                           measuredBitrateBps, targetBitrateBps, drift, bitrateBand)))

        out.append(ViewerAssertion(
            name: "clean-shutdown", passed: cleanShutdown,
            detail: cleanShutdown ? "closed without error" : "shutdown incomplete"))

        return out
    }

    /// Did `--recovery` and `--rtx-max-age` actually REACH the session?
    ///
    /// A SEVENTH assertion, additive to the spec's six, and it exists because of this project's
    /// most-repeated bug shape: a flag parsed into a variable that never crosses the ABI. The
    /// run then measures a configuration nobody chose, reports the number that WAS typed, and
    /// every field in the results file agrees with every other one.
    ///
    /// IT COMPARES THE REQUEST TO ITS ECHO, NOT TO THE OUTCOME — deliberately, and this is the
    /// distinction that makes it safe to assert on both arms. The session's `recovery` and
    /// `rtxMaxAgeMilliseconds` stats are what it was CONFIGURED with; `negotiatedRecovery` and
    /// `negotiatedRTXTimeMilliseconds` are what the far end agreed. Only the answerer settles
    /// the latter, so on the rdev arm — where the viewer answers and `recovery_mode` configures
    /// nothing — a disagreement is correct behaviour and must not fail. Asserting the echo
    /// catches the dropped flag and nothing else, which is the whole point.
    ///
    /// `reported == nil` means the stats could not be read at all; that is UNEVALUATED rather
    /// than failed, because `execution-valid` is the assertion that owns "the run was broken".
    public static func recoveryConfigured(
        requested: ViewerRecoveryMode, requestedRtxMaxAgeMilliseconds: Int,
        reported: String?, reportedRtxMaxAgeMilliseconds: Int?
    ) -> ViewerAssertion {
        guard let reported, let reportedRtxMaxAgeMilliseconds else {
            return ViewerAssertion(
                name: "recovery-configured", passed: false, evaluated: false,
                detail: "session stats unavailable")
        }
        let matches = reported == requested.rawValue
            && reportedRtxMaxAgeMilliseconds == requestedRtxMaxAgeMilliseconds
        return ViewerAssertion(
            name: "recovery-configured", passed: matches,
            detail: "asked \(requested.rawValue)/\(requestedRtxMaxAgeMilliseconds)ms, "
                + "session reports \(reported)/\(reportedRtxMaxAgeMilliseconds)ms")
    }

    /// Did `--fps` and `--bitrate` actually reach the SOURCE?
    ///
    /// An EIGHTH assertion, and the sibling of `recoveryConfigured` above — same bug shape, other
    /// end of the run. There it is a flag that never crossed the ABI; here it is a control message
    /// the host accepts and drops. `ChannelHub` routes `set-source-prefs` through `simDelegate`,
    /// which is **nil on the headless `RDEV_TEST_PATTERN=1` path** — no `SimManager` exists there —
    /// so the message passes the active-client gate and reaches nothing. Every observable agrees
    /// with both readings, and the first rdev-arm smoke asked for rdev's own default bitrate, so
    /// even the host's `[encode]` line did.
    ///
    /// SO A REQUEST IS NOT A DECISION. The report states the request in `framesPerSecond` /
    /// `bitrateBitsPerSecond` whatever happened; this says whether the host ever agreed, and
    /// `effectiveFramesPerSecond` / `effectiveBitrateBitsPerSecond` carry what it agreed to.
    ///
    /// `echo == nil` — no `view-set` entry for this source — is UNEVALUATED, not failed. The host
    /// publishing nothing about a source is not the host disagreeing about it, and the llv arm
    /// has no `view-set` at all. A partial echo is unevaluated for the same reason, per FIELD: an
    /// unstated value cannot confirm anything, and treating absence as agreement would let half a
    /// dropped request through.
    public static func sourcePrefsConfirmed(
        requestedFps: Int, requestedBitrateBps: Int, echo: ViewerSourcePrefsEcho?
    ) -> ViewerAssertion {
        let asked = "asked fps=\(requestedFps) bitrateBps=\(requestedBitrateBps)"
        guard let echo else {
            return ViewerAssertion(
                name: "source-prefs-confirmed", passed: false, evaluated: false,
                detail: asked + " — UNCONFIRMED: the host published no `view-set` entry for this "
                    + "source, so nothing says the request was applied")
        }
        let unstated = [echo.fps == nil ? "fps" : nil,
                        echo.bitrateBps == nil ? "bitrateBps" : nil].compactMap { $0 }
        guard unstated.isEmpty, let fps = echo.fps, let bitrateBps = echo.bitrateBps else {
            return ViewerAssertion(
                name: "source-prefs-confirmed", passed: false, evaluated: false,
                detail: asked + " — UNCONFIRMED: the host's `view-set` entry states no "
                    + unstated.joined(separator: " and no "))
        }
        return ViewerAssertion(
            name: "source-prefs-confirmed",
            passed: fps == requestedFps && bitrateBps == requestedBitrateBps,
            detail: asked + ", host reports fps=\(fps) bitrateBps=\(bitrateBps)")
    }
}

public struct HostStages: Equatable {
    /// AT LEAST this many frames were encoded — never exactly this many. NAMED FOR IT because
    /// the number's only consumer is an equation against `framesDecoded`, and `framesEncoded`
    /// sitting beside `framesDecoded` invites reading the pair as two exact counts. See
    /// `HostStageLog`'s doc comment for where the missing frames go.
    public let framesEncodedLowerBound: Int
    public let overlayP95Milliseconds: Double
    public let encodeP95Milliseconds: Double
    public let deliverP95Milliseconds: Double
}

/// What came of trying to read the host's `[latency]` log — with the FAILURES kept apart from
/// the ordinary absence.
///
/// WHY THE DISTINCTION IS THE POINT. `framesEncoded` is nil in three quite different situations,
/// and collapsing them (which a bare `try?` does) makes a mistyped `--host-log` path
/// indistinguishable from a probe that was never switched on. Harmless on the llv arm, where
/// unevaluated is the expected answer anyway; on the rdev arm, where Task 13 requires every
/// assertion evaluated and passed, it presents as a gate failure whose cause is nowhere in the
/// report.
public enum HostStageOutcome: Equatable {
    /// No `--host-log` was given. The llv arm's normal state: LLV's host prints no `[latency]`
    /// lines, so there is nothing to point at.
    case notRequested
    /// A path was given and could not be read at all — wrong path, or no permission.
    case unreadable(path: String, reason: String)
    /// The file was read and holds no `[latency]` line for ANY of these sources — the probe was
    /// off (`RDEV_LATENCY_PROBE=1` unset), or the labels name sources the host never reported on.
    ///
    /// ANY, not ALL, is deliberate: on a multi-source run the sender count is the SUM over the
    /// subscribed sources, so a log carrying lines for one of two is a partial count that would
    /// under-state `framesEncoded` — and an under-stated lower bound reads as
    /// `senderCountBelowDecoded`, i.e. UNEVALUATED, rather than as a failure. `sources` therefore
    /// carries every label that was looked for and `missing` says which of them were not found.
    case noMatchingLines(path: String, sources: [String], missing: [String])
    case parsed(HostStages)

    public var stages: HostStages? {
        if case let .parsed(stages) = self { return stages }
        return nil
    }

    public var framesEncodedLowerBound: Int? { stages?.framesEncodedLowerBound }

    /// The `accounting-reconciled` detail when there is no sender frame count. "" when parsed —
    /// the assertion has real inputs then and writes its own detail.
    public var unavailableDetail: String {
        switch self {
        case .notRequested:
            return "sender frame count unavailable (no --host-log)"
        case let .unreadable(path, reason):
            return "sender frame count unavailable: --host-log \(path) could not be read (\(reason))"
        case let .noMatchingLines(path, sources, missing):
            return "sender frame count unavailable: --host-log \(path) holds no [latency] line "
                + "for source\(missing.count == 1 ? "" : "s") "
                + missing.map { "'\($0)'" }.joined(separator: ", ")
                + (sources.count > missing.count
                    ? " (the run needed all of \(sources.joined(separator: ", ")))" : "")
        case .parsed:
            return ""
        }
    }
}

/// Reads the host's `[latency]` lines, which `LatencyStages` (`host/RdevHostKit/Sources/
/// RdevHostKit/LatencyStages.swift`) prints to stdout every 5 seconds under
/// `RDEV_LATENCY_PROBE=1`:
///
///   [latency] <source> n=300 overlay p50=0.2 p95=0.4 · encode p50=3.1 p95=4.8 · deliver p50=0.3 p95=0.9 ms
///
/// (or `<stage> -` in place of `<stage> p50=… p95=…` for a stage that recorded no samples in the
/// window — `LatencyStages.report()`'s own fallback.)
///
/// Each line describes its OWN window and the counters are cleared after printing, so `n` sums
/// across lines. Percentiles do NOT sum and averaging percentiles is
/// meaningless, so the worst window's p95 is reported instead — the tail is the interesting part.
///
/// THE SUM IS A LOWER BOUND ON WHAT THE HOST ENCODED, NEVER AN EXACT FIGURE — hence
/// `framesEncodedLowerBound`. The reporter prints a window only every 5 seconds and clears its
/// counters afterwards, so the frames encoded since the last line have not been published yet and
/// cannot be read from anywhere. A viewer reading this file at the end of its own run therefore
/// misses up to one full window every time, systematically. MEASURED: a 20 s rdev run decoded 199
/// frames against a sum of 184, the remaining two `n=50` windows landing after the read.
///
/// The consequence a caller must handle: `decoded > sum` is ORDINARY, not a fault. Frames cannot
/// be decoded that were never encoded, so that direction can only be this bound being low —
/// `ViewerAccounting.Outcome.senderCountBelowDecoded` is where it goes, and it is deliberately
/// neither a pass nor a failure.
public enum HostStageLog {
    /// Reads `path` (when there is one) and classifies the result.
    ///
    /// `read` is injected rather than called directly so both failure branches are reachable from
    /// a test without touching a filesystem — the caller passes
    /// `{ try String(contentsOfFile: $0, encoding: .utf8) }`. That is the whole reason the
    /// signature is shaped this way: the branch that matters most here is the one that only
    /// happens when the read THROWS, and a test that has to arrange an unreadable file to reach
    /// it is a test that will be written differently on every machine.
    public static func load(
        path: String?, source: String, read: (String) throws -> String
    ) -> HostStageOutcome {
        load(path: path, sources: [source], read: read)
    }

    /// The multi-source form. `sources` is every label whose `[latency]` lines belong to this
    /// run, and the frame counts are SUMMED across them — because on a run with two subscribed
    /// windows `framesDecoded` is likewise the total over both tracks, and comparing that against
    /// one window's sender count is not a tolerance question but a category error.
    ///
    /// The p95s are still the WORST window seen across every source, for the same reason the
    /// single-source form takes the worst window across time: percentiles do not sum, and the
    /// tail is the interesting part.
    public static func load(
        path: String?, sources: [String], read: (String) throws -> String
    ) -> HostStageOutcome {
        guard let path else { return .notRequested }
        let text: String
        do {
            text = try read(path)
        } catch {
            return .unreadable(path: path, reason: "\(error)")
        }
        let found = sources.map { ($0, parse(text, source: $0)) }
        let missing = found.filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty, !found.isEmpty else {
            return .noMatchingLines(path: path, sources: sources, missing: missing)
        }
        let stages = found.compactMap(\.1)
        return .parsed(HostStages(
            framesEncodedLowerBound: stages.reduce(0) { $0 + $1.framesEncodedLowerBound },
            overlayP95Milliseconds: stages.map(\.overlayP95Milliseconds).max() ?? 0,
            encodeP95Milliseconds: stages.map(\.encodeP95Milliseconds).max() ?? 0,
            deliverP95Milliseconds: stages.map(\.deliverP95Milliseconds).max() ?? 0))
    }

    public static func parse(_ text: String, source: String) -> HostStages? {
        var frames = 0
        var worst: [String: Double] = ["overlay": 0, "encode": 0, "deliver": 0]
        var sawSource = false

        for line in text.split(separator: "\n") {
            guard line.hasPrefix("[latency] ") else { continue }
            let fields = line.dropFirst("[latency] ".count).split(separator: " ")
            guard let name = fields.first, String(name) == source else { continue }
            sawSource = true

            // A small state machine over the tokens, rather than indexing backward from a `p95=`
            // token: the line is `<stage> p50=.. p95=..` repeated, joined by a literal `·`, so
            // tracking "which stage came most recently" is exact and needs no arithmetic on
            // positions (which would be one stray token away from an out-of-range crash).
            var currentStage: String?
            for field in fields {
                if field.hasPrefix("n="), let n = Int(field.dropFirst(2)) {
                    frames += n
                } else if worst.keys.contains(String(field)) {
                    currentStage = String(field)
                } else if field.hasPrefix("p95="), let stage = currentStage,
                          let v = Double(field.dropFirst(4)) {
                    if v > (worst[stage] ?? 0) { worst[stage] = v }
                }
            }
        }
        guard sawSource else { return nil }
        return HostStages(
            framesEncodedLowerBound: frames,
            overlayP95Milliseconds: worst["overlay"] ?? 0,
            encodeP95Milliseconds: worst["encode"] ?? 0,
            deliverP95Milliseconds: worst["deliver"] ?? 0)
    }
}
