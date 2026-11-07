import Foundation
import SwiftTerm

/// A `pty:` tab's emulator (SwiftTerm) → `TermSnapshot`, through the read-only accessors in
/// third_party/swiftterm/rdev_snapshot_access.swift. MUST be called on the thread that feeds the
/// terminal (TerminalManager holds its lock around both). Pure reading: nothing here mutates SwiftTerm.
enum SwiftTermSnapshot {
    static func capture(_ t: SwiftTerm.Terminal, title: String?) -> TermSnapshot {
        let (cols, rows) = t.getDims()
        let normal = buffer(t, t.rdevNormalBuffer, cols: cols, rows: rows, history: true)
        let alt = t.isCurrentBufferAlternate ? buffer(t, t.rdevAltBuffer, cols: cols, rows: rows, history: false) : nil
        let b = t.buffer
        var modes = TermSnapshotModes()
        modes.applicationCursor = t.applicationCursor
        modes.applicationKeypad = t.rdevApplicationKeypad
        modes.insert = t.rdevInsertMode
        modes.wraparound = t.rdevWraparound
        modes.reverseWraparound = t.rdevReverseWraparound
        modes.origin = t.rdevOriginMode
        modes.bracketedPaste = t.bracketedPasteMode
        modes.focusReporting = t.rdevSendFocus
        modes.mouse = mouse(t.mouseMode)
        switch t.rdevMouseEncoding {
        case .sgr: modes.mouseEncoding = .sgr
        case .sgrPixel: modes.mouseEncoding = .sgrPixels
        case .x10, .utf8, .urxvt: modes.mouseEncoding = .standard     // xterm.js implements neither of the last two
        }
        modes.synchronizedOutput = t.rdevSynchronizedOutput
        return TermSnapshot(
            cols: cols, rows: rows, normal: normal, alt: alt,
            cursor: TermCursor(x: min(b.x, cols), y: min(b.y, rows - 1), visible: !t.rdevCursorHidden, style: style(t.options.cursorStyle)),
            pen: attrs(t.rdevPen), modes: modes,
            charsets: TermCharsets(g: t.rdevCharsetDesignations, gl: t.rdevGLevel), title: title)
    }

    /// The text of the screen's last `count` rows, top to bottom: a blank cell a space, a wide glyph once.
    static func screenRows(_ t: SwiftTerm.Terminal, last count: Int) -> [String] {
        let (cols, rows) = t.getDims()
        let b = t.buffer
        let end = min(b.rdevYBase + rows, b.rdevLineCount)
        let start = max(b.rdevYBase, end - max(0, count))
        guard start < end else { return [] }
        return (start..<end).map { i in
            let l = b.rdevLine(i)
            var s = ""
            for x in 0..<min(cols, l.count) {
                let cd = l[x]
                if cd.width == 0 { continue }
                s += cd.rdevIsNull ? " " : String(t.getCharacter(for: cd))
            }
            return s
        }
    }

    /// `history` false (the alt buffer) reads only the screen: SwiftTerm's alt buffer has no scrollback.
    private static func buffer(_ t: SwiftTerm.Terminal, _ b: Buffer, cols: Int, rows: Int, history: Bool) -> TermBufferState {
        let end = min(b.rdevYBase + rows, b.rdevLineCount)
        let first = history ? max(0, end - (TermSnapshot.historyCap + rows)) : max(0, end - rows)
        let lines = (first..<end).map { line(t, b.rdevLine($0), cols: cols) }
        // x == cols is a DECSC taken in pending wrap: xterm.js saves (and restores) it as such.
        let saved = TermSavedCursor(x: min(b.savedX, cols), y: min(b.savedY, rows - 1), attrs: attrs(b.savedAttr),
                                    charset: t.rdevDesignation(of: b.savedCharset))
        return TermBufferState(lines: lines, scrollTop: b.scrollTop, scrollBottom: b.scrollBottom,
                               tabStops: b.rdevTabStops.prefix(cols).enumerated().filter(\.element).map(\.offset), savedCursor: saved)
    }

    private static func line(_ t: SwiftTerm.Terminal, _ l: BufferLine, cols: Int) -> TermLine {
        var cells: [TermCell] = []
        var x = 0
        let n = min(cols, l.count)
        while x < n {
            let cd = l[x]
            if cd.width == 0 { x += 1; continue }                         // a wide glyph's continuation
            let w = UInt8(min(2, max(1, Int(cd.width))))
            if cd.rdevIsNull {
                cells.append(TermCell(text: "", width: 1, attrs: TermAttrs(bg: color(cd.attribute.bg))))
                x += 1
            } else {
                cells.append(TermCell(text: String(t.getCharacter(for: cd)), width: w, attrs: attrs(cd.attribute)))
                x += Int(w)
            }
        }
        // Trailing cells that are erased AND carry nothing are not content: trim them, so a
        // never-written line is `[]` — `TermSnapshot.blank`'s — and a capture compares equal to any
        // other source of the same screen whatever either padded to. The emitter writes none of them.
        while let last = cells.last, last.text.isEmpty, last.attrs == TermAttrs() { cells.removeLast() }
        return TermLine(cells: cells, wrapped: l.rdevIsWrapped)
    }

    static func attrs(_ a: SwiftTerm.Attribute) -> TermAttrs {
        var o = TermAttrs()
        o.fg = color(a.fg); o.bg = color(a.bg)
        let s = a.style
        o.bold = s.contains(.bold); o.dim = s.contains(.dim); o.italic = s.contains(.italic)
        o.blink = s.contains(.blink); o.inverse = s.contains(.inverse); o.invisible = s.contains(.invisible)
        o.strikethrough = s.contains(.crossedOut)
        o.underline = a.underlineStyle != .none ? a.underlineStyle.rawValue : (s.contains(.underline) ? 1 : 0)
        o.underlineColor = a.underlineColor.map(color)
        return o
    }

    static func color(_ c: SwiftTerm.Attribute.Color) -> TermColor {
        switch c {
        case .ansi256(let n): return .palette(n)
        case .trueColor(let r, let g, let b): return .rgb(r, g, b)
        case .defaultColor, .defaultInvertedColor: return .default
        }
    }

    /// Not private: `Terminal.inputModes()` reads the same mapping directly, without building a whole
    /// `TermSnapshot` per keystroke batch.
    static func mouse(_ m: SwiftTerm.Terminal.MouseMode) -> TermModes.Mouse {
        switch m {
        case .off: return .off
        case .x10: return .x10
        case .vt200: return .vt200
        case .buttonEventTracking: return .buttonEvent
        case .anyEvent: return .anyEvent
        }
    }

    private static func style(_ s: CursorStyle) -> TermCursorStyle {
        switch s {
        case .blinkBlock: return .blinkBlock
        case .steadyBlock: return .steadyBlock
        case .blinkUnderline: return .blinkUnderline
        case .steadyUnderline: return .steadyUnderline
        case .blinkBar: return .blinkBar
        case .steadyBar: return .steadyBar
        }
    }
}
