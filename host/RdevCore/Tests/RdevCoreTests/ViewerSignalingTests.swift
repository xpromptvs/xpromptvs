import XCTest
@testable import RdevCore

final class ViewerSignalingTests: XCTestCase {

    func testHelloCarriesRoleAndToken() throws {
        let out = RdevSignalOut.hello(role: "client", token: "abc", codecs: ["deflate"], resumeId: nil)
        let obj = try XCTUnwrap(jsonObject(out.json()))
        XCTAssertEqual(obj["t"] as? String, "hello")
        XCTAssertEqual(obj["role"] as? String, "client")
        XCTAssertEqual(obj["token"] as? String, "abc")
        XCTAssertEqual(obj["codecs"] as? [String], ["deflate"])
        XCTAssertNil(obj["resumeId"])
    }

    func testAnswerAndIce() throws {
        let a = try XCTUnwrap(jsonObject(RdevSignalOut.answer(sdp: "v=0\r\n").json()))
        XCTAssertEqual(a["t"] as? String, "answer")
        XCTAssertEqual(a["sdp"] as? String, "v=0\r\n")

        let i = try XCTUnwrap(jsonObject(RdevSignalOut.ice(candJSON: #"{"candidate":"x"}"#).json()))
        XCTAssertEqual(i["t"] as? String, "ice")
        XCTAssertNotNil(i["cand"])
    }

    func testParseOffer() throws {
        let m = try XCTUnwrap(RdevSignalIn.parse(#"{"t":"offer","sdp":"v=0","restart":true}"#))
        guard case let .offer(sdp, restart) = m else { return XCTFail("wrong case: \(m)") }
        XCTAssertEqual(sdp, "v=0")
        XCTAssertTrue(restart)
    }

    func testParseOfferDefaultsRestartFalse() throws {
        let m = try XCTUnwrap(RdevSignalIn.parse(#"{"t":"offer","sdp":"v=0"}"#))
        guard case let .offer(_, restart) = m else { return XCTFail("wrong case") }
        XCTAssertFalse(restart)
    }

    func testParseWelcomeCarriesTurnVerbatim() throws {
        let m = try XCTUnwrap(RdevSignalIn.parse(#"{"t":"welcome","turn":{"urls":["turn:x"]}}"#))
        guard case let .welcome(turn) = m else { return XCTFail("wrong case") }
        XCTAssertTrue(turn.contains("turn:x"))
    }

    func testUnknownTypeIsNilNotACrash() {
        XCTAssertNil(RdevSignalIn.parse(#"{"t":"nonsense"}"#))
        XCTAssertNil(RdevSignalIn.parse("not json"))
    }

    // LLV's framed wire: 4-byte big-endian length prefix, then JSON {type, sdp}.
    func testLLVFrameRoundTrip() throws {
        let framed = try LLVSignal(type: "offer", sdp: "v=0").encode()
        // Computed independently of `framed` itself — the body's JSON shape is fixed
        // (`encode()` always emits `{"sdp":"...","type":"..."}`), so this is a real check
        // of the framing math, not `x == x`.
        let expectedBody = Data(#"{"sdp":"v=0","type":"offer"}"#.utf8)
        XCTAssertEqual(framed.count, 4 + expectedBody.count)
        let length = framed.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        XCTAssertEqual(length, expectedBody.count)
        XCTAssertEqual(framed.dropFirst(4), expectedBody)

        let decoded = try XCTUnwrap(LLVSignal.decode(body: framed.dropFirst(4)))
        XCTAssertEqual(decoded.type, "offer")
        XCTAssertEqual(decoded.sdp, "v=0")
    }

    func testLLVFrameRejectsUnknownFields() {
        let body = Data(#"{"type":"offer","sdp":"v=0","extra":1}"#.utf8)
        XCTAssertNil(LLVSignal.decode(body: body))
    }

    // Finding 1: `EncodeSignalMessage` (bridge_signaling.cc) rejects any `type` other than
    // "offer"/"answer" before framing anything. `encode()` must do the same, or it can build
    // bytes its own `decode()` — and the real C++ peer — would refuse.
    func testLLVEncodeRejectsTypeOutsideOfferAnswer() {
        XCTAssertThrowsError(try LLVSignal(type: "", sdp: "v=0").encode()) {
            XCTAssertEqual($0 as? LLVSignal.Failure, .invalidMessage)
        }
        XCTAssertThrowsError(try LLVSignal(type: "bogus", sdp: "v=0").encode()) {
            XCTAssertEqual($0 as? LLVSignal.Failure, .invalidMessage)
        }
        // The two legal values must still succeed.
        XCTAssertNoThrow(try LLVSignal(type: "offer", sdp: "v=0").encode())
        XCTAssertNoThrow(try LLVSignal(type: "answer", sdp: "v=0").encode())
    }

    func testLLVEncodeRejectsEmptySdp() {
        XCTAssertThrowsError(try LLVSignal(type: "offer", sdp: "").encode()) {
            XCTAssertEqual($0 as? LLVSignal.Failure, .invalidMessage)
        }
    }

    // The encoder must never be able to hand its own decoder bytes it would refuse.
    func testLLVEncodeFailureNeverReachesDecoder() {
        XCTAssertThrowsError(try LLVSignal(type: "", sdp: "").encode())
    }

    func testLLVDecodeRejectsTypeOutsideOfferAnswer() {
        let body = Data(#"{"type":"bogus","sdp":"v=0"}"#.utf8)
        XCTAssertNil(LLVSignal.decode(body: body))
    }

    func testLLVDecodeRejectsEmptySdp() {
        let body = Data(#"{"type":"offer","sdp":""}"#.utf8)
        XCTAssertNil(LLVSignal.decode(body: body))
    }

    private func jsonObject(_ s: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
    }
}
