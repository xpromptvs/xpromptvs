import Foundation
import RdevCore
@testable import RdevHostKit

/// A WINDOW-LESS client's connection as the hub sees it — no media — recording what the hub sent it.
final class WindowlessConnection: ClientConnection, @unchecked Sendable {
    let clientId: String
    private let lock = NSLock()
    private var sent: [(PionChannel, Data)] = []
    init(_ clientId: String) { self.clientId = clientId }
    var mediaPeer: PionPeer? { nil }
    func send(_ ch: PionChannel, _ data: Data) { lock.withLock { sent.append((ch, data)) } }
    /// The JSON of every control message the hub sent, in order.
    var controlMessages: [String] {
        lock.withLock { sent }.compactMap { ch, data in
            guard ch == .control, let json = unwrapMessage(data) else { return nil }
            return String(data: json, encoding: .utf8)
        }
    }
    /// The JSON of every bulk message the hub sent, in order.
    var bulkMessages: [String] {
        lock.withLock { sent }.compactMap { ch, data in
            guard ch == .bulk, let json = unwrapMessage(data) else { return nil }
            return String(data: json, encoding: .utf8)
        }
    }
}
