import XCTest
@testable import RdevCore

final class TermModeTrackerTests: XCTestCase {

    private func track(_ s: String) -> TermModes {
        var t = TermModeTracker()
        t.feed(Array(s.utf8))
        return t.modes
    }

    func testDefaults() {
        let m = TermModes()
        XCTAssertEqual(m.mouse, .off)
        XCTAssertEqual(m.mouseEncoding, .standard)
        XCTAssertFalse(m.applicationCursor)
        XCTAssertFalse(m.focusReporting)
        XCTAssertFalse(m.bracketedPaste)
        XCTAssertFalse(m.altScreen)
        XCTAssertTrue(m.cursorVisible)
    }

    func testTracksMouseTrackingAndEncoding() {
        let m = track("\u{1b}[?1003h\u{1b}[?1006h")
        XCTAssertEqual(m.mouse, .anyEvent)
        XCTAssertEqual(m.mouseEncoding, .sgr)
    }

    func testResettingAnyTrackingModeTurnsReportingOff() {
        // xterm.js semantics: ?1000l clears the active protocol whichever one set it.
        XCTAssertEqual(track("\u{1b}[?1003h\u{1b}[?1000l").mouse, .off)
        XCTAssertEqual(track("\u{1b}[?1002h\u{1b}[?1002l").mouse, .off)
    }

    func testLastTrackingModeWins() {
        XCTAssertEqual(track("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h").mouse, .anyEvent)
        XCTAssertEqual(track("\u{1b}[?1003h\u{1b}[?1000h").mouse, .vt200)
    }

    func testMultipleParametersInOneSequence() {
        // What a TUI actually emits on startup: CSI ? 1002 ; 1006 h
        let m = track("\u{1b}[?1002;1006h")
        XCTAssertEqual(m.mouse, .buttonEvent)
        XCTAssertEqual(m.mouseEncoding, .sgr)
    }

    func testTracksTheRestOfTheSet() {
        var m = track("\u{1b}[?1h\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?25l\u{1b}[?1049h")
        XCTAssertTrue(m.applicationCursor)
        XCTAssertTrue(m.focusReporting)
        XCTAssertTrue(m.bracketedPaste)
        XCTAssertTrue(m.altScreen)
        XCTAssertFalse(m.cursorVisible)
        m = track("\u{1b}[?1h\u{1b}[?1l\u{1b}[?1049h\u{1b}[?1049l")
        XCTAssertFalse(m.applicationCursor)
        XCTAssertFalse(m.altScreen)
    }

    /// PTY reads split wherever the kernel feels like it — a sequence straddling two feeds must still land.
    func testSequenceSplitAcrossFeeds() {
        var t = TermModeTracker()
        t.feed(Array("\u{1b}[?10".utf8))
        t.feed(Array("03h".utf8))
        XCTAssertEqual(t.modes.mouse, .anyEvent)

        var u = TermModeTracker()
        for byte in Array("\u{1b}[?1006h".utf8) { u.feed([byte]) }   // one byte per feed
        XCTAssertEqual(u.modes.mouseEncoding, .sgr)
    }

    func testIgnoresModeShapedBytesInsideAStringSequence() {
        // A title containing mode-shaped TEXT must not move the state (this is what a shell prompt
        // writing "[?1003h" into its window title would look like).
        XCTAssertEqual(track("\u{1b}]0;[?1003h\u{07}").mouse, .off)
        XCTAssertEqual(track("\u{1b}P[?1003h\u{1b}\\").mouse, .off)                    // DCS payload
        // Both terminators end the string, so a mode change AFTER one is real.
        XCTAssertEqual(track("\u{1b}]0;title\u{07}\u{1b}[?1003h").mouse, .anyEvent)     // BEL
        XCTAssertEqual(track("\u{1b}]0;title\u{1b}\\\u{1b}[?1003h").mouse, .anyEvent)   // ST
        // An ESC inside a string ABORTS it and starts a new sequence — real parser behaviour, so this
        // one genuinely does set the mode. Asserted so the semantics stay deliberate.
        XCTAssertEqual(track("\u{1b}]0;\u{1b}[?1003h\u{07}").mouse, .anyEvent)
    }

    func testIgnoresNonPrivateAndQuerySequences() {
        XCTAssertEqual(track("\u{1b}[1003h").mouse, .off)        // no '?' — not a DEC private mode
        XCTAssertEqual(track("\u{1b}[?1003$p").mouse, .off)      // DECRQM query, not a set
        XCTAssertTrue(track("\u{1b}[?25;1l").cursorVisible == false)
    }

    func testRISResetsEverything() {
        XCTAssertEqual(track("\u{1b}[?1003h\u{1b}[?1006h\u{1b}c").mouse, .off)
        XCTAssertEqual(track("\u{1b}[?1003h\u{1b}[?1006h\u{1b}c").mouseEncoding, .standard)
        XCTAssertTrue(track("\u{1b}[?25l\u{1b}c").cursorVisible)
    }

    func testPlainTextDoesNotDisturbState() {
        XCTAssertEqual(track("\u{1b}[?1003h$ ls -la\r\nfile.txt\r\n").mouse, .anyEvent)
    }
}

final class ModeInputTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testRecognisesTheThreeMouseEncodings() {
        XCTAssertTrue(ModeInput.isAllMouseReports(bytes("\u{1b}[<35;11;6M")))    // SGR press/move
        XCTAssertTrue(ModeInput.isAllMouseReports(bytes("\u{1b}[<0;12;7m")))     // SGR release
        XCTAssertTrue(ModeInput.isAllMouseReports(bytes("\u{1b}[35;11;6M")))     // urxvt
        XCTAssertTrue(ModeInput.isAllMouseReports([0x1b, 0x5b, 0x4d, 0x20, 0x21, 0x22]))   // X10
    }

    func testRecognisesARunOfReports() {
        // xterm can emit several in one chunk; dropping must be all-or-nothing.
        XCTAssertTrue(ModeInput.isAllMouseReports(bytes("\u{1b}[<35;11;6M\u{1b}[<35;12;7M\u{1b}[<35;13;8M")))
    }

    func testNeverMistakesRealInputForAReport() {
        for input in ["a", "ls -la\r", "\u{03}", "\u{1b}", "\u{1b}[A", "\u{1b}[3~", "\u{1b}OA", "\u{7f}",
                      "\u{1b}[<35;11;6M trailing", "\u{1b}[2M", "\u{1b}[<35;11M", ""] {
            XCTAssertFalse(ModeInput.isAllMouseReports(bytes(input)), "must not drop \(input.debugDescription)")
        }
    }

    func testFocusReports() {
        XCTAssertTrue(ModeInput.isAllFocusReports(bytes("\u{1b}[I")))
        XCTAssertTrue(ModeInput.isAllFocusReports(bytes("\u{1b}[O")))
        XCTAssertFalse(ModeInput.isAllFocusReports(bytes("\u{1b}[A")))
        XCTAssertFalse(ModeInput.isAllFocusReports(bytes("I")))
        XCTAssertFalse(ModeInput.isAllFocusReports(bytes("")))
    }

    /// The whole point: a tab that never asked for tracking refuses reports, one that did still gets them.
    func testDropsOnlyWhatTheTabCannotHaveAskedFor() {
        var off = TermModes()
        XCTAssertTrue(ModeInput.shouldDrop(bytes("\u{1b}[<35;11;6M"), modes: off))
        XCTAssertFalse(ModeInput.shouldDrop(bytes("ls\r"), modes: off))

        var tracking = TermModes()
        tracking.mouse = .anyEvent
        XCTAssertFalse(ModeInput.shouldDrop(bytes("\u{1b}[<35;11;6M"), modes: tracking),
                       "a mouse app must still receive its reports")

        off.focusReporting = false
        XCTAssertTrue(ModeInput.shouldDrop(bytes("\u{1b}[I"), modes: off))
        var focus = TermModes()
        focus.focusReporting = true
        XCTAssertFalse(ModeInput.shouldDrop(bytes("\u{1b}[I"), modes: focus))
    }

    /// End to end through the tracker: what the tab's own output says is what the filter enforces.
    func testTrackerDrivesTheFilter() {
        var t = TermModeTracker()
        XCTAssertTrue(ModeInput.shouldDrop(bytes("\u{1b}[<35;11;6M"), modes: t.modes))
        t.feed(bytes("\u{1b}[?1003h\u{1b}[?1006h"))
        XCTAssertFalse(ModeInput.shouldDrop(bytes("\u{1b}[<35;11;6M"), modes: t.modes))
        t.feed(bytes("\u{1b}[?1003l"))
        XCTAssertTrue(ModeInput.shouldDrop(bytes("\u{1b}[<35;11;6M"), modes: t.modes))
    }
}

final class TerminalInputTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// The agreement rule, both directions. The FALSE arm is the one that matters: it is the keystroke
    /// typed while the client still showed the previous tab, and delivering it is how a password ends
    /// up in a shell the user was not looking at.
    func testDeliversOnlyWhenTheClientAndTheHostNameTheSameTab() {
        let modes = TermModes()
        XCTAssertTrue(TerminalInput.shouldDeliver(named: .pty(2), activeTab: .pty(2), bytes: bytes("ls\r"), modes: modes))
        XCTAssertFalse(TerminalInput.shouldDeliver(named: .pty(1), activeTab: .pty(2), bytes: bytes("ls\r"), modes: modes))
        XCTAssertFalse(TerminalInput.shouldDeliver(named: .pty(2), activeTab: .pty(1), bytes: bytes("ls\r"), modes: modes))
    }

    /// Tab ids are compared, not merely counted: an off-by-one in either direction must fail. Without
    /// this a `named >= activeTab` or a `named != 0` would pass the test above.
    func testAdjacentTabIdsAreNotTheSameTab() {
        let modes = TermModes()
        for (named, active): (TermTabID, TermTabID) in [(.pty(3), .pty(4)), (.pty(4), .pty(3)), (.pty(1), .tmux("$1")), (.tmux("$1"), .pty(1)), (.tmux("$1"), .tmux("$2"))] {
            XCTAssertFalse(TerminalInput.shouldDeliver(named: named, activeTab: active,
                                                       bytes: bytes("x"), modes: modes),
                           "\(named.wire) and \(active.wire) are different tabs")
        }
    }

    /// The mode filter still applies on top, and it is NOT what the agreement rule is doing — these two
    /// refuse different things and each must be able to refuse alone.
    func testTheModeFilterStillAppliesToTheAgreedTab() {
        var off = TermModes()
        off.mouse = .off
        XCTAssertFalse(TerminalInput.shouldDeliver(named: .pty(2), activeTab: .pty(2),
                                                   bytes: bytes("\u{1b}[<35;11;6M"), modes: off),
                       "a tab with tracking off cannot have asked for a mouse report")

        var tracking = TermModes()
        tracking.mouse = .anyEvent
        XCTAssertTrue(TerminalInput.shouldDeliver(named: .pty(2), activeTab: .pty(2),
                                                  bytes: bytes("\u{1b}[<35;11;6M"), modes: tracking),
                      "a mouse app on the agreed tab must still receive its reports")
        XCTAssertFalse(TerminalInput.shouldDeliver(named: .pty(1), activeTab: .pty(2),
                                                   bytes: bytes("\u{1b}[<35;11;6M"), modes: tracking),
                       "agreeing about modes is not agreeing about the tab")
    }

    /// A device-query REPLY names the tab whose instance produced it — the tab whose bytes asked — so its
    /// destination is never a guess about what the user sees. It is delivered to that tab while the host
    /// OWES that tab a reply (it left a query in its bytes to the client), active or not; with nothing
    /// owed it is held to the keystroke rule exactly. Typing never takes this path.
    func testAReplyReachesItsOwnTabOnlyWhileAReplyIsOwed() {
        let modes = TermModes()
        let dsr = bytes("\u{1b}[0n")
        XCTAssertTrue(TerminalInput.shouldDeliverReply(named: .pty(1), activeTab: .pty(2), owedReplies: 1, bytes: dsr, modes: modes),
                      "owed: delivered to the tab that asked, though another is active")
        XCTAssertFalse(TerminalInput.shouldDeliverReply(named: .pty(1), activeTab: .pty(2), owedReplies: 0, bytes: dsr, modes: modes),
                       "nothing owed: a reply for a tab that is not active is refused like a keystroke")
        XCTAssertTrue(TerminalInput.shouldDeliverReply(named: .pty(2), activeTab: .pty(2), owedReplies: 0, bytes: dsr, modes: modes),
                      "nothing owed but the tab is active: the keystroke rule, unchanged")
        var off = TermModes(); off.mouse = .off
        XCTAssertFalse(TerminalInput.shouldDeliverReply(named: .pty(2), activeTab: .pty(2), owedReplies: 0,
                                                        bytes: bytes("\u{1b}[<35;11;6M"), modes: off),
                       "…mode filter included")
        XCTAssertTrue(TerminalInput.shouldDeliverReply(named: .pty(1), activeTab: nil, owedReplies: 1, bytes: dsr, modes: modes))
        for bad in ["\r rm -rf ~\r", "\u{1b}[0n\r", "x\u{1b}[0n", "\u{1b}[" + String(repeating: "1", count: 300) + "R", "\u{1b}[0n\u{7f}", ""] {
            XCTAssertFalse(TerminalInput.shouldDeliverReply(named: .pty(1), activeTab: .pty(2), owedReplies: 1,
                                                            bytes: bytes(bad), modes: modes), "\(bad.debugDescription): not reply-shaped")
        }
        // Exactly ONE sequence: zsh binds `ESC a` to accept-and-hold, so an ESC mid-message could run what
        // precedes it; and no byte >= 0x80 (a C1 CSI, or anything outside the ASCII every reply is).
        for bad in ["\u{1b}[Crm -rf ~\u{1b}a", "\u{1b}[0n\u{1b}[0n", "\u{1b}]11;x\u{1b}[A\u{07}", "\u{1b}P1$r0m\u{07}",
                    "\u{1b}[0n\u{9b}", "\u{1b}]11;é\u{07}", "\u{1b}]11;x", "\u{1b}[", "\u{1b}a"] {
            XCTAssertFalse(TerminalInput.isReplyShaped(bytes(bad)), bad.debugDescription)
        }
        XCTAssertFalse(TerminalInput.isReplyShaped([0x1b, 0x5b, 0x30, 0x9b, 0x6e]), "a raw C1 byte")
        for good in ["\u{1b}[1;1R", "\u{1b}[?25;1$y", "\u{1b}[>0;276;0c", "\u{1b}]11;rgb:0000/0000/0000\u{1b}\\", "\u{1b}]11;rgb:0/0/0\u{07}", "\u{1b}P1$r0m\u{1b}\\", "\u{1b}[?1;2c"] {
            XCTAssertTrue(TerminalInput.isReplyShaped(bytes(good)), good.debugDescription)
        }
        XCTAssertFalse(TerminalInput.shouldDeliverReply(named: .pty(1), activeTab: nil, owedReplies: 0, bytes: dsr, modes: modes))
    }
}

final class StripQueriesTests: XCTestCase {

    private func strip(_ s: String) -> String {
        String(decoding: StreamingQueryStripper.strip(Array(s.utf8)), as: UTF8.self)
    }

    func testStripsTheQueriesXtermWouldAnswer() {
        XCTAssertEqual(strip("a\u{1b}[6nb"), "ab")            // DSR / CPR request
        XCTAssertEqual(strip("a\u{1b}[5nb"), "ab")
        XCTAssertEqual(strip("a\u{1b}[?6nb"), "a\u{1b}[?6nb")  // DECDSR: tmux does not answer it (measured) — xterm.js does
        XCTAssertEqual(strip("a\u{1b}[cb"), "ab")             // DA1
        XCTAssertEqual(strip("a\u{1b}[0cb"), "ab")
        XCTAssertEqual(strip("a\u{1b}[>cb"), "ab")            // DA2
        XCTAssertEqual(strip("a\u{1b}[>0;1cb"), "ab")
        XCTAssertEqual(strip("a\u{1b}[2$pb"), "ab")           // DECRQM
        XCTAssertEqual(strip("a\u{1b}[?2026$pb"), "ab")
        XCTAssertEqual(strip("a\u{1b}[18tb"), "ab")           // window size query
        XCTAssertEqual(strip("a\u{1b}P$qm\u{1b}\\b"), "ab")   // DECRQSS
    }

    func testKeepsEverythingElse() {
        // Rendering must be untouched: the point of the replay is the picture.
        for keep in ["plain text\r\n", "\u{1b}[31mred\u{1b}[0m", "\u{1b}[2J\u{1b}[H", "\u{1b}[?1003h",
                     "\u{1b}[?1049h", "\u{1b}[10;20H", "\u{1b}]0;title\u{07}", "\u{1b}[22t", "\u{1b}[2J",
                     "\u{1b}[1;1u", "\u{1b}[ q"] {
            XCTAssertEqual(strip(keep), keep, "must not strip \(keep.debugDescription)")
        }
    }

    func testKeepsNonQueryDCSSoSixelSurvives() {
        let sixel = "\u{1b}Pq#0;2;0;0;0#1;2;100;100;0\u{1b}\\"
        XCTAssertEqual(strip(sixel), sixel)
    }

    func testHandlesATruncatedSequenceAtTheEnd() {
        // A caller may hand this a chunk cut anywhere; never emit garbage if a tail is ever partial.
        XCTAssertEqual(strip("ok\u{1b}[6"), "ok\u{1b}[6")
        XCTAssertEqual(strip("ok\u{1b}"), "ok\u{1b}")
    }

    func testStripsARealisticStartupBurst() {
        let burst = "\u{1b}[c\u{1b}[>0;1c\u{1b}[6n\u{1b}[?2026$p\u{1b}[?1003h\u{1b}[?1006hframe"
        XCTAssertEqual(strip(burst), "\u{1b}[?1003h\u{1b}[?1006hframe")   // modes survive, queries do not
    }
}

final class TermModeTrackerSeedTests: XCTestCase {
    /// A tmux tab's tracker starts from tmux's own snapshot, then follows the stream from there.
    func testSeededTrackerFollowsTheStream() {
        var seed = TermModes()
        seed.mouse = .anyEvent
        var t = TermModeTracker(modes: seed)
        XCTAssertEqual(t.modes.mouse, .anyEvent)
        t.feed(Array("\u{1b}[?2004h\u{1b}[?1003l".utf8))
        XCTAssertTrue(t.modes.bracketedPaste)
        XCTAssertEqual(t.modes.mouse, .off)
    }
}
