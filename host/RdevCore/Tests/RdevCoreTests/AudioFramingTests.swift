import XCTest
@testable import RdevCore

final class AudioFramingTests: XCTestCase {
    private func chunk(frames: Int, channels: Int = 2, value: Float = 0.5) -> [Float] {
        Array(repeating: value, count: frames * channels)
    }

    /// One frame in, one frame out, carrying its own capture time.
    func testExactFrameEmitsOnce() {
        var f = AudioFraming()
        let out = f.append(chunk(frames: 480), ptsNs: 1_000)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].samples.count, 960)      // 480 frames x 2 channels
        XCTAssertEqual(out[0].ptsNs, 1_000)
        XCTAssertEqual(f.backlogFrames, 0)
    }

    /// A short chunk emits nothing and is HELD — the encoder must never see a partial frame.
    func testShortChunkIsHeld() {
        var f = AudioFraming()
        XCTAssertTrue(f.append(chunk(frames: 300), ptsNs: 0).isEmpty)
        XCTAssertEqual(f.backlogFrames, 300)
    }

    /// Two chunks that together exceed a frame emit on the SECOND, and the emitted frame's time is
    /// the FIRST chunk's — the frame starts where its first sample was captured.
    func testFrameSpansTwoChunks() {
        var f = AudioFraming()
        _ = f.append(chunk(frames: 300), ptsNs: 0)
        let out = f.append(chunk(frames: 700), ptsNs: 6_250_000)   // 300 frames @48k = 6.25 ms
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].ptsNs, 0)
        XCTAssertEqual(out[1].ptsNs, 10_000_000)                   // exactly one 10 ms frame later
        XCTAssertEqual(f.backlogFrames, 40)                        // 1000 - 960
    }

    /// A chunk whose length is not a whole number of sample frames is REFUSED, not truncated.
    /// Truncating shears every channel from that point on and every later frame is silently wrong.
    func testRaggedChunkIsRefused() {
        var f = AudioFraming()
        XCTAssertTrue(f.append(Array(repeating: 0.1, count: 961), ptsNs: 0).isEmpty)
        XCTAssertEqual(f.backlogFrames, 0)
    }

    /// THE DISCRIMINATING TEST FOR ANCHORING, and it is the gap rather than the arithmetic.
    ///
    /// "Anchored to an epoch, never summed from rounded deltas" is UNFALSIFIABLE at the shipped
    /// configuration: every Opus frame size at 48 kHz (120/240/480/960/1920/2880) is divisible by 3,
    /// so N frames is an exact whole number of nanoseconds and a summing implementation produces
    /// byte-identical output. What a summing implementation CANNOT get right is a discontinuity: it
    /// keeps counting through the gap and every timestamp after it is wrong, forever.
    func testGapReanchorsRatherThanCountingThrough() {
        var f = AudioFraming()
        _ = f.append(chunk(frames: 480), ptsNs: 0)
        // The app went silent for 250 ms. The next chunk's own time is the truth.
        let out = f.append(chunk(frames: 480), ptsNs: 250_000_000)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].ptsNs, 250_000_000)   // a summing impl would say 10_000_000
    }

    /// A partial frame held across a gap is DROPPED rather than bridged with silence: synthesising
    /// samples makes the RTP timestamp a fiction, and the receiver handles a real gap correctly.
    func testGapDropsThePartialFrame() {
        var f = AudioFraming()
        _ = f.append(chunk(frames: 300), ptsNs: 0)
        XCTAssertEqual(f.backlogFrames, 300)
        let out = f.append(chunk(frames: 480), ptsNs: 250_000_000)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].ptsNs, 250_000_000)
        XCTAssertEqual(f.backlogFrames, 0)
    }

    /// Jitter INSIDE the tolerance is not a gap — SCK's delivery times wobble and re-anchoring on
    /// every wobble would make the media clock follow delivery jitter instead of capture time.
    func testSmallJitterDoesNotReanchor() {
        var f = AudioFraming()
        _ = f.append(chunk(frames: 480), ptsNs: 0)
        let out = f.append(chunk(frames: 480), ptsNs: 10_000_000 + 1_000_000)   // 1 ms late
        XCTAssertEqual(out[0].ptsNs, 10_000_000)   // the RUNNING count wins inside tolerance
    }

    /// reset() forgets both the buffer and the anchor.
    func testResetClearsBacklogAndAnchor() {
        var f = AudioFraming()
        _ = f.append(chunk(frames: 300), ptsNs: 0)
        f.reset()
        XCTAssertEqual(f.backlogFrames, 0)
        let out = f.append(chunk(frames: 480), ptsNs: 777)
        XCTAssertEqual(out[0].ptsNs, 777)
    }
}
