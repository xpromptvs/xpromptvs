import XCTest
@testable import RdevCore

/// The host's emulator sees 8-bit C1 as the client's xterm.js does (docs/terminal.md, "8-bit C1").
/// SwiftTerm parses BYTES: U+009B (C2 9B) in the ground state is printed, a C2 inside an OSC is data and
/// its 9C then ends it, so SwiftTerm answered no C1 query and ended strings where xterm.js does not —
/// measured, a colour query ended by U+009C and followed later by any ESC was answered by xterm.js at
/// the ST and by SwiftTerm at the ESC: TWICE. `Terminal.feed` hands SwiftTerm each C1 code point as
/// the 7-bit sequence xterm.js's "anywhere" rule makes of it.
final class TermC1TranslationTests: XCTestCase {
    private let E = "\u{1b}"

    private func answers(_ s: String, split: Int? = nil) -> [String] {
        let t = Terminal(cols: 80, rows: 24)
        var out: [String] = []
        t.onRespond = { out.append(String(decoding: $0, as: UTF8.self)) }
        let bytes = Array("a\(s)b\u{1b}[m".utf8)
        if let split { t.feed(Array(bytes[..<split])); t.feed(Array(bytes[split...])) } else { t.feed(bytes) }
        return out
    }

    func testTheTranslation() {
        var c = C1Translator()
        XCTAssertEqual(c.translate([0xc2, 0x9b, 0x36, 0x6e]), [0x18, 0x1b, 0x5b, 0x36, 0x6e], "CSI: CAN ESC [")
        XCTAssertEqual(c.translate([0xc2, 0x9c]), [0x1b, 0x5c], "ST: ESC \\ — it ENDS a string, it does not abort it")
        XCTAssertEqual(c.translate([0xc2, 0x9d, 0xc2, 0x90]), [0x18, 0x1b, 0x5d, 0x18, 0x1b, 0x50])
        XCTAssertEqual(c.translate([0xc2, 0x84, 0xc2, 0x85, 0xc2, 0x88]), [0x18, 0x1b, 0x44, 0x18, 0x1b, 0x45, 0x18, 0x1b, 0x48],
                       "IND, NEL, HTS: the three C1 controls xterm.js executes")
        XCTAssertEqual(c.translate([0xc2, 0x98, 0xc2, 0x9e, 0xc2, 0x9f]), [0x18, 0x1b, 0x58, 0x18, 0x1b, 0x58, 0x18, 0x1b, 0x58],
                       "SOS, PM, APC: a string xterm.js ignores — SOS in SwiftTerm, never its APC handler")
        XCTAssertEqual(c.translate([0xc2, 0x80, 0xc2, 0x9a]), [0x18, 0x18], "every other C1: abort, execute nothing")
        XCTAssertEqual(c.translate(Array("é“§".utf8)), Array("é“§".utf8), "anything else is untouched")
        XCTAssertEqual(c.translate([0x41, 0xc2]), [0x41], "a lead byte at the end waits…")
        XCTAssertEqual(c.translate([0x9b]), [0x18, 0x1b, 0x5b], "…for the next feed")
        XCTAssertEqual(c.translate([0xc2]), [])
        XCTAssertEqual(c.translate([0xa7]), [0xc2, 0xa7])
        XCTAssertEqual(c.translate([0xc2, 0x41]), [0xc2, 0x41], "an invalid pair is passed as it is")
    }

    /// SwiftTerm now answers what xterm.js answers, where xterm.js acts on it — and never an OSC
    /// xterm.js drops.
    func testTheHostsEmulatorAnswersC1AsXtermJsDoes() {
        XCTAssertEqual(answers("\u{9b}6n"), ["\(E)[1;2R"])
        XCTAssertEqual(answers("\u{9b}c").count, 1)
        XCTAssertEqual(answers("\(E)\u{9b}6n").count, 1)
        XCTAssertEqual(answers("\(E)(\u{9b}6n").count, 1)
        XCTAssertEqual(answers("\u{9d}11;?\u{07}").count, 1)
        XCTAssertEqual(answers("\u{90}$qm\u{9c}"), ["\(E)P1$r0m\(E)\\"])
        XCTAssertEqual(answers("\(E)P$qm\u{9c}"), ["\(E)P1$r0m\(E)\\"], "the ST ends the DCS; its lead byte is not data")
        XCTAssertEqual(answers("\(E)]11;?\u{85}"), [], "a C1 control drops the OSC, as in xterm.js")
        XCTAssertEqual(answers("\(E)]11;?\u{9b}"), [])
        XCTAssertEqual(answers("\(E)]11;?\u{9d}11;?\u{07}").count, 1)
        for split in 1...8 {
            XCTAssertEqual(answers("\u{9b}6n", split: split).count, 1, "split at \(split)")
        }
    }
}
