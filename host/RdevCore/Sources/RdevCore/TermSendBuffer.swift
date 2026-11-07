import Foundation

/// One terminal tab's host-side SEND BUFFER (docs/terminal.md, "The send buffer"). The user's rule,
/// 2026-09-27:
///
/// - A tab's live output is HELD up to `hold` (8 ms) and coalesced into ONE message: flushed `hold`
///   after the first held byte, or at once when it reaches `cap`.
/// - EXCEPT while the tab has had client INPUT within `inputWindow` (500 ms) — any keystroke, mouse or
///   wheel report the client sent TO THAT TAB, at host receipt time. Then output goes out at once,
///   unheld, so a keystroke's echo or a TUI's answer to a click pays nothing.
///
/// Why: the host sent one message per ~1 KiB pty read. Busy output was all per-message cost — frame
/// header, `Z_SYNC_FLUSH` trailer and sync-flushed DEFLATE on tiny inputs (`seq` 3379 msg/s at a ratio
/// of 0.278, `yes` 23 B/msg). Coalescing a few ms of one tab's output gives DEFLATE something to work
/// on and drops most of the trailers, while the input window keeps interactive use at zero added delay.
///
/// Pure policy: the caller supplies a monotonic clock (ns) and owns the ONE timer per tab
/// (`holdAndArm` asks for it, `timerFired` reports it). A timer is never cancelled: when the bytes it
/// was armed for leave early (the cap, input, a boundary) it finds nothing and is spent, or — when
/// newer bytes were held meanwhile — asks to be re-armed for the rest of THEIR hold. So a tab never
/// has two timers, and held bytes never leave before their hold is up unless something sends them.
///
/// Not thread-safe — the caller (TerminalManager) guards it with its lock and emits on the tab's
/// serial path.
public struct TermSendBuffer: Sendable, Equatable {
    /// How long live output may be held. ONE constant.
    public static let hold: UInt64 = 8_000_000
    /// How long after client input to a tab its output goes out unheld. ONE constant.
    public static let inputWindow: UInt64 = 500_000_000
    /// Held raw bytes that send at once: one message's worth. Raw bytes bound the compressed ones from
    /// above. SharedTermPacer splits this raw emission into transport-sized records before compression.
    public static let cap = TermWireMessage.maximumBytes

    public enum Offer: Equatable, Sendable {
        /// Send these bytes now (the held ones first, then this write). Empty for an empty write: nothing
        /// is held and nothing is to be sent (what was held before stays held).
        case send([UInt8])
        /// Held; a timer is already armed.
        case hold
        /// Held, and the caller must arm the tab's one timer to fire after this many ns.
        case holdAndArm(after: UInt64)
    }

    public enum Fire: Equatable, Sendable {
        /// The hold is up: send these.
        case send([UInt8])
        /// Newer bytes are held: fire again after this many ns (the timer stays armed).
        case rearm(after: UInt64)
        /// Nothing held: the timer is spent.
        case idle
    }

    public private(set) var pending: [UInt8] = []
    /// When the first byte of `pending` was held.
    private var heldSince: UInt64?
    private var lastInput: UInt64?
    /// A timer is outstanding for this tab.
    public private(set) var timerArmed = false
    private let capBytes: Int

    public init(cap: Int = TermSendBuffer.cap) { capBytes = cap }

    /// Client input to this tab arrived now.
    public mutating func noteInput(at now: UInt64) { lastInput = now }

    public func isInteractive(at now: UInt64) -> Bool {
        guard let t = lastInput else { return false }
        return now < t || now - t < Self.inputWindow
    }

    /// Live output for the tab. `urgent`: send now whatever the rule says — the bytes carry a device
    /// query, and who answers it (the host or the driver's xterm.js) is decided on the REAL emission, at
    /// the moment it would have left without a buffer.
    public mutating func offer(_ bytes: [UInt8], at now: UInt64, urgent: Bool = false) -> Offer {
        guard !bytes.isEmpty else { return .send([]) }            // nothing to hold, nothing to send
        if urgent || isInteractive(at: now) {
            let out = pending + bytes
            clear()
            return .send(out)
        }
        pending += bytes
        if pending.count >= capBytes { return .send(take()) }
        if heldSince == nil { heldSince = now }
        guard !timerArmed else { return .hold }
        timerArmed = true
        return .holdAndArm(after: Self.hold)
    }

    /// The tab's timer fired.
    public mutating func timerFired(at now: UInt64) -> Fire {
        guard let since = heldSince, !pending.isEmpty else { timerArmed = false; return .idle }
        let due = since + Self.hold
        guard now >= due else { return .rearm(after: due - now) }
        timerArmed = false
        return .send(take())
    }

    /// A BOUNDARY in the tab's stream (its snapshot, its `closed`, a resize): everything held, to send
    /// now, ahead of it.
    public mutating func take() -> [UInt8] {
        let out = pending
        clear()
        return out
    }

    /// The tab's output stopped reaching the context these bytes were meant for (a new wire, a pause,
    /// a re-snapshot pending): they must never be sent — the next snapshot supersedes them.
    public mutating func drop() { clear() }

    /// The caller's timer can no longer reach this buffer (the tab's tmux control client was replaced,
    /// and a timer is bound to the client it was armed on): forget it, and what it was armed for — the
    /// next held byte arms a new one. Without this the buffer would wait for a timer that never comes.
    public mutating func forgetTimer() { clear(); timerArmed = false }

    private mutating func clear() { pending = []; heldSince = nil }
}
