import XCTest
@testable import RdevCore
final class FastDeliveryTests: XCTestCase {
    func testIndependentDeliveryTrace() throws {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/fast-delivery-traces.json"))) as! [String: Any]
        func unhex(_ s: String) -> Data { var data = Data(); var i = s.startIndex; while i < s.endIndex { let j = s.index(i, offsetBy: 2); data.append(UInt8(s[i..<j], radix: 16)!); i = j }; return data }
        let d = FastDelivery(generation: unhex(obj["generation"] as! String))
        for step in obj["steps"] as! [[String: Any]] {
            let r = try XCTUnwrap(FastData.decode(unhex(step["wire"] as! String)))
            XCTAssertEqual(messages(d.receive(r, nowMs: 0)), (step["delivered"] as! [String]).map(unhex))
            XCTAssertEqual(d.receiveOffsets()[0], UInt64(step["next"] as! String))
        }
    }
    let gen = Data(repeating: 7, count: 16)
    func records(_ effects: [FastDelivery.Effect]) -> [FastData.Record] { effects.compactMap { if case .transmit(let r) = $0 { return r }; return nil } }
    func messages(_ effects: [FastDelivery.Effect]) -> [Data] { effects.compactMap { if case .deliver(_, let d) = $0 { return d }; return nil } }
    func send(_ d: FastDelivery, _ stream: UInt8, _ bytes: Data) -> [FastData.Record] {
        guard case .accepted(let e) = d.send(stream, message: bytes, nowMs: 0) else { XCTFail("not accepted"); return [] }; return records(e)
    }
    func testReorderReplayDeliversOnceWithIndependentStreams() {
        let a = FastDelivery(generation: gen), b = FastDelivery(generation: gen)
        let data = Data((0..<20000).map { UInt8($0 % 251) }); let r = send(a, 0, data)
        var effects = b.receive(r[2], nowMs: 0)
        XCTAssertEqual(messages(b.receive(send(a, 2, Data([99]))[0], nowMs: 0)), [Data([99])])
        for record in a.replay(0).reversed() { effects += b.receive(record, nowMs: 1) }
        for record in r { effects += b.receive(record, nowMs: 2) }
        XCTAssertEqual(messages(effects), [data])
        for record in records(effects + b.poll(nowMs: 22)) { _ = a.receive(record, nowMs: 22) }
        XCTAssertEqual(a.bufferedAmount(0), 0); XCTAssertEqual(b.receiveOffsets()[0], 20004)
    }
    func testPayloadAccountingAndImpossibleAcknowledgement() {
        let a = FastDelivery(generation: gen); _ = send(a, 0, Data(count: 10))
        for (offset, expected) in [(4,10),(9,5),(2,5)] {
            _ = a.receive(.init(kind: .ack, generation: gen, stream: 0, value: UInt64(offset)), nowMs: 0)
            XCTAssertEqual(a.bufferedAmount(0), expected)
        }
        XCTAssertEqual(a.receive(.init(kind: .ack, generation: gen, stream: 0, value: 15), nowMs: 0), [.failed("ack-beyond-sent")])
    }
    func testBoundsReserveControlCapacity() {
        let a = FastDelivery(generation: gen); let m = Data(count: 1048576)
        XCTAssertFalse(send(a, 0, m).isEmpty); XCTAssertFalse(send(a, 0, m).isEmpty)
        XCTAssertEqual(a.send(0, message: Data([1]), nowMs: 0), .full)
        XCTAssertFalse(send(a, 2, Data([1])).isEmpty)
        XCTAssertEqual(a.send(1, message: Data(count: 1048577), nowMs: 0), .invalid)
    }
    func testAckDeadlineAndPartialReplay() {
        let a = FastDelivery(generation: gen), b = FastDelivery(generation: gen)
        let data = Data(repeating: 42, count: 20000); let r = send(a, 0, data)
        XCTAssertTrue(records(b.receive(r[0], nowMs: 0)).isEmpty)
        XCTAssertTrue(b.poll(nowMs: 19).isEmpty)
        for ack in records(b.poll(nowMs: 20)) { _ = a.receive(ack, nowMs: 20) }
        XCTAssertEqual(a.bufferedAmount(0), 11812)
        XCTAssertEqual(messages(a.replay(0).flatMap { b.receive($0, nowMs: 21) }), [data])
    }
    func testRefusesConflictsAndUnboundedReceiveWindow() {
        let b = FastDelivery(generation: gen)
        _ = b.receive(.init(kind: .data, generation: gen, stream: 0, value: 5, bytes: Data([1])), nowMs: 0)
        XCTAssertEqual(b.receive(.init(kind: .data, generation: gen, stream: 0, value: 5, bytes: Data([2])), nowMs: 0), [.failed("conflicting-overlap")])
        XCTAssertEqual(FastDelivery(generation: gen).receive(.init(kind: .data, generation: gen, stream: 0, value: 3000000, bytes: Data([1])), nowMs: 0), [.failed("receive-window")])
        XCTAssertEqual(FastDelivery(generation: gen).receive(.init(kind: .data, generation: gen, stream: 0, value: 0, bytes: Data([0,16,0,1])), nowMs: 0), [.failed("invalid-message-length")])
        XCTAssertTrue(FastDelivery(generation: gen).receive(.init(kind: .data, generation: Data(count: 16), stream: 0, value: 0, bytes: Data([1])), nowMs: 0).isEmpty)
    }
    func testRTCAcknowledgementBatchingDoesNotDelayDeliveryAndLargeProgressIsImmediate() {
        let a = FastDelivery(generation: gen), b = FastDelivery(generation: gen), data = Data(count: 100)
        XCTAssertEqual(messages(b.receive(send(a, 0, data)[0], nowMs: 0, ackDelayMs: 1000)), [data])
        XCTAssertTrue(b.poll(nowMs: 999).isEmpty)
        XCTAssertEqual(records(b.poll(nowMs: 1000)).first?.value, 104)
        XCTAssertEqual(records(b.receive(send(a, 0, Data(count: 10000))[0], nowMs: 1001, ackDelayMs: 1000)).first?.value, 104 + 8192)
    }
    func testRTCAcknowledgementsReleaseTheSharedTerminalSpareBudget() {
        let a = FastDelivery(generation: gen), b = FastDelivery(generation: gen)
        XCTAssertTrue(records(b.receive(send(a, 0, Data(count: 1020))[0], nowMs: 0, ackDelayMs: 1000)).isEmpty)
        XCTAssertEqual(records(b.receive(send(a, 0, Data(count: 1020))[0], nowMs: 1, ackDelayMs: 1000)).first?.value, 2048)
    }
}
