import XCTest
@testable import RdevCore

final class TmuxMessagesTests: XCTestCase {
    private func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    func testParsesListSessions() {
        XCTAssertEqual(TmuxList.parse("$0\talpha\t1\t1\n$1\tmy beta\t3\t0\n"),
                       [TmuxSessionInfo(id: "$0", name: "alpha", windows: 1, attached: 1),
                        TmuxSessionInfo(id: "$1", name: "my beta", windows: 3, attached: 0)])
        XCTAssertEqual(TmuxList.parse(""), [])
        XCTAssertEqual(TmuxList.parse("garbage\n$2\tx\t1\t0\n"), [TmuxSessionInfo(id: "$2", name: "x", windows: 1, attached: 0)])
    }

    /// tmux keeps U+2028/U+2029 in a session name (measured on 3.7c, review M1, 2026-10-01), and a tab
    /// name may hold one (`protocol/fixtures/tab-names.json`). Splitting the listing on every Unicode
    /// newline cut such a session's line in two: it vanished from the list, its tab closed as "ended" on
    /// the next reconcile, and it could not be opened again. tmux ends a line with `\n` and nothing else.
    func testASessionNameWithALineSeparatorIsOneSession() {
        let out = "$1\ta\u{2028}b\t1\t0\n$2\tc\u{2029}d\t2\t1\n"
        XCTAssertEqual(TmuxList.parse(out), [
            TmuxSessionInfo(id: "$1", name: "a\u{2028}b", windows: 1, attached: 0),
            TmuxSessionInfo(id: "$2", name: "c\u{2029}d", windows: 2, attached: 1),
        ])
    }

    func testListJSON() {
        let o = obj(tmuxListJSON(available: true, sessions: [TmuxSessionInfo(id: "$0", name: "a", windows: 2, attached: 1)]))
        XCTAssertEqual(o["t"] as? String, "tmux-list"); XCTAssertEqual(o["available"] as? Bool, true)
        let s = (o["sessions"] as? [[String: Any]])?.first
        XCTAssertEqual(s?["id"] as? String, "$0"); XCTAssertEqual(s?["name"] as? String, "a")
        XCTAssertEqual(s?["windows"] as? Int, 2); XCTAssertEqual(s?["attached"] as? Int, 1)
        XCTAssertEqual(obj(tmuxListJSON(available: false, sessions: []))["available"] as? Bool, false)
    }

    func testErrorAndClosedJSON() {
        let e = obj(tmuxErrorJSON(session: "$4", reason: "session-gone"))
        XCTAssertEqual(e["t"] as? String, "tmux-error"); XCTAssertEqual(e["session"] as? String, "$4")
        XCTAssertEqual(e["reason"] as? String, "session-gone")
        XCTAssertTrue(obj(tmuxErrorJSON(session: nil, reason: "unavailable"))["session"] is NSNull)
        let c = obj(tmuxClosedJSON(session: "$4", reason: "ended"))
        XCTAssertEqual(c["t"] as? String, "tmux-closed"); XCTAssertEqual(c["session"] as? String, "$4")
        XCTAssertEqual(c["reason"] as? String, "ended")
    }

    /// An `open-terminal` the host refused (the tab cap) says so, so the client can stop waiting to
    /// focus a tab that is not coming.
    func testTermErrorJSON() {
        let e = obj(termErrorJSON(reason: "too-many-tabs"))
        XCTAssertEqual(e["t"] as? String, "term-error"); XCTAssertEqual(e["reason"] as? String, "too-many-tabs")
    }

    /// `rename-session`'s new name, as an ARGUMENT that tmux turns back into exactly the name. Measured
    /// against tmux 3.7c (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §3): tmux
    /// FORMAT-EXPANDS the name (`#{session_id}` became `$1`, `#S` the old name, `#(…)` is a shell job),
    /// so every `#` is doubled — except a run of them before `[`, which tmux copies verbatim
    /// (a style); and a trailing `;` ends a command in tmux's argv parse, so it travels as `\;`. The round
    /// trip through a real tmux is `TerminalManagerTmuxTests.testARenameIsTheLiteralName`.
    func testRenameArgumentIsTheLiteralNameThroughTmuxsParse() {
        let cases: [(String, String)] = [
            ("build", "build"),
            ("", ""),
            ("#", "##"),
            ("a#", "a##"),
            ("##", "####"),
            ("#S", "##S"),
            ("#{session_id}", "##{session_id}"),
            ("#(echo hi)", "##(echo hi)"),
            ("#,#}", "##,##}"),
            ("#[fg=red]x", "#[fg=red]x"),
            ("##[x", "##[x"),
            ("a #[b] #c", "a #[b] ##c"),
            // Raw literals: the backslash is the point.
            ("x;", #"x\;"#),
            (";", #"\;"#),
            ("a;b", "a;b"),
            ("#;", #"##\;"#),
            (#"x\;"#, #"x\\;"#),
            ("-dash", "-dash"),
            ("é🎉 #", "é🎉 ##"),
        ]
        for (name, arg) in cases { XCTAssertEqual(TmuxList.renameArgument(name), arg, name.debugDescription) }
    }
}
