import XCTest
@testable import RdevCore

/// NOTE ON `try XCTUnwrap(r.paired.first)` RATHER THAN `r.paired[0]`.
///
/// The plan specified these tests with `r.paired[0]`, and this is a deliberate amendment to it,
/// agreed with the plan's author. Every assertion is preserved exactly; only the way the sample is
/// reached changed. `XCTAssertEqual(r.paired.count, 1)` does not stop execution, so a regression in
/// `pair` reaches the subscript, and an out-of-range subscript is a Swift TRAP — it aborts the whole
/// 486-test binary and reports one misleading failure, in a module whose `BUILD.bazel` treats the
/// test count as the thing being watched. That is not hypothetical here: it is exactly what happened
/// during this task's step-5 mutation check, where the trap killed the run after two tests and made
/// "4 of 5 fail" take two runs and a removed test to establish. `XCTUnwrap` fails that one test and
/// lets the other 485 report.
final class InputToDecodeTests: XCTestCase {
    func testAMatchedPairSplitsIntoInputAndMediaPaths() throws {
        let r = InputToDecode.pair(
            sends: [(ordinal: 1, sentMs: 1_000)],
            decodes: [(ordinal: 1, stampMs: 1_012, decodedMs: 1_045)])
        XCTAssertEqual(r.paired.count, 1)
        let s = try XCTUnwrap(r.paired.first)
        XCTAssertEqual(s.inputPathMs, 12)   // send -> the app reacted
        XCTAssertEqual(s.mediaPathMs, 33)   // reaction -> decoded
        XCTAssertEqual(s.totalMs, 45)
    }

    /// A repaint with no new input carries the PREVIOUS ordinal. Counting it again would
    /// invent a sample whose media path is real but whose input path is fiction.
    func testARepeatedOrdinalIsPairedOnceNotTwice() {
        let r = InputToDecode.pair(
            sends: [(ordinal: 1, sentMs: 1_000)],
            decodes: [(ordinal: 1, stampMs: 1_012, decodedMs: 1_045),
                      (ordinal: 1, stampMs: 1_012, decodedMs: 1_061)])
        XCTAssertEqual(r.paired.count, 1)
        XCTAssertEqual(r.unmatchedDecodes, 1)
    }

    /// An input that never produced a frame is LOSS, and must be visible as such rather
    /// than silently shrinking the sample set.
    func testAnInputThatNeverArrivedIsCountedNotDropped() {
        let r = InputToDecode.pair(
            sends: [(ordinal: 1, sentMs: 1_000), (ordinal: 2, sentMs: 1_100)],
            decodes: [(ordinal: 1, stampMs: 1_012, decodedMs: 1_045)])
        XCTAssertEqual(r.paired.count, 1)
        XCTAssertEqual(r.unmatchedSends, 1)
    }

    /// An ordinal that was never sent means the target and the harness disagree about
    /// what happened -- never a sample.
    func testADecodeForAnUnsentOrdinalIsRefused() {
        let r = InputToDecode.pair(
            sends: [(ordinal: 1, sentMs: 1_000)],
            decodes: [(ordinal: 9, stampMs: 1_012, decodedMs: 1_045)])
        XCTAssertEqual(r.paired.count, 0)
        XCTAssertEqual(r.unmatchedDecodes, 1)
    }

    /// The target's ordinal is monotonic, so a repeated ordinal in `sends` is a reconciliation bug
    /// upstream. Only one of the two can ever pair; the other must still be COUNTED, or the run
    /// reports a full sample set while an input silently vanished from the accounting.
    func testARepeatedSendOrdinalPairsOnceAndCountsTheOther() throws {
        let r = InputToDecode.pair(
            sends: [(ordinal: 1, sentMs: 1_000), (ordinal: 1, sentMs: 1_004)],
            decodes: [(ordinal: 1, stampMs: 1_012, decodedMs: 1_045)])
        XCTAssertEqual(r.paired.count, 1)
        XCTAssertEqual(try XCTUnwrap(r.paired.first).inputPathMs, 12)   // the FIRST send, not the second
        XCTAssertEqual(r.unmatchedSends, 1)
        XCTAssertEqual(r.unmatchedDecodes, 0)
    }

    /// The stamp is the LOW 32 BITS of an epoch millisecond, and it rolls over every ~49.7 days.
    /// Subtracting as `Int64` across that boundary reports ~4.29e9 ms on one half and ~-4.29e9 on
    /// the other -- a catastrophic stall and a negative latency, both entirely plausible-looking
    /// in a percentile. Both halves must wrap.
    func testSubtractionsWrapAcrossThe32BitRollover() throws {
        let sentMs: Int64 = Int64(UInt32.max) - 5      // 6 ms before the rollover
        let stampMs: UInt32 = 6                        // 12 ms later, having wrapped
        let decodedMs: Int64 = Int64(UInt32.max) + 41  // low 32 bits = 40, i.e. 34 ms after the stamp
        let r = InputToDecode.pair(sends: [(ordinal: 1, sentMs: sentMs)],
                                   decodes: [(ordinal: 1, stampMs: stampMs, decodedMs: decodedMs)])
        XCTAssertEqual(r.paired.count, 1)
        let s = try XCTUnwrap(r.paired.first)
        XCTAssertEqual(s.inputPathMs, 12)
        XCTAssertEqual(s.mediaPathMs, 34)
        XCTAssertEqual(s.totalMs, 46)
    }

    func testAnEmptyRunPairsNothingRatherThanCrashing() {
        let r = InputToDecode.pair(sends: [], decodes: [])
        XCTAssertEqual(r.paired.count, 0)
        XCTAssertEqual(r.unmatchedSends, 0)
        XCTAssertEqual(r.unmatchedDecodes, 0)
    }
}
