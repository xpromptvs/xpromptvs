import Foundation

/// Re-frames ScreenCaptureKit's arbitrarily-sized audio chunks into the exact frame sizes Opus
/// accepts, carrying each frame's true capture time.
///
/// PURE AND OWNED BY RdevCore, with no CoreAudio in it: the `AudioBufferList` extraction and the
/// non-interleaved-to-interleaved conversion stay in RdevHostKit, so everything about frame sizes,
/// timestamps and gaps is testable with plain arrays.
public struct AudioFraming {
    public struct Frame: Equatable, Sendable {
        /// Interleaved: `channels * framesPerChannel` samples.
        public let samples: [Float]
        /// Capture time of this frame's FIRST sample.
        public let ptsNs: Int64
        public init(samples: [Float], ptsNs: Int64) { self.samples = samples; self.ptsNs = ptsNs }
    }

    /// 10 ms at 48 kHz — HALF WebRTC's usual 20. It halves packetization delay for a few percent of
    /// bitrate, and packetization delay is the one budget rdev spends freely. Named rather than
    /// inlined so the trade is re-measurable.
    public static let defaultFramesPerChannel = 480

    /// How far a chunk's own timestamp may sit from where the running count says it should before
    /// the stream is treated as DISCONTINUOUS and re-anchored. 5 ms — half a default frame.
    ///
    /// It must not be too tight: SCK's delivery times wobble, and re-anchoring on every wobble makes
    /// the media clock follow DELIVERY jitter instead of capture time — the same class of error the
    /// video path measured as a -5.87% media-clock drift.
    public static let defaultToleranceNs: Int64 = 5_000_000

    public let channels: Int
    public let sampleRate: Int
    public let framesPerChannel: Int
    public let toleranceNs: Int64

    private var pending: [Float] = []
    private var anchorPtsNs: Int64 = 0
    private var framesSinceAnchor: Int64 = 0
    private var anchored = false

    public init(channels: Int = 2,
                sampleRate: Int = 48_000,
                framesPerChannel: Int = AudioFraming.defaultFramesPerChannel,
                toleranceNs: Int64 = AudioFraming.defaultToleranceNs) {
        self.channels = max(1, channels)
        self.sampleRate = max(1, sampleRate)
        self.framesPerChannel = max(1, framesPerChannel)
        self.toleranceNs = max(0, toleranceNs)
    }

    /// Samples still held, per channel.
    public var backlogFrames: Int { pending.count / channels }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        anchored = false
        framesSinceAnchor = 0
    }

    /// Accept one interleaved chunk and return whatever whole frames it completes.
    ///
    /// A RAGGED CHUNK IS REFUSED, NOT TRUNCATED. Truncating shears the channels from that point on,
    /// and every later frame is silently wrong in a way that sounds like a broken encoder.
    public mutating func append(_ interleaved: [Float], ptsNs: Int64) -> [Frame] {
        guard !interleaved.isEmpty, interleaved.count % channels == 0 else { return [] }

        if !anchored {
            anchorPtsNs = ptsNs
            framesSinceAnchor = 0
            anchored = true
        } else {
            let expected = ptsFor(frames: framesSinceAnchor + Int64(backlogFrames))
            if abs(ptsNs - expected) > toleranceNs {
                // A GAP IS CARRIED HONESTLY. The partial frame is dropped rather than bridged with
                // silence — synthesised samples make the RTP timestamp a fiction, and a receiver
                // handles a real gap correctly on its own.
                pending.removeAll(keepingCapacity: true)
                anchorPtsNs = ptsNs
                framesSinceAnchor = 0
            }
        }

        pending.append(contentsOf: interleaved)

        var out: [Frame] = []
        let frameSamples = framesPerChannel * channels
        while pending.count >= frameSamples {
            out.append(Frame(samples: Array(pending[0..<frameSamples]),
                             ptsNs: ptsFor(frames: framesSinceAnchor)))
            pending.removeFirst(frameSamples)
            framesSinceAnchor += Int64(framesPerChannel)
        }
        return out
    }

    /// ANCHORED TO AN EPOCH, NEVER SUMMED FROM ROUNDED DELTAS — the rule `FrameTrack` learned on the
    /// video side, where a fixed per-frame step accumulated to a -5.87% media-clock error.
    ///
    /// At 48 kHz with any Opus frame size this happens to be exact either way (every one is
    /// divisible by 3), so the two are indistinguishable in steady state. What differs is a GAP:
    /// see `AudioFramingTests.testGapReanchorsRatherThanCountingThrough`.
    private func ptsFor(frames: Int64) -> Int64 {
        anchorPtsNs + frames * 1_000_000_000 / Int64(sampleRate)
    }
}
