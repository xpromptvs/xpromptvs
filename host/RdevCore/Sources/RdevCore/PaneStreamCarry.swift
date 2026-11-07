import Foundation

/// One tmux pane's byte stream, followed across the stretches where rdev does NOT forward it to the
/// driver — before the tab's snapshot is delivered, and while a hidden driver is paused.
///
/// tmux reads a pane in chunks that end at any byte, and its own input parser keeps whatever it has
/// half-read: the lead bytes of a UTF-8 character, or the start of an escape sequence. A snapshot
/// (`capture-pane`, `display`) therefore EXCLUDES that half — the cursor has not moved for it — and
/// the first `%output` after the snapshot starts with the other half. Forwarded alone, orphan
/// continuation bytes paint U+FFFD and move the cursor; an orphan `8;5;174m` paints as text. So the
/// unfinished tail of EVERY byte the pane produced is kept, forwarded or not, and put in front of the
/// first live bytes after a restart: exactly where the snapshot's cursor says the character belongs.
///
/// While forwarding, a chunk never ENDS mid-character — the lead bytes wait (microseconds) for the
/// rest — so the client's streaming decoder never holds a half that a following snapshot would flush
/// as U+FFFD. Escape sequences are not held here: `StreamingQueryStripper` already holds them.
///
/// A stretch rdev never RECEIVED (tmux `%pause`d the pane and discarded its output) leaves the tail
/// unknown: the caller `reset`s it. (Every open tmux tab's control client runs with output ON, so no
/// other stretch is lost.) If a restart's first bytes are then orphan
/// continuation bytes, `forward` returns nil and the caller takes a fresh snapshot — by then tmux has
/// parsed the whole character, so its grid has it. Once: a second orphan in a row is sent as it is,
/// so a pane that really prints stray continuation bytes cannot loop the snapshot.
///
/// Not thread-safe — the caller (TerminalManager) holds its lock.
public struct PaneStreamCarry: Sendable {
    /// The unfinished end of everything the pane produced: an escape sequence or a UTF-8 character.
    public private(set) var tail: [UInt8] = []
    /// Lead bytes of a character withheld from a forwarded chunk until the character completes.
    private var held: [UInt8] = []
    private var restarted = false
    private var healed = false
    /// A tail longer than this is a runaway (an unterminated OSC/DCS), released rather than carried.
    public static let maxTail = 4096

    public init() {}

    /// Bytes the driver will not see.
    public mutating func skip(_ bytes: [UInt8]) {
        tail = Self.unfinishedTail(tail + bytes)
    }

    /// A snapshot was delivered: the driver's view now matches tmux's grid, which excludes `tail`.
    public mutating func restart() {
        restarted = true
        held = []
    }

    /// Bytes were produced that rdev never received: the tail is unknown.
    public mutating func reset() {
        tail = []
        held = []
    }

    /// Bytes to forward → what to send (possibly empty), or nil: orphan continuation bytes right after
    /// a restart that nothing can complete — take a fresh snapshot instead (the bytes count as skipped).
    public mutating func forward(_ bytes: [UInt8]) -> [UInt8]? {
        let prefix: [UInt8]
        if restarted {
            if tail.isEmpty, let first = bytes.first, Self.isContinuation(first), !healed {
                healed = true
                skip(bytes)
                return nil
            }
            restarted = false
            prefix = tail
        } else {
            prefix = held
        }
        healed = false
        tail = Self.unfinishedTail(tail + bytes)
        var out = prefix + bytes
        let cut = Self.incompleteUTF8(out) ?? out.count
        held = Array(out[cut...])
        out.removeSubrange(cut...)
        return out
    }

    static func isContinuation(_ b: UInt8) -> Bool { b & 0xC0 == 0x80 }

    /// The unfinished end of `b`: from the start of an escape sequence that has not ended, or of a
    /// UTF-8 character that has not ended, whichever starts first. An escape tail over `maxTail` is
    /// released (as `StreamingQueryStripper` releases it) — but a character still unfinished at the
    /// very end is carried regardless: it is short by construction and its lead bytes are real.
    static func unfinishedTail(_ b: [UInt8]) -> [UInt8] {
        let utf8 = incompleteUTF8(b)
        let cuts = [StreamingQueryStripper.incompleteTail(b), utf8].compactMap { $0 }
        if let cut = cuts.min(), b.count - cut <= maxTail { return Array(b[cut...]) }
        return utf8.map { Array(b[$0...]) } ?? []
    }

    /// Index of a trailing UTF-8 character whose lead byte and continuation bytes are all there so far
    /// but which needs more, or nil. An invalid sequence is not "unfinished" — it is never completed.
    static func incompleteUTF8(_ b: [UInt8]) -> Int? {
        var i = b.count - 1
        var continuations = 0
        while i >= 0, continuations < 3, isContinuation(b[i]) { continuations += 1; i -= 1 }
        guard i >= 0 else { return nil }
        let need: Int
        switch b[i] {
        case 0xC2...0xDF: need = 1
        case 0xE0...0xEF: need = 2
        case 0xF0...0xF4: need = 3
        default: return nil
        }
        return continuations < need ? i : nil
    }
}
