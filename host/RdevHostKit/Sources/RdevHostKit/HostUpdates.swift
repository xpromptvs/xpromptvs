import Foundation
import RdevCore

/// App policy and E2E authority meet here; no installer operation runs on a channel queue.
public final class HostUpdates: @unchecked Sendable {
    public typealias Reply = @Sendable (Data) -> Void
    public typealias Handler = @Sendable (HostUpdateRequest, HostUpdateRequester, @escaping Reply) -> Void
    private let lock = NSLock()
    private var release: ReleaseIdentity?
    private var allowed = true
    private var available: Int?
    private var handler: Handler?
    private var authority: (@Sendable (String) -> HostUpdateRequester?)?
    private var refresh: (@Sendable () -> Void)?
    public init() {}
    public func configure(release: ReleaseIdentity?, allowed: Bool, available: Int?, handler: Handler?) {
        let refresh = lock.withLock { self.release = release; self.allowed = allowed; self.available = available; self.handler = handler; return self.refresh }
        refresh?()
    }
    public func setAuthority(_ authority: (@Sendable (String) -> HostUpdateRequester?)?) { lock.withLock { self.authority = authority } }
    func onRefresh(_ callback: @escaping @Sendable () -> Void) { lock.withLock { refresh = callback } }
    public func info(for client: String) -> Data {
        let (release, allowed, available, supported, auth) = lock.withLock { (self.release, self.allowed, self.available, handler != nil, authority) }
        let info: [String: Any] = ["t":"host-info", "release":release?.object ?? NSNull(),
            "update":["supported":supported,"allowed":allowed,"eligible":auth?(client) != nil,"availableBuild":available as Any? ?? NSNull()]]
        return (try? JSONSerialization.data(withJSONObject: info)) ?? Data()
    }
    func receive(_ payload: Data, client: String, reply: @escaping Reply) -> Bool {
        guard payload.count <= 4096, let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], object["t"] as? String == "host-update-request" else { return false }
        guard let request = HostUpdateRequest.parse(object) else { return true }
        let (allowed, handler, authority) = lock.withLock { (self.allowed, self.handler, self.authority) }
        guard allowed, let handler, let requester = authority?(client) else {
            reply(Self.status(request.requestId, phase: "failed", error: "Remote updates are unavailable or not permitted.")); return true
        }
        handler(request, requester, reply); return true
    }
    public static func status(_ id: UUID, phase: String, target: Int? = nil, error: String? = nil) -> Data {
        var o: [String: Any] = ["t":"host-update-status","requestId":id.uuidString.lowercased(),"phase":phase]
        if let target { o["targetBuild"] = target }; if let error { o["error"] = error }
        return (try? JSONSerialization.data(withJSONObject:o)) ?? Data()
    }
}
