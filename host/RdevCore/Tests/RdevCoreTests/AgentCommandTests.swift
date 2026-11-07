import XCTest
@testable import RdevCore

final class AgentCommandTests: XCTestCase {
    func testImageMetadataIsScopedAndAcceptsOnlyAnImageReference() {
        XCTAssertNotNil(AgentCommand.parse(["v":1,"id":"one","op":"asset-info","thread":"t","args":["item":"i","path":"/a.png"]]))
        XCTAssertNil(AgentCommand.parse(["v":1,"id":"one","op":"asset-info","args":["item":"i","path":"/a.png"]]))
        XCTAssertNil(AgentCommand.parse(["v":1,"id":"one","op":"asset-info","thread":"t","args":["recursive":true]]))
    }
    func testCompactIsThreadScopedAndAcceptsNoRPCParameters() throws {
        XCTAssertNotNil(AgentCommand.parse(["v":1,"id":"one","op":"compact","thread":"live"]))
        XCTAssertNil(AgentCommand.parse(["v":1,"id":"one","op":"compact"]))
        XCTAssertNil(AgentCommand.parse(["v":1,"id":"one","op":"compact","thread":"live","args":["method":"anything"]]))
    }
    func testOnlyExplicitAgentOperationsAreAccepted() throws {
        XCTAssertNotNil(AgentCommand.parse(["t":"agent-request", "v":1, "id":"one", "op":"list"]))
        XCTAssertNil(AgentCommand.parse(["t":"agent-request", "v":1, "id":"one", "op":"process/spawn"]))
        XCTAssertNil(AgentCommand.parse(["t":"agent-request", "v":2, "id":"one", "op":"list"]))
        XCTAssertNil(AgentCommand.parse(["t":"agent-request", "v":1, "id":"", "op":"list"]))
    }
    func testThreadScopedActionsCannotBecomeUnaddressedOrChangeConfigurationOnJoin() throws {
        XCTAssertNil(AgentCommand.parse(["v":1, "id":"one", "op":"send", "args":["text":"hello"]]))
        XCTAssertNil(AgentCommand.parse(["v":1, "id":"one", "op":"join", "thread":"thread", "args":["sandbox":"danger-full-access"]]))
        let command = try XCTUnwrap(AgentCommand.parse(["v":1, "id":"one", "op":"join", "thread":"thread", "epoch":"7"]))
        XCTAssertEqual(command.thread, "thread")
        XCTAssertEqual(command.epoch, "7")
    }
    func testChildrenRequiresAnExactParentAndAllowsNoArbitraryFilters() throws {
        XCTAssertNil(AgentCommand.parse(["v":1,"id":"one","op":"children"]))
        XCTAssertNil(AgentCommand.parse(["v":1,"id":"one","op":"children","thread":"parent","args":["cwd":"/other"]]))
        XCTAssertNotNil(AgentCommand.parse(["v":1,"id":"one","op":"children","thread":"parent","args":[:]]))
    }
    func testAgentMessagesAreExplicitlyClassifiedByPresentation() throws {
        let data = Data(#"{"t":"agent-request","v":1,"id":"one","op":"hello"}"#.utf8)
        let message = try XCTUnwrap(parseInbound(data))
        XCTAssertFalse(WindowlessPolicy.permits(message))
        XCTAssertTrue(NativeSimulatorPolicy.permits(message, focusedSource: nil))
    }
}
