import XCTest
@testable import RdevCore

final class AudioOwnershipTests: XCTestCase {
    private func win(_ id: String, _ pid: Int32) -> AudioSource {
        AudioSource(id: id, owner: .application(pid: pid))
    }
    private func display(_ id: String) -> AudioSource {
        AudioSource(id: id, owner: .everything)
    }

    /// THE CONTROL ARM. Two windows of DIFFERENT apps must BOTH carry audio.
    ///
    /// Without this, "carry nothing, ever" satisfies every other test here — the same trap the
    /// palette's `locked` branch documents. A dedupe rule that dedupes everything is not a dedupe
    /// rule, and it is silent: you would simply never hear anything.
    func testDistinctApplicationsBothCarry() {
        let s = [win("win:1", 100), win("win:2", 200)]
        XCTAssertEqual(AudioOwnership.carriers(s), ["win:1", "win:2"])
        XCTAssertEqual(AudioOwnership.elect(s), ["win:1": "win:1", "win:2": "win:2"])
    }

    /// Two windows of ONE app: the first carries, the second yields TO IT BY NAME so the client can
    /// say "audio from <window>" rather than rendering a silent window that looks broken.
    ///
    /// MEASURED, NOT ASSUMED (2026-09-03, spec's Measured section, arm H): a PAUSED, SILENT
    /// QuickTime window carried a DIFFERENT QuickTime window's audio at 99.4%.
    func testSameApplicationYieldsToTheFirst() {
        let s = [win("win:1", 100), win("win:2", 100)]
        XCTAssertEqual(AudioOwnership.carriers(s), ["win:1"])
        XCTAssertEqual(AudioOwnership.elect(s)["win:2"], "win:1")
    }

    /// A display source is the system mix, so it owns EVERY application's audio and every window
    /// yields to it — including a window subscribed BEFORE it. "First subscriber wins" ranks within
    /// an application; a display is not an application.
    func testDisplayClaimsEverything() {
        let s = [win("win:1", 100), display("dsp:1"), win("win:2", 200)]
        XCTAssertEqual(AudioOwnership.carriers(s), ["dsp:1"])
        XCTAssertEqual(AudioOwnership.elect(s)["win:1"], "dsp:1")
        XCTAssertEqual(AudioOwnership.elect(s)["win:2"], "dsp:1")
    }

    /// Two displays: the first carries, the second yields. Two system mixes would double every sound.
    func testSecondDisplayYields() {
        let s = [display("dsp:1"), display("dsp:2")]
        XCTAssertEqual(AudioOwnership.carriers(s), ["dsp:1"])
        XCTAssertEqual(AudioOwnership.elect(s)["dsp:2"], "dsp:1")
    }

    /// FIRST SUBSCRIBER WINS, AND LOSING THE WINNER PROMOTES THE NEXT. A later subscribe never
    /// steals audio from a live one (that would churn on every window opened); an unsubscribe
    /// re-runs the election and the survivor carries.
    func testCarrierMovesOnUnsubscribe() {
        XCTAssertEqual(AudioOwnership.carriers([win("win:1", 100), win("win:2", 100)]), ["win:1"])
        XCTAssertEqual(AudioOwnership.carriers([win("win:2", 100)]), ["win:2"])
    }

    /// Empty in, empty out — and specifically NOT a crash.
    func testEmptyIsEmpty() {
        XCTAssertEqual(AudioOwnership.carriers([]), [])
        XCTAssertEqual(AudioOwnership.elect([]), [:])
    }

    /// A duplicate id must not trap. ViewSet already refuses duplicate subscriptions, so this is
    /// defence rather than a supported input — but a crash in the host is not an acceptable
    /// response to a bookkeeping bug elsewhere.
    func testDuplicateIdDoesNotTrap() {
        let s = [win("win:1", 100), win("win:1", 100)]
        XCTAssertEqual(AudioOwnership.carriers(s), ["win:1"])
    }

    /// REVIEW FOCUS 1. A stream with no owning process is a DISPLAY to the election (`.everything`), so a simulator
    /// given that owner would silence every window. `.silent` carries its own — empty — audio and takes nobody's.
    func testASimulatorTakesNobodysAudio() {
        let window = AudioSource(id: "win:1", owner: .application(pid: 42))
        let sim = AudioSource(id: "sim:U", owner: .silent)
        XCTAssertEqual(AudioOwnership.elect([sim, window]), ["sim:U": "sim:U", "win:1": "win:1"])
        XCTAssertEqual(AudioOwnership.elect([window, sim]), ["sim:U": "sim:U", "win:1": "win:1"])
        XCTAssertEqual(AudioOwnership.carriers([sim, window]), ["sim:U", "win:1"])
    }
}
