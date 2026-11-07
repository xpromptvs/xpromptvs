import XCTest
@testable import RdevCore

final class SavedAgentTabsTests:XCTestCase {
    func testAgentTabsRoundTripWithSelectionNamesAndInterleavedTerminalOrder() throws {
        var state=SessionState()
        _=state.syncTerminals(["pty:1","tmux:$2"])
        _=state.openAgent("one",title:"Build",cwd:"/project")
        _=state.setAgentName("one","Custom")
        _=state.openAgent("two",title:"Review",cwd:"/other")
        _=state.moveTab("agent:one",before:"tmux:$2")
        _=state.selectAgent("one")
        _=state.setAgentStatus("one","active",activeFlags:[])
        var saved=SavedTerminalTabs(tabs:[.pty(cwd:"/",name:nil),.tmux(session:"$2")])
        saved.agents=SavedAgentTabs(state:state,terminalIDs:["pty:1","tmux:$2"])
        let decoded=try XCTUnwrap(SavedTerminalTabs(json:saved.json()))
        var restored=SessionState();_=restored.syncTerminals(["pty:9","tmux:$2"])
        XCTAssertTrue(restored.restoreAgents(try XCTUnwrap(decoded.agents),terminalIDs:[0:"pty:9",1:"tmux:$2"]))
        XCTAssertEqual(restored.tabOrder,["pty:9","agent:one","tmux:$2","agent:two"])
        XCTAssertEqual(restored.selectedAgent,"one");XCTAssertEqual(restored.view.surface,.agents)
        XCTAssertEqual(restored.agents.first?.name,"Custom");XCTAssertNil(restored.agents.first?.status)
        XCTAssertFalse(restored.restoreAgents(try XCTUnwrap(decoded.agents),terminalIDs:[:]),"never overwrite a running workspace")
    }
    func testAgentOnlyWorkspaceAndTerminalSurfaceRestoreWithoutRuntimeClaims() throws {
        var state=SessionState();_=state.openAgent("one",title:"Build",cwd:"/project");_=state.setView(surface:.terminal,fullscreen:nil)
        var saved=SavedTerminalTabs();saved.agents=SavedAgentTabs(state:state,terminalIDs:[])
        let decoded=try XCTUnwrap(SavedTerminalTabs(json:saved.json()))
        var restored=SessionState();_=restored.restoreAgents(try XCTUnwrap(decoded.agents),terminalIDs:[:])
        XCTAssertEqual(restored.agents.map(\.id),["one"]);XCTAssertEqual(restored.selectedAgent,"one")
        XCTAssertEqual(restored.view.surface,.terminal)
    }
}
