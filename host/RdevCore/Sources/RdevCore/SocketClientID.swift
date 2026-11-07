/// **A SOCKET CLIENT'S ID IS ITS OWN NAMESPACE** (docs/sources-and-focus.md, "Window-less clients").
/// `ChannelHub` knows every client by one string. A relay client is known by the id its hello gave
/// the relay: a per-tab UUID in practice, but any non-empty string the relay accepts
/// (`control-plane/src/protocol.ts`). A socket client is known by `sock:` + its hello's id. The
/// prefix keeps a tab that reached this Mac both ways as two clients. RESERVING it is what stops a
/// relay peer NAMING a socket client: a `peer-left` for `sock:<id>` would unregister the Mac's own
/// local window.
public enum SocketClientID {
    public static let prefix = "sock:"

    /// The id `ChannelHub` registers a socket client under.
    public static func make(_ client: String) -> String { prefix + client }

    /// True for an id only a socket client may hold. Relay traffic naming one is dropped whole
    /// (`SharingRoom.handle`).
    public static func isReserved(_ id: String) -> Bool { id.hasPrefix(prefix) }
}

extension SignalingEvent {
    /// The relay peer an event is about, or nil for one about no peer. EXHAUSTIVE, with no `default`:
    /// a new event must say whether it names a peer, or a reserved id could slip through it.
    public var peerID: String? {
        switch self {
        case .welcome, .offer, .error, .pong, .hostLeft: return nil   // `hostLeft` names the HOST, never a client
        case .peerJoined(let id), .peerLeft(let id), .peerSuspended(let id), .peerResumed(let id, _): return id
        case .answer(_, let id): return id
        case .ice(_, let id): return id
        case .e2e(_, let peer, _): return peer
        }
    }
}
