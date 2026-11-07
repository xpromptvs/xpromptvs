import XCTest
@testable import RdevCore

/// What a terminal tab is when it comes back — reopened (⌘⇧T) or restored at the app's next launch.
final class SavedTerminalTabsTests: XCTestCase {
    func testTheFileRoundTripsInOrderWithTheActiveTab() {
        let saved = SavedTerminalTabs(tabs: [.pty(cwd: "/Users/x/code", name: "server"), .tmux(session: "$3"), .pty(cwd: nil, name: nil)],
                                      active: 1)
        XCTAssertEqual(SavedTerminalTabs(json: saved.json()), saved)
    }

    /// One bad entry costs that entry, never the file — and `active` follows the entry it named.
    func testAnEntryItCannotReadIsSkippedAndActiveFollows() {
        let json = #"{"v":1,"active":3,"tabs":[{"kind":"pty","cwd":"/a"},{"kind":"tmux","session":"; rm -rf /"},{"kind":"???"},{"kind":"tmux","session":"$7"}]}"#
        let saved = SavedTerminalTabs(json: Data(json.utf8))
        XCTAssertEqual(saved?.tabs, [.pty(cwd: "/a", name: nil), .tmux(session: "$7")])
        XCTAssertEqual(saved?.active, 1, "file index 3 is kept entry 1")
    }

    func testARelativeDirectoryAndAnEmptyNameAreDropped() {
        let json = #"{"v":1,"tabs":[{"kind":"pty","cwd":"code","name":""}]}"#
        XCTAssertEqual(SavedTerminalTabs(json: Data(json.utf8))?.tabs, [.pty(cwd: nil, name: nil)])
    }

    func testActiveOnASkippedOrMissingEntryIsNone() {
        XCTAssertNil(SavedTerminalTabs(json: Data(#"{"v":1,"active":1,"tabs":[{"kind":"pty"},{"kind":"bad"}]}"#.utf8))?.active)
        XCTAssertNil(SavedTerminalTabs(json: Data(#"{"v":1,"active":9,"tabs":[{"kind":"pty"}]}"#.utf8))?.active)
        XCTAssertNil(SavedTerminalTabs(tabs: [], active: 0).active)
    }

    func testNotAFileOfOursIsNil() {
        XCTAssertNil(SavedTerminalTabs(json: Data("[]".utf8)))
        XCTAssertNil(SavedTerminalTabs(json: Data(#"{"v":2,"tabs":[]}"#.utf8)), "another version")
        XCTAssertNil(SavedTerminalTabs(json: Data("not json".utf8)))
    }

    func testClosedTabsComeBackNewestFirstAndAreBounded() {
        var closed = ClosedTerminalTabs()
        for i in 0..<(ClosedTerminalTabs.limit + 5) { closed.push(.pty(cwd: "/\(i)", name: nil)) }
        XCTAssertEqual(closed.items.count, ClosedTerminalTabs.limit)
        XCTAssertEqual(closed.pop(), .pty(cwd: "/\(ClosedTerminalTabs.limit + 4)", name: nil))
        XCTAssertEqual(closed.items.first, .pty(cwd: "/5", name: nil), "the oldest five went")
        var empty = ClosedTerminalTabs()
        XCTAssertNil(empty.pop())
        XCTAssertTrue(empty.isEmpty)
    }
}
