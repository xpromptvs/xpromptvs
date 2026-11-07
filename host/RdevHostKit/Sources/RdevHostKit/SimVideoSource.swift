import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import RdevCore

public protocol SimVideoSource { func start(into sink: VideoFrameSink) }

/// The full capture-source contract SimManager drives a binding through (start + live controls +
/// teardown). Both SimFramebufferVideoSource and ScreenCaptureSource conform. (SimVideoSource stays
/// the minimal `start(into:)` seam; StreamVideoSource is what a hot-swappable binding holds.)
public protocol StreamVideoSource: AnyObject {
    func start(into sink: VideoFrameSink)
    func stop()
    func setScale(_ v: Double)
    func setFpsCap(_ fps: Int)
    /// The source's size in NATIVE PIXELS (points x the display's backing scale, i.e. what `scale == 1.0`
    /// would capture), or nil when it isn't known yet or the source has no meaningful notion of one.
    ///
    /// Exists so a client joining an ALREADY-CAPTURING source can still be told the native size. It is
    /// otherwise published only by `ScreenCaptureSource.onSizeChange`, which fires when capture STARTS and
    /// on a poll-detected size change — so a client that reconnects within the grace window, or a second
    /// client, would never learn it, and Auto resolution would silently never send.
    var nativePixelSize: CGSize? { get }
    /// Called with each whole audio frame this source captured, on the source's own audio queue.
    /// A source with no audio simply never calls it — see the default below.
    var onAudioFrame: ((AudioFraming.Frame) -> Void)? { get set }
}

public extension StreamVideoSource {
    /// Sources with no display backing scale (the simulator framebuffer, the headless test pattern) simply
    /// don't report one; `nil` already means UNKNOWN everywhere downstream.
    var nativePixelSize: CGSize? { nil }

    /// Sources with no audio (the headless test pattern) accept the assignment and never call it.
    /// A DEFAULT RATHER THAN A CONFORMANCE BURDEN: every such source would otherwise carry an
    /// identical dead property, and the one that forgot would fail to build for no useful reason.
    var onAudioFrame: ((AudioFraming.Frame) -> Void)? {
        get { nil }
        set { _ = newValue }
    }
}

/// Headless stand-in: emits an animated CVPixelBuffer on a timer to the encoder sink.
/// Used on the RDEV_TEST_PATTERN=1 path (the headless automated smoke). The real capture path
/// is `SimFramebufferVideoSource` (in-process IOSurface).
public final class TestPatternSource: SimVideoSource, @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private weak var sink: VideoFrameSink?
    private var tick: Int64 = 0
    /// Instrument-only capture suppression; set before start, read on the video queue.
    var shouldEmitVideoFrame: (() -> Bool)?

    /// 60 fps, and ONE constant paces the timer AND stamps the presentation timestamp. They must
    /// agree: a pts that disagrees with the emission rate is a pacing bug that presents downstream
    /// as jitter, and the jitter-derived numbers are what this project measures and publishes.
    ///
    /// It also stops this path lying about the host. `RDEV_VIDEO_FPS` was removed on 2026-07-30
    /// because 60 is fixed in code — while this timer had been emitting 10 fps the whole time, so
    /// the encoder ran at `fps=60` over a 10 fps source and every arm measured against it was
    /// measuring the stand-in rather than the engine.
    static let frameIntervalNs = 16_666_667

    /// Frame size. 320x240 by default; RdevHostRuntime enlarges it to 640x480 under
    /// RDEV_LATENCY_PROBE=1, because the timecode stamp is 576x24 px and simply does not fit
    /// on the default pattern — an unstamped frame reports no latency at all.
    private let width: Int
    private let height: Int

    /// 440 Hz, AND THE FREQUENCY IS THE ASSERTION. `scripts/gate-audio-negotiation.sh` FFTs what the
    /// browser decoded and looks for this bin: "an audio track exists" is satisfied by a negotiated
    /// track delivering silence, and silence is the likeliest failure of every stage in this
    /// pipeline — the framer, the encoder, the MSID, the sink election and the client's routing all
    /// fail that way.
    public static let toneHz = 440.0
    /// 10 ms, matching `AudioFraming.defaultFramesPerChannel` at 48 kHz. ONE constant paces the
    /// timer AND stamps the pts, the rule `frameIntervalNs` already follows: a pts that disagrees
    /// with the emission rate is a pacing bug, and pacing is what this project measures.
    static let audioFrameIntervalNs = 10_000_000
    private static let audioSampleRate = 48_000
    private static let audioFramesPerPacket = 480
    private var audioTimer: DispatchSourceTimer?
    private var audioTick: Int64 = 0
    /// Set before `start(into:)`. Read only on the audio timer's queue.
    public var onAudioFrame: ((AudioFraming.Frame) -> Void)?

    public init(width: Int = 320, height: Int = 240) {
        self.width = width
        self.height = height
    }

    /// One 10 ms stereo frame of the tone, starting at sample `index * 480`.
    ///
    /// THE PHASE IS DERIVED FROM THE ABSOLUTE SAMPLE INDEX, never accumulated per packet: a running
    /// phase drifts on any rounding and the tone smears across bins, which is exactly the thing the
    /// gate measures. Full scale x0.5, so a decoder's overshoot cannot clip.
    static func toneFrame(index: Int64) -> AudioFraming.Frame {
        let n = audioFramesPerPacket
        var samples = [Float](repeating: 0, count: n * 2)
        let base = index * Int64(n)
        for i in 0..<n {
            let t = Double(base + Int64(i)) / Double(audioSampleRate)
            let v = Float(0.5 * sin(2.0 * Double.pi * toneHz * t))
            samples[i * 2] = v; samples[i * 2 + 1] = v
        }
        return AudioFraming.Frame(samples: samples, ptsNs: index * Int64(audioFrameIntervalNs))
    }
    public func start(into sink: VideoFrameSink) {
        self.sink = sink
        let queue = DispatchQueue(label: "rdev.testpattern.video")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(TestPatternSource.frameIntervalNs))
        t.setEventHandler { [weak self] in
            guard let self, let sink = self.sink else { return }
            let tick = self.tick
            self.tick += 1
            guard self.shouldEmitVideoFrame?() ?? true else { return }
            guard let buffer = TestPatternSource.makePixelBuffer(width: self.width, height: self.height, tick: tick) else { return }
            sink.encode(buffer, ptsNs: tick * Int64(TestPatternSource.frameIntervalNs))
        }
        self.timer = t; t.resume()

        // THE TONE RUNS ON ITS OWN TIMER, not off the video one: 10 ms against 16.67 ms, and folding
        // them together would emit audio at the video rate — which is what the gate would then be
        // measuring instead of the audio path.
        guard onAudioFrame != nil else { return }
        let audioQueue = DispatchQueue(label: "rdev.testpattern.audio")
        let at = DispatchSource.makeTimerSource(queue: audioQueue)
        at.schedule(deadline: .now(), repeating: .nanoseconds(TestPatternSource.audioFrameIntervalNs))
        at.setEventHandler { [weak self] in
            guard let self, let emit = self.onAudioFrame else { return }
            emit(TestPatternSource.toneFrame(index: self.audioTick))
            self.audioTick += 1
        }
        self.audioTimer = at; at.resume()
    }

    /// Re-point the pattern at a different encoder. The timer reads `sink` every tick, so this is the
    /// whole switch — no stop/start, and therefore no window in which two encoders are being fed (the
    /// single-feeder invariant the real capture path has to work much harder for).
    ///
    /// `sink` is WEAK: the caller must retain the new encoder BEFORE calling this, or the pattern goes
    /// silent and the symptom is a frozen client rather than a crash.
    public func retarget(to sink: VideoFrameSink) { self.sink = sink }

    // MARK: - The pattern
    //
    // It used to be `memset(base, tick * 4)` — one flat grey, cycling slowly. At 10 fps that gave
    // AV1 CBR nothing to spend a 2 Mbit/s budget on (measured 11,218 bps), so any engine compared
    // against it was being measured on its ability to encode nothing. The frame now carries real
    // SPATIAL detail (a zone plate, whose ring frequency rises with radius) and real TEMPORAL
    // residual (the plate's centre and phase move, and a hard-edged bar sweeps across), which is
    // what makes the bitrate a property of the encoder rather than of the source.

    /// Height of the flat, static band at the top — LOAD-BEARING for the latency instrument.
    ///
    /// Under `RDEV_LATENCY_PROBE=1` `FrameOverlaySink` draws the 576x24 timecode over this band
    /// just before encode, and both decoders (`web/src/lib/probe.ts`, `ViewerStampDecode`) find the
    /// stamp by scanning row y=2 for the first dark→light edge and thresholding against the stamp's
    /// own black/white reference cells. High-frequency detail behind and immediately below the
    /// stamp smears into it at 2 Mbit/s and costs stamp coverage — i.e. it would break the very
    /// measurement this richer pattern exists to feed.
    ///
    /// The band is also what keeps the probe's NEGATIVE control honest: with the probe off nothing
    /// is stamped, and a row that is flat along x cannot manufacture the dark→light edge a decoder
    /// looks for.
    static let calmRows = 40

    /// Level of the calm band. Dark, so the stamp's white cells sit at maximum contrast against it.
    static let calmLevel: UInt8 = 24

    /// Sine, ±55 — the ±127 wave already scaled by the 7/16 the two components are mixed at, so the
    /// inner loop has nothing left to multiply, convert or clamp. A table and not `sin()`: the
    /// pattern has 16.6 ms to fill 640x480 and two transcendental calls per pixel would not fit.
    ///
    /// A `.allocate`d pointer rather than an `[Int]`, and this is NOT premature: at `-Onone` — which
    /// is what `bazel build` produces and therefore what every smoke and every measurement runs —
    /// `withUnsafeBufferPointer` + `UnsafeBufferPointer.subscript` are real calls in the inner loop.
    /// Measured on the shipped shape at 640x480: **17.9 ms/frame through a buffer pointer versus
    /// 0.7 ms through a raw one**, against a 16.6 ms budget that also has to cover the overlay copy
    /// and the whole synchronous encode. Written once at first use and never mutated, so sharing it
    /// across sources is safe.
    private static let sineLUT: UnsafeMutablePointer<Int> = {
        let p = UnsafeMutablePointer<Int>.allocate(capacity: 1024)
        for i in 0 ..< 1024 {
            p[i] = (Int((sin(Double(i) * 2 * Double.pi / 1024) * 127).rounded()) * 7) >> 4
        }
        return p
    }()

    /// Luma → packed BGRA, indexed by `512 + a + z`. Folds the clamp and the pixel assembly into the
    /// lookup the value is already costing. Sized 1024 and clamped so that ANY sum two `sineLUT`
    /// entries can produce (±110 today) is in range with room to spare — a later change to the
    /// amplitude must not turn into an out-of-bounds read on a raw pointer.
    private static let pixelLUT: UnsafeMutablePointer<UInt32> = {
        let p = UnsafeMutablePointer<UInt32>.allocate(capacity: 1024)
        for i in 0 ..< 1024 { p[i] = pack(UInt8(clamping: i - 512 + 128)) }
        return p
    }()

    /// Grey level → one little-endian 32BGRA pixel (`A R G B` from the top). arm64 macOS only, and
    /// greyscale anyway, so only alpha's position actually matters here.
    private static func pack(_ v: UInt8) -> UInt32 {
        0xFF00_0000 | (UInt32(v) << 16) | (UInt32(v) << 8) | UInt32(v)
    }

    /// A triangle wave in `0 ..< span` — deterministic, bounded, and stateless bouncing motion.
    static func bounce(_ v: Int64, span: Int) -> Int {
        guard span > 1 else { return 0 }
        let period = Int64(2 * (span - 1))
        var m = v % period
        if m < 0 { m += period }
        return Int(m < Int64(span) ? m : period - m)
    }

    static func makePixelBuffer(width: Int, height: Int, tick: Int64) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            draw(into: base, stride: CVPixelBufferGetBytesPerRow(buffer),
                 width: width, height: height, tick: tick)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Paint one frame.
    ///
    /// **LOAD-BEARING — a PURE FUNCTION OF `tick`.** No `Date()`, no wall clock, no randomness. The
    /// engine comparison this source feeds has a determinism band: two runs of the same duration
    /// have to produce comparable output, and a time-based animation would make every run differ
    /// and the band unmeasurable. Reaching for a clock is the natural way to write an animation and
    /// is exactly what must not happen here.
    ///
    /// **LOAD-BEARING — greyscale (r == g == b) everywhere.** `e2e/latency-overlay-verify.mjs`
    /// classifies the debug cursor rectangle as a saturated primary against a NEUTRAL background
    /// (`isNeutral`: |r-g| < 40 and |g-b| < 40, sampled at the frame centre), and its negative
    /// control asserts neutrality with the overlay off. A colourful pattern fails that control —
    /// and it would buy nothing: chroma is 4:2:0-subsampled, so the luma detail below is where the
    /// bits go regardless.
    private static func draw(into base: UnsafeMutableRawPointer, stride: Int,
                             width: Int, height: Int, tick: Int64) {
        // 32BGRA's row bytes are a multiple of 4 by construction; the whole frame is written as
        // packed pixels, so bail rather than emit something half-drawn if that ever stops holding.
        guard width > 0, height > 0, stride >= width * 4, stride % 4 == 0 else { return }
        let calm = min(calmRows, height)
        let sine = sineLUT, pixel = pixelLUT

        let calmPixel = pack(calmLevel)
        for y in 0 ..< calm {
            let row = (base + y &* stride).assumingMemoryBound(to: UInt32.self)
            var x = 0
            while x < width { row[x] = calmPixel; x &+= 1 }
        }
        guard calm < height else { return }

        // Phases advance with `tick` alone. `&*` rather than trapping arithmetic: a host left
        // running for years must wrap deterministically, never crash.
        let wavePhase = Int(truncatingIfNeeded: tick &* 9)
        let zonePhase = Int(truncatingIfNeeded: tick &* 4)
        // ~4 cycles of the diagonal wave across the frame, ~3 down it (Q8 per-pixel phase step).
        let stepX = max(1, (1024 * 4 << 8) / width)
        let stepY = max(1, (1024 * 3 << 8) / height)
        // The zone plate's centre bounces, so the ring field never simply translates — global
        // motion compensation cannot predict it away, which is the point.
        let cx = bounce(tick &* 3, span: width)
        let cy = calm + bounce(tick &* 2, span: height - calm)

        // Per-column terms, so the inner loop is two lookups, two adds and a store.
        let cols = UnsafeMutablePointer<Int>.allocate(capacity: width * 2)
        defer { cols.deallocate() }
        for x in 0 ..< width {
            cols[x] = (x &* stepX) >> 8
            let dx = x &- cx
            cols[width &+ x] = (dx &* dx) >> 5
        }

        for y in calm ..< height {
            let rowWave = ((y &* stepY) >> 8) &+ wavePhase
            let dy = y &- cy
            let rowZone = ((dy &* dy) >> 5) &+ zonePhase
            let row = (base + y &* stride).assumingMemoryBound(to: UInt32.self)
            var x = 0
            while x < width {
                let a = sine[(cols[x] &+ rowWave) & 1023]
                let z = sine[(cols[width &+ x] &+ rowZone) & 1023]
                row[x] = pixel[512 &+ a &+ z]
                x &+= 1
            }
        }

        // A hard-edged bar sweeping across the busy region. The plasma is smooth by construction,
        // and smooth-and-moving is cheap to predict; an inverted band contributes the sharp,
        // relocating edges that actually cost bits. Kept OUT of the calm band, and applied as its
        // own narrow pass so the main loop stays branch-free. `^ 0x00FFFFFF` inverts B, G and R and
        // leaves alpha alone.
        let barW = max(8, width / 20)
        let barX = bounce(tick &* 5, span: max(2, width - barW))
        let barEnd = min(width, barX + barW)
        for y in calm ..< height {
            let row = (base + y &* stride).assumingMemoryBound(to: UInt32.self)
            var x = barX
            while x < barEnd { row[x] ^= 0x00FF_FFFF; x &+= 1 }
        }
    }
}
