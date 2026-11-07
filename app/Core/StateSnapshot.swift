import Foundation

/// Everything the dashboard used to poll, as one canonical JSON document. Equality IS "the page
/// would render something different", so "push only on change" is this type's `==`.
public struct StateSnapshot: Equatable, Sendable {
    public let json: String

    public init?(state: [String: Any], account: [String: Any], e2e: [String: Any], capabilities: Int,
                 adopt: Any?, addDevice: Any? = nil, listing: [String: Any]) {
        // `adopt` only while this Mac is unenrolled (e2e status 1) — the row discards it otherwise.
        let unenrolled = (e2e["status"] as? Int) == 1
        let object: [String: Any] = [
            "state": state, "account": account, "e2e": e2e, "capabilities": capabilities,
            "adopt": unenrolled ? (adopt ?? NSNull()) : NSNull(), "listing": listing,
            // The Add device dialog's run (`AddDeviceHost`); null when none is under way or just ended.
            "addDevice": addDevice ?? NSNull(),
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        json = String(decoding: data, as: UTF8.self)
    }
}
