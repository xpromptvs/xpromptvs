import Foundation

/// **THE NEW MAC'S WORD ON THE CHAIN IT WAS ISSUED** (Add device by code; docs/pairing.md, "Add device by code"). Sent
/// by the adopted Mac (`AdoptByCode`) inside the session the `pair` handshake opened — sealed like any signalling
/// message — once it has COMMITTED the chain, or refused it, and before anything slower (§12.2's registration).
///
/// Until 2026-10-07 the issuer reported "added" the moment the chain LEFT it, and nothing came back: the Mac mini's
/// connection dropped as its chain was sent, the laptop said the Mac was added, and the mini sat on "Adding this Mac…".
/// The issuer now says added only on `adopted`. One JSON object, the shape every signalling message has; both languages
/// hold to `protocol/fixtures/adoption-ack.json`.
public enum AdoptionAck: Equatable, Sendable {
    case adopted
    /// Refused — `reason` is the new Mac's own code (`AdoptByCode`'s `failed(reason:)`).
    case refused(reason: String)

    public var json: Data {
        let obj: [String: Any]
        switch self {
        case .adopted: obj = ["t": "adopted"]
        case .refused(let reason): obj = ["t": "adopt-refused", "reason": reason]
        }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    /// Nil for anything that is not one — an issuer waiting for it ignores other messages rather than guessing.
    public static func parse(_ data: Data) -> AdoptionAck? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = obj["t"] as? String else { return nil }
        switch t {
        case "adopted": return .adopted
        case "adopt-refused": return .refused(reason: obj["reason"] as? String ?? "")
        default: return nil
        }
    }
}
