import XCTest
@testable import RdevCore
final class AppWorkspaceTests:XCTestCase {
    func testWorkspaceMessagesAndWindowlessDenial() {
        let rows:[(String,InboundMessage)]=[
            (#"{"t":"apps-capabilities","packedV1":true}"#,.appsCapabilities(true)),
            (#"{"t":"apps-list"}"#,.appsList),
            (#"{"t":"apps-add","app":"token"}"#,.appsAdd("token")),
            (#"{"t":"apps-remove","app":"token"}"#,.appsRemove("token")),
            (#"{"t":"apps-restore-all"}"#,.appsRestoreAll)]
        for (wire,message) in rows {XCTAssertEqual(parseInbound(Data(wire.utf8)),message);XCTAssertFalse(WindowlessPolicy.permits(message));XCTAssertFalse(NativeSimulatorPolicy.permits(message,focusedSource:nil))}
        XCTAssertNil(parseInbound(Data(#"{"t":"apps-add","app":""}"#.utf8)))
    }
    func testWorkspacePackingDescriptor() throws {
        XCTAssertTrue(WorkspaceFormat.v1.supported)
        let snapshot=WorkspaceSnapshot()
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:snapshot.wire()) as? [String:Any])
        XCTAssertEqual(object["t"] as? String,"apps-state")
        let format=try XCTUnwrap(object["format"] as? [String:Any])
        XCTAssertEqual(format["codedWidth"] as? Int,3840)
        XCTAssertEqual(format["logicalWidth"] as? Int,1280)
        XCTAssertEqual(format["format"] as? String,"workspace-rgb-alpha-hit-v1")
    }
}
