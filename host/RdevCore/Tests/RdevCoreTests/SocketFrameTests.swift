import XCTest
@testable import RdevCore

/// The message-socket frame and hello, against the SAME cross-implementation vectors protocol/'s
/// socket-frame.test.ts asserts (protocol/fixtures/socket-frames.json, from
/// scripts/gen_socket_frame_fixture.py). The host PARSES hellos — only the client writes one.
final class SocketFrameTests: XCTestCase {
    private struct Frame: Decodable { let name: String; let channel: String; let payload: String; let frame: String }
    private struct BadFrame: Decodable { let name: String; let frame: String }
    private struct Hello: Decodable { let name: String; let payload: String; let client: String; let intent: String }
    private struct BadHello: Decodable { let name: String; let payload: String }
    private struct Fixture: Decodable {
        let channels: [String: UInt8]; let helloVersion: Int
        let frames: [Frame]; let malformedFrames: [BadFrame]; let hellos: [Hello]; let malformedHellos: [BadHello]
    }

    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/socket-frames.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    private func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        })
    }

    func testTheFixtureAndTheImplementationAgreeAboutTheChannels() {
        XCTAssertEqual(Self.fx.channels.count, SocketChannel.allCases.count)
        for c in SocketChannel.allCases { XCTAssertEqual(Self.fx.channels["\(c)"], c.rawValue, "\(c)") }
        XCTAssertEqual(Self.fx.helloVersion, SocketHello.version)
        XCTAssertFalse(Self.fx.frames.isEmpty || Self.fx.malformedFrames.isEmpty
                       || Self.fx.hellos.isEmpty || Self.fx.malformedHellos.isEmpty,
                       "an empty list would pass every assertion below")
    }

    func testEveryFrame() throws {
        for f in Self.fx.frames {
            let channel = try XCTUnwrap(SocketChannel.allCases.first { "\($0)" == f.channel }, f.name)
            XCTAssertEqual(SocketFrame.encode(channel, hex(f.payload)), hex(f.frame), f.name)
            let decoded = try XCTUnwrap(SocketFrame.decode(hex(f.frame)), f.name)
            XCTAssertEqual(decoded.channel, channel, f.name)
            XCTAssertEqual(decoded.payload, hex(f.payload), f.name)
            // A `Data` slice keeps its parent's indices; everything downstream reads `payload[0]`.
            XCTAssertEqual(decoded.payload.startIndex, 0, "\(f.name): the payload must be rebased")
        }
    }

    func testEveryMalformedFrameIsRefused() {
        for f in Self.fx.malformedFrames { XCTAssertNil(SocketFrame.decode(hex(f.frame)), f.name) }
    }

    func testEveryHello() throws {
        for h in Self.fx.hellos {
            let intent = try XCTUnwrap(JoinIntent(rawValue: h.intent), h.name)
            XCTAssertEqual(SocketHello.parse(hex(h.payload)), SocketHello(client: h.client, intent: intent), h.name)
        }
    }

    func testEveryMalformedHelloIsRefused() {
        for h in Self.fx.malformedHellos { XCTAssertNil(SocketHello.parse(hex(h.payload)), h.name) }
    }
}
