import XCTest
@testable import RdevCore

/// THE BELL AS xterm.js RINGS IT (`TermBellWatch`; docs/terminal.md, "The bell"): a BEL the parser
/// EXECUTES — in the ground state, the ESC state or a CSI — and never one that ends an OSC, nor one inside a
/// DCS or SOS/PM/APC string. A tmux tab's bytes are WITHHELD from the client while it is hidden, so the host
/// must find its bells itself, and must find exactly the ones the client's xterm.js would have rung.
final class TermBellWatchTests: XCTestCase {
    /// (A Swift `"\u{9d}"` is the CODE POINT U+009D — the bytes C2 9D, as a UTF-8 stream carries it.)
    private func bells(_ chunks: [String]) -> Int {
        var w = TermBellWatch()
        return chunks.reduce(0) { $0 + w.feed(Array($1.utf8)) }
    }
    private func bells(_ s: String) -> Int { bells([s]) }

    func testABareBELRings() {
        XCTAssertEqual(bells("done\u{07}"), 1)
        XCTAssertEqual(bells("\u{07}\u{07}x\u{07}"), 3)
        XCTAssertEqual(bells("no bell here"), 0)
    }

    /// The commonest BEL in a stream is NOT a bell: the terminator of a title (`ESC ] 0 ; … BEL`).
    func testABELThatEndsAnOSCDoesNotRing() {
        XCTAssertEqual(bells("\u{1b}]0;my title\u{07}"), 0)
        XCTAssertEqual(bells("\u{1b}]2;a\u{07}\u{07}"), 1, "the second BEL is in the ground state again")
        XCTAssertEqual(bells("\u{9d}0;c1 title\u{07}"), 0, "a C1 OSC (U+009D) too")
        XCTAssertEqual(bells("\u{1b}]0;st\u{1b}\\\u{07}"), 1, "ended by ST, then a bell")
        XCTAssertEqual(bells("\u{1b}]0;c1st\u{9c}\u{07}"), 1, "ended by a C1 ST, then a bell")
    }

    func testAnOSCSplitAcrossReadsStillOwnsItsBEL() {
        XCTAssertEqual(bells(["\u{1b}", "]0;ti", "tle", "\u{07}", "\u{07}"]), 1)
        var w = TermBellWatch()                              // U+009D is C2 9D: split between its two bytes
        XCTAssertEqual(w.feed([0xC2]) + w.feed([0x9D] + Array("0;x\u{07}".utf8)), 0, "a C1 introducer split between its two bytes")
    }

    /// The ESC state and a CSI EXECUTE a C0 byte in place (xterm.js's table) — a BEL there rings.
    func testABELInsideACSIOrAfterAnESCRings() {
        XCTAssertEqual(bells("\u{1b}[1\u{07}m"), 1)
        XCTAssertEqual(bells("\u{1b}\u{07}[m"), 1)
        XCTAssertEqual(bells("\u{1b}(\u{07}B"), 1, "ESC + intermediate, then the BEL")
    }

    /// Inside a DCS a BEL is DATA, and SOS/PM/APC ignore it: neither ends the string, neither rings.
    func testABELInsideADCSOrAnAPCIsNotABell() {
        XCTAssertEqual(bells("\u{1b}P1$q\u{07}m\u{1b}\\"), 0)
        XCTAssertEqual(bells("\u{1b}_G a\u{07}b\u{1b}\\"), 0)
        XCTAssertEqual(bells("\u{1b}^pm\u{07}\u{1b}\\\u{07}"), 1)
    }

    /// CAN and SUB abort a string; ESC ends it and begins the next sequence.
    func testAnAbortedStringReturnsToTheGroundState() {
        XCTAssertEqual(bells("\u{1b}]0;x\u{18}\u{07}"), 1)
        XCTAssertEqual(bells("\u{1b}Pq\u{1a}\u{07}"), 1)
        XCTAssertEqual(bells("\u{1b}]0;x\u{1b}[m\u{07}"), 1)
    }

    /// A C1 code point acts wherever it appears (xterm.js's "anywhere" rules): one that is no introducer
    /// ends a string as it does a CSI.
    func testAC1ControlEndsAString() {
        XCTAssertEqual(bells("\u{1b}]0;x\u{85}\u{07}"), 1, "NEL ends the OSC")
        XCTAssertEqual(bells("\u{90}1$q\u{07}\u{9c}\u{07}"), 1, "a C1 DCS holds its BEL; the C1 ST ends it")
    }

    func testResetForgetsAnOpenString() {
        var w = TermBellWatch()
        XCTAssertEqual(w.feed(Array("\u{1b}]0;x".utf8)), 0)
        w.reset()
        XCTAssertEqual(w.feed([0x07]), 1, "the stream was cut: a BEL after it is the ground state's")
    }

    // MARK: - against the host's own emulator

    /// DIFFERENTIAL: SwiftTerm is the xterm.js parser ported (and the host feeds it 7-bit forms of C1,
    /// `C1Translator`), so a `pty:` tab's bell — read off SwiftTerm — and a `tmux:` tab's — read off this
    /// watch — must agree, byte for byte, chunked anyhow.
    func testTheWatchRingsExactlyWhereSwiftTermDoes() throws {
        var cases: [[UInt8]] = [
            "done\u{07}", "\u{1b}]0;t\u{07}x\u{07}", "\u{1b}[3\u{07}1m", "\u{1b}P1$q\u{07}\u{1b}\\\u{07}",
            "\u{9d}0;x\u{07}\u{07}", "\u{1b}]0;x\u{18}\u{07}", "\u{1b}_x\u{07}\u{1b}\\\u{07}",
            "\u{1b}]0;x\u{85}\u{07}", "\u{1b}#\u{07}8", "\u{1b}]0;\u{1b}[\u{07}m", "a\u{07}\u{1b}]8;;u\u{07}l\u{1b}]8;;\u{07}\u{07}",
        ].map { Array($0.utf8) }
        let corpus = Self.fixtures.appendingPathComponent("term-corpus")
        for name in try FileManager.default.contentsOfDirectory(atPath: corpus.path) where name.hasSuffix(".bin") {
            cases.append([UInt8](try Data(contentsOf: corpus.appendingPathComponent(name))))
        }
        XCTAssertGreaterThan(cases.count, 30)
        var nonZero = 0
        for bytes in cases {
            let term = Terminal(cols: 80, rows: 24)
            var swift = 0
            term.onBell = { swift += 1 }
            term.feed(bytes)
            // Chunked at every 7 bytes: the watch's state must ride between reads.
            var w = TermBellWatch(), mine = 0
            var i = 0
            while i < bytes.count { mine += w.feed(Array(bytes[i..<min(i + 7, bytes.count)])); i += 7 }
            XCTAssertEqual(mine, swift, String(decoding: bytes.prefix(80), as: UTF8.self).debugDescription)
            if swift > 0 { nonZero += 1 }
        }
        XCTAssertGreaterThan(nonZero, 4, "the comparison is not vacuous: SwiftTerm rang in several cases")
    }

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures")
}
