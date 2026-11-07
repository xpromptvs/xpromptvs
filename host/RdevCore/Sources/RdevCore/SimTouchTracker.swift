import Foundation

/// A point normalised 0…1 to a simulator's NATIVE frame (what the digitizer takes) or, before `SimRotation`, to the
/// picture as shown. Which one is the caller's to say; the type carries no frame.
public struct SimPoint: Equatable, Sendable {
    public let x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// One digitizer event: the DTUHID `IndigoDigitizerEvent`'s eventType 0 / 1 / 2, with its one or two contacts.
public enum SimTouchEvent: Equatable, Sendable {
    case start([SimPoint]), move([SimPoint]), end([SimPoint])
}

/// The client's `sim-touch` phases → digitizer events (docs/superpowers/specs/2026-10-13-simulator-sources-design.md,
/// "The wire"). DTUHID tracks ONE gesture of one or two contacts; the client keeps a finger in its slot and ends a
/// gesture whenever the count changes. This also REPAIRS a garbled stream (a lost `up`, a count that changed on a
/// move): a contact left down in the simulator is a stuck finger nobody on the client can see, so every repair ends
/// the open gesture where it last was.
public struct SimTouchTracker: Sendable {
    private var open: [SimPoint] = []
    public init() {}

    public mutating func apply(phase: String, points: [SimPoint]) -> [SimTouchEvent] {
        guard (1...2).contains(points.count) else { return [] }
        switch phase {
        case "down":
            var out = cancel()
            out.append(.start(points)); open = points
            return out
        case "move":
            if open.isEmpty { open = points; return [.start(points)] }
            if open.count != points.count {
                var out = cancel()
                out.append(.start(points)); open = points
                return out
            }
            open = points
            return [.move(points)]
        case "up":
            guard !open.isEmpty else { return [] }
            let at = open.count == points.count ? points : open
            open = []
            return [.end(at)]
        default:
            return []
        }
    }

    /// End whatever is down, where it last was.
    public mutating func cancel() -> [SimTouchEvent] {
        guard !open.isEmpty else { return [] }
        defer { open = [] }
        return [.end(open)]
    }
}
