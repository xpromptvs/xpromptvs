import XCTest
@testable import RdevCore
final class PublicationRestorationTests: XCTestCase {
    func testDisabledAgentRestorationPreservesOriginalAndSelectsTerminal() {
        let data = Data(#"{"v":1,"tabs":[{"kind":"pty","cwd":"/tmp"},{"kind":"tmux","session":"$3"}],"agents":{"tabs":[{"id":"session","title":"Agent","cwd":"/tmp"}],"selected":"session","showing":true,"order":["terminal:0","agent:session","terminal:1"]}}"#.utf8)
        let original = SavedTerminalTabs(json: data)!
        let filtered = original.restoring(graphicalAgents: false)
        XCTAssertNil(filtered.agents)
        XCTAssertEqual(filtered.tabs, original.tabs)
        XCTAssertEqual(filtered.active, 0)
        XCTAssertNotNil(original.agents)
        XCTAssertEqual(original.restoring(graphicalAgents: true), original)
        XCTAssertEqual(SavedTerminalTabs(json: data), original)
    }
    func testEmptyAndSelectedTerminalRestorationRemainValid() {
        XCTAssertNil(SavedTerminalTabs().restoring(graphicalAgents: false).active)
        let saved = SavedTerminalTabs(tabs: [.pty(cwd: "/tmp", name: nil), .pty(cwd: "/tmp", name: "two")], active: 1)
        XCTAssertEqual(saved.restoring(graphicalAgents: false).active, 1)
    }
}
