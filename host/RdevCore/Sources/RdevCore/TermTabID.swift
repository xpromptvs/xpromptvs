import Foundation

/// A terminal tab's identity, as the host and the client both name it. Like a source id, the PREFIX
/// is the kind: `pty:<n>` is a host-owned shell, `tmux:$<n>` is a tmux session (tmux's own session
/// id, stable across a rename). There is no numeric form — it was retired outright on 2026-09-25, so
/// a peer still sending numbers is a version skew and its messages are malformed.
public enum TermTabID: Hashable, Sendable {
    case pty(Int)
    /// The associated value is the tmux session id INCLUDING its `$`.
    case tmux(String)

    public init?(wire: String) {
        func digits(_ s: Substring) -> Bool { !s.isEmpty && s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
        if wire.hasPrefix("pty:") {
            let rest = wire.dropFirst(4)
            guard digits(rest), let n = Int(rest), n >= 1 else { return nil }
            self = .pty(n)
        } else if wire.hasPrefix("tmux:$") {
            let rest = wire.dropFirst(6)
            guard digits(rest) else { return nil }
            self = .tmux("$" + rest)
        } else {
            return nil
        }
    }

    public var wire: String {
        switch self {
        case .pty(let n): return "pty:\(n)"
        case .tmux(let s): return "tmux:\(s)"
        }
    }

    public var tmuxSession: String? {
        if case .tmux(let s) = self { return s }
        return nil
    }
}
