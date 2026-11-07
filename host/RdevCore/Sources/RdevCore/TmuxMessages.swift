import Foundation

/// One tmux session as `tmux-list` reports it. `id` is tmux's own session id (`$3`).
public struct TmuxSessionInfo: Equatable, Sendable {
    public let id: String
    public let name: String
    public let windows: Int
    public let attached: Int
    public init(id: String, name: String, windows: Int, attached: Int) {
        self.id = id; self.name = name; self.windows = windows; self.attached = attached
    }
}

public enum TmuxList {
    public static let format = "#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}"

    /// `list-sessions -F format`. A line that does not parse is skipped rather than failing the list.
    public static func parse(_ stdout: String) -> [TmuxSessionInfo] {
        // `\n` ONLY (and `\r\n`, one Character in Swift): tmux ends a line with nothing else, while a
        // session NAME may hold U+2028/U+2029, which `isNewline` would cut it at (review M1, 2026-10-01).
        stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 4, isSessionId(String(f[0])), let w = Int(f[2]), let a = Int(f[3]) else { return nil }
            return TmuxSessionInfo(id: String(f[0]), name: String(f[1]), windows: w, attached: a)
        }
    }

    /// `$<digits>` and nothing else. Session ids are interpolated into `-t` targets, so this is the
    /// line between a client naming a session and a client writing tmux commands.
    public static func isSessionId(_ s: String) -> Bool { TermTabID(wire: "tmux:" + s) != nil }

    /// `name` as the ARGUMENT `rename-session -t <id> -- <arg>` turns back into exactly `name`, through a
    /// process's argv (never a control client's command line, which tmux parses as syntax).
    ///
    /// MEASURED AGAINST tmux 3.7c, two layers deep:
    /// - tmux FORMAT-EXPANDS the new name: `#{session_id}` became `$1`, `#S` the session's old name, a
    ///   lone trailing `#` vanished, and `#(echo hi)x` became `x` — tmux reads `#(…)` as a SHELL JOB. So
    ///   every `#` is doubled (`##` is a literal `#`) — EXCEPT a run of `#` right before `[`, which tmux
    ///   copies VERBATIM (it is a style, left for drawing) and must therefore be left alone.
    /// - tmux's argv parse treats an argument ENDING in `;` as a command separator and strips the `;`
    ///   (`x;` became `x`); `\;` there is a literal `;`. So a trailing `;` travels as `\;`.
    /// What tmux then does to the name is tmux's: it stores a backslash vis-encoded (`a\b` lists as
    /// `a\\b`) and refuses a control character — `TabName` already has.
    public static func renameArgument(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(name.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "#" else { out.append(scalars[i]); i += 1; continue }
            var j = i
            while j < scalars.count, scalars[j] == "#" { j += 1 }
            let run = j - i
            let verbatim = j < scalars.count && scalars[j] == "["
            out.append(contentsOf: Array(repeating: "#" as Unicode.Scalar, count: verbatim ? run : 2 * run))
            i = j
        }
        var arg = String(out)
        if arg.hasSuffix(";") { arg.removeLast(); arg += "\\;" }
        return arg
    }
}

/// `{"t":"tmux-list","available":Bool,"sessions":[{id,name,windows,attached}]}`. `available:false`
/// means the host found no `tmux` binary.
public func tmuxListJSON(available: Bool, sessions: [TmuxSessionInfo]) -> Data {
    let arr: [[String: Any]] = sessions.map { ["id": $0.id, "name": $0.name, "windows": $0.windows, "attached": $0.attached] }
    return (try? JSONSerialization.data(withJSONObject: ["t": "tmux-list", "available": available, "sessions": arr])) ?? Data()
}

/// The host refused an `open-terminal` — the only reason today is the tab cap (`too-many-tabs`). Without
/// it the client waited for a tab that was not coming, and focused the NEXT new one it saw.
public func termErrorJSON(reason: String) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["t": "term-error", "reason": reason])) ?? Data()
}

/// A driver's tmux request was refused (`unavailable`, `session-gone`, `too-many-tabs`), or the host
/// gave up on a tab it could not read (`snapshot-failed`; the session lives).
public func tmuxErrorJSON(session: String?, reason: String) -> Data {
    let obj: [String: Any] = ["t": "tmux-error", "session": session as Any? ?? NSNull(), "reason": reason]
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

/// The HOST removed a tmux tab (the session ended or was killed). The client forgets the session on
/// this, and only on this, its own `×`, or a `tmux-error` — never by diffing a `term-list`.
public func tmuxClosedJSON(session: String, reason: String) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["t": "tmux-closed", "session": session, "reason": reason])) ?? Data()
}
