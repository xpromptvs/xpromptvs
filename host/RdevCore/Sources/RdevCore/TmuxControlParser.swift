import Foundation

/// One thing tmux said in control mode (`tmux -C`). Only what rdev acts on is modelled; every other
/// notification (`%layout-change`, `%window-add`, `%unlinked-*`, …) is dropped by the parser.
public enum TmuxEvent: Equatable, Sendable {
    /// One `%begin … %end|%error` block. `fromUs` is the block's flags field: 1 for a command THIS
    /// client sent, 0 for tmux's own (the initial attach), which must not be matched to a command.
    case reply(ok: Bool, fromUs: Bool, lines: [String])
    /// `%output` and `%extended-output` alike; `pane` is tmux's pane id (`%0`).
    case output(pane: String, bytes: [UInt8])
    case sessionChanged(session: String, name: String)
    case sessionRenamed(session: String, name: String)
    case sessionWindowChanged(session: String, window: String)
    case windowPaneChanged(window: String, pane: String)
    case sessionsChanged
    /// Server-wide paste buffer change, not attributed to a pane. Consumers must choose one active client.
    case pasteBufferChanged(name: String)
    /// A window's layout changed — its SIZE is the part rdev reads: another client resizing a window
    /// rdev shows is how it learns to claim the size back (see `TerminalManager`).
    case layoutChange(window: String, width: Int, height: Int)
    case pause(pane: String)
    case exit(reason: String?)
}

extension TmuxEvent {
    /// Consecutive `%output` for the SAME pane merged into one event. A full-screen redraw arrives as
    /// one `%output` per line (measured: 1282 events for one resize redraw), and forwarding each as its
    /// own message made the client paint it line by line. Only ADJACENT events merge, so ordering
    /// against replies and notifications is untouched.
    public static func coalesced(_ events: [TmuxEvent]) -> [TmuxEvent] {
        var out: [TmuxEvent] = []
        out.reserveCapacity(events.count)
        for e in events {
            if case .output(let pane, let bytes) = e, case .output(let lastPane, let lastBytes)? = out.last,
               pane == lastPane {
                out[out.count - 1] = .output(pane: pane, bytes: lastBytes + bytes)
            } else {
                out.append(e)
            }
        }
        return out
    }
}

/// Line-oriented control-mode parser, measured against tmux 3.7c
/// (`protocol/fixtures/tmux-control-3.7c.txt`):
/// - a command's reply is `%begin <time> <n> <flags>` … `%end|%error <time> <n> <flags>`;
/// - once `refresh-client -f pause-after` is set, `%output %p data` becomes
///   `%extended-output %p <age> … : data`;
/// - pane bytes are escaped as `\ooo` octal (control bytes and the backslash itself); everything
///   else, UTF-8 included, is literal. A raw LF never appears inside data, so LF always ends a line.
/// - **a line is NOT a whole number of characters.** tmux ends an `%output` line wherever its read of
///   the pty ended, so a UTF-8 character can start on one line and finish on the next (captured:
///   `%output %0 \033]0;\xe2\x9c` then `%output %0 \xb3 C`). Pane data is therefore unescaped
///   from the RAW BYTES and handed on as bytes; it is never a `String` here. The consumer's byte
///   stream reassembles the character. Decoding the line first turned each half into U+FFFD.
///
/// Not thread-safe; one per control client, fed from its single read loop.
public struct TmuxControlParser: Sendable {
    private var partial: [UInt8] = []
    /// Non-nil while inside `%begin … %end`: every line there is reply content, `%`-prefixed or not.
    private var block: [String]? = nil
    /// The `<time> <number>` of the open `%begin`. Reply content is NOT escaped — a pane printing
    /// `%end 1 2 1` comes back raw inside a `capture-pane` block (measured on 3.7c) — so only the
    /// `%end`/`%error` carrying the SAME two fields closes the block (iTerm2 does the same).
    private var blockKey: String = ""

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [TmuxEvent] {
        var events: [TmuxEvent] = []
        for b in bytes {
            if b == 0x0a {
                if let e = line(partial) { events.append(e) }
                partial.removeAll(keepingCapacity: true)
            } else {
                partial.append(b)
            }
        }
        return events
    }

    private mutating func line(_ raw: [UInt8]) -> TmuxEvent? {
        // Pane data first, as BYTES, before anything decodes the line (see the type's comment). Inside
        // a reply block a line that looks like `%output` is reply content, so this is outside one only.
        if block == nil, let e = Self.outputLine(raw) { return e }
        let s = String(decoding: raw, as: UTF8.self)
        if var lines = block {
            if (s.hasPrefix("%end ") || s.hasPrefix("%error ")) && Self.blockKey(s) == blockKey {
                block = nil
                return .reply(ok: s.hasPrefix("%end "), fromUs: s.split(separator: " ").last == "1", lines: lines)
            }
            lines.append(s)
            block = lines
            return nil
        }
        if s.hasPrefix("%begin ") { block = []; blockKey = Self.blockKey(s); return nil }
        let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first else { return nil }
        let rest = parts.count > 1 ? parts[1] : ""
        switch head {
        case "%session-changed", "%session-renamed":
            let f = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard f.count == 2 else { return nil }
            return head == "%session-changed" ? .sessionChanged(session: String(f[0]), name: String(f[1]))
                                              : .sessionRenamed(session: String(f[0]), name: String(f[1]))
        case "%session-window-changed":
            let f = rest.split(separator: " ")
            guard f.count == 2 else { return nil }
            return .sessionWindowChanged(session: String(f[0]), window: String(f[1]))
        case "%window-pane-changed":
            let f = rest.split(separator: " ")
            guard f.count == 2 else { return nil }
            return .windowPaneChanged(window: String(f[0]), pane: String(f[1]))
        case "%sessions-changed": return .sessionsChanged
        case "%paste-buffer-changed":
            guard !rest.isEmpty, rest.utf8.count <= 1024,
                  !rest.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
            return .pasteBufferChanged(name: String(rest))
        case "%layout-change":
            // `%layout-change @w <layout> <visible-layout> <flags>`; a layout starts `csum,WxH,x,y…`.
            let f = rest.split(separator: " ")
            guard f.count >= 2 else { return nil }
            let dims = f[1].split(separator: ",")
            guard dims.count >= 2 else { return nil }
            let wh = dims[1].split(separator: "x")
            guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) else { return nil }
            return .layoutChange(window: String(f[0]), width: w, height: h)
        case "%pause": return .pause(pane: String(rest))
        case "%exit": return .exit(reason: rest.isEmpty ? nil : String(rest))
        default: return nil
        }
    }

    /// `<time> <number>` of a `%begin`/`%end`/`%error` line.
    private static func blockKey(_ s: String) -> String {
        s.split(separator: " ").dropFirst().prefix(2).joined(separator: " ")
    }

    private static let outputPrefix = Array("%output ".utf8)
    private static let extendedPrefix = Array("%extended-output ".utf8)

    /// `%output %p <data>` or `%extended-output %p <age> … : <data>`, read from the raw line; nil for
    /// any other line (and for a malformed one of these, which is dropped as before). The pane id and
    /// the fields before ` : ` are ASCII, so only they are decoded.
    private static func outputLine(_ raw: [UInt8]) -> TmuxEvent? {
        if raw.starts(with: outputPrefix) {
            let rest = raw[outputPrefix.count...]
            guard let sp = rest.firstIndex(of: 0x20) else { return nil }
            return .output(pane: String(decoding: rest[..<sp], as: UTF8.self),
                           bytes: unescape(rest[(sp + 1)...]))
        }
        if raw.starts(with: extendedPrefix) {
            let rest = raw[extendedPrefix.count...]
            var i = rest.startIndex
            while i + 2 < rest.endIndex, !(rest[i] == 0x20 && rest[i + 1] == 0x3a && rest[i + 2] == 0x20) { i += 1 }
            guard i + 2 < rest.endIndex else { return nil }
            let pane = rest[..<i].split(separator: 0x20).first.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return .output(pane: pane, bytes: unescape(rest[(i + 3)...]))
        }
        return nil
    }

    /// `\ooo` → one byte, `\\` → a backslash (tmux emits `\134`, but accept both); all else literal.
    /// BYTES in, bytes out: taking a `String` is what let a partial character be decoded (into U+FFFD)
    /// before it was ever unescaped.
    public static func unescape<C: Collection<UInt8>>(_ s: C) -> [UInt8] {
        let u = Array(s)
        var out: [UInt8] = []
        out.reserveCapacity(u.count)
        let octal: ClosedRange<UInt8> = 0x30...0x37
        var i = 0
        while i < u.count {
            // The first digit is at most 3: `\377` is the largest byte, and a shifted `\4xx` would
            // silently wrap into the wrong one.
            if u[i] == 0x5c, i + 3 < u.count,
               (0x30...0x33).contains(u[i + 1]), octal.contains(u[i + 2]), octal.contains(u[i + 3]) {
                out.append((u[i + 1] - 0x30) << 6 | (u[i + 2] - 0x30) << 3 | (u[i + 3] - 0x30))
                i += 4
            } else if u[i] == 0x5c, i + 1 < u.count, u[i + 1] == 0x5c {
                out.append(0x5c)
                i += 2
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return out
    }
}
