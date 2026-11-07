import XCTest
import RdevCore
@testable import RdevHostKit
final class FastClientConnectionTests: XCTestCase {
    func testSparseRTCTerminalProgressDoesNotWaitForAOneSecondAck() {
        let gen = Data(repeating: 8, count: 16)
        let acked = expectation(description: "terminal ACK releases pacing capacity")
        let c = FastClientConnection(clientId: "terminal-ack", generation: gen, onOpen: { _ in },
            onMessage: { _, _ in }, onFailure: { XCTFail($0) })
        defer { c.close() }
        c.setWebSocketSender { bytes in
            if let r = FastData.decode(bytes), r.kind == .ack, r.stream == 0, r.value == 5 { acked.fulfill() }
            return true
        }
        c.markReady()
        let sender = FastDelivery(generation: gen)
        if case let .accepted(effects) = sender.send(0, message: Data([42]), nowMs: 0) {
            for effect in effects { if case let .transmit(r) = effect { c.receive(r, from: .webRTC) } }
        }
        wait(for: [acked], timeout: 0.8)
    }
    func testReadyOpensOnceAndInputDeliversOnceAcrossReplay() throws {
        let gen = Data(repeating: 1, count: 16)
        let opened = expectation(description: "three opens"); opened.expectedFulfillmentCount = 3
        let delivered = expectation(description: "one input"); delivered.assertForOverFulfill = true
        let c = FastClientConnection(clientId: "remote", generation: gen, onOpen: { _ in opened.fulfill() }, onMessage: { ch, data in
            XCTAssertEqual(ch, .input); XCTAssertEqual(data, wrapMessage(Data(#"{"t":"key","term":"pty:1","data":"a"}"#.utf8))); delivered.fulfill()
        }, onFailure: { XCTFail($0) })
        defer { c.close() }
        c.setWebSocketSender { _ in true }; c.markReady(); c.markReady()
        let engine = FastDelivery(generation: gen)
        guard case .accepted(let effects) = engine.send(1, message: wrapMessage(Data(#"{"t":"key","term":"pty:1","data":"a"}"#.utf8)), nowMs: 0) else { return XCTFail() }
        for _ in 0..<2 { for effect in effects { if case .transmit(let r) = effect { c.receive(r, from: .webSocket) } } }
        wait(for: [opened, delivered], timeout: 2)
        XCTAssertNil(c.mediaPeer); XCTAssertFalse(c.mediaReady); XCTAssertEqual(c.presentation, .streamedSources)
    }
    func testHostUpdateRequestReachesControlHandlerOverFastChannel() {
        let gen = Data(repeating: 3, count: 16)
        let delivered = expectation(description: "update reaches its authority handler")
        let bytes = wrapMessage(Data(#"{"t":"host-update-request","requestId":"47b01652-900b-44c7-bb13-60704c2bb0b4","minimumBuild":3}"#.utf8))
        let c = FastClientConnection(clientId: "owner", generation: gen, onOpen: { _ in }, onMessage: { ch, data in
            XCTAssertEqual(ch, .control); XCTAssertEqual(data, bytes); delivered.fulfill()
        }, onFailure: { XCTFail($0) })
        defer { c.close() }
        c.setWebSocketSender { _ in true }; c.markReady()
        let sender = FastDelivery(generation: gen)
        if case .accepted(let effects) = sender.send(2, message: bytes, nowMs: 0) {
            for effect in effects { if case .transmit(let record) = effect { c.receive(record, from: .webSocket) } }
        }
        wait(for: [delivered], timeout: 1)
    }
    func testPreReadyAndBulkTrafficNeverReachApplication() {
        let gen = Data(repeating: 2, count: 16)
        let delivered = expectation(description: "no delivery"); delivered.isInverted = true
        let c = FastClientConnection(clientId: "remote", generation: gen, onOpen: { _ in }, onMessage: { _, _ in delivered.fulfill() }, onFailure: { _ in })
        defer { c.close() }; c.setWebSocketSender { _ in true }
        let e = FastDelivery(generation: gen)
        if case .accepted(let effects) = e.send(2, message: wrapMessage(Data(#"{"t":"paste-end","id":"x"}"#.utf8)), nowMs: 0) {
            for effect in effects { if case .transmit(let r) = effect { c.receive(r, from: .webSocket) } }
            c.markReady()
            for effect in effects { if case .transmit(let r) = effect { c.receive(r, from: .webSocket) } }
        }
        wait(for: [delivered], timeout: 0.1)
    }
    func testQueuedApplicationMessagesAreBoundedWhileAHandlerIsBlocked() {
        let gen = Data(repeating: 6, count: 16)
        let entered = expectation(description: "handler blocked")
        let failed = expectation(description: "bounded queue fails visibly")
        let release = DispatchSemaphore(value: 0)
        let c = FastClientConnection(clientId: "bounded", generation: gen, onOpen: { ch in
            if ch == .terminal { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
        }, onMessage: { _, _ in }, onFailure: { _ in failed.fulfill() })
        defer { c.close() }
        c.setWebSocketSender { _ in true }; c.markReady()
        wait(for: [entered], timeout: 2)
        let engine = FastDelivery(generation: gen)
        let msg = wrapMessage(Data(#"{"t":"list-terminals"}"#.utf8))
        for _ in 0..<2050 {
            if case .accepted(let effects) = engine.send(2, message: msg, nowMs: 0) {
                for effect in effects { if case .transmit(let r) = effect { c.receive(r, from: .webSocket) } }
                _ = engine.receive(.init(kind: .ack, generation: gen, stream: 2, value: c.receiveOffsets()[2]), nowMs: 0)
            }
        }
        release.signal()
        wait(for: [failed], timeout: 2)
    }
    func testOutgoingRecordsDoNotWaitForAnApplicationHandler() {
        let entered = expectation(description: "application handler entered")
        let sent = expectation(description: "output leaves while application handler is blocked")
        let release = DispatchSemaphore(value: 0)
        let c = FastClientConnection(clientId: "independent-output", generation: Data(repeating: 8, count: 16), onOpen: { ch in
            if ch == .terminal { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
        }, onMessage: { _, _ in }, onFailure: { XCTFail($0) })
        defer { release.signal(); c.close() }
        c.setWebSocketSender { bytes in
            if FastData.decode(bytes)?.kind == .data { sent.fulfill() }; return true
        }
        c.markReady(); wait(for: [entered], timeout: 1)
        c.send(.terminal, Data([4, 0]))
        wait(for: [sent], timeout: 1)
    }

    func testSlowControlHandlerDoesNotHoldTerminalInput() {
        let entered = expectation(description: "control handler blocked")
        let input = expectation(description: "input runs independently")
        let release = DispatchSemaphore(value: 0)
        let gen = Data(repeating: 9, count: 16)
        let c = FastClientConnection(clientId: "independent-input", generation: gen, onOpen: { _ in }, onMessage: { ch, _ in
            if ch == .control { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
            if ch == .input { input.fulfill() }
        }, onFailure: { XCTFail($0) })
        defer { release.signal(); c.close() }
        c.setWebSocketSender { _ in true }; c.markReady()
        let sender = FastDelivery(generation: gen)
        func send(_ stream: UInt8, _ json: String) {
            if case .accepted(let effects) = sender.send(stream, message: wrapMessage(Data(json.utf8)), nowMs: 0) {
                for effect in effects { if case .transmit(let record) = effect { c.receive(record, from: .webSocket) } }
            }
        }
        send(2, #"{"t":"list-terminals"}"#)
        wait(for: [entered], timeout: 1)
        send(1, #"{"t":"key","term":"pty:1","data":"a"}"#)
        wait(for: [input], timeout: 1)
    }

}
