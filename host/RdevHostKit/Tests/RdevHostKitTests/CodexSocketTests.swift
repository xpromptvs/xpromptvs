import XCTest
@testable import RdevHostKit

final class CodexSocketTests: XCTestCase {
    // Catches a decoder that assumes one network read is one complete WebSocket frame.
    func testSplitAndFragmentedFramesAreReassembledAndPingIsSeparate() throws {
        let decoder = CodexWebSocketDecoder(limit: 1024)
        XCTAssertTrue(try decoder.feed(Data([0x01, 3, 97])).isEmpty)
        XCTAssertTrue(try decoder.feed(Data([98, 99])).isEmpty)
        let ping = try decoder.feed(Data([0x89, 1, 42]))
        XCTAssertEqual(ping, [.ping(Data([42]))])
        XCTAssertEqual(try decoder.feed(Data([0x80, 2, 100, 101])), [.message(Data("abcde".utf8))])
    }
    func testRejectsMaskedServerFramesAndOversizedFragmentedMessages() throws {
        XCTAssertThrowsError(try CodexWebSocketDecoder(limit: 10).feed(Data([0x81, 0x80, 0, 0, 0, 0])))
        let decoder = CodexWebSocketDecoder(limit: 4)
        XCTAssertTrue(try decoder.feed(Data([0x01, 3, 97, 98, 99])).isEmpty)
        XCTAssertThrowsError(try decoder.feed(Data([0x80, 2, 100, 101])))
    }
    func testClientFrameMasksEveryPayloadByteIncludingExtendedLength() throws {
        let data = Data(repeating: 65, count: 130)
        let frame = CodexWebSocketDecoder.clientFrame(data, opcode: 1, mask: [1, 2, 3, 4])
        XCTAssertEqual(Array(frame.prefix(8)), [0x81, 0xfe, 0, 130, 1, 2, 3, 4])
        XCTAssertEqual(Array(frame.dropFirst(8).prefix(5)), [64, 67, 66, 69, 64])
    }
    func testRealDaemonReadOnlyDiscoveryWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["RDEV_CODEX_LIVE_READ"] == "1" else { throw XCTSkip("opt-in daemon discovery") }
        let socket = CodexSocket(path: NSHomeDirectory() + "/.codex/app-server-control/app-server-control.sock")
        defer { socket.close() }
        let connected = expectation(description: "initialize")
        socket.connect { result in
            if case .failure(let error) = result { XCTFail(String(describing: error)) }
            connected.fulfill()
        }
        wait(for: [connected], timeout: 12)
        let listed = expectation(description: "read only loaded threads")
        socket.call(method: "thread/loaded/list", params: [:]) { result in
            switch result {
            case .success(let value): XCTAssertNotNil(value["data"] as? [String])
            case .failure(let error): XCTFail(String(describing: error))
            }
            listed.fulfill()
        }
        wait(for: [listed], timeout: 22)
    }
}
