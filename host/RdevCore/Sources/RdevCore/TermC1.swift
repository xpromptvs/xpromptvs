import Foundation

/// 8-bit C1 AS THE CLIENT'S xterm.js READS IT, for the host's SwiftTerm (docs/terminal.md, "8-bit C1").
///
/// xterm.js 6 parses the CODE POINTS its UTF-8 decoder yields, and U+0080-U+009F (bytes C2 80-C2 9F)
/// are C1 controls in EVERY parser state (`EscapeSequenceParser`'s "anywhere" rules): U+009B, U+009D,
/// U+0090 begin a CSI, OSC, DCS — dropping any sequence in progress, an OSC or DCS never answered —
/// U+009C is ST, U+0098/9E/9F begin a string it ignores, IND/NEL/HTS execute, the rest abort. SwiftTerm
/// parses BYTES: a C2 in the ground state prints the pair as a character, and inside a string the C2 is
/// data and the 9C that follows ENDS it — so SwiftTerm answered no C1 query, and a colour query ended
/// by U+009C was answered by xterm.js at the ST and by SwiftTerm at the next ESC (MEASURED, both). So
/// SwiftTerm is handed each C1 code point as the 7-bit sequence that has the same effect on it: ST as
/// `ESC \`, everything else behind a CAN, which ends any sequence in progress WITHOUT dispatching it.
///
/// A lead byte at the end of a feed waits for the next one. Continuation bytes 0x80-0x9F that belong
/// to other characters (“ is E2 80 9C) are untouched — and SwiftTerm still reads those as C1 inside a
/// sequence (docs/terminal.md lists what that leaves).
public struct C1Translator: Sendable {
    private var lead = false

    public init() {}

    public mutating func translate(_ bytes: [UInt8]) -> [UInt8] {
        if !lead && !bytes.contains(0xC2) { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 8)
        var i = 0
        if lead {
            guard let f = bytes.first else { return [] }
            lead = false
            if (0x80...0x9f).contains(f) { out += Self.sevenBit(f); i = 1 } else { out.append(0xC2) }
        }
        while i < bytes.count {
            let c = bytes[i]
            if c == 0xC2 {
                guard i + 1 < bytes.count else { lead = true; break }
                if (0x80...0x9f).contains(bytes[i + 1]) { out += Self.sevenBit(bytes[i + 1]); i += 2; continue }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static let ESC: UInt8 = 0x1b, CAN: UInt8 = 0x18

    /// The 7-bit form of the C1 control `c` (0x80-0x9F), as it acts in xterm.js 6.
    static func sevenBit(_ c: UInt8) -> [UInt8] {
        switch c {
        case 0x9c: return [ESC, 0x5c]                          // ST: ENDS a string (answered)
        case 0x9b: return [CAN, ESC, 0x5b]                     // CSI
        case 0x9d: return [CAN, ESC, 0x5d]                     // OSC
        case 0x90: return [CAN, ESC, 0x50]                     // DCS
        case 0x98, 0x9e, 0x9f: return [CAN, ESC, 0x58]         // SOS/PM/APC: ignored — never SwiftTerm's APC handler
        case 0x84: return [CAN, ESC, 0x44]                     // IND
        case 0x85: return [CAN, ESC, 0x45]                     // NEL
        case 0x88: return [CAN, ESC, 0x48]                     // HTS
        default: return [CAN]                                  // executes nothing; aborts what was in progress
        }
    }
}
