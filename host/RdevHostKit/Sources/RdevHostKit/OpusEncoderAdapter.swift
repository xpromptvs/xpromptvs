import Foundation
import COpusBridge
import RdevCore

/// The only `AudioEncoding` conformance: libopus at 48 kHz stereo.
///
/// LIVES IN RdevHostKit, NEVER RdevCore. libwebrtc statically embeds its own libopus and
/// tools/RdevViewer links libwebrtc AND RdevCore; putting this in RdevCore would manufacture the
/// duplicate-symbol problem that CAOMBridge's partial-link-and-localize genrule exists to solve for
/// libaom. Here there is no second copy of Opus in any binary rdev links.
public final class OpusEncoderAdapter: AudioEncoding, @unchecked Sendable {
    /// 96 kbit/s stereo. Negligible beside video, and well above where Opus stops being transparent
    /// for the UI sounds, alerts and music this actually carries.
    public static let defaultBitrateBps = 96_000

    /// Opus never exceeds this for one frame at rdev's rates. Sized once and reused so the encode
    /// path allocates nothing per frame beyond the payload it hands on.
    private static let scratchBytes = 4_000

    private let lock = NSLock()
    private var encoder: OpaquePointer?                       // guarded by lock
    private var sinks: [SinkKey: any AudioTrackSink] = [:]    // guarded by lock
    private var scratch: [UInt8]                              // guarded by lock
    private let channels: Int
    private let sampleRate: Int
    private let framesPerChannel: Int
    private let sourceID: String
    /// Report counters, guarded by `lock` with everything else here.
    private var reportedFrames = 0
    private var reportedBytes = 0
    private var reportedDrops = 0
    private var lastReportAt = Date()
    /// The `[audio]` line is PRINTED HERE, not on the audio queue. One line per five seconds would
    /// hardly matter, but the rule this repo already follows is that stdio never blocks a media
    /// dispatcher — `recordOutput` returns its line for the same reason.
    private let reportQueue = DispatchQueue(label: "rdev.audio.report", qos: .utility)
    /// Every call that reached libopus, ever. TEST-ONLY, and it exists because the no-sink guard in
    /// `encode` has NO OTHER OBSERVABLE EFFECT: with no sinks attached, guarded and unguarded code
    /// both deliver nothing, so a test written against the sink interface cannot tell them apart and
    /// silently covers nothing. Guarded by `lock`.
    private var encodeCallsForTest = 0

    public init?(sourceID: String = "?",
                 channels: Int = 2,
                 sampleRate: Int = 48_000,
                 framesPerChannel: Int = AudioFraming.defaultFramesPerChannel,
                 bitrateBps: Int = OpusEncoderAdapter.defaultBitrateBps) {
        self.sourceID = sourceID
        self.channels = channels
        self.sampleRate = sampleRate
        self.framesPerChannel = framesPerChannel
        self.scratch = [UInt8](repeating: 0, count: OpusEncoderAdapter.scratchBytes)

        var err: Int32 = 0
        // OPUS_APPLICATION_AUDIO, NOT _VOIP. rdev carries application audio and music, not speech;
        // the VOIP mode's speech model degrades everything else.
        guard let enc = opus_encoder_create(Int32(sampleRate), Int32(channels),
                                            OPUS_APPLICATION_AUDIO, &err), err == OPUS_OK else {
            print("[audio] opus_encoder_create failed: \(err)")
            return nil
        }
        self.encoder = enc
        // EVERY SETTING IS STATUS-CHECKED, the rule every VTSessionSetProperty here follows: a
        // refused setting is indistinguishable from an applied one, so silence must mean applied.
        setCtl(OPUS_SET_BITRATE_REQUEST, Int32(bitrateBps), "bitrate")
        // In-band FEC is free resilience on a lossy path and costs nothing on a clean one. It needs
        // an expected loss percentage to do anything at all — at 0 it is silently inert.
        setCtl(OPUS_SET_INBAND_FEC_REQUEST, 1, "inband FEC")
        setCtl(OPUS_SET_PACKET_LOSS_PERC_REQUEST, 5, "expected packet loss")
        // DTX OFF. It would save bandwidth on silence and complicates timestamps; a measurement,
        // not a default.
        setCtl(OPUS_SET_DTX_REQUEST, 0, "DTX")
        print("[audio] \(sourceID) opus encoder \(sampleRate)Hz \(channels)ch " +
              "\(framesPerChannel) frames/pkt @\(bitrateBps)bps fec=1")
    }

    deinit { destroy() }

    /// MUST BE CALLED WITH `lock` HELD, or from `init` before the object escapes.
    private func setCtl(_ request: Int32, _ value: Int32, _ label: String) {
        guard let encoder else { return }
        let rc = rdev_opus_encoder_ctl_set(encoder, request, value)
        if rc != OPUS_OK { print("[audio] opus ctl \(label) refused: \(rc)") }
    }

    public func addSink(_ s: any AudioTrackSink) {
        lock.lock(); sinks[s.sinkKey] = s; lock.unlock()
    }
    public func removeSink(_ s: any AudioTrackSink) {
        lock.lock(); sinks[s.sinkKey] = nil; lock.unlock()
    }
    public func removeAllSinks() {
        lock.lock(); sinks.removeAll(); lock.unlock()
    }
    public func setBitrate(_ v: Int) {
        lock.lock(); defer { lock.unlock() }
        setCtl(OPUS_SET_BITRATE_REQUEST, Int32(v), "bitrate")
    }
    public func invalidate() { destroy() }

    private func destroy() {
        lock.lock(); defer { lock.unlock() }
        if let encoder { opus_encoder_destroy(encoder) }
        encoder = nil
        sinks.removeAll()
    }

    public func encode(_ frame: AudioFraming.Frame) {
        lock.lock()
        guard let encoder else { lock.unlock(); return }
        // NOBODY IS LISTENING — DO NOT ENCODE. A source that yielded to another window of the same
        // application, or that every client has muted, still has capture running and still calls
        // this ~100 times a second. Encoding into an empty sink map would burn CPU per source for
        // audio no one can hear, which on a multi-window subscription is the difference between
        // paying for one Opus encode and paying for N.
        //
        // It also keeps the report below honest: a `[audio]` line means audio really went somewhere.
        guard !sinks.isEmpty else { lock.unlock(); return }
        // A WRONG-SIZED FRAME IS DROPPED RATHER THAN OFFERED TO libopus, which refuses a
        // non-standard frame size — and a refusal nobody notices reads as intermittent silence.
        guard frame.samples.count == framesPerChannel * channels else {
            reportedDrops += 1
            lock.unlock()
            print("[audio] dropping a \(frame.samples.count)-sample frame " +
                  "(expected \(framesPerChannel * channels))")
            return
        }
        var written: Int32 = 0
        frame.samples.withUnsafeBufferPointer { pcm in
            scratch.withUnsafeMutableBufferPointer { out in
                guard let pcmBase = pcm.baseAddress, let outBase = out.baseAddress else { return }
                written = opus_encode_float(encoder, pcmBase, Int32(framesPerChannel),
                                            outBase, Int32(out.count))
            }
        }
        guard written > 0 else {
            reportedDrops += 1
            lock.unlock()
            print("[audio] opus_encode_float failed: \(written)")
            return
        }
        let payload = Array(scratch[0..<Int(written)])
        let targets = Array(sinks.values)
        reportedFrames += 1
        reportedBytes += payload.count
        encodeCallsForTest += 1
        let line = reportLineLocked(sinkCount: targets.count)
        lock.unlock()
        if let line { reportQueue.async { print(line) } }
        // OUTSIDE THE LOCK, the discipline every fan-out here follows: a sink's write reaches the
        // bridge, and holding an encoder lock across it is how two locks end up nested.
        for sink in targets { sink.writeAudio(payload, ptsNs: frame.ptsNs) }
    }

    /// How many frames actually reached libopus. TEST-ONLY — see `encodeCallsForTest`.
    var encodesForTest: Int { lock.lock(); defer { lock.unlock() }; return encodeCallsForTest }

    /// The five-second `[audio]` line, or nil when it is not due. Caller holds `lock`.
    ///
    /// ZEROES ARE PRINTED, NOT OMITTED — the `[bridge] fec:` rule. `drops=0 sinks=2` beside a live
    /// source separates "the encoder is fine" from "there is no instrument at all", and a line that
    /// appears only when something is wrong trains a reader to believe silence means healthy.
    private func reportLineLocked(sinkCount: Int) -> String? {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastReportAt)
        guard elapsed >= 5 else { return nil }
        let line = String(format: "[audio] %@ %d pkts %d B %.1f kbps drops=%d sinks=%d",
                          sourceID, reportedFrames, reportedBytes,
                          Double(reportedBytes) * 8 / elapsed / 1000, reportedDrops, sinkCount)
        reportedFrames = 0; reportedBytes = 0; reportedDrops = 0
        lastReportAt = now
        return line
    }

    /// TEST-ONLY. Decodes what this encoder produced, so a test can assert the TONE survived rather
    /// than that bytes were produced. Not on the `AudioEncoding` protocol — nothing in the product
    /// decodes audio.
    public static func decodeForTest(_ packets: [[UInt8]], channels: Int, sampleRate: Int) -> [Float] {
        var err: Int32 = 0
        guard let dec = opus_decoder_create(Int32(sampleRate), Int32(channels), &err),
              err == OPUS_OK else { return [] }
        defer { opus_decoder_destroy(dec) }
        let maxFrames: Int32 = 5760          // 120 ms, Opus's largest frame
        var out: [Float] = []
        var buf = [Float](repeating: 0, count: Int(maxFrames) * channels)
        for packet in packets {
            var n: Int32 = 0
            packet.withUnsafeBufferPointer { p in
                buf.withUnsafeMutableBufferPointer { b in
                    guard let outBase = b.baseAddress else { return }
                    n = opus_decode_float(dec, p.baseAddress, Int32(p.count), outBase, maxFrames, 0)
                }
            }
            if n > 0 { out.append(contentsOf: buf[0..<(Int(n) * channels)]) }
        }
        return out
    }
}
