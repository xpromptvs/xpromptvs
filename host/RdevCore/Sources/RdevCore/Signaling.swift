import Foundation

public struct TurnCreds: Codable, Sendable {
    public let urls: [String]; public let username: String; public let credential: String; public let ttl: Int
}

private func encodeJSON(_ obj: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

/// `resumeId`: a CLIENT's identity across reconnects — the relay holds a dropped client's place for its grace
/// window and RESUMES it under the same id, where without one a reconnect is a stranger to the host.
public func helloJSON(role: String, token: String, codecs: [String]? = nil, resumeId: String? = nil) -> Data {
    var o: [String: Any] = ["t": "hello", "role": role, "token": token]
    if let codecs { o["codecs"] = codecs }
    if let resumeId { o["resumeId"] = resumeId }
    return encodeJSON(o)
}
public func offerJSON(_ sdp: String, peer: String) -> Data { encodeJSON(["t": "offer", "sdp": sdp, "peer": peer]) }
/// `state`: THE TAB BAR, carried by a peer's FIRST offer (2026-10-05; docs/sources-and-focus.md, "The offer carries
/// the tab bar") — `ChannelHub.offerState`'s messages, each one JSON object of the shape the control channel carries,
/// so the client draws the session's real tabs while WebRTC still connects. Absent when empty. It rides INSIDE the
/// offer, and the offer leaves only sealed in the peer's §11 session (`SharingRoom.sendSealed`): the relay sees
/// ciphertext, as it does of the SDP.
public func offerJSON(_ sdp: String, peer: String, restart: Bool, state: [Data] = []) -> Data {
    var o: [String: Any] = ["t": "offer", "sdp": sdp, "peer": peer]
    if restart { o["restart"] = true }
    let messages = state.compactMap { try? JSONSerialization.jsonObject(with: $0) }
    if !messages.isEmpty { o["state"] = messages }
    return encodeJSON(o)
}
public func answerJSON(_ sdp: String) -> Data { encodeJSON(["t": "answer", "sdp": sdp]) }
public func iceJSON(_ cand: [String: Any], peer: String) -> Data { encodeJSON(["t": "ice", "cand": cand, "peer": peer]) }

/// One E2E envelope (§11.3). `mode` is present on the INITIAL handshake message only.
/// `peer`: the client a HOST addresses; nil from a CLIENT, which has one peer and is tagged by the relay.
public func e2eJSON(_ ct: String, peer: String?, mode: E2EWire.Mode? = nil) -> Data {
    var obj: [String: Any] = ["t": "e2e", "ct": ct]
    if let peer { obj["peer"] = peer }
    if let mode { obj["mode"] = mode.rawValue }
    return encodeJSON(obj)
}
public func byeJSON(_ reason: String?) -> Data {
    var o: [String: Any] = ["t": "bye"]; if let reason { o["reason"] = reason }; return encodeJSON(o)
}
public func pingJSON() -> Data { encodeJSON(["t": "ping"]) }
/// "I hold no session for you — reconnect." Plaintext and empty but for the routing: see
/// `RdevHostRuntime.resetE2E`, and the control plane's `E2EReset` for why a forged one grants nothing.
public func e2eResetJSON(peer: String) -> Data { encodeJSON(["t": "e2e-reset", "peer": peer]) }

public enum ResumeMode: String, Sendable { case ice, rebuild }

/// Why a client joined (docs/sources-and-focus.md, "The join intent"): `connect` — its session's first join, a
/// person connecting — takes control on the host; `reconnect` — a recovery of a session that already joined —
/// keeps its place. A RELAY client says it inside its §11 session (`JoinHello`, `client-confirm`'s app_hello), never
/// to the relay; a socket client in its socket `hello` (`SocketHello`). Absent or unknown: nil, which claims nothing.
public enum JoinIntent: String, Sendable { case connect, reconnect }

public enum SignalingEvent {
    case welcome(TurnCreds), peerJoined(String), peerLeft(String)
    case peerSuspended(String), peerResumed(String, ResumeMode)
    case offer(String), answer(String, String), ice([String: Any]?, String?), error(String, String?), pong
    /// To a CLIENT: the host has left the room (`{"t":"peer-left","role":"host"}`, the relay's `hostLeftMsg`).
    case hostLeft
    /// The E2E signalling envelope (§11.3): one base64url Noise message, the peer it routes to or
    /// from, and — on the initial handshake only — the mode.
    case e2e(ct: String, peer: String?, mode: E2EWire.Mode?)
}

public enum SignalingRouter {
    /// §7 caps a Noise message at 65,535 bytes; unpadded base64url of that is 87,380 characters.
    /// Refusing above it stops a peer making the host buffer something no Noise session could have
    /// produced — and the same bound is enforced by the relay, independently.
    public static let e2eCiphertextMax = 87_380

    public static func route(_ data: Data) -> SignalingEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = obj["t"] as? String else { return nil }
        switch t {
        case "welcome":
            guard let turnObj = obj["turn"],
                  let turnData = try? JSONSerialization.data(withJSONObject: turnObj),
                  let turn = try? JSONDecoder().decode(TurnCreds.self, from: turnData) else { return nil }
            return .welcome(turn)
        case "peer-joined": return (obj["peer"] as? String).map { .peerJoined($0) }
        case "peer-left":
            if let peer = obj["peer"] as? String { return .peerLeft(peer) }
            return obj["role"] as? String == "host" ? .hostLeft : nil
        case "peer-suspended": return (obj["peer"] as? String).map { .peerSuspended($0) }
        case "peer-resumed":
            guard let peer = obj["peer"] as? String else { return nil }
            let mode = ResumeMode(rawValue: obj["mode"] as? String ?? "ice") ?? .ice
            return .peerResumed(peer, mode)
        case "offer": return (obj["sdp"] as? String).map { .offer($0) }
        case "answer": return (obj["sdp"] as? String).map { .answer($0, obj["peer"] as? String ?? "") }
        case "ice": return .ice(obj["cand"] as? [String: Any], obj["peer"] as? String)
        case "e2e":
            // VALIDATED HERE, NOT TRUSTED FROM THE RELAY. §4 places the Control Plane inside the
            // adversary model, so the framing checks it performs are a convenience for itself and
            // prove nothing to us. A malformed envelope must die at this boundary, not inside a
            // Noise session.
            guard let ct = obj["ct"] as? String,
                  !ct.isEmpty, ct.count <= SignalingRouter.e2eCiphertextMax,
                  ct.allSatisfy({ $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" || $0 == "_" })
            else { return nil }
            // An unknown mode is a REFUSAL, not a default: §11.3 says to reject unknown modes, and a
            // silent fallback to `auth` would let a peer pick the pattern by sending nonsense.
            var mode: E2EWire.Mode?
            if let raw = obj["mode"] as? String {
                guard let m = E2EWire.Mode(rawValue: raw) else { return nil }
                mode = m
            }
            return .e2e(ct: ct, peer: obj["peer"] as? String, mode: mode)
        case "error": return .error(obj["code"] as? String ?? "unknown", obj["msg"] as? String)
        case "pong": return .pong
        default: return nil
        }
    }
}
