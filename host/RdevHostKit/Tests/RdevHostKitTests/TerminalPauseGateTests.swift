import XCTest
@testable import RdevHostKit

final class TerminalPauseGateTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        let lock = NSLock(); var events: [String] = []
        func add(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }
    private final class Owner: @unchecked Sendable {
        let lock = NSLock(); var id: AnyHashable?
        func set(_ v: AnyHashable?) { lock.lock(); id = v; lock.unlock() }
        var current: AnyHashable? { lock.lock(); defer { lock.unlock() }; return id }
    }
    private func gate(_ log: Log, owner: Owner = Owner()) -> TerminalPauseGate {
        TerminalPauseGate(delay: .milliseconds(100), owner: { owner.current },
                          apply: { log.add("pause") }, lift: { log.add("resume") }, clear: { log.add("clear") })
    }

    func testAPauseAppliesAfterTheHold() {
        let log = Log(), g = gate(log)
        g.pause(from: nil); g.sync()
        XCTAssertEqual(log.all, [], "not before the hold")
        Thread.sleep(forTimeInterval: 0.3); g.sync()
        XCTAssertEqual(log.all, ["pause"])
    }

    /// REVIEW FOCUS 5: a phone app-switch shorter than the hold re-serializes nothing and cannot
    /// leave a pause behind that lands after the resume.
    func testATerminalResumeInsideTheHoldCancelsThePause() {
        let log = Log(), g = gate(log)
        g.pause(from: nil); g.resume(from: nil)
        Thread.sleep(forTimeInterval: 0.3); g.sync()
        XCTAssertEqual(log.all, [])
    }

    func testAResumeAfterAnAppliedPauseLiftsIt() {
        let log = Log(), g = gate(log)
        g.pause(from: nil); Thread.sleep(forTimeInterval: 0.3)
        g.resume(from: nil); g.sync()
        XCTAssertEqual(log.all, ["pause", "resume"])
        g.resume(from: nil); g.sync()
        XCTAssertEqual(log.all, ["pause", "resume"], "a second resume re-serializes nothing")
    }

    func testRepeatedPausesApplyOnce() {
        let log = Log(), g = gate(log)
        g.pause(from: nil); g.pause(from: nil); g.pause(from: nil)
        Thread.sleep(forTimeInterval: 0.3); g.sync()
        XCTAssertEqual(log.all, ["pause"])
    }

    func testResetVoidsAPendingPauseAndClears() {
        let log = Log(), g = gate(log)
        g.pause(from: nil); g.reset()
        Thread.sleep(forTimeInterval: 0.3); g.sync()
        XCTAssertEqual(log.all, ["clear"])
    }

    /// Final review M3: a pause/resume is checked against the driver on the message thread, then
    /// queued. A claim landing between the two must void it: the NEW driver's page is visible and
    /// asked for nothing. And a rebuilt driver's OLD connection is not its owner either.
    func testAPauseOrResumeFromAnyoneButTheDriversConnectionIsDropped() {
        let log = Log(), owner = Owner(), g = gate(log, owner: owner)
        owner.set("a")
        g.pause(from: "a"); Thread.sleep(forTimeInterval: 0.3); g.sync()
        XCTAssertEqual(log.all, ["pause"], "the driver's own pause applies")
        owner.set("b"); g.reset()                                         // the claim
        g.pause(from: "a")                                                // checked before it, queued after
        Thread.sleep(forTimeInterval: 0.3); g.sync()
        XCTAssertEqual(log.all, ["pause", "clear"], "the old driver's pause does not reach the new one")
        g.pause(from: "b"); Thread.sleep(forTimeInterval: 0.3); g.sync()
        g.resume(from: "a"); g.sync()
        XCTAssertEqual(log.all, ["pause", "clear", "pause"], "nor does its resume")
        g.resume(from: "b"); g.sync()
        XCTAssertEqual(log.all, ["pause", "clear", "pause", "resume"])
    }
}
