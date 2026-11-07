import XCTest
@testable import RdevCore

final class TmuxPaneStateTests: XCTestCase {
    // Field order is TmuxPaneState.format's: pane cx cy w h alt cursor keypad std button all sgr
    func testParsesPaneState() {
        let s = TmuxPaneState.parse("%3 9 0 100 30 1 1 1 1 0 0 1 0 2000")!
        XCTAssertEqual(s.pane, "%3"); XCTAssertEqual(s.cursorX, 9); XCTAssertEqual(s.cursorY, 0)
        XCTAssertEqual(s.width, 100); XCTAssertEqual(s.height, 30)
        XCTAssertTrue(s.modes.altScreen); XCTAssertTrue(s.modes.cursorVisible); XCTAssertTrue(s.modes.applicationCursor)
        XCTAssertEqual(s.modes.mouse, .vt200); XCTAssertEqual(s.modes.mouseEncoding, .sgr)
        // Without the trailing formats neither is known; they start OFF and are learned from the stream.
        XCTAssertFalse(s.modes.bracketedPaste); XCTAssertFalse(s.modes.focusReporting)
        XCTAssertNil(TmuxPaneState.parse("%3 9 0"))
        XCTAssertNil(TmuxPaneState.parse("%3 x 0 100 30 1 1 1 1 0 0 1"))
        XCTAssertNil(TmuxPaneState.parse("3 9 0 100 30 1 1 1 1 0 0 1"))
    }

    /// ?1003 beats ?1002 beats ?1000 — a pane reports the richest mode it has set.
    func testMousePrecedence() {
        XCTAssertEqual(TmuxPaneState.parse("%0 0 0 80 24 0 1 0 1 1 1 0 0 2000")!.modes.mouse, .anyEvent)
        XCTAssertEqual(TmuxPaneState.parse("%0 0 0 80 24 0 1 0 1 1 0 0 0 2000")!.modes.mouse, .buttonEvent)
        XCTAssertEqual(TmuxPaneState.parse("%0 0 0 80 24 0 1 0 0 0 0 0 0 2000")!.modes.mouse, .off)
    }

    func testStreamingStripperRemovesQueriesEvenWhenSplit() {
        var st = StreamingQueryStripper()
        XCTAssertEqual(st.feed(Array("ab\u{1b}[".utf8)), Array("ab".utf8))          // held back
        XCTAssertEqual(st.feed(Array("6nc".utf8)), Array("c".utf8))                  // CPR query dropped
        XCTAssertEqual(st.feed(Array("\u{1b}[31mx".utf8)), Array("\u{1b}[31mx".utf8)) // SGR passes
        XCTAssertEqual(st.feed(Array("\u{1b}[c".utf8)), [])                          // DA dropped
    }

    /// The same recognisers as a DETECTOR (the send buffer's): whether the bytes completed a query, a
    /// query split across reads counting on the read that completes it; nothing is removed.
    func testQueryDetectorFindsCompletedQueriesEvenWhenSplit() {
        var d = StreamingQueryStripper()
        XCTAssertFalse(d.detectsQuery(Array("ab\u{1b}[31mx\u{1b}]0;t\u{07}".utf8)))
        XCTAssertFalse(d.detectsQuery(Array("ab\u{1b}[".utf8)))                    // half a query
        XCTAssertTrue(d.detectsQuery(Array("13t".utf8)))                            // completed here
        XCTAssertFalse(d.detectsQuery(Array("plain".utf8)))
        XCTAssertTrue(d.detectsQuery(Array("x\u{1b}]11;?\u{07}".utf8)))
        XCTAssertTrue(d.detectsQuery(Array("\u{1b}P$qm\u{1b}\\".utf8)))
        XCTAssertFalse(d.detectsQuery(Array("\u{1b}[14".utf8)))
        XCTAssertTrue(d.detectsQuery(Array(";2t".utf8)))                            // CSI 14;2 t
    }

    /// The detector COUNTS: the host owes the client one accepted reply per query xterm.js is to answer
    /// (`TerminalManager`'s reply credit), so two queries in one read are two, and a split one counts
    /// once, on the read that completes it.
    func testQueryCounterCountsEachCompletedQueryOnce() {
        var d = StreamingQueryStripper()
        XCTAssertEqual(d.countQueries(Array("a\u{1b}[5n\u{1b}[c b".utf8)), 2)             // DSR + DA
        XCTAssertEqual(d.countQueries(Array("\u{1b}[6".utf8)), 0)                         // half a CPR
        XCTAssertEqual(d.countQueries(Array("n\u{1b}]11;?\u{07}\u{1b}[31m".utf8)), 2)       // its end + OSC 11
        XCTAssertEqual(d.countQueries(Array("plain \u{1b}[?25l".utf8)), 0)
    }

    /// A lone trailing ESC is held, an OSC ended by ST is complete, and a sequence that never ends is
    /// released once it is huge, so a runaway DCS cannot swallow the stream.
    func testStreamingStripperBounds() {
        var st = StreamingQueryStripper()
        XCTAssertEqual(st.feed([0x61, 0x1b]), [0x61])
        XCTAssertEqual(st.feed(Array("[1m".utf8)), Array("\u{1b}[1m".utf8))
        XCTAssertEqual(st.feed(Array("\u{1b}]0;title\u{1b}\\z".utf8)), Array("\u{1b}]0;title\u{1b}\\z".utf8))
        var big = StreamingQueryStripper()
        let dcs: [UInt8] = [0x1b, 0x50] + Array(repeating: 0x41, count: 5000)
        XCTAssertEqual(big.feed(dcs).count, dcs.count)
    }

    /// ESC + intermediates is not a finished sequence: `ESC (` cut before its final byte is held, like
    /// a split CSI, so the final is not sent alone (where xterm would paint it as text). Kept consistent
    /// with `PaneStreamCarry`, which uses the same `incompleteTail`.
    func testStreamingStripperHoldsAnEscapeCutAfterItsIntermediate() {
        var st = StreamingQueryStripper()
        XCTAssertEqual(st.feed(Array("a\u{1b}(".utf8)), Array("a".utf8))
        XCTAssertEqual(st.feed(Array("0b".utf8)), Array("\u{1b}(0b".utf8))
        XCTAssertEqual(st.feed(Array("\u{1b} ".utf8)), [])
        XCTAssertEqual(st.feed(Array("#8".utf8)), Array("\u{1b} #8".utf8))
        XCTAssertEqual(st.feed(Array("\u{1b}7c".utf8)), Array("\u{1b}7c".utf8), "no intermediate: complete")
    }

    /// OSC 4/10/11/12 with `?` are colour QUERIES: tmux answers them itself, and xterm.js would answer
    /// again into the pane. Setting a colour, and a title, are not queries and pass.
    func testColourQueriesAreStripped() {
        var st = StreamingQueryStripper()
        XCTAssertEqual(st.feed(Array("a\u{1b}]11;?\u{1b}\\b".utf8)), Array("ab".utf8))
        XCTAssertEqual(st.feed(Array("\u{1b}]10;?\u{07}c".utf8)), Array("c".utf8))
        let keep = "\u{1b}]11;rgb:0000/0000/0000\u{07}\u{1b}]0;title\u{07}\u{1b}]4;1;#ff0000\u{07}"
        XCTAssertEqual(st.feed(Array(keep.utf8)), Array(keep.utf8))
    }

    /// …but ONLY the queries tmux 3.7c answers itself (MEASURED 2026-09-27, a `-C` client attached):
    /// tmux does not answer OSC 4, OSC 12, OSC 10/11 asking more than one colour, or DECDSR `CSI ? 6 n`,
    /// all of which xterm.js answers — stripped, nobody would. They are left for xterm.js, once.
    func testQueriesTmuxDoesNotAnswerAreLeftForTheClient() {
        for q in ["\u{1b}]4;1;?\u{07}", "\u{1b}]4;1;?;2;?\u{1b}\\", "\u{1b}]12;?\u{07}", "\u{1b}]10;?;?\u{07}",
                  "\u{1b}]11;?;?\u{07}", "\u{1b}[?6n"] {
            var st = StreamingQueryStripper()
            XCTAssertEqual(st.feed(Array("a\(q)b".utf8)), Array("a\(q)b".utf8), q.debugDescription)
        }
        for q in ["\u{1b}]10;?\u{07}", "\u{1b}]11;?\u{1b}\\", "\u{1b}[6n", "\u{1b}[5n", "\u{1b}[c", "\u{1b}[>c", "\u{1b}[?25$p",
                  "\u{1b}[4$p", "\u{1b}P$qm\u{1b}\\"] {
            var st = StreamingQueryStripper()
            XCTAssertEqual(st.feed(Array("a\(q)b".utf8)), Array("ab".utf8), q.debugDescription)
        }
    }

    /// A tmux tab drops the stream carries of panes that no longer exist; anything that is not a pane
    /// id is ignored.
    func testLivePanesAreTheListedPaneIds() {
        XCTAssertEqual(TmuxSnapshot.livePanes(["%0", "%12", "", "garbage"]), ["%0", "%12"])
    }

    private func state(h: Int, limit: Int = 2000, w: Int = 20, rows: Int = 3, alt: Int = 0, cx: Int = 0, cy: Int = 0) -> TmuxPaneState {
        TmuxPaneState.parse("%1 \(cx) \(cy) \(w) \(rows) \(alt) 1 0 0 0 0 0 \(h) \(limit)")!
    }

    func testParsesHistoryFields() {
        let s = state(h: 42, limit: 50000)
        XCTAssertEqual(s.historySize, 42); XCTAssertEqual(s.historyLimit, 50000)
    }

    /// tmux reports the pane's scroll region (0-based rows), origin mode (?6), whether the app is inside
    /// a synchronized update (?2026) and bracketed paste (?2004, tmux 3.7+) — appended to the format in
    /// the order tmux gained them, so an older tmux that lacks the newest (it expands to nothing) still
    /// parses: no update in progress, bracketed paste left to the stream.
    func testParsesScrollRegionOriginSyncAndBracketedPaste() {
        let s = TmuxPaneState.parse("%1 2 1 20 5 0 1 0 0 0 0 0 0 2000 1 3 1 1 1")!
        XCTAssertEqual(s.scrollTop, 1); XCTAssertEqual(s.scrollBottom, 3)
        XCTAssertTrue(s.originMode); XCTAssertTrue(s.synchronizedOutput); XCTAssertTrue(s.modes.bracketedPaste)
        XCTAssertFalse(s.modes.focusReporting, "tmux 3.7c has no format for ?1004")
        let old = TmuxPaneState.parse("%1 2 1 20 5 0 1 0 0 0 0 0 0 2000")!
        XCTAssertEqual(old.scrollTop, 0); XCTAssertEqual(old.scrollBottom, 4)
        XCTAssertFalse(old.originMode); XCTAssertFalse(old.synchronizedOutput)
        let v30 = TmuxPaneState.parse("%1 2 1 20 5 0 1 0 0 0 0 0 0 2000 0 2 1")!     // tmux 3.0-3.3
        XCTAssertEqual(v30.scrollBottom, 2); XCTAssertTrue(v30.originMode); XCTAssertFalse(v30.synchronizedOutput)
        let v36 = TmuxPaneState.parse("%1 2 1 20 5 0 1 0 0 0 0 0 0 2000 0 2 0 1")!   // before 3.7
        XCTAssertTrue(v36.synchronizedOutput); XCTAssertFalse(v36.modes.bracketedPaste)
        XCTAssertFalse(TmuxPaneState.parse("%1 2 1 20 5 0 1 0 0 0 0 0 0 2000 0 4 0 0 0")!.modes.bracketedPaste)
        XCTAssertNil(TmuxPaneState.parse("%1 2 1 20 5 0 1 0 0 0 0 0 0 2000 x 2 0"))
        XCTAssertNil(TmuxPaneState.parse("%1 2 1 20 5 0 1 0 0 0 0 0 0 2000 1"), "half a region is not one")
        XCTAssertNil(TmuxPaneState.parse("%1 2 1 20 5 0 1 0 0 0 0 0 0 2000 1 3"), "a region with no origin flag")
        XCTAssertTrue(TmuxPaneState.format.hasSuffix(
            "#{scroll_region_upper} #{scroll_region_lower} #{origin_flag} #{synchronized_output_flag} #{bracket_paste_flag}"))
    }
}
