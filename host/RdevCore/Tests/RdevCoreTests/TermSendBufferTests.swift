import XCTest
@testable import RdevCore

/// The host-side terminal SEND BUFFER's policy (docs/terminal.md, "The send buffer"): a tab's live
/// output is held up to `hold` and coalesced into one message, flushed `hold` after the first held
/// byte or at once at the cap — EXCEPT within `inputWindow` of client input to that tab, when output
/// goes out at once. Times are nanoseconds on a caller-supplied monotonic clock.
final class TermSendBufferTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testTheConstantsAreTheUsersRule() {
        XCTAssertEqual(TermSendBuffer.hold, 8 * ms)
        XCTAssertEqual(TermSendBuffer.inputWindow, 500 * ms)
        XCTAssertEqual(TermSendBuffer.cap, TermWireMessage.maximumBytes)
    }

    /// N small writes inside the hold become ONE send, due `hold` after the FIRST held byte.
    func testSmallWritesInsideTheHoldCoalesceIntoOneSend() {
        var buf = TermSendBuffer()
        let t0: UInt64 = 1_000 * ms
        XCTAssertEqual(buf.offer(b("a"), at: t0), .holdAndArm(after: TermSendBuffer.hold))
        for i in 1...9 { XCTAssertEqual(buf.offer(b("\(i)"), at: t0 + UInt64(i) * ms / 2), .hold) }
        XCTAssertEqual(buf.pending, b("a123456789"))
        XCTAssertEqual(buf.timerFired(at: t0 + TermSendBuffer.hold), .send(b("a123456789")))
        XCTAssertTrue(buf.pending.isEmpty)
        XCTAssertFalse(buf.timerArmed)
    }

    /// Reaching the cap sends at once — the held bytes and this write, in order.
    func testReachingTheCapSendsAtOnce() {
        var buf = TermSendBuffer(cap: 10)
        XCTAssertEqual(buf.offer(b("12345"), at: 0), .holdAndArm(after: TermSendBuffer.hold))
        XCTAssertEqual(buf.offer(b("6789"), at: 1), .hold)
        XCTAssertEqual(buf.offer(b("0ab"), at: 2), .send(b("1234567890ab")))
        XCTAssertTrue(buf.pending.isEmpty)
        // The armed timer finds nothing; it is spent, not re-armed.
        XCTAssertEqual(buf.timerFired(at: TermSendBuffer.hold), .idle)
        XCTAssertFalse(buf.timerArmed)
    }

    /// Within 500 ms of input output is sent unheld; once the window has passed it is held again.
    func testInputWithinTheWindowSendsAtOnceAndExpires() {
        var buf = TermSendBuffer()
        let t0: UInt64 = 5_000 * ms
        buf.noteInput(at: t0)
        XCTAssertEqual(buf.offer(b("echo"), at: t0 + 2 * ms), .send(b("echo")))
        XCTAssertEqual(buf.offer(b("more"), at: t0 + TermSendBuffer.inputWindow - 1), .send(b("more")))
        XCTAssertEqual(buf.offer(b("late"), at: t0 + TermSendBuffer.inputWindow), .holdAndArm(after: TermSendBuffer.hold))
    }

    /// Input arriving while bytes are held: the next output carries them out with it, in order.
    func testInteractiveOutputCarriesTheHeldBytesInOrder() {
        var buf = TermSendBuffer()
        XCTAssertEqual(buf.offer(b("held"), at: 0), .holdAndArm(after: TermSendBuffer.hold))
        buf.noteInput(at: 1 * ms)
        XCTAssertEqual(buf.offer(b("+echo"), at: 2 * ms), .send(b("held+echo")))
    }

    /// `urgent` (the emulator answered a device query in these bytes and the driver's xterm.js is to
    /// answer it instead) sends at once, so the host decides "reached" only on the real emission.
    func testUrgentSendsAtOnce() {
        var buf = TermSendBuffer()
        XCTAssertEqual(buf.offer(b("x"), at: 0), .holdAndArm(after: TermSendBuffer.hold))
        XCTAssertEqual(buf.offer(b("\u{1b}[5n"), at: 1, urgent: true), .send(b("x\u{1b}[5n")))
    }

    /// ONE timer per tab: a timer armed for an earlier batch that was flushed early re-arms for the
    /// remainder of the next batch's hold instead of sending it early — and no second timer is armed.
    func testAnEarlyTimerRearmsForTheRemainderAndNoSecondTimerIsArmed() {
        var buf = TermSendBuffer(cap: 4)
        XCTAssertEqual(buf.offer(b("ab"), at: 0), .holdAndArm(after: TermSendBuffer.hold))
        XCTAssertEqual(buf.offer(b("cd"), at: 1 * ms), .send(b("abcd")))              // the cap, early
        XCTAssertEqual(buf.offer(b("e"), at: 3 * ms), .hold, "the armed timer covers it")
        XCTAssertEqual(buf.timerFired(at: 8 * ms), .rearm(after: 3 * ms))
        XCTAssertTrue(buf.timerArmed)
        XCTAssertEqual(buf.offer(b("f"), at: 9 * ms), .hold)
        XCTAssertEqual(buf.timerFired(at: 11 * ms), .send(b("ef")))
    }

    /// A boundary (snapshot, closed, resize) TAKES the held bytes; a loss of context DROPS them. Either
    /// way the armed timer then finds nothing.
    func testTakeAndDropEmptyTheBufferAndSpendTheTimer() {
        var buf = TermSendBuffer()
        _ = buf.offer(b("abc"), at: 0)
        XCTAssertEqual(buf.take(), b("abc"))
        XCTAssertEqual(buf.take(), [])
        XCTAssertEqual(buf.timerFired(at: TermSendBuffer.hold), .idle)
        _ = buf.offer(b("def"), at: 20 * ms)
        buf.drop()
        XCTAssertTrue(buf.pending.isEmpty)
        XCTAssertEqual(buf.timerFired(at: 28 * ms), .idle)
    }

    /// A timer the caller lost (a replaced tmux client's) is forgotten: the next held byte arms anew.
    func testAForgottenTimerIsArmedAgainByTheNextHeldByte() {
        var buf = TermSendBuffer()
        XCTAssertEqual(buf.offer(b("a"), at: 0), .holdAndArm(after: TermSendBuffer.hold))
        buf.forgetTimer()
        XCTAssertTrue(buf.pending.isEmpty)
        XCTAssertEqual(buf.offer(b("b"), at: 1), .holdAndArm(after: TermSendBuffer.hold))
    }

    /// Nothing to send is never a message.
    func testEmptyOutputIsNeverSent() {
        var buf = TermSendBuffer()
        buf.noteInput(at: 0)
        XCTAssertEqual(buf.offer([], at: 1), .send([]), "not `.hold`: nothing was held")
        XCTAssertFalse(buf.timerArmed)
        var held = TermSendBuffer()
        _ = held.offer(b("x"), at: 0)
        XCTAssertEqual(held.offer([], at: 1), .send([]))
        XCTAssertEqual(held.pending, b("x"), "what was held stays held")
    }
}
