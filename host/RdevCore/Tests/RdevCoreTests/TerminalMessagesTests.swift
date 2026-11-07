import XCTest
@testable import RdevCore

final class TerminalMessagesTests: XCTestCase {

    private func parse(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    func testTermListShape() {
        let tabs = [
            TabDescriptor(id: .pty(1), ordinal: 1, title: "~/build/rdev"),
            TabDescriptor(id: .tmux("$5"), ordinal: 3, title: ""),
        ]
        let obj = parse(termListJSON(tabs: tabs, activeId: .tmux("$5")))
        XCTAssertEqual(obj["t"] as? String, "term-list")
        XCTAssertEqual(obj["activeId"] as? String, "tmux:$5")
        let arr = obj["tabs"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 2)
        XCTAssertEqual(arr?[0]["id"] as? String, "pty:1")
        XCTAssertEqual(arr?[0]["n"] as? Int, 1)
        XCTAssertEqual(arr?[0]["title"] as? String, "~/build/rdev")
        XCTAssertEqual(arr?[1]["id"] as? String, "tmux:$5")
        XCTAssertEqual(arr?[1]["n"] as? Int, 3)
        XCTAssertEqual(arr?[1]["title"] as? String, "")
    }

    /// The host's bell for output that reached no client (docs/terminal.md, "The bell"): the tab's wire id,
    /// both kinds, and nothing else.
    func testTermBellNamesItsTab() {
        XCTAssertEqual(parse(termBellJSON(term: .pty(3))) as NSDictionary, ["t": "term-bell", "term": "pty:3"] as NSDictionary)
        XCTAssertEqual(parse(termBellJSON(term: .tmux("$7"))) as NSDictionary, ["t": "term-bell", "term": "tmux:$7"] as NSDictionary)
    }

    func testTermListNullActive() {
        let obj = parse(termListJSON(tabs: [], activeId: nil))
        XCTAssertEqual(obj["t"] as? String, "term-list")
        XCTAssertTrue(obj["activeId"] is NSNull)
        XCTAssertEqual((obj["tabs"] as? [[String: Any]])?.count, 0)
    }

    /// `name` is PRESENT ONLY WHEN SET (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md,
    /// §2.2): a tab nobody named carries no field at all, never `null` or `""`, so the client's label
    /// falls through to the title and then to "Terminal N".
    func testTermListCarriesANameOnlyWhenSet() {
        let tabs = [
            TabDescriptor(id: .pty(1), ordinal: 1, title: "~/build", name: "build"),
            TabDescriptor(id: .pty(2), ordinal: 2, title: ""),
            TabDescriptor(id: .tmux("$5"), ordinal: 3, title: "work"),
        ]
        let arr = parse(termListJSON(tabs: tabs, activeId: .pty(1)))["tabs"] as? [[String: Any]]
        XCTAssertEqual(arr?[0]["name"] as? String, "build")
        XCTAssertEqual(arr?[0]["title"] as? String, "~/build", "the title rides beside it")
        XCTAssertFalse(arr?[1].keys.contains("name") ?? true, "absent, not null")
        XCTAssertFalse(arr?[2].keys.contains("name") ?? true, "a tmux tab's label is its title")
    }

    /// `agent` is PRESENT ONLY WHILE an agent runs in the tab's foreground (`AgentActivity`).
    func testTermListCarriesAnAgentOnlyWhileOneRuns() {
        let tabs = [
            TabDescriptor(id: .pty(1), ordinal: 1, title: "zsh"),
            TabDescriptor(id: .tmux("$5"), ordinal: 2, title: "work", agent: .working),
            TabDescriptor(id: .pty(2), ordinal: 3, title: "claude", agent: .idle),
        ]
        let arr = parse(termListJSON(tabs: tabs, activeId: .pty(1)))["tabs"] as? [[String: Any]]
        XCTAssertFalse(arr?[0].keys.contains("agent") ?? true, "absent, not null")
        XCTAssertEqual(arr?[1]["agent"] as? String, "working")
        XCTAssertEqual(arr?[2]["agent"] as? String, "idle")
    }
    func testForegroundAgentKindChangesWithoutAnActivityChange() {
        var pool = TabPool()
        let id = pool.open()!
        XCTAssertTrue(pool.setAgent(id, .idle, kind: "claude"))
        XCTAssertTrue(pool.setAgent(id, .idle, kind: "codex"))
        let arr = parse(termListJSON(tabs: pool.tabs, activeId: id))["tabs"] as! [[String: Any]]
        XCTAssertEqual(arr[0]["agentKind"] as? String, "codex")
        XCTAssertFalse(pool.setAgent(id, .idle, kind: "codex"))
        XCTAssertTrue(pool.setAgent(id, nil, kind: nil))
        let gone = parse(termListJSON(tabs: pool.tabs, activeId: id))["tabs"] as! [[String: Any]]
        XCTAssertNil(gone[0]["agentKind"])
    }

}
