import Accelerate
import CoreVideo
import Foundation
import LLVCore
import RdevCore

/// Conforms LLV's `RealtimeVideoEncoder` (libaom AV1) to rdev's `VideoEncoding`, so `SourceStream`,
/// `SimManager` and `ChannelHub` are unchanged. One per SOURCE, exactly like the SVT-AV1 `AV1Encoder`
/// it replaces: it is fed captured frames and fans each encoded temporal unit out to every registered
/// `TrackSink`, so N clients watching one window cost ONE encode.
///
/// `screenDetectionMode` is `.antialiasingAware` deliberately: every rdev source is a macOS window
/// full of anti-aliased text, and this is LLV's analogue of the SVT `scm=3` setting the previous
/// encoder used for exactly that reason. libaom's default detector is documented as easily fooled by
/// anti-aliased text into deciding the content is natural, which then disables palette mode and intra
/// block copy — the two tools that matter most for what rdev actually streams.
///
/// THE BRIEF'S PREMISE ABOUT PIXELS IS WRONG, AND THAT IS WHY THIS TYPE CONVERTS.
/// `RealtimeVideoEncoder.encode` does take a `CVPixelBuffer` directly, but LLV's libaom backend
/// accepts ONLY `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12) at EXACTLY the dimensions the
/// encoder was created with — `LLVCore.AV1Encoder.encode` throws `unexpectedPixelLayout` otherwise.
/// rdev's capture is `kCVPixelFormatType_32BGRA` end to end (`ScreenCaptureSource.makeConfig`,
/// `FrameOverlaySink`, `TestPatternSource`), so a BGRA→NV12 conversion is unavoidable here. It is not
/// a new cost: the SVT path already paid a BGRA→I420 conversion of the same shape. Converting here
/// rather than switching the capture format is deliberate — `FrameOverlaySink` (the cursor overlay and
/// the latency-probe stamp) is BGRA-only and would SILENTLY stop drawing, and the H.264/H.265
/// `VTEncoder` path takes BGRA directly.
///
/// THREADING — two locks, matching `AV1Encoder`'s split, and for the same reasons:
///   `lock`    guards sinks + prefs. Short holds, touched from the peer's ordered dispatcher.
///   `encLock` guards the libaom encoder, the staging buffer and the frame counter; used only by
///             `encode()`/`invalidate()`. A software encode takes milliseconds and must not block
///             addSink/removeSink; conversely `invalidate()` must not free the encoder out from under
///             an in-flight encode.
/// The lock ORDER is `encLock` then `lock` (the fan-out at the end of `encode`), never the reverse.
final class LLVEncoderAdapter: VideoEncoding, @unchecked Sendable {
    /// LOAD-BEARING. `SimManager.ensureEncoder` compares this against the freshly negotiated codec to
    /// decide whether a pooled encoder can be reused or must be rebuilt. libaom produces AV1 OBUs and
    /// `pion_peer_write_track_video` ships them as-is, so this encoder IS the connection's AV1 — a
    /// wrong value here silently rebuilds a good encoder every resolve, or silently reuses an AV1
    /// encoder on a track that negotiated H.265 (RTP flows, every state reads healthy, nothing decodes).
    var codec: NegotiatedCodec { negotiatedCodec }

    /// The codec this adapter was BUILT for. Immutable: a codec change is a new encoder, because
    /// changing it on a live one would mean a new SSRC and a fresh sequencer anyway.
    private let negotiatedCodec: NegotiatedCodec

    /// LLVCore's `VideoCodec` is the ENCODER's vocabulary; `NegotiatedCodec` is the WIRE's. Kept as
    /// separate types deliberately — the ABI already carries two different codec numberings in two
    /// directions, and conflating them is a recorded trap.
    private var llvCodec: LLVCore.VideoCodec {
        switch negotiatedCodec {
        case .av1: .av1
        case .h265: .hevc
        case .h264: .h264
        }
    }

    /// Names the codec in `[encode]` lines. That log is the only vantage point that knows what is
    /// really being encoded, so it must not say AV1 while VideoToolbox is producing H.264.
    private var codecLabel: String {
        switch negotiatedCodec {
        case .av1: "AV1"
        case .h265: "H.265"
        case .h264: "H.264"
        }
    }

    /// THE 72…3840 x 64…2160 CLAMP IS LIBAOM'S, NOT A PROPERTY OF ENCODING. `EncodeDimensions.fit`
    /// exists because libaom REFUSES anything outside it, and a refusal meant a source streamed zero
    /// frames indefinitely — for a window 8 px over on height. VideoToolbox has different limits, so
    /// applying libaom's to it would announce a `CLAMPED from …` downscale nothing required and
    /// quietly cost picture.
    ///
    /// The VideoToolbox bounds are deliberately generous rather than exact: this exists to avoid a
    /// hard refusal, and a session that still fails to create reports itself through the
    /// `FAILED to create` line below.
    static func dimensionBounds(
        for codec: NegotiatedCodec
    ) -> (minWidth: Int, maxWidth: Int, minHeight: Int, maxHeight: Int) {
        switch codec {
        case .av1:
            (RealtimeVideoDimensions.minimumWidth, RealtimeVideoDimensions.maximumWidth,
             RealtimeVideoDimensions.minimumHeight, RealtimeVideoDimensions.maximumHeight)
        case .h264, .h265:
            (16, 7680, 16, 4320)
        }
    }

    private let lock = NSLock()
    private var sinks: [SinkKey: any VideoTrackSink] = [:]
    private var forceKeyframe = false
    private var fps: Int
    private var bitrateBps: Int
    private var pendingBitrate = false

    private let encLock = NSLock()
    private var encoder: RealtimeVideoEncoder?
    private var staging: CVPixelBuffer?
    // Encoder queue only (encLock). A plan is consumed only after valid conversion.
    private var nextReferenceControl: AV1ReferenceControl?
    private var referencePlanner: ((String, UInt64, Bool) -> ReferenceFramePlan)?
    private var referenceRequest: ((RecoveryIntent) -> Void)?
    private var referenceFailure: (() -> Void)?
    private let recoveryQueue: DispatchQueue
    private var referenceConfiguration: UInt64 = 0
    private var referenceRequestSerial: UInt64 = 0, referenceServedSerial: UInt64 = 0
    private var referenceGeneration: UInt64 = 0 // lock-protected mirror for queued request admission
    private var referenceEnabled = false // guarded by lock; configuration/serials by encLock
    private var referenceEncoding = AV1ReferenceEncoding()
    private var referenceEpoch = UUID().uuidString
    // Guarded by lock, like ptsByFrameID, because receive() may be asynchronous.
    private var referenceByFrameID: [UInt64: AV1ReferenceFrameMetadata] = [:]

    /// Called on the serialized encoding path. The planner must be pure with respect to
    /// the encoder: no encoder reentry, network IO, or waiting on another dispatch queue.
    func setReferencePlanner(_ planner: @escaping (String, UInt64, Bool) -> ReferenceFramePlan,
                             onRequest: ((RecoveryIntent) -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        encLock.lock(); defer { encLock.unlock() }
        precondition(negotiatedCodec == .av1)
        referencePlanner = planner; referenceRequest = onRequest; referenceFailure = onFailure
        referenceConfiguration &+= 1
        referenceEncoding.reset()
        referenceEpoch = UUID().uuidString
        lock.lock(); forceKeyframe = true; referenceEnabled = true; referenceGeneration = referenceConfiguration; lock.unlock()
    }
    func disableReferencePlanner() {
        encLock.lock(); defer { encLock.unlock() }
        referenceConfiguration &+= 1
        referencePlanner = nil; referenceRequest = nil; referenceFailure = nil
        referenceEncoding.reset(); referenceEpoch = UUID().uuidString
        // Explicit libaom reference mode cannot return to automatic mode in place.
        encoder = nil; stagingValid = false
        lock.lock(); referenceEnabled = false; referenceGeneration = referenceConfiguration; forceKeyframe = true; referenceByFrameID.removeAll(); lock.unlock()
    }
    private func prepareReference(frameID: UInt64, force: Bool) throws -> AV1ReferenceEncoding.Prepared? {
        guard let referencePlanner else { return nil }
        let prepared = try referenceEncoding.prepare(referencePlanner(referenceEpoch, frameID, force),
                                                     epoch: referenceEpoch, frameID: frameID)
        lock.lock(); referenceByFrameID[frameID] = prepared.metadata; lock.unlock()
        return prepared
    }

    private let qualificationRecorder = AV1QualificationRecorder.configured()
    private var stagingValid = false
    private var lastEncodedPTS: Int64 = 0
    private var lastEncodedAt: UInt64 = 0
    private var lastRecoveryPTS: Int64 = 0

    func setReferenceControl(_ control: AV1ReferenceControl) {
        encLock.lock(); defer { encLock.unlock() }
        nextReferenceControl = control
    }

    /// A still screen may not produce another capture callback. Serialize with conversion,
    /// reuse only a complete staging image, and assign a new monotonic media timestamp.
    @discardableResult
    func encodeRecoveryFromStaging(ptsNs: Int64) -> Bool {
        encLock.lock(); defer { encLock.unlock() }
        return encodeRecoveryFromStagingLocked(ptsNs: ptsNs)
    }
    private func encodeRecoveryFromStagingLocked(ptsNs: Int64) -> Bool {
        guard negotiatedCodec == .av1, stagingValid, let encoder, let staging,
              lastEncodedPTS < Int64.max else { return false }
        lock.lock()
        let force = forceKeyframe; forceKeyframe = false
        let rate = bitrateBps, applyRate = pendingBitrate; pendingBitrate = false
        let wantedFps = fps
        lock.unlock()
        guard wantedFps == encoderFps else {
            lock.lock(); forceKeyframe = true; if applyRate { pendingBitrate = true }; lock.unlock()
            return false
        }
        let timestamp = max(ptsNs, lastEncodedPTS + 1)
        frameID &+= 1
        let id = frameID
        lock.lock(); ptsByFrameID[id] = timestamp; lock.unlock()
        do {
            if applyRate { try encoder.setBitrate(rate) }
            let reference = try prepareReference(frameID: id, force: force)
            try encoder.encode(pixelBuffer: staging, frameID: id, inputSequence: id,
                               forceKeyframe: force || reference?.independent == true,
                               referenceControl: reference?.control ?? nextReferenceControl)
            if let reference { referenceEncoding.commit(reference) }
            nextReferenceControl = nil
            referenceServedSerial = referenceRequestSerial
            lastEncodedPTS = timestamp
            lastEncodedAt = DispatchTime.now().uptimeNanoseconds
            lastRecoveryPTS = timestamp
            return true
        } catch {
            referenceEncoding.reset(); referenceEpoch = UUID().uuidString
            lock.lock(); referenceByFrameID[id] = nil; forceKeyframe = true; ptsByFrameID[id] = nil; lock.unlock()
            return false
        }
    }

    /// The region the viewer can see. Everything else is filled with `Checkerboard` so the bitrate
    /// goes where it is being looked at rather than being spread over a window the viewer may be
    /// seeing a tenth of. Guarded by `lock`, like every other live-tunable.
    private var crop: CropRect = .full
    /// What the STAGING BUFFER currently reflects. `nil` means "unpainted".
    ///
    /// LOAD-BEARING that `recreate` resets this. A fresh staging buffer holds none of the previous
    /// one's pattern, so painting only when the CROP changes would work until Auto moved the scale —
    /// which happens the moment the user zooms, the moment this feature exists for. Guarded by
    /// `encLock`, alongside `staging` itself.
    private var paintedCrop: CropRect?
    /// The dimensions the CAPTURE SOURCE is emitting, and the (possibly smaller) ones the ENCODER was
    /// built with. They differ only when `EncodeDimensions.fit` had to clamp — see `encode`.
    private var sourceWidth = 0, sourceHeight = 0
    private var width = 0, height = 0, encoderFps = 0
    /// Scratch BGRA at the clamped size, allocated ONLY while a clamp is active. `nil` on the normal
    /// path, which is what keeps a source that fits from paying anything for this feature.
    private var scaled: UnsafeMutableRawPointer?
    private var scaledBytes = 0, scaledStride = 0
    /// libaom's PTS, in the encoder's 1/fps timebase. Monotonic per encoder; reset on recreate because
    /// the encoder is new and its timebase starts again.
    private var frameID: UInt64 = 0
    /// The (sourceW, sourceH, fps) a create already failed for, so a size libaom refuses does not
    /// re-attempt — and re-log — 60 times a second. Cleared by any change to those three. With the
    /// clamp in place this should now be unreachable for DIMENSION reasons; it still guards the rest
    /// (an out-of-range bitrate, an allocation failure, libaom refusing a control).
    private var createFailed: (w: Int, h: Int, fps: Int)?
    /// The capture timestamp of every frame currently INSIDE the encoder, keyed by the frame id its
    /// access unit comes back with.
    ///
    /// A MAP rather than one field, because an asynchronous backend can hold several frames at once.
    /// libaom returns before the next `encode`, so on that path it never holds more than one entry.
    /// Guarded by `lock` and NOT by `encLock`: `receive` may run on a thread holding neither, and it
    /// must never take `encLock` (see `receive`).
    private var ptsByFrameID: [UInt64: Int64] = [:]
    /// One-shot: a capture source emitting something other than BGRA is a wiring bug, not a frame
    /// event, and it would otherwise be a subscribed source with zero frames and zero diagnostics —
    /// in a subsystem where `[encode]` silence is documented to mean something else entirely.
    private var warnedPixelFormat = false

    /// Names this encoder in its log lines — the SOURCE id, since there is one encoder per source and
    /// the `[encode]` lines would otherwise be indistinguishable with several windows open.
    private let label: String

    /// libaom's `cpu-used`, 0 (slowest, best quality per bit) to 12 (fastest). It is a REAL
    /// PARAMETER as of 2026-08-17 and was a constant pinned inside `LibaomTuningProfile` before
    /// that, which is why the retired SVT preset ladder and the `RDEV_AV1_*` variables became
    /// inert when the encoder was swapped. The default is LLV's own, so rdev's behaviour is
    /// unchanged; deciding what the value SHOULD be per resolution is separate, measured work.
    private let cpuUsed: Int

    /// `codec` DEFAULTS TO `.av1` AND NOTHING PASSES ANYTHING ELSE YET. This increment adds the
    /// capability; SDP resolution supplies the real value in a later one. Same shape as `cpuUsed`,
    /// which became a real parameter while keeping its shipped value.
    init(fps: Int, bitrateBps: Int, label: String = "",
         cpuUsed: Int = RealtimeVideoEncoder.defaultCpuUsed,
         codec: NegotiatedCodec = .av1,
         recoveryQueue: DispatchQueue = DispatchQueue(label: "rdev.av1-recovery")) {
        self.recoveryQueue = recoveryQueue
        self.fps = fps
        self.bitrateBps = bitrateBps
        self.label = label
        self.cpuUsed = cpuUsed
        self.negotiatedCodec = codec
    }

    /// **THIS IS NOT `VTEncoder`'S USE-AFTER-FREE GUARD, AND NO SUCH GUARD IS NEEDED HERE.**
    ///
    /// `VTEncoder` needs one because VideoToolbox holds an UNRETAINED pointer to it (the callback
    /// refcon) and a frame in flight at dealloc fires the callback on freed memory — a SIGSEGV, not a
    /// dropped frame. libaom's Swift wrapper has NO such hazard: `CAOMBridge.c` registers no callback
    /// of any kind (`grep -c 'callback' CAOMBridge.c` == 0), `llv_aom_encoder_encode_nv12` is a
    /// synchronous one-in/one-out call, and `LLVCore.AV1Encoder` invokes its `outputHandler` inline on
    /// the calling thread before returning. There is no asynchronous path that can outlive this object,
    /// so the encoder itself needs nothing here — ARC releasing it IS the destroy.
    ///
    /// All this does is free `scaled`, a RAW allocation ARC does not manage. It is non-nil only while
    /// a source is being clamped to libaom's dimension limits, so on every ordinary teardown this is a
    /// no-op. `invalidate()` frees it too and nils it, so the two are idempotent with each other.
    ///
    /// The hazard that DOES exist here is the mirror image of VideoToolbox's: `LLVCore.AV1Encoder`
    /// stores its `outputHandler` strongly, so a handler capturing `self` strongly would form
    /// adapter → RealtimeVideoEncoder → AV1Encoder → closure → adapter, and NOTHING would ever
    /// dealloc — `llv_aom_encoder_destroy` would never run and every source would leak a libaom
    /// encoder plus its frame buffers for the host's lifetime. `[weak self]` in `recreate` is what
    /// closes that, and it is also what makes `invalidate()` deterministic: with no cycle, nilling
    /// `encoder` drops the last reference and `llv_aom_encoder_destroy` runs on that line. It is what
    /// makes THIS `deinit` reachable at all, too.
    deinit {
        scaled?.deallocate()
    }

    func addSink(_ s: any VideoTrackSink) {
        lock.lock(); sinks[s.sinkKey] = s; forceKeyframe = true; outSinkAttaches += 1; lock.unlock()
    }
    func removeSink(_ s: any VideoTrackSink) {
        lock.lock(); sinks[s.sinkKey] = nil; lock.unlock()
    }
    func removeAllSinks() { lock.lock(); sinks.removeAll(); lock.unlock() }
    func requestKeyframe() { requestRecovery(.independentKeyframe) }
    func requestRecovery(_ intent: RecoveryIntent) {
        lock.lock()
        outKeyframeRequests += 1
        let enabled = referenceEnabled, generation = referenceGeneration
        if !enabled { forceKeyframe = true }
        lock.unlock()
        guard enabled else { return }
        // Never make the ordered peer dispatcher wait on an in-progress encode.
        recoveryQueue.async { [weak self] in
            guard let self else { return }
            self.encLock.lock()
            guard self.referencePlanner != nil, self.referenceConfiguration == generation else { self.encLock.unlock(); return }
            let hasSinks = self.lock.withLock { !self.sinks.isEmpty }
            guard hasSinks else { self.encLock.unlock(); return }
            self.referenceRequest?(intent)
            if intent == .independentKeyframe {
                self.referenceEncoding.reset(); self.referenceEpoch = UUID().uuidString
                self.lock.lock(); self.forceKeyframe = true; self.lock.unlock()
            }
            self.referenceRequestSerial &+= 1
            let serial = self.referenceRequestSerial, configuration = self.referenceConfiguration
            self.encLock.unlock()
            self.recoveryQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                guard let self else { return }
                self.encLock.lock()
                guard self.referenceConfiguration == configuration, self.referenceRequestSerial == serial,
                      self.referenceServedSerial < serial, self.referencePlanner != nil else { self.encLock.unlock(); return }
                // Capture timestamps need not share the system-uptime epoch.
                // Advance from the last encoded capture using elapsed host time.
                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = Int64(clamping: now >= self.lastEncodedAt ? now - self.lastEncodedAt : 0)
                let (timestamp, overflow) = self.lastEncodedPTS.addingReportingOverflow(elapsed)
                let success = self.encodeRecoveryFromStagingLocked(ptsNs: overflow ? Int64.max : timestamp)
                let failure = self.referenceFailure
                self.encLock.unlock()
                if !success { failure?() }
            }
        }
    }

    /// libaom fixes the frame rate at create time (it is the encoder's timebase denominator), so an fps
    /// change is applied by recreating on the next frame — the same trade the SVT path made, and it is
    /// the path a focus change takes (`applyFocus` re-rates the demoted/promoted streams).
    func setFps(_ v: Int) { lock.lock(); fps = v; lock.unlock() }

    /// Live-tunable, like fps and bitrate. It never changes the frame's DIMENSIONS, so it costs no
    /// encoder recreate and no keyframe — which is exactly why the client needs no synchronisation
    /// for it. See `CropRect`.
    func setCrop(_ v: CropRect) { lock.lock(); crop = v; lock.unlock() }

    /// The staging plane's luma, copied out. FOR TESTS ONLY — it exists because the masked pixels are
    /// otherwise unobservable without a decoder, and `gate-rdev-viewer.sh` is a much heavier way to
    /// learn the same thing. Copies rather than lending the pointer, so a caller cannot outlive the
    /// buffer's lock.
    func stagingLumaForTest() -> (bytes: [UInt8], width: Int, height: Int, stride: Int)? {
        encLock.lock()
        defer { encLock.unlock() }
        guard let s = staging else { return nil }
        guard CVPixelBufferLockBaseAddress(s, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(s, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(s, 0) else { return nil }
        let w = CVPixelBufferGetWidth(s), h = CVPixelBufferGetHeight(s)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(s, 0)
        let bytes = [UInt8](UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self), count: stride * h))
        return (bytes, w, h, stride)
    }
    /// Bitrate retargets live (CBR) and needs no recreate.
    func setBitrate(_ v: Int) { lock.lock(); bitrateBps = v; pendingBitrate = true; lock.unlock() }

    /// Deterministic teardown, ahead of and idempotent with `deinit` (grace-pool teardown). Nilling
    /// `encoder` here IS the destroy: the output handler holds `self` weakly, so this is the last
    /// strong reference and `llv_aom_encoder_destroy` runs synchronously on that line rather than
    /// whenever the last `SourceStream` reference happens to drop. Idempotent — a second call finds
    /// nil. SAFE ONLY once the feeding capture source has been `stop()`'d (its `.sync` drain
    /// guarantees no `encode()` is in flight); `encLock` covers the rest.
    func invalidate() {
        encLock.lock(); defer { encLock.unlock() }
        referenceConfiguration &+= 1
        referencePlanner = nil; referenceRequest = nil; referenceFailure = nil
        lock.lock(); referenceEnabled = false; referenceGeneration = referenceConfiguration; lock.unlock()
        encoder = nil
        staging = nil
        stagingValid = false; lastEncodedPTS = 0; lastEncodedAt = 0; lastRecoveryPTS = 0
        referenceEncoding.reset(); referenceEpoch = UUID().uuidString
        lock.lock(); referenceByFrameID.removeAll(); lock.unlock()
        lock.lock(); ptsByFrameID.removeAll(); lock.unlock()
        scaled?.deallocate(); scaled = nil; scaledBytes = 0; scaledStride = 0
        sourceWidth = 0; sourceHeight = 0
        width = 0; height = 0; encoderFps = 0
        frameID = 0
        createFailed = nil
    }

    // WHAT THE ENCODER ACTUALLY PRODUCED, as opposed to what it was asked for.
    //
    // The `[encode]` line reports the REQUEST — the bitrate handed to libaom — and this project has
    // been caught before by a preference that was acknowledged and never applied, invisible from
    // every other vantage point. It also cannot show where the bits went: a stream whose budget is
    // being consumed by forced keyframes looks identical, at the request level, to one spending it
    // on the picture. Under scrolling those are exactly the two cases worth telling apart.
    //
    // Reported every 5 s, matching LatencyStages, because a per-frame line at 60 fps perturbs what
    // it measures. Counters are touched only from the encode path, which is serialized per source.
    private var outBytes = 0
    private var outFrames = 0
    private var outKeyBytes = 0
    private var outKeyframes = 0
    /// Rate-control drops in the current reporting window. Guarded by `lock`, like every other
    /// `out*` counter — `receive` runs on the encoder's thread and `recordOutput` reads them.
    private var outDrops = 0
    /// WHY A KEYFRAME WAS ASKED FOR, SPLIT BY WHO ASKED — the discriminator for "still too many
    /// keyframes on still content", measured on a real iPad AFTER the infinite-GOP fix.
    ///
    /// That fix removed the ~5 periodic IDRs a 60-frame interval produces in a 5 s window at 60 fps,
    /// and the count fell by about that much (6-15 -> 4-7) — so it worked, and it REVEALED a second
    /// source that had always been there. Without these two counters the next step is a guess, and
    /// this file already has one wrong guess recorded against it.
    ///
    /// `outKeyframeRequests` counts `requestKeyframe()`: PLI/FIR relayed from the receiver, the
    /// reconnect push, and the IDR on attach. `outSinkAttaches` counts `addSink`, which forces one
    /// too — separated because track churn and receiver-driven loss want completely different fixes,
    /// and a single total could not tell them apart.
    private var outKeyframeRequests = 0
    private var outSinkAttaches = 0
    private var outWindowStart = DispatchTime.now().uptimeNanoseconds
    /// SPIKE INSTRUMENT: per-frame DELTA sizes for the window. `produced …kbps` is an average, and an
    /// average cannot show a burst — a stream whose scroll frames are 8x its median leaves the host
    /// as 8x the packets in one shot, which is a transport event no aggregate reports.
    private var outSizes: [Int] = []
    /// SPIKE INSTRUMENT: capture-to-capture intervals, in microseconds. THE ONE THING THE HOST LOG
    /// CANNOT OTHERWISE SHOW. `produced … 59.7 fps` is an average over five seconds and stays
    /// beautiful while the source hitches — a window that delivers 55 frames evenly and 5 in a clump
    /// reports the same number as one running like a metronome. A receiver's `[rx]` line cannot see
    /// it either: with honest RTP timestamps the hitch is faithfully reproduced, so it shows up as
    /// neither loss nor jitter. Reported here because a client that cannot run rdev's own pacing
    /// probe (an iPhone, say) leaves this the only route to the number.
    private var outCaptureGaps: [Int] = []
    /// Supplied by whoever owns the capture source, because the adapter cannot reach it. Returns the
    /// non-`complete` SCK frame statuses since the last call. Without it, `late` below cannot tell a
    /// window that DID NOT CHANGE from one the machine was too slow to compose — the same gap, and
    /// opposite responses. Optional: the test-pattern source has no such notion.
    public var nonCompleteTicks: (() -> [String: Int])?
    private var lastCaptureNs: Int64 = 0

    /// RETURNS the periodic line instead of printing it, because it is now called with `lock` HELD
    /// and printing under a lock taken by the peer's ordered dispatcher would block that dispatcher
    /// on stdio. The caller prints after unlocking.
    ///
    /// The counters moved under `lock` with delivery: they used to be documented as "touched only
    /// from the encode path, which is serialized per source", and an asynchronous backend delivers
    /// from a thread that path does not own.
    private func recordOutput(byteCount: Int, keyframe: Bool) -> String? {
        outBytes += byteCount
        outFrames += 1
        if keyframe { outKeyframes += 1; outKeyBytes += byteCount } else { outSizes.append(byteCount) }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedNs = now &- outWindowStart
        guard elapsedNs >= 5_000_000_000 else { return nil }
        // Read ONCE, here, where `lock` is already the caller's discipline for the `out*` counters —
        // `sinks` lives under the same lock and this is the only place the report needs it.
        let sinksCount = sinks.count
        let seconds = Double(elapsedNs) / 1_000_000_000
        let kbps = Double(outBytes) * 8 / seconds / 1000
        let fps = Double(outFrames) / seconds
        let keyShare = outBytes > 0 ? Double(outKeyBytes) * 100 / Double(outBytes) : 0
        // `dropped` earns its place beside fps: a stream at 58 fps with 40 drops a window is
        // holding its cadence by discarding pictures, which reads as healthy on every other number.
        // `sinks` is the LIVE count, and it sits beside `attach` because the two answer different
        // halves of one question. An encoder producing at 60fps while NOTHING reaches either
        // transport has exactly two explanations — no sink is attached, or the attached sinks point
        // at a peer that is gone — and `attach`, a count of past events, cannot separate them.
        // Observed as `[dc] sent=0` beside `[bridge] fec: media 0 pkts` with the encoder at
        // 1.9Mbit/s: everything downstream silent, and no way to say which.
        //
        // `requested` and `attach` sit beside `keyframes` so the three can be READ TOGETHER, which
        // is the whole point: keyframes without requests means the ENCODER is producing them
        // unbidden, keyframes tracking requests means the RECEIVER is asking, and attach accounts
        // for the ones rdev forces itself on a track bind. Three numbers, three different faults.
        let line = String(
            format: "[encode] %@ produced %.0fkbps asked=%dkbps · %.1f fps · %d keyframes "
                + "(%.0f%% of bits) · %d dropped · %d requested · %d attach",
            logName, kbps, bitrateBps / 1000, fps, outKeyframes, keyShare, outDrops,
            outKeyframeRequests, outSinkAttaches)
            // APPENDED, NOT ANOTHER FORMAT SPECIFIER. The first attempt added a `%d` to the string
            // above and printed 794978668, then 0, while video was plainly flowing — the specifier
            // went in and its argument did not. Interpolation cannot lose its argument, and a
            // counter that lies is worse than no counter: this one exists to be believed at the
            // moment everything else has gone silent.
            + " · \(sinksCount) sinks"
        // Keyframes are EXCLUDED above: everyone already knows an IDR is huge, and leaving them in
        // would put the interesting delta-frame tail underneath them.
        var sizeLine = ""
        if outSizes.count >= 8 {
            let sorted = outSizes.sorted()
            let pick = { (q: Double) in sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))] }
            let median = max(1, pick(0.5))
            sizeLine = String(
                format: "\n[frames] %@ delta bytes p50=%d p95=%d max=%d · burst p95/p50=%.1fx "
                    + "· max packets=%d",
                logName, median, pick(0.95), sorted[sorted.count - 1],
                Double(pick(0.95)) / Double(median),
                (sorted[sorted.count - 1] + 1_199) / 1_200)
        }
        if outCaptureGaps.count >= 8 {
            let gaps = outCaptureGaps.sorted()
            let at = { (q: Double) in gaps[min(gaps.count - 1, Int(q * Double(gaps.count)))] }
            // `late` is the count that took MORE THAN 1.5 frame times — a frame the source simply
            // did not produce on schedule. That is the number to read: a handful per window is
            // ordinary, a few percent is visible as judder however healthy every other line looks.
            let frameUs = Int(1_000_000.0 / max(1.0, Double(fps)))
            let late = outCaptureGaps.filter { $0 > frameUs * 3 / 2 }.count
            sizeLine += String(
                format: "\n[capture] %@ interval ms p50=%.1f p95=%.1f max=%.1f · late %d/%d (%.1f%%)",
                logName, Double(at(0.5)) / 1_000, Double(at(0.95)) / 1_000,
                Double(gaps[gaps.count - 1]) / 1_000,
                late, outCaptureGaps.count, 100 * Double(late) / Double(outCaptureGaps.count))
            // PRINTED EVEN WHEN ZERO, and named. `idle 0` beside `late 12` says the source really was
            // too slow; `idle 40` beside the same `late` says forty of those gaps were a window that
            // simply did not change, which is not a fault at all.
            let ticks = nonCompleteTicks?() ?? [:]
            let shown = ticks.isEmpty ? "idle 0"
                : ticks.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " ")
            sizeLine += " · " + shown
        }
        outCaptureGaps.removeAll(keepingCapacity: true)
        outSizes.removeAll(keepingCapacity: true)
        outBytes = 0; outFrames = 0; outKeyBytes = 0; outKeyframes = 0; outDrops = 0
        outKeyframeRequests = 0; outSinkAttaches = 0
        outWindowStart = now
        return line + sizeLine
    }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64) {
        // 4:2:0 has no chroma plane for an odd row/column. Round DOWN to even and convert that
        // sub-rectangle; the capture buffer's stride lets vImage read a narrower width for free.
        // (ScreenCaptureSource already emits even dimensions; the test pattern and a future source
        // need not, and libaom rejects odd dimensions outright.)
        let w = CVPixelBufferGetWidth(pixelBuffer) & ~1
        let h = CVPixelBufferGetHeight(pixelBuffer) & ~1
        guard w >= 2, h >= 2 else { return }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            lock.lock(); let warned = warnedPixelFormat; warnedPixelFormat = true; lock.unlock()
            if !warned {
                let f = CVPixelBufferGetPixelFormatType(pixelBuffer)
                print("[encode] \(logName) \(codecLabel) dropping every frame: capture is not 32BGRA "
                    + "(got \(fourCC(f))). This encoder converts BGRA->NV12 and cannot read it.")
            }
            return
        }

        lock.lock()
        let force = forceKeyframe; forceKeyframe = false
        let applyRate = pendingBitrate; pendingBitrate = false
        let curFps = fps, curBitrate = bitrateBps
        let curCrop = crop
        lock.unlock()

        encLock.lock()
        defer { encLock.unlock() }

        if let recorder = qualificationRecorder {
            do { try recorder.record(pixelBuffer, source: logName, pts: ptsNs) }
            catch { recorder.stop(error: error) }
        }
        // A capture queued before the recovery repeat is now older than the picture sent.
        // Drop it; changing its capture timestamp would falsify the media clock.
        if lastRecoveryPTS != 0 && ptsNs <= lastRecoveryPTS {
            lock.lock()
            if force { forceKeyframe = true }
            if applyRate { pendingBitrate = true }
            lock.unlock()
            return
        }

        if encoder == nil || w != sourceWidth || h != sourceHeight || curFps != encoderFps {
            recreate(sourceWidth: w, sourceHeight: h, fps: curFps, bitrateBps: curBitrate)
        } else if applyRate {
            do {
                try encoder?.setBitrate(curBitrate)
                // A live retarget deliberately does NOT recreate, so without this it would be the one
                // pref change that leaves no trace at the only vantage point that knows what is really
                // being encoded.
                print("[encode] \(logName) \(codecLabel) bitrate -> \(curBitrate / 1000)kbps")
            } catch {
                print("[encode] \(logName) \(codecLabel) bitrate -> \(curBitrate / 1000)kbps REJECTED: \(error)")
            }
        }
        // A keyframe request must survive a frame that never reaches the encoder. `force` was CONSUMED
        // above, so every bail-out below re-arms it: a PLI or a fresh subscribe that landed on the one
        // frame whose conversion failed would otherwise be swallowed, and the client waits out the
        // browser's PLI debounce staring at nothing (infinite GOP — there is no periodic IDR to save it).
        // Re-arming can only cost an extra keyframe; dropping one costs seconds of black.
        func rearmKeyframe() { if force { lock.lock(); forceKeyframe = true; lock.unlock() } }

        guard let enc = encoder, let staging else { rearmKeyframe(); return }

        stagingValid = false
        if !convert(bgra: pixelBuffer, into: staging, crop: curCrop) { rearmKeyframe(); return }

        stagingValid = true
        frameID &+= 1
        let id = frameID
        // The access unit comes back carrying only its frame id, so the capture timestamp has to be
        // parked where `receive` can find it — which may be another thread entirely.
        lock.lock()
        ptsByFrameID[id] = ptsNs
        if lastCaptureNs != 0, ptsNs > lastCaptureNs {
            outCaptureGaps.append(Int((ptsNs - lastCaptureNs) / 1_000))
        }
        lastCaptureNs = ptsNs
        lock.unlock()
        do {
            // `inputSequence` is LLV's input-to-decode correlator and rdev's bridge carries no input
            // sequence on this path, so it mirrors the frame id — a monotonic value, which is all the
            // encoder itself requires (it becomes libaom's PTS in the 1/fps timebase).
            let reference = try prepareReference(frameID: id, force: force)
            try enc.encode(pixelBuffer: staging, frameID: id, inputSequence: id,
                           forceKeyframe: force || reference?.independent == true,
                           referenceControl: reference?.control ?? nextReferenceControl)
            if let reference { referenceEncoding.commit(reference) }
            nextReferenceControl = nil
            referenceServedSerial = referenceRequestSerial
            lastEncodedPTS = ptsNs
            lastEncodedAt = DispatchTime.now().uptimeNanoseconds
        } catch {
            print("[encode] \(logName) \(codecLabel) encode failed: \(error)")
            // The frame never reached the encoder, so nothing will ever come back for it. Left in
            // place, the map would grow by one entry per failed frame for the encoder's whole life.
            referenceEncoding.reset(); referenceEpoch = UUID().uuidString
            lock.lock(); referenceByFrameID[id] = nil; forceKeyframe = true; ptsByFrameID[id] = nil; lock.unlock()
            rearmKeyframe()
            referenceFailure?()
            return
        }
        // DELIVERY IS NOT HERE ANY MORE — see `receive`. It used to read a `pendingUnit` field on
        // this line, which worked only because libaom fires its handler inline before `encode`
        // returns. `force` has already been consumed, so nothing below may bail without re-arming.
    }

    // MARK: - private (encLock held)

    /// DELIVERY HAPPENS HERE, AND THAT IS WHAT MAKES THIS ADAPTER BACKEND-AGNOSTIC.
    ///
    /// libaom calls this SYNCHRONOUSLY from inside `AV1Encoder.encode`, on the encoding thread, with
    /// `encLock` ALREADY HELD by that same thread. VideoToolbox calls it on ITS OWN thread with no
    /// lock held at all. Both are safe because this method takes only `lock` — and taking `lock`
    /// while `encLock` is held is the sanctioned order (`encLock` then `lock`, never the reverse),
    /// which is exactly the order the libaom path arrives in.
    ///
    /// IT MUST NEVER TAKE `encLock`. On the libaom path that is a self-deadlock (NSLock is not
    /// reentrant); on the VideoToolbox path it would serialise delivery behind the next encode.
    ///
    /// THE PREVIOUS DESIGN read the access unit out of a field on the line after `enc.encode(...)`
    /// returned. Correct for an inline callback; for an asynchronous one it read nil and dropped
    /// EVERY frame — no error, no log, a source that encodes and never delivers.
    private func receive(_ result: Result<EncodedAccessUnit, Error>) {
        switch result {
        case .failure(let error):
            // A DROPPED FRAME IS NOT AN ERROR — see the test of the same name. `noErr` with a nil
            // sample buffer is VideoToolbox's signal that the rate controller discarded this frame,
            // and LLVCore surfaces exactly that as `missingSampleBuffer`. Counted and reported on
            // the periodic `produced` line beside fps and keyframes; logging it per frame buried
            // the real errors underneath it — hundreds of lines in one iPad session.
            //
            // CLASSIFIED HERE RATHER THAN IN THE ENGINE deliberately: adding a `VideoEncoderError`
            // case risks a frozen exhaustive `switch`, and changing the `Result` payload would
            // change a public typealias the frozen tests use. `missingSampleBuffer` is produced for
            // this and nothing else, so the mapping is exact.
            if case VideoEncoderError.missingSampleBuffer = error {
                lock.lock(); outDrops += 1; lock.unlock()
                return
            }
            print("[encode] \(logName) \(codecLabel) output error: \(error)")
        case .success(let unit):
            let bytes = [UInt8](unit.data)
            // The ENCODER's own measurement of its own span. More accurate than timing the call from
            // the outside, and the only figure that means anything once delivery is asynchronous.
            LatencyStages.shared.record(.encode, source: logName,
                                        ms: Double(unit.encodeNanoseconds) / 1_000_000)

            lock.lock()
            // A MISSING ENTRY SHIPS THE PICTURE WITH pts 0 rather than dropping the frame. An
            // unexpected frame id means the pts bookkeeping is wrong; a wrong timestamp is something
            // the client's jitter buffer absorbs, and no picture is not.
            let pts = ptsByFrameID.removeValue(forKey: unit.frameID) ?? 0
            let reference = referenceByFrameID.removeValue(forKey: unit.frameID)
            let report = recordOutput(byteCount: bytes.count, keyframe: unit.isKeyframe)
            let targets = Array(sinks.values)
            lock.unlock()

            if let report { print(report) }
            let d0 = DispatchTime.now().uptimeNanoseconds
            for s in targets {
                if let reference { s.writeVideo(bytes, ptsNs: pts, keyframe: unit.isKeyframe, reference: reference) }
                else { s.writeVideo(bytes, ptsNs: pts, keyframe: unit.isKeyframe) }
            }
            LatencyStages.shared.record(.deliver, source: logName,
                                        ms: Double(DispatchTime.now().uptimeNanoseconds &- d0) / 1_000_000)
        }
    }

    /// Test seam: deliver an access unit exactly as a backend would, from whatever thread the caller
    /// is on. It exists because driving a real encoder from a unit test would test the encoder rather
    /// than this adapter's handoff — which is the thing that breaks when the backend changes.
    func deliverForTest(_ result: Result<EncodedAccessUnit, Error>) { receive(result) }

    /// Test seam, beside `deliverForTest` and internal for the same reason — a drop is invisible
    /// from outside otherwise: it produces no sink write and, by design, no log line.
    var dropsForTest: Int { lock.lock(); defer { lock.unlock() }; return outDrops }

    /// Test seam. Same reasoning: a keyframe REQUEST leaves no trace of its own, and the whole
    /// value of the counter is telling requests apart from sink attaches.
    var keyframeRequestsForTest: Int {
        lock.lock(); defer { lock.unlock() }; return outKeyframeRequests
    }
    var sinkAttachesForTest: Int { lock.lock(); defer { lock.unlock() }; return outSinkAttaches }

    private func recreate(sourceWidth sw: Int, sourceHeight sh: Int, fps f: Int, bitrateBps b: Int) {
        if let failed = createFailed, failed.w == sw, failed.h == sh, failed.fps == f { return }
        let prevW = width, prevH = height

        // DOWNSCALE TO FIT RATHER THAN REFUSE. libaom rejects anything outside 72…3840 x 64…2160, and
        // a refusal here used to mean the source streamed ZERO FRAMES INDEFINITELY after one log line
        // — for a window only 8 px over on height (a 1658x1084 pt retina window is 3316x2168 native,
        // which rdev's own auto-resolution gate records). SVT had no such ceiling. Maintainer's
        // decision: a slightly smaller picture beats no picture, and it fits the model rdev already
        // has, since Auto resolution varies the streamed size continuously anyway.
        let bounds = Self.dimensionBounds(for: negotiatedCodec)
        let (w, h) = EncodeDimensions.fit(width: sw, height: sh,
                                          minWidth: bounds.minWidth,
                                          maxWidth: bounds.maxWidth,
                                          minHeight: bounds.minHeight,
                                          maxHeight: bounds.maxHeight)
        let clamped = (w != sw || h != sh)

        // Release the OLD encoder before allocating the new one, so two libaom encoders (each with its
        // own reference buffers) are never live for one source at once.
        encoder = nil
        staging = nil
        stagingValid = false; lastEncodedPTS = 0; lastEncodedAt = 0; lastRecoveryPTS = 0
        referenceEncoding.reset(); referenceEpoch = UUID().uuidString
        lock.lock(); referenceByFrameID.removeAll(); lock.unlock()
        lock.lock(); ptsByFrameID.removeAll(); lock.unlock()
        scaled?.deallocate(); scaled = nil; scaledBytes = 0; scaledStride = 0
        sourceWidth = 0; sourceHeight = 0
        width = 0; height = 0; encoderFps = 0
        frameID = 0

        // Scratch BGRA for the resample, allocated ONLY while a clamp is active — the normal path has
        // no scratch, no extra copy and no branch cost. Reallocated by the same condition that
        // recreates the encoder, so it can never outlive its dimensions.
        var scratch: UnsafeMutableRawPointer?
        if clamped {
            let stride = w * 4
            scratch = UnsafeMutableRawPointer.allocate(byteCount: stride * h, alignment: 16)
            scaledStride = stride
            scaledBytes = stride * h
        }

        guard let buffer = Self.makeNV12Buffer(width: w, height: h) else {
            print("[encode] \(logName) FAILED to allocate a \(w)x\(h) NV12 staging buffer")
            scratch?.deallocate(); scaledBytes = 0; scaledStride = 0
            createFailed = (sw, sh, f)
            return
        }
        let created: RealtimeVideoEncoder
        do {
            created = try RealtimeVideoEncoder(
                codec: llvCodec,
                width: w, height: h, fps: f, bitrate: b,
                temporalCompression: true,
                scalabilityMode: .l1t1,
                screenDetectionMode: .antialiasingAware,
                cpuUsed: cpuUsed,
                // PASSED EXPLICITLY, next to the BT.709 tags `makeNV12Buffer` puts on the staging
                // buffer and the BT.709 matrix `ColorConvert` converts with, because those three
                // have to agree and this is the only place all three are visible at once. It is
                // also LLVCore's default, so this is documentation rather than a divergence.
                colorConfiguration: .bt709,
                av1ObservationHandler: { _ in },
                // `[weak self]` IS THE CYCLE-BREAKER — see the note where `deinit` would be. LLVCore's
                // AV1Encoder stores this closure strongly for its whole life, so a strong capture would
                // make `invalidate()` a no-op and leak a libaom encoder per source.
                outputHandler: { [weak self] result in self?.receive(result) }
            )
        } catch {
            // With the fit above, dimensions can no longer be the cause. What is left: an out-of-range
            // bitrate, an allocation failure inside libaom, or libaom REFUSING one of the controls —
            // which is the real guard on `screenDetectionMode`, see the log line below.
            print("[encode] \(logName) FAILED to create a \(w)x\(h) \(codecLabel) encoder: \(error)")
            scratch?.deallocate(); scaledBytes = 0; scaledStride = 0
            createFailed = (sw, sh, f)
            return
        }

        encoder = created
        staging = buffer
        // A FRESH STAGING BUFFER HOLDS NO PATTERN. Forcing a repaint here is what keeps the mask
        // alive across every resolution change Auto makes — and Auto moves the scale the moment the
        // user zooms, which is the moment the mask is wanted.
        paintedCrop = nil
        scaled = scratch
        sourceWidth = sw; sourceHeight = sh
        width = w; height = h; encoderFps = f
        createFailed = nil

        // The ground truth for what is actually being ENCODED, downstream of the capture config, and
        // deliberately the same shape as the line VTEncoder/AV1Encoder print — silence here still means
        // the capture source is emitting the old dimensions (the stale-CVPixelBufferPool trap).
        //
        // `asked(...)` IS AN HONEST LABEL, NOT A HEDGE. `acceptedSettings` reads like a readback and is
        // not one: on the libaom path every field in it is derived from the VALIDATED SWIFT REQUEST
        // (`LLVCore/AV1Encoder.swift`, the `acceptedSettings = AV1EncoderAcceptedSettings(` literal
        // — cited by name rather than by line, which is what a colour-tag diff just invalidated)
        // before `llv_aom_encoder_create` is ever called. An
        // earlier version of this line flagged a disagreement with `!! expected antialiasing-aware`;
        // that branch was UNREACHABLE, and a check that reads as protection while being incapable of
        // firing is worse than no check.
        //
        // The real guard is create-failure: `llv_aom_encoder_create` destroys the encoder and returns
        // an error if libaom refuses any `aom_codec_control`, including
        // AV1E_SET_SCREEN_CONTENT_DETECTION_MODE. So a printed line means every value below was
        // ACCEPTED — transitively, via the absence of the `FAILED to create` line above it.
        //
        // A DIRECT READBACK IS NOT MERELY UNDONE, IT IS UNAVAILABLE. Editing CAOMBridge.c is
        // permitted now (G1 released Sources/ on 2026-08-17), so the constraint an earlier version of
        // this comment cited is gone — but libaom itself publishes no GET control for any of these:
        // its whole `AV1E_GET_*`/`AOME_GET_*` set is the quantizer, loop-filter level, active map,
        // sequence-level indices, operating-point count, GF interval/info, CDEF strength and the
        // high-motion screen flag. There is no getter for cpu-used, for the screen-content detection
        // mode, or for tiles. So the transitive argument is not a stand-in for a check somebody could
        // write today; it is the only check there is. COLOUR IS THE EXCEPTION and needs no control at
        // all: the CICP is written into the AV1 sequence header, so it can be read straight back out
        // of the bitstream, which is what //host/RdevCore:AV1ColourTests does.
        let s = created.acceptedSettings
        func opt(_ v: Int?) -> String { v.map(String.init) ?? "?" }
        // tileColumns/tileRows carry log2 values (LLVCore assigns tileColumnsLog2 to them), so the
        // previous `tiles=1x1` meant 2x2 and understated the tiling on the one line documented as
        // ground truth. Printed as the real tile count, with the log2 kept alongside.
        func tiles(_ v: Int?) -> String { v.map { "\(1 << $0)" } ?? "?" }
        let from = (prevW > 0 && prevH > 0) ? "\(prevW)x\(prevH) -> " : ""
        // A SILENT downscale is its own trap: the size the client asked for and the size being encoded
        // would disagree with nothing to say so, at the one vantage point that knows.
        let clampNote = clamped
            ? " CLAMPED from \(sw)x\(sh) (libaom max \(RealtimeVideoDimensions.maximumWidth)x"
              + "\(RealtimeVideoDimensions.maximumHeight), min \(RealtimeVideoDimensions.minimumWidth)x"
              + "\(RealtimeVideoDimensions.minimumHeight))"
            : ""
        // THE SUFFIX DESCRIBES THE BACKEND THAT IS ACTUALLY RUNNING. It printed libaom's tuning
        // fields unconditionally, so a VideoToolbox session reported
        // `asked(cpu-used=? threads=? tiles=?x? scm=?)` — four unknowns on the one line this project
        // treats as ground truth for what is being encoded, and the line read while diagnosing every
        // defect in this increment.
        //
        // VideoToolbox's equivalents are its GOP and its low-delay invariants, and unlike libaom's
        // they are genuinely READ BACK off the session (see EncoderAcceptedSettings) rather than
        // restated from the request — so `gop(...)` is evidence in a way `asked(...)` is not.
        let tuning: String
        if s.implementation == "VideoToolbox" {
            let duration = s.maxKeyFrameIntervalDuration.map { String(Int($0)) } ?? "?"
            tuning = "gop(interval=\(opt(s.keyframeInterval)) duration=\(duration)"
                + " realtime=\(s.realTime) lowLatency=\(s.lowLatencyRateControl)"
                + " reorder=\(s.frameReordering))"
        } else {
            tuning = "asked(cpu-used=\(opt(s.cpuUsed)) threads=\(opt(s.threads)) "
                + "tiles=\(tiles(s.tileColumns))x\(tiles(s.tileRows)) "
                + "scm=\(s.screenDetectionMode?.rawValue ?? "?"))"
        }
        print("[encode] \(logName) \(codecLabel) \(from)\(w)x\(h) fps=\(f) bitrate=\(b / 1000)kbps "
            + "\(s.implementation) \(tuning)\(clampNote)")
    }

    /// BGRA → (resample, only when clamped) → NV12 into the encoder's staging buffer. Returns false
    /// silently per frame when a buffer cannot be locked; a log here would fire at 60 fps.
    ///
    /// **The vImage status IS checked.** The staging buffer is reused across frames, so a refused
    /// conversion that reported success would re-encode the PREVIOUS frame's pixels — a stream that
    /// reads healthy at every other vantage point and is visibly frozen, which is this codebase's
    /// signature failure mode.
    private func convert(bgra: CVPixelBuffer, into destination: CVPixelBuffer,
                         crop: CropRect) -> Bool {
        guard CVPixelBufferLockBaseAddress(bgra, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(bgra) else { return false }

        // Source of the conversion: the capture buffer itself, or the resampled scratch when clamping.
        var src = base.assumingMemoryBound(to: UInt8.self)
        var srcStride = CVPixelBufferGetBytesPerRow(bgra)
        if let scaled {
            let err = ColorConvert.scaleBGRA(src, width: sourceWidth, height: sourceHeight,
                                             srcStride: srcStride,
                                             dst: scaled, dstWidth: width, dstHeight: height,
                                             dstStride: scaledStride)
            guard err == kvImageNoError else {
                print("[encode] \(logName) \(codecLabel) downscale \(sourceWidth)x\(sourceHeight) -> "
                    + "\(width)x\(height) failed: vImage \(err)")
                return false
            }
            src = scaled.assumingMemoryBound(to: UInt8.self)
            srcStride = scaledStride
        }

        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(destination, 0),
              let cbCr = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else { return false }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)

        // THE CROP IS IN FINAL FRAME COORDINATES, after the resample above — `width`/`height`, never
        // the capture's own size, which differ whenever `EncodeDimensions.fit` had to clamp.
        // `pixels` answers nil for a full or degenerate rect, and that nil is what keeps the normal
        // path byte-identical to what it was.
        let px = crop.pixels(frameWidth: width, frameHeight: height)

        if let px, paintedCrop != crop {
            Checkerboard.paintNV12(y: y, yStride: yStride, cbCr: cbCr, cStride: cStride,
                                   width: width, height: height)
            paintedCrop = crop
            // THE PERCENTAGE IS THE POINT — the one number that says whether the feature is doing
            // anything, and a run reading 100% is a no-reproduction rather than a pass. Logged HERE
            // rather than on `recreate`'s line, because a crop change deliberately causes no
            // recreate: a note there would print on exactly the events this is not about.
            let pct = (px.w * px.h * 100) / max(1, width * height)
            print("[encode] \(logName) \(codecLabel) crop=\(px.w)x\(px.h)+\(px.x)+\(px.y) "
                + "(\(pct)% of \(width)x\(height))")
        } else if px == nil, paintedCrop != nil {
            // Back to full. The full-frame conversion below overwrites every pixel, so there is
            // nothing to repaint — but the record has to be cleared, or a later return to the SAME
            // crop would skip the paint it needs.
            paintedCrop = nil
            print("[encode] \(logName) \(codecLabel) crop=full")
        }

        let err: vImage_Error
        if let px {
            let o = px.offsets(srcStride: srcStride, yStride: yStride, cStride: cStride)
            err = ColorConvert.bgraToNV12(
                src + o.srcByteOffset, width: o.width, height: o.height, srcStride: srcStride,
                y: y + o.yByteOffset, yStride: yStride,
                cbCr: cbCr + o.cbCrByteOffset, cStride: cStride)
        } else {
            err = ColorConvert.bgraToNV12(
                src, width: width, height: height, srcStride: srcStride,
                y: y, yStride: yStride, cbCr: cbCr, cStride: cStride)
        }
        guard err == kvImageNoError else {
            print("[encode] \(logName) \(codecLabel) BGRA->NV12 \(width)x\(height) failed: vImage \(err)")
            return false
        }
        return true
    }

    /// A pixel format as its four-character code, so a wrong-format log names the format a reader can
    /// look up rather than a bare integer.
    private func fourCC(_ v: OSType) -> String {
        let chars = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }
        return chars.allSatisfy { $0 >= 32 && $0 < 127 }
            ? "'" + String(decoding: chars, as: UTF8.self) + "'"
            : String(v)
    }

    /// One staging buffer per resolution, reused for every frame. Safe because `encode()` is serialized
    /// by `encLock` and `LLVCore.AV1Encoder` COPIES both planes out (into `cachedLuma`/`cachedChroma`)
    /// before returning, so exactly one frame is ever live in it. It is reallocated by the SAME
    /// condition that recreates the encoder, so it can never outlive its dimensions.
    private static func makeNV12Buffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  nil, &pb) == kCVReturnSuccess, let pb else { return nil }
        // Tagged to match what ColorConvert actually produces. libaom does NOT read these — the AV1
        // sequence header's CICP is a separate matter, carried by `colorConfiguration: .bt709` in
        // `recreate` — but an untagged buffer is a lie about its own contents to anything that ever
        // does look, which on this codebase has been VideoToolbox more than once.
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return pb
    }

    private var logName: String { label.isEmpty ? "video" : label }
}
