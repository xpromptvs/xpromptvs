import XCTest
@testable import RdevCore

final class TmuxControlParserTests: XCTestCase {
    private func events(_ s: String) -> [TmuxEvent] { var p = TmuxControlParser(); return p.feed(Array(s.utf8)) }

    func testUnescapeOctalAndBackslash() {
        func u(_ s: String) -> [UInt8] { TmuxControlParser.unescape(Array(s.utf8)) }
        XCTAssertEqual(u(#"a\033[1m\015\012\134b"#), [0x61, 0x1b, 0x5b, 0x31, 0x6d, 0x0d, 0x0a, 0x5c, 0x62])
        XCTAssertEqual(u("é"), [0xc3, 0xa9])                                               // UTF-8 passes through
        XCTAssertEqual(TmuxControlParser.unescape([0xc3]), [0xc3])                         // so does HALF of one
        XCTAssertEqual(u(#"x\01"#), Array(#"x\01"#.utf8))                                  // truncated escape: literal
        // Above \377 is not a byte. tmux never emits one; it must stay literal rather than overflow.
        XCTAssertEqual(u(#"\477"#), Array(#"\477"#.utf8))
    }

    func testOutputAndExtendedOutput() {
        XCTAssertEqual(events("%output %0 hi\\015\\012\n"), [.output(pane: "%0", bytes: Array("hi\r\n".utf8))])
        XCTAssertEqual(events("%output %0  \n"), [.output(pane: "%0", bytes: [0x20])])       // a lone space is data
        XCTAssertEqual(events("%extended-output %3 12 : x\\033\n"), [.output(pane: "%3", bytes: [0x78, 0x1b])])
    }

    /// A pane's payload can LOOK like an event; only a line's start is ever an event keyword.
    func testOutputPayloadThatLooksLikeAnEvent() {
        XCTAssertEqual(events("%output %0 %exit\n"), [.output(pane: "%0", bytes: Array("%exit".utf8))])
    }

    /// Inside a reply block every line is reply content, even one starting with `%`.
    func testReplyBlockCollectsLinesVerbatim() {
        let e = events("%begin 1 2 1\n$0\talpha\t1\t1\n%output-looking line\n%end 1 2 1\n")
        XCTAssertEqual(e, [.reply(ok: true, fromUs: true, lines: ["$0\talpha\t1\t1", "%output-looking line"])])
        XCTAssertEqual(events("%begin 1 3 1\nparse error\n%error 1 3 1\n"), [.reply(ok: false, fromUs: true, lines: ["parse error"])])
        XCTAssertEqual(events("%begin 1 4 0\n%end 1 4 0\n"), [.reply(ok: true, fromUs: false, lines: [])])
    }

    func testNotifications() {
        XCTAssertEqual(events("%session-changed $1 beta\n"), [.sessionChanged(session: "$1", name: "beta")])
        XCTAssertEqual(events("%session-renamed $1 my name\n"), [.sessionRenamed(session: "$1", name: "my name")])
        XCTAssertEqual(events("%session-window-changed $1 @4\n"), [.sessionWindowChanged(session: "$1", window: "@4")])
        XCTAssertEqual(events("%window-pane-changed @4 %7\n"), [.windowPaneChanged(window: "@4", pane: "%7")])
        XCTAssertEqual(events("%sessions-changed\n"), [.sessionsChanged])
        XCTAssertEqual(events("%pause %2\n"), [.pause(pane: "%2")])
        XCTAssertEqual(events("%exit\n"), [.exit(reason: nil)])
        XCTAssertEqual(events("%exit detached\n"), [.exit(reason: "detached")])
        // The window's SIZE is what matters: someone else resizing it is how rdev learns to claim it back.
        XCTAssertEqual(events("%layout-change @0 a87d,100x30,0,0,0 a87d,100x30,0,0,0 *\n"),
                       [.layoutChange(window: "@0", width: 100, height: 30)])
        XCTAssertEqual(events("%layout-change @3 bfe1,206x58,0,0{103x58,0,0,1,102x58,104,0,2} x *\n"),
                       [.layoutChange(window: "@3", width: 206, height: 58)])
        XCTAssertEqual(events("%layout-change @0 nonsense\n"), [])
    }

    /// RAW bytes: a split UTF-8 character is not a Swift String, so `events(_: String)` cannot say it.
    private func events(bytes: [UInt8]) -> [TmuxEvent] { var p = TmuxControlParser(); return p.feed(bytes) }
    private func outputBytes(_ evs: [TmuxEvent]) -> [UInt8] {
        evs.flatMap { e -> [UInt8] in if case .output(_, let b) = e { return b } else { return [] } }
    }
    private static let replacement: [UInt8] = [0xef, 0xbf, 0xbd]
    private func containsReplacement(_ b: [UInt8]) -> Bool {
        b.count >= 3 && (0...(b.count - 3)).contains { Array(b[$0..<$0 + 3]) == Self.replacement }
    }

    /// tmux ends an `%output` line wherever its pty read ended — partway through a UTF-8 character
    /// included (captured on 3.7c: `%output %0 \033]0;\xe2\x9c` then `%output %0 \xb3 C`). Pane data
    /// is BYTES: decoding a line as UTF-8 before unescaping turned each half into U+FFFD, and the host
    /// sent those as real characters (one `─` became two cells, lines wrapped, cursor moves missed).
    func testCharacterSplitAcrossTwoOutputLines() {
        let wire: [UInt8] = Array("%output %0 ".utf8) + [0xe2, 0x94] + [0x0a]
                          + Array("%output %0 ".utf8) + [0x80] + [0x0a]
        let evs = events(bytes: wire)
        XCTAssertEqual(evs, [.output(pane: "%0", bytes: [0xe2, 0x94]), .output(pane: "%0", bytes: [0x80])])
        let joined = outputBytes(TmuxEvent.coalesced(evs))
        XCTAssertEqual(joined, [0xe2, 0x94, 0x80])
        XCTAssertFalse(containsReplacement(joined), "no U+FFFD may be manufactured from a split character")
        XCTAssertEqual(String(decoding: joined, as: UTF8.self), "\u{2500}")
    }

    func testCharacterSplitAcrossTwoExtendedOutputLines() {
        let wire: [UInt8] = Array("%extended-output %0 5 : ".utf8) + [0x61, 0xe2, 0x9c] + [0x0a]
                          + Array("%extended-output %0 5 : ".utf8) + [0xb3, 0x62] + [0x0a]
        let joined = outputBytes(events(bytes: wire))
        XCTAssertEqual(joined, [0x61, 0xe2, 0x9c, 0xb3, 0x62])
        XCTAssertFalse(containsReplacement(joined))
    }

    /// Escapes sit right beside the split: an octal escape and an escaped backslash before the partial
    /// character, and an octal escape right after the continuation byte.
    func testEscapesAtTheSplitBoundary() {
        let wire: [UInt8] = Array(#"%output %0 \033]0;\134"#.utf8) + [0xe2, 0x9c] + [0x0a]
                          + Array("%output %0 ".utf8) + [0xb3] + Array(#"\007\\"#.utf8) + [0x0a]
        let joined = outputBytes(events(bytes: wire))
        XCTAssertEqual(joined, [0x1b, 0x5d, 0x30, 0x3b, 0x5c, 0xe2, 0x9c, 0xb3, 0x07, 0x5c])
        XCTAssertFalse(containsReplacement(joined))
    }

    /// A lone invalid byte on its own line is passed through as that byte, never "repaired" — the
    /// terminal emulator on the client, which sees the whole stream, is the one place that may judge it.
    func testInvalidBytePassesThroughUntouched() {
        let wire: [UInt8] = Array("%output %0 ".utf8) + [0xff] + [0x0a]
        XCTAssertEqual(events(bytes: wire), [.output(pane: "%0", bytes: [0xff])])
    }

    func testLineSplitAcrossFeeds() {
        var p = TmuxControlParser()
        XCTAssertEqual(p.feed(Array("%output %0 ab".utf8)), [])
        XCTAssertEqual(p.feed(Array("c\\015\n".utf8)), [.output(pane: "%0", bytes: Array("abc\r".utf8))])
    }

    /// The committed transcript from real tmux 3.7c parses into the events it visibly contains.
    func testRealTranscript() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/tmux-control-3.7c.txt")
        var p = TmuxControlParser()
        let evs = p.feed([UInt8](try Data(contentsOf: url)))
        let out = evs.compactMap { e -> [UInt8]? in if case .output(_, let b) = e { return b } else { return nil } }.flatMap { $0 }
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("\\ \u{1b}[31mred\u{1b}[0m é"), "a backslash, an SGR and UTF-8 survive unescaping")
        XCTAssertTrue(text.contains("X\r\n"), "%extended-output carries data too")
        XCTAssertTrue(evs.contains(.sessionChanged(session: "$1", name: "beta")))
        XCTAssertTrue(evs.contains(.sessionRenamed(session: "$1", name: "gamma")))
        XCTAssertTrue(evs.contains(.sessionsChanged))
        XCTAssertTrue(evs.contains(.reply(ok: true, fromUs: true, lines: ["$0\talpha\t1\t1", "$1\tbeta\t1\t0"])))
        XCTAssertTrue(evs.contains { if case .reply(false, true, _) = $0 { return true }; return false })
        XCTAssertEqual(evs.last, .exit(reason: nil))
    }

    /// Reply content is NOT escaped: a pane that prints `%end …` comes back raw inside a
    /// `capture-pane` block (measured on 3.7c). Only the %end whose time and number match the %begin
    /// closes it, or a screen could forge events and shift reply matching.
    func testOnlyTheMatchingEndClosesABlock() {
        XCTAssertEqual(events("%begin 7 8 1\n%end 1 2 1\n%output %0 fake\n%begin 3 3 1\n%end 7 8 1\n"),
                       [.reply(ok: true, fromUs: true, lines: ["%end 1 2 1", "%output %0 fake", "%begin 3 3 1"])])
        XCTAssertEqual(events("%begin 7 8 1\n%error 7 9 1\nx\n%error 7 8 1\n"),
                       [.reply(ok: false, fromUs: true, lines: ["%error 7 9 1", "x"])])
    }

    /// One tmux read carries many `%output` lines — a full-screen redraw is one per line. Consecutive
    /// output for the SAME pane merges into one event (one message, one write on the client); anything
    /// else between them keeps its place, so ordering against replies and notifications is unchanged.
    func testCoalescingMergesConsecutiveOutputOfOnePane() {
        let evs: [TmuxEvent] = [
            .output(pane: "%0", bytes: [0x61]), .output(pane: "%0", bytes: [0x62]),
            .output(pane: "%1", bytes: [0x63]), .output(pane: "%1", bytes: [0x64]),
            .sessionsChanged,
            .output(pane: "%1", bytes: [0x65]),
        ]
        XCTAssertEqual(TmuxEvent.coalesced(evs), [
            .output(pane: "%0", bytes: [0x61, 0x62]), .output(pane: "%1", bytes: [0x63, 0x64]),
            .sessionsChanged,
            .output(pane: "%1", bytes: [0x65]),
        ])
        XCTAssertEqual(TmuxEvent.coalesced([]), [])
    }
}
