import Foundation
import SwiftTerm

/// `TermSnapshot` → bytes that make a FRESH xterm.js instance, already sized to `cols × rows`, into
/// that state. The order is the spec's (docs/superpowers/specs/2026-09-26-terminal-serializer-design.md)
/// with refinements the differential check and a review against xterm.js 6.0.0 forced: the NORMAL
/// buffer's saved cursor is stood on before `?1049h` (which saves into that slot); G0/GL go back to
/// ASCII right after every DECSC and the real charsets are designated only AFTER the pending-wrap
/// rewrite (a glyph rewritten under DEC graphics would be remapped, `a` → `▒`); the alt screen is
/// erased with the default pen after `?1049h` (which fills it with the stance's background); a
/// continuation that starts erased forces its wrap with a written space (CUF/ECH clamp a pending-wrap
/// x onto the previous row's last cell); a short line before a continuation is padded to `cols`; the
/// row a continuation wraps into is re-erased with the default pen when the wrap-time pen had a
/// background (a scrolling wrap fills it with that); a saved cursor at x == cols (DECSC in pending
/// wrap) is stood on the way the live one is, by rewriting its row's last glyph; and the pen is
/// restated last.
///
/// Not written, on purpose: the title (it stays on `term-list`), hyperlinks, palette changes, images.
public enum TermSnapshotEmitter {

    public static func emit(_ s: TermSnapshot) -> [UInt8] {
        var o = Out()
        o.csi("!p"); o.csi("?7h")                              // autowrap ON until the end: the line writes,
                                                               // the ?45 statement and the pending-wrap rewrite need it
        o.normalLines(s.normal.lines, cols: s.cols)
        o.region(s.normal, rows: s.rows)
        o.tabStops(s.normal.tabStops, cols: s.cols)
        if let alt = s.alt {
            // ?1049h saves the cursor into the NORMAL buffer's slot: stand where it was saved.
            o.stand(s.normal.savedCursor, cols: s.cols, rows: s.rows, screen: s.normal.lines.suffix(s.rows))
            o.csi("?1049h")
            o.resetPen()                                        // the stance's pen must not colour the alt rows,
            o.asciiGL()                                         // nor its charset map them
            o.csi("H"); o.csi("2J")                             // ?1049h filled the screen with the stance's bg
            o.altRows(alt.lines, cols: s.cols)
            o.region(alt, rows: s.rows)
            o.tabStops(alt.tabStops, cols: s.cols)
            o.stand(alt.savedCursor, cols: s.cols, rows: s.rows, screen: alt.lines.suffix(s.rows)); o.esc("7"); o.asciiGL()
        } else {
            o.stand(s.normal.savedCursor, cols: s.cols, rows: s.rows, screen: s.normal.lines.suffix(s.rows)); o.esc("7"); o.asciiGL()
        }
        o.modes(s.modes, cursor: s.cursor)
        o.cursor(s)
        o.charsets(s.charsets)
        o.csi(s.modes.insert ? "4h" : "4l")
        o.csi(s.modes.wraparound ? "?7h" : "?7l")
        o.setPen(s.pen)
        if s.modes.synchronizedOutput { o.csi("?2026h") }
        return o.bytes
    }

    // MARK: SGR

    /// The full statement, starting from a reset: `0;…`.
    public static func sgr(_ a: TermAttrs) -> String { (["0"] + params(a)).joined(separator: ";") }

    /// The shortest parameter list taking `from` to `to`, or nil when they are equal. Anything turned
    /// OFF is restated in full — `22` alone would drop bold AND dim, and per-flag offs are a zoo.
    public static func sgrDelta(from a: TermAttrs, to b: TermAttrs) -> String? {
        if a == b { return nil }
        let offs = (a.bold && !b.bold) || (a.dim && !b.dim) || (a.italic && !b.italic) || (a.blink && !b.blink)
            || (a.inverse && !b.inverse) || (a.invisible && !b.invisible) || (a.strikethrough && !b.strikethrough)
            || (a.underline != 0 && b.underline == 0)
            || (a.fg != .default && b.fg == .default) || (a.bg != .default && b.bg == .default)
            || (a.underlineColor != nil && b.underlineColor == nil)
        if offs { return sgr(b) }
        var p: [String] = []
        if b.bold && !a.bold { p.append("1") }
        if b.dim && !a.dim { p.append("2") }
        if b.italic && !a.italic { p.append("3") }
        if b.underline != a.underline { p.append(underline(b.underline)) }
        if b.blink && !a.blink { p.append("5") }
        if b.inverse && !a.inverse { p.append("7") }
        if b.invisible && !a.invisible { p.append("8") }
        if b.strikethrough && !a.strikethrough { p.append("9") }
        if b.fg != a.fg { p.append(color(b.fg, base: 30)) }
        if b.bg != a.bg { p.append(color(b.bg, base: 40)) }
        if b.underlineColor != a.underlineColor, let c = b.underlineColor { p.append(color(c, base: 50)) }
        return p.joined(separator: ";")
    }

    static func params(_ a: TermAttrs) -> [String] {
        var p: [String] = []
        if a.bold { p.append("1") }
        if a.dim { p.append("2") }
        if a.italic { p.append("3") }
        if a.underline != 0 { p.append(underline(a.underline)) }
        if a.blink { p.append("5") }
        if a.inverse { p.append("7") }
        if a.invisible { p.append("8") }
        if a.strikethrough { p.append("9") }
        if a.fg != .default { p.append(color(a.fg, base: 30)) }
        if a.bg != .default { p.append(color(a.bg, base: 40)) }
        if let c = a.underlineColor { p.append(color(c, base: 50)) }
        return p
    }

    private static func underline(_ n: UInt8) -> String { n == 1 ? "4" : "4:\(n)" }

    /// base 30 = foreground, 40 = background, 50 = underline colour (`58`, which has no short forms).
    private static func color(_ c: TermColor, base: Int) -> String {
        switch c {
        case .default: return "\(base + 9)"
        case .palette(let n) where n < 8 && base != 50: return "\(base + Int(n))"
        case .palette(let n) where n < 16 && base != 50: return "\(base + 60 + Int(n) - 8)"
        case .palette(let n): return "\(base + 8);5;\(n)"
        case .rgb(let r, let g, let b): return "\(base + 8);2;\(r);\(g);\(b)"
        }
    }

    // MARK: the writer

    private struct Out {
        var bytes: [UInt8] = []
        var pen = TermAttrs()                       // DECSTR leaves the pen at the default
        /// The last thing written, when it was a GLYPH with nothing after it: the next may join it.
        var lastGlyph: String? = nil

        /// Anything but a glyph: a sequence or a control ends what the next glyph could join.
        mutating func raw(_ s: String) { bytes += Array(s.utf8); lastGlyph = nil }

        /// A glyph (or a run of spaces). One that would JOIN the glyph written just before it — nothing
        /// between them, and together one grapheme, or the previous ends in a ZWJ (the client's grapheme
        /// rules join any pictograph after one) — is kept apart with a NUL. The capture holds them as
        /// two cells because they did NOT join where the app wrote them (a sequence came between:
        /// docs/terminal.md, "Glyph widths"). A ZERO-WIDTH scalar always counts as joining — the client
        /// folds any of them into the previous cell (ZWSP too, which Swift's rules would not join) —
        /// so an orphan one written by SwiftTerm as its own column is kept apart as well. Both
        /// emulators execute NUL as nothing, and a control ends a join in both.
        mutating func glyph(_ text: String) {
            if let prev = lastGlyph, let first = text.unicodeScalars.first,
               (prev + text).count < prev.count + text.count || prev.unicodeScalars.last?.value == 0x200D
                || SwiftTerm.Terminal.rdevColumnWidth(first) == 0 {
                bytes.append(0)
            }
            bytes += Array(text.utf8)
            lastGlyph = text
        }
        mutating func csi(_ s: String) { raw("\u{1b}[" + s) }
        mutating func esc(_ s: String) { raw("\u{1b}" + s) }
        mutating func cup(_ y: Int, _ x: Int) { csi("\(y + 1);\(x + 1)H") }

        mutating func setPen(_ a: TermAttrs) {
            guard let d = TermSnapshotEmitter.sgrDelta(from: pen, to: a) else { return }
            csi(d + "m"); pen = a
        }
        mutating func resetPen() { if pen != TermAttrs() { csi("0m"); pen = TermAttrs() } }

        /// Oldest first; CRLF between lines that are not continued, none after the last. A line the
        /// NEXT one continues is written to exactly `cols` cells with no CRLF, so xterm.js wraps it and
        /// sets the continuation's wrap flag itself — the only way to set that flag.
        mutating func normalLines(_ lines: [TermLine], cols: Int) {
            var continued = false
            for (i, l) in lines.enumerated() {
                let next = i + 1 < lines.count ? lines[i + 1] : nil
                let continues = (next?.wrapped ?? false) && l.width <= cols
                line(l, cols: cols, continued: continued, continues: continues, nextStartsWide: next?.cells.first?.width == 2)
                if next != nil, !continues { resetPen(); raw("\r\n") }
                continued = continues
            }
        }

        /// Each row by ABSOLUTE position (nothing scrolls), except a continuation, which the previous
        /// row's exact-width write wraps into.
        mutating func altRows(_ lines: [TermLine], cols: Int) {
            var continued = false
            for (r, l) in lines.enumerated() {
                if !continued { cup(r, 0) }
                let next = r + 1 < lines.count ? lines[r + 1] : nil
                let continues = (next?.wrapped ?? false) && l.width <= cols
                line(l, cols: cols, continued: continued, continues: continues, nextStartsWide: next?.cells.first?.width == 2)
                continued = continues
            }
            resetPen()
        }

        /// `continued`: the previous line was written to exactly `cols`, so xterm.js is in PENDING WRAP
        /// and this line's first WRITE performs the wrap. `continues`: the next line continues this one.
        mutating func line(_ l: TermLine, cols: Int, continued: Bool, continues: Bool, nextStartsWide: Bool) {
            var cells = l.cells
            if continues {
                // A SHORT line the next one continues is padded with erased cells, so the next write
                // wraps instead of landing on this row. (A reflow can leave one; the tail then goes out
                // as spaces, the known limit below.)
                let width = l.width
                if width < cols { cells += Array(repeating: TermCell(text: "", width: 1, attrs: TermAttrs()), count: cols - width) }
                // A wide glyph that did not fit left ONE erased cell: xterm.js's own wrap of that glyph
                // (the next line's first) fills it exactly as it was.
                if nextStartsWide, cells.last?.text == "" { cells.removeLast() }
            } else {
                while let last = cells.last, last.text.isEmpty, last.attrs.bg == .default { cells.removeLast() }
            }
            var wrapPending = continued
            // The first write after a pending wrap performs it, and a wrap that SCROLLS fills the new row
            // with the pen's background (BufferService.scroll(eraseAttr)). Erase the rest of the row with
            // the default pen, unless that write itself reached the last column.
            func wrapped(_ o: inout Out, width: Int) {
                guard wrapPending else { return }
                wrapPending = false
                if o.pen.bg != .default, width < cols { o.resetPen(); o.csi("K") }
            }
            if continued, cells.isEmpty { cells = [TermCell(text: "", width: 1, attrs: TermAttrs())] }
            var i = 0
            while i < cells.count {
                let c = cells[i]
                guard c.text.isEmpty else {
                    setPen(c.attrs); glyph(c.text); wrapped(&self, width: Int(c.width)); i += 1; continue
                }
                var j = i
                while j < cells.count, cells[j].text.isEmpty, cells[j].attrs.bg == c.attrs.bg { j += 1 }
                let n = j - i
                if continues && j == cells.count {
                    // KNOWN LIMIT: an erased tail on a wrapped line cannot keep the wrap flag without a
                    // write, so it is written as spaces (docs/terminal.md, Known limits).
                    setPen(TermAttrs(bg: c.attrs.bg)); glyph(String(repeating: " ", count: n)); wrapped(&self, width: n)
                } else if wrapPending {
                    // CUF and ECH clamp a pending-wrap x to cols-1 FIRST (InputHandler), so they would hit
                    // the previous row's last glyph. Force the wrap with a written space, step back onto
                    // it, and erase the run — which also puts that space back to erased.
                    setPen(TermAttrs(bg: c.attrs.bg)); glyph(" "); wrapped(&self, width: 1)
                    csi("D"); setPen(TermAttrs(bg: c.attrs.bg)); csi("\(n)X")
                    if j < cells.count { csi("\(n)C") }
                } else {
                    if c.attrs.bg != .default { setPen(TermAttrs(bg: c.attrs.bg)); csi("\(n)X") }
                    if j < cells.count { csi("\(n)C") }
                }
                i = j
            }
        }

        mutating func region(_ b: TermBufferState, rows: Int) {
            if b.scrollTop != 0 || b.scrollBottom != rows - 1 { csi("\(b.scrollTop + 1);\(b.scrollBottom + 1)r") }
        }

        mutating func tabStops(_ stops: [Int], cols: Int) {
            guard stops != TermSnapshot.defaultTabStops(cols: cols) else { return }
            csi("3g")
            for c in stops { cup(0, c); esc("H") }
        }

        /// Position, pen and GL charset as a DECSC should capture them (the charset through G0 + SI;
        /// `charsets` puts the real designations back afterwards).
        /// `screen`: the rows the stance is on, for a saved x == cols (a DECSC taken in pending wrap),
        /// which is reproduced like the live cursor's — by rewriting the glyph covering the last column.
        /// Origin mode is off here (DECSTR), so the row is absolute.
        mutating func stand(_ sc: TermSavedCursor, cols: Int, rows: Int, screen: ArraySlice<TermLine>) {
            let y = min(max(0, sc.y), rows - 1)
            if sc.x >= cols {
                let row = Array(screen)
                pendingWrap(y: y, row: y < row.count ? row[y].cells : [], cols: cols)
            } else {
                cup(y, max(0, sc.x))
            }
            setPen(sc.attrs)
            esc("(" + String(UnicodeScalar(sc.charset ?? UInt8(ascii: "B"))))
            raw("\u{0f}")
        }

        /// G0 = US ASCII in GL: what a stance leaves behind must not map the glyphs written next.
        mutating func asciiGL() { esc("(B"); raw("\u{0f}") }

        mutating func charsets(_ c: TermCharsets) {
            let intermediates = ["(", ")", "*", "+"]
            for g in 0..<4 where g == 0 || c.g[g] != nil {
                esc(intermediates[g] + String(UnicodeScalar(c.g[g] ?? UInt8(ascii: "B"))))
            }
            switch c.gl {
            case 1: raw("\u{0e}")
            case 2: esc("n")
            case 3: esc("o")
            default: raw("\u{0f}")
            }
        }

        /// The boolean modes are stated explicitly in BOTH directions; the mouse protocol, the mouse
        /// encoding and DECSCUSR only when NOT the default, which is what DECSTR (`CSI ! p`, the first
        /// thing `emit` writes) leaves on a fresh instance. `?6` last: it homes the cursor, and `cursor`
        /// follows. IRM and `?7` come after the pending-wrap rewrite (see `emit`).
        mutating func modes(_ m: TermSnapshotModes, cursor: TermCursor) {
            csi(m.applicationCursor ? "?1h" : "?1l")
            esc(m.applicationKeypad ? "=" : ">")
            // ?45 BEFORE the real ?7: SwiftTerm and xterm.js honour reverse wraparound only while
            // autowrap is on, and `emit`'s opening `?7h` guarantees it is here. The snapshot's own ?7
            // value is stated after the pending-wrap rewrite, at the end of `emit`.
            csi(m.reverseWraparound ? "?45h" : "?45l")
            if cursor.style != .blinkBlock { csi("\(cursor.style.rawValue) q") }
            csi(cursor.visible ? "?25h" : "?25l")
            csi(m.bracketedPaste ? "?2004h" : "?2004l")
            csi(m.focusReporting ? "?1004h" : "?1004l")
            switch m.mouse {
            case .off: break
            case .x10: csi("?9h")
            case .vt200: csi("?1000h")
            case .buttonEvent: csi("?1002h")
            case .anyEvent: csi("?1003h")
            }
            switch m.mouseEncoding {
            case .standard: break
            case .sgr: csi("?1006h")
            case .sgrPixels: csi("?1016h")
            }
            csi(m.origin ? "?6h" : "?6l")
        }

        /// CUP (region-relative under ?6). A pending wrap is reproduced by rewriting the glyph that
        /// covers the last column, which leaves xterm.js exactly there.
        mutating func cursor(_ s: TermSnapshot) {
            let b = s.alt ?? s.normal
            let top = s.modes.origin ? b.scrollTop : 0
            let y = min(max(0, s.cursor.y), s.rows - 1)
            guard s.cursor.x >= s.cols else { cup(y - top, min(max(0, s.cursor.x), s.cols - 1)); return }
            pendingWrap(y: y, row: y < s.screen.count ? s.screen[y].cells : [], cols: s.cols, top: top)
        }

        /// Leaves the cursor at x == cols on row `y` by rewriting the glyph that covers the last column.
        mutating func pendingWrap(y: Int, row: [TermCell], cols: Int, top: Int = 0) {
            var col = 0
            var covering: (Int, TermCell)? = nil
            for c in row {
                if col + Int(c.width) >= cols { covering = (col, c); break }
                col += Int(c.width)
            }
            // No glyph reaches the last column: the row's tail is empty cells a capture trimmed, so the
            // one rewritten is an empty cell with default attributes — what the untrimmed row held there.
            let (start, cell) = covering ?? (cols - 1, TermCell(text: "", width: 1, attrs: TermAttrs()))
            cup(y - top, start)
            setPen(cell.attrs)
            glyph(cell.text.isEmpty ? " " : cell.text)
            // A row with NO glyph at all — every cell erased, one background: what EL 1 or EL 2 leaves
            // when it runs IN pending wrap (reachable: `printf 'Z%.0s' {1..80}; printf '\e[1K'`). The
            // space just written would stay as a written space, so it is erased again with EL 1, which
            // SwiftTerm and xterm.js both apply at x == cols WITHOUT leaving pending wrap or touching
            // the row's wrap flag. KNOWN LIMIT: a row that HAS glyphs and an erased last cell (a scroll
            // in pending wrap, or a saved cursor whose row was rewritten) keeps the written space —
            // no sequence erases one cell and stays in pending wrap (docs/terminal.md, Known limits).
            if cell.text.isEmpty, row.allSatisfy({ $0.text.isEmpty && $0.attrs == TermAttrs(bg: cell.attrs.bg) }) {
                setPen(TermAttrs(bg: cell.attrs.bg)); csi("1K")
            }
        }
    }
}
