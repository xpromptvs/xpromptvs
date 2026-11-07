import Foundation

/// rdev's signaling wire, client side. Mirrors `web/src/lib/signaling.ts`: the client sends
/// hello/answer/ice/bye/ping and receives welcome/offer/ice/peer-*/error/pong. Pure — the socket
/// lives in tools/RdevViewer.
public enum RdevSignalOut: Sendable {
    case hello(role: String, token: String, codecs: [String], resumeId: String?)
    case answer(sdp: String)
    case ice(candJSON: String)
    case bye(reason: String?)
    case ping
    /// One §11.3 envelope. `mode` rides the INITIAL handshake message only — §11.3 binds it into
    /// the prologue, so a later one would be describing a session that is already keyed.
    ///
    /// **No `peer` field, unlike the host's.** A client has exactly one peer and the relay routes
    /// its messages by the socket they arrived on; the host names its peer because it may hold
    /// several, and an unaddressed host envelope is DROPPED (measured).
    case e2e(ct: String, mode: E2EWire.Mode?)

    public func json() -> String {
        switch self {
        case let .hello(role, token, codecs, resumeId):
            var o: [String: Any] = ["t": "hello", "role": role, "token": token, "codecs": codecs]
            if let resumeId { o["resumeId"] = resumeId }
            return Self.encode(o)
        case let .answer(sdp):
            return Self.encode(["t": "answer", "sdp": sdp])
        case let .ice(candJSON):
            // `cand` is an object, not a string — splice the caller's JSON in unquoted.
            return #"{"t":"ice","cand":"# + candJSON + "}"
        case let .bye(reason):
            var o: [String: Any] = ["t": "bye"]
            if let reason { o["reason"] = reason }
            return Self.encode(o)
        case .ping:
            return #"{"t":"ping"}"#
        case let .e2e(ct, mode):
            var o: [String: Any] = ["t": "e2e", "ct": ct]
            if let mode { o["mode"] = mode.rawValue }
            return Self.encode(o)
        }
    }

    private static func encode(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}

public enum RdevSignalIn: Equatable, Sendable {
    case welcome(turn: String)      // raw JSON, passed to the peer as ice_servers_json
    case offer(sdp: String, restart: Bool)
    case ice(candJSON: String)
    case peerJoined
    case peerLeft
    case error(code: String, msg: String)
    case pong
    /// One §11.3 envelope from the host.
    case e2e(ct: String, mode: E2EWire.Mode?)

    /// Returns nil for malformed input and for types this client does not handle. Callers MUST
    /// log an unhandled type rather than dropping it silently — `web/src/lib/signaling.ts` learned
    /// that the hard way (a `default: break` hid a permanently-unsatisfiable smoke step).
    public static func parse(_ text: String) -> RdevSignalIn? {
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["t"] as? String else { return nil }
        switch t {
        case "welcome":
            let turn = o["turn"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return .welcome(turn: turn)
        case "offer":
            guard let sdp = o["sdp"] as? String else { return nil }
            return .offer(sdp: sdp, restart: (o["restart"] as? Bool) == true)
        case "ice":
            guard let cand = o["cand"],
                  let d = try? JSONSerialization.data(withJSONObject: cand),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return .ice(candJSON: s)
        case "peer-joined": return .peerJoined
        case "peer-left":   return .peerLeft
        case "error":       return .error(code: o["code"] as? String ?? "", msg: o["msg"] as? String ?? "")
        case "pong":        return .pong
        case "e2e":
            // VALIDATED HERE, NOT TRUSTED FROM THE RELAY — the same shape `SignalingRouter.route`
            // applies on the host, and for the same reason: §4 places the Control Plane inside the
            // adversary model, so its framing checks prove nothing to us. A malformed envelope dies
            // at this boundary rather than inside a Noise session.
            guard let ct = o["ct"] as? String, !ct.isEmpty,
                  ct.count <= SignalingRouter.e2eCiphertextMax,
                  ct.allSatisfy({ $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII
                                  || $0 == "-" || $0 == "_" })
            else { return nil }
            // An unknown mode is a REFUSAL, not a default: a silent fallback to `auth` would let a
            // peer pick the pattern by sending nonsense.
            var mode: E2EWire.Mode?
            if let raw = o["mode"] as? String {
                guard let m = E2EWire.Mode(rawValue: raw) else { return nil }
                mode = m
            }
            return .e2e(ct: ct, mode: mode)
        default:            return nil
        }
    }
}

/// LLV's signaling wire: a 4-byte big-endian length prefix followed by JSON `{type, sdp}` with
/// unknown fields rejected. Format reference: `host/streaming-engine/LibWebRTCBridge/
/// bridge_signaling.cc` (read only — that tree is frozen by gate G1).
public struct LLVSignal: Equatable, Sendable {
    public let type: String
    public let sdp: String

    public init(type: String, sdp: String) {
        self.type = type
        self.sdp = sdp
    }

    /// `.invalidMessage` mirrors `EncodeSignalMessage`'s guard: `type` must be exactly "offer" or
    /// "answer", and `sdp` must be non-empty — bytes this encoder must never hand to a decoder
    /// (ours or the real C++ peer's) that would refuse them.
    public enum Failure: Error, Equatable { case tooLarge, invalidMessage }
    public static let maxBytes = 4 * 1024 * 1024

    public func encode() throws -> Data {
        guard type == "offer" || type == "answer", !sdp.isEmpty else { throw Failure.invalidMessage }
        let body = Data((#"{"sdp":"# + Self.quote(sdp) + #","type":"# + Self.quote(type) + "}").utf8)
        guard body.count > 0, body.count <= Self.maxBytes else { throw Failure.tooLarge }
        var out = Data(count: 4)
        let n = UInt32(body.count)
        out[0] = UInt8(truncatingIfNeeded: n >> 24)
        out[1] = UInt8(truncatingIfNeeded: n >> 16)
        out[2] = UInt8(truncatingIfNeeded: n >> 8)
        out[3] = UInt8(truncatingIfNeeded: n)
        out.append(body)
        return out
    }

    public static func decode<C: Collection>(body: C) -> LLVSignal? where C.Element == UInt8 {
        let data = Data(body)
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o.count == 2,                                   // DisallowUnknownFields
              let type = o["type"] as? String,
              let sdp = o["sdp"] as? String,
              type == "offer" || type == "answer",             // matches DecodeSignalMessage's fields check
              !sdp.isEmpty else { return nil }
        return LLVSignal(type: type, sdp: sdp)
    }

    private static func quote(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s], options: [])
        guard let d, var t = String(data: d, encoding: .utf8) else { return "\"\"" }
        t.removeFirst(); t.removeLast()                       // strip the array brackets
        return t
    }
}

/// The two descriptions a viewer session can hand back, kept in SEPARATE slots.
///
/// WHY A TYPE FOR TWO OPTIONAL STRINGS. The ABI has an `on_offer` and an `on_answer` callback and
/// exactly one of them fires per role: the viewer OFFERS on the llv arm and ANSWERS on the rdev
/// one. Task 10 wired both trampolines to the same handler, which stored an answer into the
/// offer's slot and signalled "the offer is ready" — inert on the llv arm, because `on_answer`
/// never fires there, and precisely wrong on the arm Task 11 adds, where it would send a remote
/// answer back out as though the session had produced it.
///
/// Keeping the routing here rather than in the callback bodies is what makes it testable at all:
/// the trampolines are `@convention(c)` and the session they belong to needs a live libwebrtc
/// peer connection, so nothing about them is reachable from a unit test. This is.
public struct ViewerSDPInbox: Equatable {
    /// The description this session GENERATED, as the offerer.
    public private(set) var offer: String?
    /// The description the PEER generated, as seen by an answerer. Never the same slot as
    /// `offer`: they travel in opposite directions and only one of them is ours to send.
    public private(set) var answer: String?

    public init() {}

    public mutating func receiveOffer(_ sdp: String) { offer = sdp }
    public mutating func receiveAnswer(_ sdp: String) { answer = sdp }
}
