import Foundation

/// The modes that decide how a client emulator BEHAVES; a tmux tab follows them off its stream between
/// snapshots (`TermModeTracker`), a pty tab reads them from SwiftTerm (`Terminal.inputModes`).
///
/// The mode set is exactly what xterm.js honours — tracking a mode it ignores (`?1005`/`?1015`, removed
/// upstream) would only put noise on the wire.
public struct TermModes: Equatable, Sendable {
    /// `?9 / ?1000 / ?1002 / ?1003` — which pointer events the app wants reported. Last one set wins,
    /// and resetting ANY of them turns reporting off entirely (xterm.js semantics).
    public enum Mouse: Equatable, Sendable { case off, x10, vt200, buttonEvent, anyEvent }
    /// `?1006 / ?1016` — how those events are encoded. Restoring this WITH the tracking mode is
    /// load-bearing: an app that asked for SGR but is fed default-encoded events misparses the
    /// coordinates, which is worse than reporting nothing at all.
    public enum MouseEncoding: Equatable, Sendable { case standard, sgr, sgrPixels }

    public var applicationCursor = false        // ?1    DECCKM — arrows as SS3 (ESC O A) not CSI
    public var mouse: Mouse = .off              // ?9 / ?1000 / ?1002 / ?1003
    public var mouseEncoding: MouseEncoding = .standard
    public var focusReporting = false           // ?1004 — client emits ESC[I / ESC[O on focus change
    public var bracketedPaste = false           // ?2004
    public var cursorVisible = true             // ?25
    public var altScreen = false                // ?47 / ?1047 / ?1049
    // Followed for the HOST's answers to a tmux tab's C1 DECRQM (`TermHostReplies`), with xterm.js 6's
    // semantics — tmux's own formats diverge from xterm.js after a DECSTR (tmux ignores it), a `?66h`
    // (tmux ignores it) or a `?12` (xterm.js reads it as an OPTION): measured, 3.7c.
    public var applicationKeypad = false        // ESC = / ESC > / ?66 — DECNKM
    public var insert = false                   // CSI 4 h — IRM
    public var wraparound = true                // ?7
    public var reverseWraparound = false        // ?45
    public var origin = false                   // ?6
    /// `?12`: xterm.js's `cursorBlink` OPTION, which `mountXterm` starts true and nothing but `?12h/l`
    /// changes (not DECSCUSR, not RIS, not DECSTR) — what its DECRQM `?12` and DECRQSS ` q` report.
    public var cursorBlink = true
    /// `CSI 20 h`: xterm.js's `convertEol` OPTION (off in the product) — DECRQM 20.
    public var convertEol = false

    public init() {}
}

/// Follows a tab's raw PTY output and keeps its current `TermModes`.
///
/// Why a tracker and not the emulator's own state: SwiftTerm exposes `mouseMode` but keeps the mouse
/// *encoding* (`?1006`) private, and restoring tracking without the encoding is worse than not
/// restoring at all (see `TermModes.MouseEncoding`). Reading the mode changes straight off the byte
/// stream gets both, and stays a pure value type we can test.
///
/// Not thread-safe — the caller (TerminalManager) holds its lock.
public struct TermModeTracker: Sendable {
    public private(set) var modes = TermModes()

    /// Enough of a VT parser to not be fooled by mode-shaped bytes inside a title or DCS payload, and
    /// to survive a sequence SPLIT across two PTY reads (the state rides between `feed` calls).
    private enum State: Sendable { case ground, esc, csi, str, strEsc }
    private var state: State = .ground
    private var params: [UInt8] = []

    public init() {}

    /// Start from a known state — a tmux tab's is tmux's own snapshot (`TmuxPaneState`) — and follow
    /// the stream from there.
    public init(modes: TermModes) { self.modes = modes }

    /// Feed `bytes`, and return the modes as they stood at each offset in `marks` (ascending, each in
    /// `0...bytes.count`): what an xterm.js reading the same stream would report to a query that ends
    /// there — a later sequence in the same read does not change its answer.
    public mutating func modes(feeding bytes: [UInt8], at marks: [Int]) -> [TermModes] {
        var at = 0
        var out: [TermModes] = []
        for m in marks {
            let end = min(max(m, at), bytes.count)
            feed(Array(bytes[at..<end])); at = end
            out.append(modes)
        }
        feed(Array(bytes[at...]))
        return out
    }

    public mutating func feed(_ bytes: [UInt8]) {
        for b in bytes {
            switch state {
            case .ground:
                if b == 0x1b { state = .esc }
            case .esc:
                handleEsc(b)
            case .csi:
                if b >= 0x40, b <= 0x7e { applyCSI(final: b); state = .ground }
                else if b == 0x1b { state = .esc }                  // aborted mid-sequence
                else if params.count < 64 { params.append(b) }
            case .str:
                if b == 0x07 { state = .ground } else if b == 0x1b { state = .strEsc }
            case .strEsc:
                if b == 0x5c { state = .ground } else { handleEsc(b) }   // ST, else the ESC starts anew
            }
        }
    }

    private mutating func handleEsc(_ b: UInt8) {
        switch b {
        case 0x5b: params.removeAll(keepingCapacity: true); state = .csi   // '['  CSI
        case 0x5d, 0x50, 0x58, 0x5e, 0x5f: state = .str                    // OSC / DCS / SOS / PM / APC
        case 0x63:                                                         // ESC c — RIS
            // xterm.js's OPTIONS survive a full reset; everything else is fresh.
            let (blink, eol) = (modes.cursorBlink, modes.convertEol)
            modes = TermModes(); modes.cursorBlink = blink; modes.convertEol = eol
            state = .ground
        case 0x3d: modes.applicationKeypad = true; state = .ground        // ESC = — DECKPAM
        case 0x3e: modes.applicationKeypad = false; state = .ground       // ESC > — DECKPNM
        case 0x1b: state = .esc
        default: state = .ground
        }
    }

    /// Apply `CSI ? Pm ; Pm h|l`, the ANSI modes `CSI Pm h|l` (IRM, and `convertEol`'s 20) and DECSTR
    /// (`CSI ! p`). Anything else (a query, a sub-parameter, another private or intermediate form,
    /// DECSTBM) is skipped.
    private mutating func applyCSI(final: UInt8) {
        if final == 0x70, params == [0x21] { softReset(); return }
        guard final == 0x68 || final == 0x6c else { return }
        let set = (final == 0x68)
        let ansi = params.first != 0x3f
        var value = 0, digits = false, valid = true
        for b in ansi ? params[...] : params.dropFirst() {
            if b >= 0x30, b <= 0x39 { value = min(value * 10 + Int(b - 0x30), 99_999); digits = true }
            else if b == 0x3b { if digits, valid { apply(value, set, ansi: ansi) }; value = 0; digits = false; valid = true }
            else { valid = false }                                          // ':' sub-params, intermediates
        }
        if digits, valid { apply(value, set, ansi: ansi) }
    }

    /// xterm.js `softReset`: every DEC private mode it keeps in `decPrivateModes` (origin, ?2026,
    /// cursor keys, keypad, bracketed paste, focus, reverse wrap; wraparound back ON) and IRM; the
    /// cursor is shown. Mouse tracking lives elsewhere (CoreMouseService) and survives, as do OPTIONS.
    private mutating func softReset() {
        modes.applicationCursor = false
        modes.applicationKeypad = false
        modes.bracketedPaste = false
        modes.focusReporting = false
        modes.cursorVisible = true
        modes.origin = false
        modes.wraparound = true
        modes.reverseWraparound = false
        modes.insert = false
    }

    private mutating func apply(_ mode: Int, _ set: Bool, ansi: Bool) {
        if ansi {
            switch mode {
            case 4: modes.insert = set
            case 20: modes.convertEol = set
            default: break
            }
            return
        }
        switch mode {
        case 6: modes.origin = set
        case 7: modes.wraparound = set
        case 12: modes.cursorBlink = set
        case 45: modes.reverseWraparound = set
        case 66: modes.applicationKeypad = set
        case 1: modes.applicationCursor = set
        case 9: modes.mouse = set ? .x10 : .off
        case 1000: modes.mouse = set ? .vt200 : .off
        case 1002: modes.mouse = set ? .buttonEvent : .off
        case 1003: modes.mouse = set ? .anyEvent : .off
        case 1004: modes.focusReporting = set
        case 1006: modes.mouseEncoding = set ? .sgr : .standard
        case 1016: modes.mouseEncoding = set ? .sgrPixels : .standard
        case 25: modes.cursorVisible = set
        case 2004: modes.bracketedPaste = set
        case 47, 1047, 1049: modes.altScreen = set
        default: break
        }
    }
}

/// Recognises the input a CLIENT emulator generates *because of* a mode, so the host can refuse it when
/// the receiving tab never asked for that mode.
///
/// Why this is needed on top of the attach reset: a tab switch repoints the write target to the new tab
/// IMMEDIATELY, but the client only drops the old tab's modes when the attach payload reaches it a round
/// trip later. Everything the pointer does in that window is generated under the OLD tab's mode and
/// delivered to the NEW tab's shell — a couple of mouse reports typed into a fresh prompt. Closing it by
/// timing is impossible (the window is however long the network is); refusing input the tab cannot have
/// asked for is not timing-dependent at all, and covers the same race on claim and on reconnect.
///
/// **Still needed after keystrokes started naming their tab** (`TerminalManager.write(_:toTerminal:)`).
/// The two overlap without either containing the other: the target check refuses everything sent while
/// the client's idea of the active tab is stale, mouse reports included, but on claim and on reconnect
/// the client's tab id is CURRENT while its emulator's modes are not, and only this filter sees that.
public enum ModeInput {

    /// Length of the mouse report starting at `i`, or nil. Covers the three encodings a client can be
    /// left in: SGR/SGR-pixels (`ESC[<b;x;yM|m`), X10 (`ESC[M` + 3 bytes) and urxvt (`ESC[b;x;yM`).
    static func mouseReportLength(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 2 < b.count, b[i] == 0x1b, b[i + 1] == 0x5b else { return nil }
        if b[i + 2] == 0x4d { return i + 5 < b.count ? 6 : nil }          // ESC [ M Cb Cx Cy
        var j = i + 2
        if b[j] == 0x3c { j += 1 }                                        // '<' — SGR
        var digits = 0, semis = 0
        while j < b.count {
            let c = b[j]
            if c >= 0x30, c <= 0x39 { digits += 1; j += 1 }
            else if c == 0x3b { semis += 1; j += 1 }
            else { break }
        }
        guard j < b.count, digits > 0, semis == 2 else { return nil }     // exactly Cb ; Cx ; Cy
        // 'm' only terminates SGR; a bare `ESC [ Ps ; Ps ; Ps M` is urxvt (and, as an OUTPUT sequence,
        // Delete-Line — but this is the input path, where a client sends keystrokes and reports, not DL).
        guard b[j] == 0x4d || (b[j] == 0x6d && b[i + 2] == 0x3c) else { return nil }
        return j - i + 1
    }

    /// True when `bytes` is nothing but mouse reports — never a keystroke, so dropping it is safe.
    public static func isAllMouseReports(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        var i = 0
        while i < bytes.count {
            guard let n = mouseReportLength(bytes, i) else { return false }
            i += n
        }
        return true
    }

    /// `ESC[I` / `ESC[O` — the focus in/out report a client sends under `?1004`. Same race, same remedy.
    public static func isAllFocusReports(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, bytes.count % 3 == 0 else { return false }
        for i in stride(from: 0, to: bytes.count, by: 3) {
            guard bytes[i] == 0x1b, bytes[i + 1] == 0x5b, bytes[i + 2] == 0x49 || bytes[i + 2] == 0x4f else { return false }
        }
        return true
    }

    /// Should this input be refused for a tab in these modes? Only ever true for input the client could
    /// not have produced without a mode the tab does not have.
    public static func shouldDrop(_ bytes: [UInt8], modes: TermModes) -> Bool {
        if modes.mouse == .off, isAllMouseReports(bytes) { return true }
        if !modes.focusReporting, isAllFocusReports(bytes) { return true }
        return false
    }
}

/// The whole rule for whether driver input reaches a shell: the client and the host must agree about
/// which tab the user was typing into, AND the tab must be able to have asked for these bytes.
///
/// Both conditions live HERE, in one expression, because they were separately true and separately
/// forgettable. The host's terminal write is now a lock hold around a single call to this, so there is
/// no second site restating either half and no way to apply one check without the other.
public enum TerminalInput {

    /// - Parameters:
    ///   - named: the tab the CLIENT said it was typing into, from its last `term-list`.
    ///   - activeTab: the tab the host would write to.
    ///
    /// A disagreement REFUSES the bytes; it never redirects them to `named`. The client's id reports
    /// what the user was looking at, not where to deliver: `named` is by construction not the active
    /// tab in that branch, so honouring it would put keystrokes into a shell that is on nobody's
    /// screen. Keys dropped across a tab switch are retyped; a password in the wrong shell is not
    /// recoverable, and neither is one in a shell the user never saw.
    public static func shouldDeliver(named: TermTabID, activeTab: TermTabID, bytes: [UInt8], modes: TermModes) -> Bool {
        named == activeTab && !ModeInput.shouldDrop(bytes, modes: modes)
    }

    /// A DEVICE-QUERY REPLY (`term-reply`), which xterm.js produced while parsing a tab's bytes — never
    /// typing, which the client sends as `key`.
    ///
    /// The keystroke rule above exists because a keystroke's tab is a CLAIM about what the user was
    /// looking at, and a stale claim must not redirect it. A reply's tab is not a claim: it names the
    /// instance that parsed the query, which is the tab whose bytes asked, whatever is on screen — so
    /// delivering it there redirects nothing. And the host accepts one only while it OWES that tab a
    /// reply (`owedReplies`: it left a query in that tab's bytes to the client, and has not been
    /// answered for it yet), so a reply cannot be spent on a tab that asked nothing. With nothing owed —
    /// a query outside the counted set — it is held to the keystroke rule, exactly as before.
    ///
    /// This is what closes the window where the client's VISIBLE tab and the host's ACTIVE tab differ
    /// (a user switch the host has not processed; a host-opened tab whose `term-list` has not arrived):
    /// the host leaves every query that reached the client to the client, and the client's answer
    /// reaches the tab that asked whichever way the switch lands.
    /// SHAPED like a terminal's answer: exactly ONE complete sequence and nothing else — a CSI (`ESC [`,
    /// parameter and intermediate bytes, ONE final byte ending the message), an OSC (`ESC ]`, printable
    /// ASCII, ending in BEL or ST) or a DCS (`ESC P`, printable ASCII, ending in ST); no other ESC (zsh
    /// binds `ESC a` to accept-and-hold, so an ESC mid-message could run what precedes it), no other
    /// control byte, no byte >= 0x80 (a C1 CSI; every xterm.js answer is ASCII), at most `maxReplyBytes`.
    /// A credit admits nothing else, so "a credited reply cannot type a command line" is a property the
    /// host ENFORCES rather than one it assumes about the client.
    public static func isReplyShaped(_ b: [UInt8]) -> Bool {
        guard b.count >= 3, b.count <= maxReplyBytes, b[0] == 0x1b else { return false }
        let printable: (UInt8) -> Bool = { $0 >= 0x20 && $0 <= 0x7e }
        switch b[1] {
        case 0x5b:                                                     // CSI
            let body = b[2..<(b.count - 1)]
            return (0x40...0x7e).contains(b[b.count - 1]) && body.allSatisfy { (0x20...0x3f).contains($0) }
        case 0x5d, 0x50:                                               // OSC, DCS
            let st = b.count >= 4 && b[b.count - 2] == 0x1b && b[b.count - 1] == 0x5c
            let bel = b[1] == 0x5d && b[b.count - 1] == 0x07
            guard st || bel else { return false }
            return b[2..<(b.count - (st ? 2 : 1))].allSatisfy(printable)
        default:
            return false
        }
    }
    public static let maxReplyBytes = 256

    public static func shouldDeliverReply(named: TermTabID, activeTab: TermTabID?, owedReplies: Int,
                                          bytes: [UInt8], modes: TermModes) -> Bool {
        if owedReplies > 0, isReplyShaped(bytes) { return true }
        guard let activeTab else { return false }
        return shouldDeliver(named: named, activeTab: activeTab, bytes: bytes, modes: modes)
    }
}

