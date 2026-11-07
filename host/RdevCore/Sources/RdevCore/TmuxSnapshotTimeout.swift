import Foundation

/// How long a tmux tab's snapshot batch may go unanswered before its control client is killed
/// (`TmuxControlClient.batch`'s timeout). A client killed that way is restarted, and the new client
/// snapshots again — so on a host too starved to answer within 5 s, a FIXED timeout restarts the
/// control client every ~5 s for as long as the starvation lasts, each restart another attach and
/// another snapshot the host cannot afford. Each CONSECUTIVE timeout doubles the next one, capped at
/// eight times the base (40 s), and a snapshot that SUCCEEDS starts again from the base.
/// Per tab, surviving its control client's restarts. Pure; the manager holds one per tmux tab.
public struct TmuxSnapshotTimeout: Equatable, Sendable {
    public let base: TimeInterval
    public private(set) var current: TimeInterval

    public init(base: TimeInterval = 5) { self.base = base; current = base }

    public var cap: TimeInterval { base * 8 }

    /// The snapshot got no reply within `current`: the next one waits twice as long.
    public mutating func timedOut() { current = min(current * 2, cap) }

    /// A snapshot was answered: back to the base.
    public mutating func succeeded() { current = base }
}
