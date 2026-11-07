import XCTest
import RdevCore
@testable import RdevHostKit

/// Collects what an encoder emits, so the delivery contract is testable without a peer.
///
/// It holds its OWN token object rather than minting `ObjectIdentifier(NSObject())` inline: an
/// inline temporary is deallocated immediately and its address can be reused, which would let two
/// sinks collide in the encoder's map and make `testFansOutToEverySink` pass or fail by allocator
/// luck.
private final class CollectingAudioSink: AudioTrackSink {
    private let token = NSObject()
    private let slot: Int32
    var packets: [[UInt8]] = []
    var ptsNs: [Int64] = []

    init(slot: Int32 = 0) { self.slot = slot }
    var sinkKey: SinkKey { SinkKey(peer: ObjectIdentifier(token), slot: slot) }
    func writeAudio(_ payload: [UInt8], ptsNs: Int64) {
        packets.append(payload); self.ptsNs.append(ptsNs)
    }
}

final class OpusEncoderAdapterTests: XCTestCase {
    /// A 440 Hz stereo sine, `frames` sample-frames of it, starting at sample `offset`.
    private func tone(frames: Int, offset: Int = 0, sampleRate: Int = 48_000) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(sin(2.0 * Double.pi * 440.0 * Double(offset + i) / Double(sampleRate)))
            out[i * 2] = v; out[i * 2 + 1] = v
        }
        return out
    }

    /// THE ROUND TRIP IS THE TEST. "Bytes came out" is satisfied by an encoder emitting garbage, and
    /// silence is the most likely failure of every stage in this pipeline — so decode what was
    /// encoded and check the tone survived.
    func testEncodedToneDecodesBackToTheSameTone() throws {
        let enc = try XCTUnwrap(OpusEncoderAdapter())
        let sink = CollectingAudioSink()
        enc.addSink(sink)
        // Opus needs a few frames to converge; 50 x 10 ms = half a second.
        for i in 0..<50 {
            enc.encode(AudioFraming.Frame(samples: tone(frames: 480, offset: i * 480),
                                          ptsNs: Int64(i) * 10_000_000))
        }
        XCTAssertEqual(sink.packets.count, 50)
        XCTAssertTrue(sink.packets.allSatisfy { !$0.isEmpty }, "an empty packet is not a packet")

        let pcm = OpusEncoderAdapter.decodeForTest(sink.packets, channels: 2, sampleRate: 48_000)
        // Skip the first 100 ms — the codec's own convergence, not a defect.
        let steady = Array(pcm.dropFirst(480 * 10 * 2))
        XCTAssertGreaterThan(steady.count, 0, "decoded nothing at all")
        let rms = (steady.reduce(0.0) { $0 + Double($1 * $1) } / Double(steady.count)).squareRoot()
        // A full-scale sine has RMS 0.707. Anything near zero means we decoded SILENCE, which is
        // exactly the failure a "packets were produced" assertion cannot see.
        XCTAssertGreaterThan(rms, 0.3, "decoded audio is silent — the tone did not survive")
        XCTAssertLessThan(rms, 1.0)
    }

    /// The sink carries the FRAME's capture time through untouched. The encoder must not restamp.
    func testPtsIsCarriedThrough() throws {
        let enc = try XCTUnwrap(OpusEncoderAdapter())
        let sink = CollectingAudioSink()
        enc.addSink(sink)
        enc.encode(AudioFraming.Frame(samples: tone(frames: 480), ptsNs: 123_456_789))
        XCTAssertEqual(sink.ptsNs, [123_456_789])
    }

    /// One encode, N sinks — the property that makes N clients on one window cost ONE encode.
    func testFansOutToEverySink() throws {
        let enc = try XCTUnwrap(OpusEncoderAdapter())
        let a = CollectingAudioSink(slot: 0), b = CollectingAudioSink(slot: 1)
        enc.addSink(a); enc.addSink(b)
        enc.encode(AudioFraming.Frame(samples: tone(frames: 480), ptsNs: 0))
        XCTAssertEqual(a.packets.count, 1)
        XCTAssertEqual(b.packets.count, 1)
    }

    func testRemovedSinkStopsReceiving() throws {
        let enc = try XCTUnwrap(OpusEncoderAdapter())
        let sink = CollectingAudioSink()
        enc.addSink(sink)
        enc.encode(AudioFraming.Frame(samples: tone(frames: 480), ptsNs: 0))
        enc.removeSink(sink)
        enc.encode(AudioFraming.Frame(samples: tone(frames: 480), ptsNs: 10_000_000))
        XCTAssertEqual(sink.packets.count, 1)
    }

    /// A frame of the wrong length is DROPPED, not passed to libopus. opus_encode refuses a
    /// non-standard frame size, and a refused encode that is not noticed reads as intermittent
    /// silence rather than as an error.
    func testWrongSizedFrameIsDropped() throws {
        let enc = try XCTUnwrap(OpusEncoderAdapter())
        let sink = CollectingAudioSink()
        enc.addSink(sink)
        enc.encode(AudioFraming.Frame(samples: tone(frames: 333), ptsNs: 0))
        XCTAssertTrue(sink.packets.isEmpty)
    }

    /// NOBODY LISTENING MEANS NOTHING ENCODED, and re-attaching resumes.
    ///
    /// A source that yielded to another window of the same application still has capture running and
    /// still calls encode ~100 times a second. Encoding into an empty sink map would burn a whole
    /// Opus encode per source for audio nobody can hear — on a multi-window subscription, the
    /// difference between paying once and paying N times.
    func testNoSinksMeansNoEncodeAndReattachingResumes() throws {
        let enc = try XCTUnwrap(OpusEncoderAdapter())
        let sink = CollectingAudioSink()
        // No sink at all: must not trap, and MUST NOT REACH libopus.
        //
        // The count is what makes this a real test. Delivery cannot see the difference — with no
        // sinks, a guarded and an unguarded encode both deliver nothing — so asserting on
        // `sink.packets` alone would pass whether or not the guard exists.
        enc.encode(AudioFraming.Frame(samples: tone(frames: 480), ptsNs: 0))
        XCTAssertEqual(enc.encodesForTest, 0, "encoded a frame with nobody listening")
        enc.addSink(sink)
        enc.encode(AudioFraming.Frame(samples: tone(frames: 480), ptsNs: 10_000_000))
        XCTAssertEqual(sink.packets.count, 1, "attaching a sink must resume encoding")
        XCTAssertEqual(enc.encodesForTest, 1)
        enc.removeSink(sink)
        enc.encode(AudioFraming.Frame(samples: tone(frames: 480), ptsNs: 20_000_000))
        XCTAssertEqual(sink.packets.count, 1)
        XCTAssertEqual(enc.encodesForTest, 1, "kept encoding after the last sink went away")
    }

    /// invalidate() is deterministic teardown, and encoding after it must not trap.
    func testEncodeAfterInvalidateIsANoOp() throws {
        let enc = try XCTUnwrap(OpusEncoderAdapter())
        let sink = CollectingAudioSink()
        enc.addSink(sink)
        enc.invalidate()
        enc.encode(AudioFraming.Frame(samples: tone(frames: 480), ptsNs: 0))
        XCTAssertTrue(sink.packets.isEmpty)
    }
}
