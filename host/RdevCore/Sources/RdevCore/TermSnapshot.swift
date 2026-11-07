import Foundation

/// A terminal's STATE, as xterm.js 6 keeps it — what a fresh client instance must become to be
/// indistinguishable from one that saw every byte (docs/terminal.md, "Serialized state"). Two
/// pipelines produce it (`SwiftTermSnapshot` for `pty:` tabs, `TmuxSnapshot` for `tmux:` tabs) and
/// one emitter turns it into bytes (`TermSnapshotEmitter`). Pure and `Equatable`: the round trip
/// snapshot → emit → feed → snapshot is a test, not a hope.
///
/// KNOWN LIMITS of the model and its emission (for docs/terminal.md, "Known limits"):
/// - A palette colour 0–15 is emitted in its SHORT form (`30–37`/`90–97`, P16) even when the app wrote
///   `38;5;n` (P256): SwiftTerm does not keep the distinction. Under xterm.js's
///   `drawBoldTextInBrightColors`, BOLD + a P16 colour 0–7 renders in the bright variant where the
///   P256 original did not.
/// - DECSC (`TermSavedCursor`) saves only fg/bg of the pen in xterm.js, not underline style or
///   underline colour; a saved pen carrying them is restored without them on the client either way.
/// - An erased tail on a line the next one continues is written as SPACES (the wrap flag needs a write
///   into the last column), and so is the padding of a short line before a continuation.
public enum TermColor: Hashable, Sendable {
    case `default`
    /// 0–255. 0–15 are emitted as `30–37/90–97` (SwiftTerm does not keep the P16/P256 distinction).
    case palette(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TermAttrs: Hashable, Sendable {
    public var fg: TermColor = .default
    public var bg: TermColor = .default
    public var bold = false
    public var dim = false
    public var italic = false
    public var blink = false
    public var inverse = false
    public var invisible = false
    public var strikethrough = false
    /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed (`SGR 4:n`).
    public var underline: UInt8 = 0
    public var underlineColor: TermColor? = nil
    public init() {}
    /// What an ERASED cell carries in xterm.js: the background of the pen that erased it, nothing else.
    public init(bg: TermColor) { self.bg = bg }
}

/// One cell as a writer sees it: a grapheme (or "" for a cell never written / erased) and its width.
/// A wide glyph's continuation cell is not stored — it is implied by `width == 2`.
public struct TermCell: Equatable, Sendable {
    public var text: String
    public var width: UInt8
    public var attrs: TermAttrs
    public init(text: String, width: UInt8, attrs: TermAttrs) { self.text = text; self.width = width; self.attrs = attrs }
}

public struct TermGlyph: Equatable, Sendable {
    public var text: String
    public var width: UInt8
}

public struct TermRun: Equatable, Sendable {
    public var attrs: TermAttrs
    public var glyphs: [TermGlyph]
}

public struct TermLine: Equatable, Sendable {
    public var runs: [TermRun]
    /// This line CONTINUES the previous one (xterm.js / SwiftTerm `isWrapped`).
    public var wrapped: Bool

    public init(cells: [TermCell], wrapped: Bool = false) {
        var runs: [TermRun] = []
        for c in cells {
            let g = TermGlyph(text: c.text, width: c.width)
            if let last = runs.indices.last, runs[last].attrs == c.attrs { runs[last].glyphs.append(g) }
            else { runs.append(TermRun(attrs: c.attrs, glyphs: [g])) }
        }
        self.runs = runs
        self.wrapped = wrapped
    }

    public var cells: [TermCell] {
        runs.flatMap { r in r.glyphs.map { TermCell(text: $0.text, width: $0.width, attrs: r.attrs) } }
    }

    /// Columns the line occupies.
    public var width: Int { runs.reduce(0) { $0 + $1.glyphs.reduce(0) { $0 + Int($1.width) } } }
}

/// DECSC's slot. xterm.js saves position, pen and the GL charset (not origin mode), per buffer.
public struct TermSavedCursor: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var attrs: TermAttrs
    /// The GL charset at save time, as its designation byte; nil = US ASCII.
    public var charset: UInt8?
    public init(x: Int = 0, y: Int = 0, attrs: TermAttrs = TermAttrs(), charset: UInt8? = nil) {
        self.x = x; self.y = y; self.attrs = attrs; self.charset = charset
    }
}

public struct TermBufferState: Equatable, Sendable {
    /// Oldest first. Normal buffer: history then the `rows` visible lines. Alt buffer: `rows` lines.
    public var lines: [TermLine]
    /// The scroll region, 0-based inclusive rows.
    public var scrollTop: Int
    public var scrollBottom: Int
    public var tabStops: [Int]
    public var savedCursor: TermSavedCursor
    public init(lines: [TermLine], scrollTop: Int, scrollBottom: Int, tabStops: [Int], savedCursor: TermSavedCursor) {
        self.lines = lines; self.scrollTop = scrollTop; self.scrollBottom = scrollBottom
        self.tabStops = tabStops; self.savedCursor = savedCursor
    }
}

/// DECSCUSR's parameter.
public enum TermCursorStyle: Int, Equatable, Sendable {
    case blinkBlock = 1, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar
}

public struct TermCursor: Equatable, Sendable {
    /// `x == cols` is the pending-wrap state (the last column was written; the next glyph wraps).
    public var x: Int
    /// Row on the active buffer's SCREEN, 0-based, absolute (not region-relative).
    public var y: Int
    public var visible: Bool
    public var style: TermCursorStyle
    public init(x: Int, y: Int, visible: Bool, style: TermCursorStyle) { self.x = x; self.y = y; self.visible = visible; self.style = style }
}

public struct TermCharsets: Equatable, Sendable {
    /// G0–G3 designation bytes; nil = US ASCII.
    public var g: [UInt8?]
    /// Which of G0–G3 is in GL.
    public var gl: Int
    public init(g: [UInt8?] = [nil, nil, nil, nil], gl: Int = 0) { self.g = g; self.gl = gl }
}

/// Every DEC/ANSI mode xterm.js honours that a snapshot must restate.
public struct TermSnapshotModes: Equatable, Sendable {
    public var applicationCursor = false          // ?1
    public var applicationKeypad = false          // ESC = / ESC >
    public var insert = false                     // IRM, CSI 4 h
    public var wraparound = true                  // ?7
    public var reverseWraparound = false          // ?45
    public var origin = false                     // ?6
    public var bracketedPaste = false             // ?2004
    public var focusReporting = false             // ?1004
    public var mouse: TermModes.Mouse = .off      // ?9 / ?1000 / ?1002 / ?1003
    public var mouseEncoding: TermModes.MouseEncoding = .standard   // ?1006 / ?1016
    public var synchronizedOutput = false         // ?2026 — an update is in progress
    public init() {}
}

public struct TermSnapshot: Equatable, Sendable {
    /// History kept and restored — the client's xterm.js `scrollback`.
    public static let historyCap = 5000

    public var cols: Int
    public var rows: Int
    public var normal: TermBufferState
    /// Present only while the app is on the alternate screen.
    public var alt: TermBufferState?
    public var cursor: TermCursor
    /// The attributes the next printed character gets.
    public var pen: TermAttrs
    public var modes: TermSnapshotModes
    public var charsets: TermCharsets
    /// Not rendered by the emitter — titles stay on `term-list`.
    public var title: String?

    public init(cols: Int, rows: Int, normal: TermBufferState, alt: TermBufferState?, cursor: TermCursor,
                pen: TermAttrs, modes: TermSnapshotModes, charsets: TermCharsets, title: String?) {
        self.cols = cols; self.rows = rows; self.normal = normal; self.alt = alt; self.cursor = cursor
        self.pen = pen; self.modes = modes; self.charsets = charsets; self.title = title
    }

    public var activeIsAlt: Bool { alt != nil }

    /// The active buffer's visible rows (the last `rows` lines).
    public var screen: [TermLine] { Array((alt ?? normal).lines.suffix(rows)) }

    public static func defaultTabStops(cols: Int) -> [Int] { Array(stride(from: 0, to: cols, by: 8)) }

    /// What a fresh terminal of this size is.
    public static func blank(cols: Int, rows: Int) -> TermSnapshot {
        let buffer = TermBufferState(lines: Array(repeating: TermLine(cells: []), count: rows), scrollTop: 0,
                                     scrollBottom: rows - 1, tabStops: defaultTabStops(cols: cols), savedCursor: TermSavedCursor())
        return TermSnapshot(cols: cols, rows: rows, normal: buffer, alt: nil,
                            cursor: TermCursor(x: 0, y: 0, visible: true, style: .blinkBlock),
                            pen: TermAttrs(), modes: TermSnapshotModes(), charsets: TermCharsets(), title: nil)
    }
}

extension TermSnapshot {
    /// **SCROLLBACK COMES AFTER THE SCREEN** (docs/terminal.md): a capture with more than this many lines of history
    /// goes as its SCREEN first, its full self following as the late history. A smaller one goes whole, as before.
    public static let lateHistoryLines = 200

    /// This capture's SCREEN alone — the normal buffer trimmed to its last `rows` lines, as the offer's preview is
    /// (`TerminalManager.captureScreen`); the alt buffer, the modes and the cursor as they are — when its history is
    /// worth sending later; nil when it goes whole. A first row that continues a history line is written as a row of
    /// its own (its wrap flag unset): only the screen instance shows it, and the full snapshot replaces that.
    public var screenForLateHistory: TermSnapshot? {
        guard normal.lines.count > rows + Self.lateHistoryLines else { return nil }
        var screen = self
        screen.normal.lines = Array(normal.lines.suffix(rows))
        return screen
    }
}

