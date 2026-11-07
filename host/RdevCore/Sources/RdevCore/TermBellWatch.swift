import Foundation

/// THE BELL AS THE CLIENT'S xterm.js 6 RINGS IT (docs/terminal.md, "The bell") — for a `tmux:` tab, whose
/// bytes the host does not feed an emulator (a `pty:` tab's bell is SwiftTerm's own, `Terminal.onBell`;
/// `TermBellWatchTests` holds the two to the same answer on the corpus).
///
/// xterm.js EXECUTES a BEL — rings — in the ground state, the ESC state (and ESC + intermediates) and every
/// CSI state, where a C0 byte acts in place. It does NOT in a string: a BEL ENDS an OSC (a title's
/// `ESC ] 0 ; … BEL` is the commonest BEL in a stream, and no bell), is DATA inside a DCS, and is ignored in
/// SOS/PM/APC. So all this needs to know is whether a string is open, and which kind:
/// - an OSC, DCS, SOS, PM or APC opens from the ESC state (`ESC ]`, `ESC P`, `ESC X`, `ESC ^`, `ESC _`) or
///   from its C1 code point anywhere (U+009D, U+0090, U+0098, U+009E, U+009F — the bytes C2 9D …, read as
///   xterm.js reads the decoded stream);
/// - a string closes at ESC (which begins the next sequence), CAN or SUB (an abort), the C1 ST (U+009C), any
///   other C1 code point (xterm.js's "anywhere" rules: executed, back to ground), and — an OSC only — BEL.
///
/// The state rides between `feed` calls, so a sequence split across reads is followed. Not thread-safe: the
/// caller (TerminalManager) holds its lock.
public struct TermBellWatch: Sendable, Equatable {
    private enum State: Sendable, Equatable { case ground, esc, escInter, csi, osc, string }
    private var state: State = .ground
    /// The last byte was C2, the lead byte of a code point that may be a C1 control.
    private var lead = false

    public init() {}

    /// The stream was cut (tmux discarded a paused pane's output, a snapshot reseeded the tab): back to the
    /// ground state.
    public mutating func reset() { state = .ground; lead = false }

    /// Feed `bytes`; how many BELs xterm.js would ring in them.
    public mutating func feed(_ bytes: [UInt8]) -> Int {
        var rang = 0
        for b in bytes {
            if lead {
                lead = false
                if (0x80...0x9f).contains(b) { c1(b); continue }
            }
            switch b {
            case 0xC2: lead = true                                    // perhaps a C1 code point: decided next byte
            case 0x1b: state = .esc                                    // from anywhere: ends a string, restarts
            case 0x18, 0x1a: state = .ground                           // CAN, SUB: an abort
            case 0x07:
                switch state {
                case .osc: state = .ground                             // the OSC's terminator — no bell
                case .string: break                                    // DCS data, or ignored
                case .ground, .esc, .escInter, .csi: rang += 1         // executed in place
                }
            default:
                switch state {
                case .ground, .osc, .string: break
                case .esc:
                    switch b {
                    case 0x5b: state = .csi                            // [
                    case 0x5d: state = .osc                            // ]
                    case 0x50, 0x58, 0x5e, 0x5f: state = .string       // P X ^ _
                    case 0x20...0x2f: state = .escInter                // an intermediate: `ESC ( P` is no DCS
                    case 0x30...0x7e, 0x80...: state = .ground         // a final, or a code point that ends it
                    default: break                                     // C0 executed, DEL ignored
                    }
                case .escInter:
                    if (0x30...0x7e).contains(b) || b >= 0x80 { state = .ground }
                case .csi:
                    if (0x40...0x7e).contains(b) || b >= 0x80 { state = .ground }   // the final, or aborted
                }
            }
        }
        return rang
    }

    /// A C1 code point (U+0080…U+009F), wherever it lands.
    private mutating func c1(_ b: UInt8) {
        switch b {
        case 0x9b: state = .csi
        case 0x9d: state = .osc
        case 0x90, 0x98, 0x9e, 0x9f: state = .string
        default: state = .ground                                       // ST, or executed: back to ground
        }
    }
}
