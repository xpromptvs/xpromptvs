import Foundation

// READ-ONLY views of SwiftTerm state that rdev's terminal serializer needs
// (host/RdevCore/Sources/RdevCore/SwiftTermSnapshot.swift). Compiled INTO module SwiftTerm by
// //third_party/swiftterm:SwiftTerm, so internal members are reachable; the five private ones read
// here are widened to internal by rdev-snapshot-access.patch. Nothing here writes. Every accessor
// has a test in Tests/SwiftTermAccessorTests.swift.

/// `?1006` / `?1016` and the two encodings xterm.js no longer implements.
public enum RdevMouseEncoding: Equatable, Sendable { case x10, utf8, sgr, urxvt, sgrPixel }

extension Terminal {
    public var rdevNormalBuffer: Buffer { normalBuffer }
    public var rdevAltBuffer: Buffer { altBuffer }
    public var rdevCursorHidden: Bool { cursorHidden }
    public var rdevOriginMode: Bool { originMode }
    public var rdevWraparound: Bool { wraparound }
    public var rdevReverseWraparound: Bool { reverseWraparound }
    public var rdevInsertMode: Bool { insertMode }
    public var rdevApplicationKeypad: Bool { applicationKeypad }
    public var rdevSendFocus: Bool { sendFocus }
    /// `?2026` is on: an update is in progress (SwiftTerm ends it after 1 s on its own).
    public var rdevSynchronizedOutput: Bool { synchronizedOutputActive }
    /// The attributes the next printed character gets.
    public var rdevPen: Attribute { curAttr }

    public var rdevMouseEncoding: RdevMouseEncoding {
        switch mouseProtocol {
        case .x10: return .x10
        case .utf8: return .utf8
        case .sgr: return .sgr
        case .urxvt: return .urxvt
        case .sgrPixel: return .sgrPixel
        }
    }

    /// G0–G3 as the final byte that designated them (`0` DEC graphics, `A` UK, …); nil = US ASCII.
    public var rdevCharsetDesignations: [UInt8?] { gCharsets.map { rdevDesignation(of: $0) } }
    /// Which of G0–G3 is invoked into GL (SI = 0, SO = 1, LS2 = 2, LS3 = 3).
    public var rdevGLevel: Int { Int(gLevel) }

    /// The final byte whose table is `charset` (the smallest, if two designations share a table).
    /// US ASCII is nil in BOTH its forms: a fresh G is nil, and `ESC ( B` stores an EMPTY table.
    public func rdevDesignation(of charset: [UInt8: String]?) -> UInt8? {
        guard let charset, !charset.isEmpty else { return nil }
        return CharSets.all.filter { $0.value == charset }.map(\.key).min()
    }
}

extension Buffer {
    /// Lines held: history + the visible rows (the screen is `rdevYBase ..< rdevYBase + rows`).
    public var rdevLineCount: Int { lines.count }
    /// Rows of history above the screen.
    public var rdevYBase: Int { yBase }
    public func rdevLine(_ i: Int) -> BufferLine { lines[i] }
    public var rdevTabStops: [Bool] { tabStops }
}

extension BufferLine {
    /// This line CONTINUES the previous one (xterm.js semantics).
    public var rdevIsWrapped: Bool { isWrapped }
}

extension CharData {
    /// Never written (or erased): xterm.js's empty cell, as opposed to a written space.
    public var rdevIsNull: Bool { code == 0 }
}

extension Terminal {
    /// The columns ONE scalar takes on its own, as SwiftTerm's printing path counts it (0 for a mark or
    /// a format character, -1 for a control). What joins a grapheme is decided in `Terminal.feed`; this
    /// is the table under it, which protocol/fixtures/term-widths.json carries to the client's
    /// xterm.js (web/src/client/term-unicode.ts).
    public static func rdevColumnWidth(_ scalar: UnicodeScalar) -> Int { UnicodeUtil.columnWidth(rune: scalar) }
}

extension Terminal {
    /// Tests only (fix 10): no OSC body is being held between feeds — an oversized one was discarded,
    /// not kept growing.
    public var rdevOscBodyIsEmptyForTests: Bool { parser._osc.isEmpty }

    /// Tests only (fix 11): how many parameters, separators and intermediates the parser is holding for
    /// the sequence in progress.
    public var rdevParserHeldForTests: (pars: Int, parsTxt: Int, collect: Int) {
        (parser._pars.count, parser._parsTxt.count, parser._collect.count)
    }
}
