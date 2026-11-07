import Foundation

/// Side effects a `ChannelHub` must perform after a membership change. `activate`/`deactivate`
/// name the client to add/remove as a video consumer (and `activate` also gets a fresh terminal
/// snapshot). `broadcastState` means re-send `control-state` to every connected client.
public struct ActiveClientEffects: Equatable {
    public var activate: String?
    public var deactivate: String?
    public var broadcastState: Bool
    public init(activate: String?, deactivate: String?, broadcastState: Bool) {
        self.activate = activate; self.deactivate = deactivate; self.broadcastState = broadcastState
    }
}

/// Pure state machine for single-active-client control. Not thread-safe; the caller
/// (`ChannelHub`) serializes access under its own lock.
public final class ActiveClientTracker {
    public private(set) var activeId: String?
    private var clients: Set<String> = []

    public init() {}

    public var clientCount: Int { clients.count }
    public func isActive(_ id: String) -> Bool { activeId == id }

    /// A client connected. The first one with no active client becomes active — and so does one that
    /// `claim`s: a client CONNECTING (its join intent is `connect`) takes control at once, the driver it
    /// replaces going passive exactly as on "Move here". A RECONNECT never claims: it keeps its place.
    public func join(_ id: String, claim: Bool = false) -> ActiveClientEffects {
        clients.insert(id)
        if activeId == nil {
            activeId = id
            return ActiveClientEffects(activate: id, deactivate: nil, broadcastState: true)
        }
        // The driver itself joining again with the intent changes nothing (its control open states it).
        if claim { return activeId == id ? ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: false) : self.claim(id) }
        return ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: false)
    }

    /// A connected client clicked "Move here". Transfers control unless it is already active — and then RE-STATES
    /// it (`broadcastState`): a page that pressed Move here believes it is passive, and the driver's `control-state`
    /// it missed (sent into a phone's suspended channel, say, when the other device left and it was promoted) is
    /// what it lacks. It used to be a silent no-op, so that page showed "active elsewhere" however often it was
    /// tapped (2026-10-06, "move here often doesnt work on mobile").
    public func claim(_ id: String) -> ActiveClientEffects {
        guard clients.contains(id) else {
            return ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: false)
        }
        guard activeId != id else {
            return ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: true)
        }
        let old = activeId
        activeId = id
        return ActiveClientEffects(activate: id, deactivate: old, broadcastState: true)
    }

    /// A client disconnected. If it was active, clear active and auto-promote iff exactly one remains.
    public func leave(_ id: String) -> ActiveClientEffects {
        clients.remove(id)
        guard activeId == id else {
            return ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: false)
        }
        activeId = nil
        if clients.count == 1, let next = clients.first {
            activeId = next
            return ActiveClientEffects(activate: next, deactivate: nil, broadcastState: true)
        }
        return ActiveClientEffects(activate: nil, deactivate: nil, broadcastState: true)
    }
}
