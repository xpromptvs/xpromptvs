import XCTest
@testable import RdevCore

final class SignalingTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testHelloJSONShape() throws {
        let data = helloJSON(role: "host", token: "tok", codecs: ["deflate"])
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["t"] as? String, "hello")
        XCTAssertEqual(obj["role"] as? String, "host")
        XCTAssertEqual(obj["token"] as? String, "tok")
        XCTAssertEqual(obj["codecs"] as? [String], ["deflate"])
    }

    /// A CLIENT that names a `resumeId` is the same client after a reconnect (Add device by code: a blip while the
    /// person decides must not make the issuer a stranger to the new Mac). None named, none sent.
    func testHelloCarriesAResumeIdOnlyWhenGiven() throws {
        let named = try JSONSerialization.jsonObject(with: helloJSON(role: "client", token: "t", resumeId: "r-1")) as! [String: Any]
        XCTAssertEqual(named["resumeId"] as? String, "r-1")
        let bare = try JSONSerialization.jsonObject(with: helloJSON(role: "client", token: "t")) as! [String: Any]
        XCTAssertNil(bare["resumeId"])
    }

    /// The relay tells a CLIENT its host left as `peer-left` with `role: "host"` and NO peer — which this router
    /// dropped, so a Swift client never heard it.
    func testAHostLeavingReachesAClient() {
        guard case .hostLeft? = SignalingRouter.route(json(#"{"t":"peer-left","role":"host"}"#)) else {
            return XCTFail("expected hostLeft")
        }
        guard case .peerLeft("c1")? = SignalingRouter.route(json(#"{"t":"peer-left","peer":"c1"}"#)) else {
            return XCTFail("a client leaving is still peerLeft")
        }
        XCTAssertNil(SignalingRouter.route(json(#"{"t":"peer-left"}"#)))
    }

    /// `protocol/fixtures/adoption-ack.json`, which the browser's `adoptionAck` holds to as well.
    func testTheAdoptionAckFixture() throws {
        struct Case: Decodable { let json: String; let kind: String; let reason: String? }
        struct Fixture: Decodable { let cases: [Case]; let not: [String] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/adoption-ack.json")
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for c in fx.cases {
            let expected: AdoptionAck = c.kind == "adopted" ? .adopted : .refused(reason: c.reason ?? "")
            XCTAssertEqual(AdoptionAck.parse(Data(c.json.utf8)), expected, c.json)
            XCTAssertEqual(AdoptionAck.parse(expected.json), expected, "round trip: \(c.json)")
        }
        for n in fx.not { XCTAssertNil(AdoptionAck.parse(Data(n.utf8)), n) }
    }

    func testRoutesWelcomeWithTurn() {
        let data = json(#"{"t":"welcome","sessionId":"s1","turn":{"urls":["turn:x"],"username":"u","credential":"c","ttl":600}}"#)
        guard case let .welcome(turn)? = SignalingRouter.route(data) else { return XCTFail("expected welcome") }
        XCTAssertEqual(turn.urls, ["turn:x"])
        XCTAssertEqual(turn.ttl, 600)
    }

    func testRoutesOffer() {
        if case .offer("v=0")? = SignalingRouter.route(json(#"{"t":"offer","sdp":"v=0"}"#)) {} else { XCTFail("offer") }
    }

    func testOfferJSONIncludesPeer() throws {
        let obj = try JSONSerialization.jsonObject(with: offerJSON("v=0", peer: "c1")) as! [String: Any]
        XCTAssertEqual(obj["t"] as? String, "offer")
        XCTAssertEqual(obj["sdp"] as? String, "v=0")
        XCTAssertEqual(obj["peer"] as? String, "c1")
    }

    func testIceJSONIncludesPeer() throws {
        let obj = try JSONSerialization.jsonObject(with: iceJSON(["candidate": "x"], peer: "c2")) as! [String: Any]
        XCTAssertEqual(obj["t"] as? String, "ice")
        XCTAssertEqual((obj["cand"] as? [String: Any])?["candidate"] as? String, "x")
        XCTAssertEqual(obj["peer"] as? String, "c2")
    }

    func testRoutesPeerJoinedAndLeftById() {
        if case .peerJoined("c1")? = SignalingRouter.route(json(#"{"t":"peer-joined","peer":"c1"}"#)) {} else { XCTFail("peer-joined") }
        if case .peerLeft("c1")? = SignalingRouter.route(json(#"{"t":"peer-left","peer":"c1"}"#)) {} else { XCTFail("peer-left") }
    }

    func testRoutesAnswerWithPeer() {
        if case let .answer(sdp, peer)? = SignalingRouter.route(json(#"{"t":"answer","sdp":"v=0","peer":"c1"}"#)) {
            XCTAssertEqual(sdp, "v=0"); XCTAssertEqual(peer, "c1")
        } else { XCTFail("answer") }
    }

    func testRoutesIceWithPeer() {
        if case let .ice(cand, peer)? = SignalingRouter.route(json(#"{"t":"ice","cand":{"candidate":"x"},"peer":"c1"}"#)) {
            XCTAssertEqual(cand?["candidate"] as? String, "x"); XCTAssertEqual(peer, "c1")
        } else { XCTFail("ice") }
    }

    func testUnknownAndBadJSONReturnNil() {
        XCTAssertNil(SignalingRouter.route(json(#"{"t":"frobnicate"}"#)))
        XCTAssertNil(SignalingRouter.route(json("not json{")))
    }

    /// THE JOIN INTENT IS NOT THE RELAY'S TO REPORT (docs/sources-and-focus.md, "The join intent"): a client says it
    /// inside its §11 session (`JoinHello`), so an `intent` the relay adds to a join or a resume is read by nobody —
    /// the event carries the peer, and its mode, and nothing it could move control with.
    func testAnIntentInTheRelaysReportIsReadByNobody() {
        if case .peerJoined("c1")? = SignalingRouter.route(Data(#"{"t":"peer-joined","peer":"c1","intent":"connect"}"#.utf8)) {} else { XCTFail("peer-joined") }
        guard case let .peerResumed(id, mode)? = SignalingRouter.route(Data(#"{"t":"peer-resumed","peer":"id1","mode":"rebuild","intent":"connect"}"#.utf8)),
              id == "id1", mode == .rebuild else { return XCTFail("peer-resumed") }
    }
}

final class SignalingResumeTests: XCTestCase {
    func testRoutesPeerSuspended() {
        let data = Data(#"{"t":"peer-suspended","peer":"id1"}"#.utf8)
        guard case .peerSuspended("id1")? = SignalingRouter.route(data) else {
            return XCTFail("expected .peerSuspended")
        }
    }
    func testRoutesPeerResumedWithMode() {
        let data = Data(#"{"t":"peer-resumed","peer":"id1","mode":"rebuild"}"#.utf8)
        guard case let .peerResumed(id, mode)? = SignalingRouter.route(data), id == "id1", mode == .rebuild else {
            return XCTFail("expected .peerResumed(id1, .rebuild)")
        }
    }
    /// The relay parses `e2e-reset` with an exact key set, so an extra field here is a refused reset.
    func testE2EResetJSONNamesThePeerAndNothingElse() throws {
        let obj = try JSONSerialization.jsonObject(with: e2eResetJSON(peer: "id1")) as! [String: Any]
        XCTAssertEqual(obj as NSDictionary, ["t": "e2e-reset", "peer": "id1"] as NSDictionary)
    }
    func testPeerResumedDefaultsToIceOnMissingMode() {
        let data = Data(#"{"t":"peer-resumed","peer":"id1"}"#.utf8)
        guard case let .peerResumed(_, mode)? = SignalingRouter.route(data), mode == .ice else {
            return XCTFail("expected default .ice")
        }
    }
    func testOfferJSONCarriesRestart() throws {
        let obj = try JSONSerialization.jsonObject(with: offerJSON("v=0", peer: "id1", restart: true)) as! [String: Any]
        XCTAssertEqual(obj["restart"] as? Bool, true)
    }
    func testOfferJSONOmitsRestartByDefault() throws {
        let obj = try JSONSerialization.jsonObject(with: offerJSON("v=0", peer: "id1")) as! [String: Any]
        XCTAssertNil(obj["restart"])
    }
    /// THE TAB BAR rides a fresh offer (docs/sources-and-focus.md, "The offer carries the tab bar"): each message as
    /// a JSON OBJECT in order — never a string the client would have to parse twice — and absent when there is none.
    func testOfferJSONCarriesTheStateMessagesAsObjectsInOrder() throws {
        let state = [Data(#"{"t":"control-state","active":true,"clients":1}"#.utf8),
                     Data(#"{"t":"term-list","tabs":[{"id":"pty:1","n":1,"title":"zsh"}],"activeId":"pty:1"}"#.utf8)]
        let obj = try JSONSerialization.jsonObject(with: offerJSON("v=0", peer: "id1", restart: false, state: state)) as! [String: Any]
        let carried = obj["state"] as? [[String: Any]]
        XCTAssertEqual(carried?.map { $0["t"] as? String }, ["control-state", "term-list"])
        XCTAssertEqual((carried?[1]["tabs"] as? [[String: Any]])?.first?["title"] as? String, "zsh")
        XCTAssertEqual(obj["sdp"] as? String, "v=0")
        XCTAssertNil(obj["restart"])
        let none = try JSONSerialization.jsonObject(with: offerJSON("v=0", peer: "id1", restart: true)) as! [String: Any]
        XCTAssertNil(none["state"], "no state, no field")
    }
}

/// The E2E signalling envelope (§11.3) on the HOST side.
///
/// **Validated here, not trusted from the relay.** §4 places the Control Plane inside the adversary
/// model, so the framing checks it performs prove nothing to us — a malformed envelope must die at
/// this boundary rather than inside a Noise session.
final class SignalingE2ETests: XCTestCase {

    private func route(_ json: String) -> SignalingEvent? {
        SignalingRouter.route(Data(json.utf8))
    }

    func testAWellFormedEnvelopeRoutes() throws {
        guard case .e2e(let ct, let peer, let mode)? = route(#"{"t":"e2e","ct":"abc-_123","peer":"c1","mode":"pair"}"#)
        else { return XCTFail("expected an e2e event") }
        XCTAssertEqual(ct, "abc-_123")
        XCTAssertEqual(peer, "c1")
        XCTAssertEqual(mode, .pair)

        guard case .e2e(let bare, let noPeer, let noMode)? = route(#"{"t":"e2e","ct":"AA"}"#)
        else { return XCTFail("the optional fields are optional") }
        XCTAssertEqual(bare, "AA")
        XCTAssertNil(noPeer)
        XCTAssertNil(noMode)
    }

    func testEveryModeRoutes() {
        for mode in E2EWire.Mode.allCases {
            guard case .e2e(_, _, let got)? = route(#"{"t":"e2e","ct":"AA","mode":"\#(mode.rawValue)"}"#)
            else { return XCTFail("\(mode) did not route") }
            XCTAssertEqual(got, mode)
        }
    }

    /// AN UNKNOWN MODE IS A REFUSAL, not a default. §11.3 says to reject unknown modes, and a silent
    /// fallback to `auth` would let a peer choose the handshake pattern by sending nonsense.
    func testMalformedEnvelopesAreRefused() {
        XCTAssertNil(route(#"{"t":"e2e"}"#), "no ct")
        XCTAssertNil(route(#"{"t":"e2e","ct":""}"#), "empty ct")
        XCTAssertNil(route(#"{"t":"e2e","ct":"ab+c"}"#), "base64, not base64url")
        XCTAssertNil(route(#"{"t":"e2e","ct":"ab/c"}"#), "base64, not base64url")
        XCTAssertNil(route(#"{"t":"e2e","ct":"abc="}"#), "padded")
        XCTAssertNil(route(#"{"t":"e2e","ct":"AA","mode":"sideways"}"#), "an unknown mode")
    }

    /// §7 caps a Noise message at 65,535 bytes — 87,380 unpadded base64url characters. The bound is
    /// enforced here AND by the relay, independently, because neither can rely on the other.
    func testTheCiphertextBoundIsEnforced() {
        let at = String(repeating: "A", count: SignalingRouter.e2eCiphertextMax)
        XCTAssertNotNil(route(#"{"t":"e2e","ct":"\#(at)"}"#), "exactly the bound")
        XCTAssertNil(route(#"{"t":"e2e","ct":"\#(at)A"}"#), "one over")
    }

    /// Encode and route are inverses, and `mode` appears only when given — it belongs on the initial
    /// handshake message alone.
    func testEncodeRoundTrips() throws {
        let withMode = e2eJSON("AA-_", peer: "c9", mode: .resume)
        guard case .e2e(let ct, _, let mode)? = SignalingRouter.route(withMode) else {
            return XCTFail("encoded envelope did not route")
        }
        XCTAssertEqual(ct, "AA-_")
        XCTAssertEqual(mode, .resume)

        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: e2eJSON("AA", peer: "c1")) as? [String: Any])
        XCTAssertNil(obj["mode"], "no mode unless one was given")
        XCTAssertEqual(obj["peer"] as? String, "c1")
    }
}
