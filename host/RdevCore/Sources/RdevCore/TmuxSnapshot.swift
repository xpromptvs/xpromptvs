import Foundation
import SwiftTerm

/// A `tmux:` tab's state from tmux ITSELF (tmux holds the screen; rdev never emulates a tmux pane): the
/// joined history (`capture-pane -p -e -J`), the screen (`-p -e -N`), the saved normal screen under an
/// alt screen (`-a -p -e -N`), and `display -p` flags — parsed into the same `TermSnapshot` a `pty:`
/// tab produces, so both kinds restore through one emitter.
///
/// What tmux cannot report, or rdev does not read (restored as defaults — docs/terminal.md, Known
/// limits): the wrap flag of a SCREEN line (`capture-pane` does not say; history is joined with `-J`
/// and split again at the current width); `?1004` (no format — the caller passes the stream
/// tracker's); the pen; the saved cursor; the charset STATE (G0–G3, GL — the GLYPHS survive: tmux keeps
/// a DEC graphics cell's ASCII byte and the capture brackets the run with SO/SI, which this maps); an
/// erased cell as distinct from a written space (tmux stores both as a space); `?45`. Tab stops come
/// from `pane_tabs`, the cursor style from `cursor_shape` and `cursor_blinking`.
public enum TmuxSnapshot {
    public static let historyLines = TermSnapshot.historyCap
    /// No tab advances more than tmux's widest pane (`PANE_MAXIMUM`-ish; `resize-window` refuses more).
    public static let maxTabAdvance = 10_000
    /// `pane_tabs` is LAST: it expands to NOTHING when every stop is cleared (`CSI 3g`), which still
    /// leaves its separating space — six fields, the last empty. `cursor_shape` is `default`, `block`,
    /// `underline` or `bar` and `cursor_blinking` 0/1 (measured, tmux 3.7c, for every `CSI n SP q`: 0 and
    /// none are `default 0`); a tmux without them expands both to nothing, which reads as unknown.
    public static let extraFormat = "#{insert_flag} #{keypad_flag} #{wrap_flag} #{cursor_shape} #{cursor_blinking} #{pane_tabs}"

    public struct Extra: Equatable, Sendable {
        public var insert: Bool
        public var keypad: Bool
        public var wraparound: Bool
        /// 0-based columns (`pane_tabs`, tmux keeps one set per pane); nil = unknown, the defaults.
        public var tabStops: [Int]?
        public var cursorStyle: TermCursorStyle?
        public init(insert: Bool, keypad: Bool, wraparound: Bool, tabStops: [Int]? = nil, cursorStyle: TermCursorStyle? = nil) {
            self.insert = insert; self.keypad = keypad; self.wraparound = wraparound; self.tabStops = tabStops
            self.cursorStyle = cursorStyle
        }
        /// The six fields of `extraFormat` (or just the first three).
        public static func parse(_ line: String) -> Extra? {
            let f = line.split(separator: " ", omittingEmptySubsequences: false)
            guard f.count == 3 || f.count == 6 else { return nil }
            let n = f.prefix(3).compactMap { Int($0) }
            guard n.count == 3 else { return nil }
            var tabs: [Int]? = nil
            var style: TermCursorStyle? = nil
            if f.count == 6 {
                style = cursorStyle(shape: f[3], blinking: f[4] == "1")
                let parts = f[5].split(separator: ",").map { Int($0) }
                if parts.allSatisfy({ ($0 ?? -1) >= 0 }) { tabs = parts.compactMap { $0 } }
            }
            return Extra(insert: n[0] == 1, keypad: n[1] == 1, wraparound: n[2] == 1, tabStops: tabs, cursorStyle: style)
        }

        /// tmux's shape/blinking as DECSCUSR's style — what SwiftTermSnapshot reads for the same `CSI n SP q`.
        /// `default` (DECSCUSR 0, or never set) is xterm.js's default, a blinking block, whatever tmux
        /// says of blinking.
        static func cursorStyle(shape: Substring, blinking: Bool) -> TermCursorStyle? {
            switch shape {
            case "default": return .blinkBlock
            case "block": return blinking ? .blinkBlock : .steadyBlock
            case "underline": return blinking ? .blinkUnderline : .steadyUnderline
            case "bar": return blinking ? .blinkBar : .steadyBar
            default: return nil
            }
        }
    }

    /// ONE batch, every command against the SESSION (its active pane): tmux runs lines it reads together
    /// in one pass, so the cursor `display` reports and the screen the captures return agree, and the
    /// batch's replies are ordered with the pane's `%output` in the control stream. The `-a` capture
    /// answers `%error` unless the pane is on the alt screen (each command is its own line, so that
    /// error stops nothing). The pane list prunes the carries of panes that are gone.
    ///
    /// The screen captures carry `-N`: without it tmux trims a line's trailing spaces EVEN UNDER A
    /// BACKGROUND, so an erase with a colour (`CSI 44m CSI K`, a TUI's status bar) came back with its
    /// coloured tail gone (measured, tmux 3.7c). `-J` already keeps them for the history — which tmux
    /// has trimmed itself by then (also measured), a limit of tmux's history.
    ///
    /// `history`: how much history to capture — none for an OFFER's screen (`TerminalManager.screenPreview`), which
    /// shows the screen alone; then the capture is one line, so the batch keeps its shape and `build` is given none.
    public static func commands(session s: String, history: Int = historyLines) -> [String] {
        ["display -p -t \(s) '\(TmuxPaneState.format)'",
         "display -p -t \(s) '\(extraFormat)'",
         "capture-pane -p -e -J -S -\(max(history, 1)) -E -1 -t \(s)",
         "capture-pane -p -e -N -t \(s)",
         "capture-pane -a -p -e -N -t \(s)",
         paneListCommand(session: s),
         // What the model depends on (TmuxGlyphs): the SERVER's version, and the two server options
         // that change its widths. An older tmux answers the options with an error: its default model.
         "display -p '#{version}'",
         "show-options -sv variation-selector-always-wide",
         "show-options -sv codepoint-widths"]
    }

    /// The width options from the batch's last two replies (`commands`); an error reads as absent.
    public static func glyphOptions(variationSelectorAlwaysWide: [String]?, codepointWidths: [String]?) -> TmuxGlyphOptions {
        TmuxGlyphOptions.parse(variationSelectorAlwaysWide: variationSelectorAlwaysWide, codepointWidths: codepointWidths)
    }

    /// The snapshot as it goes to the client: the server's width options FIRST, in band, when they are
    /// not tmux's defaults (`TmuxGlyphOptions.osc`), so the tab's instance counts the snapshot — and
    /// everything after it — by them.
    public static func emit(_ snap: TermSnapshot, glyphs: TmuxGlyphOptions) -> [UInt8] {
        Array(glyphs.osc.utf8) + TermSnapshotEmitter.emit(snap)
    }

    public static func paneListCommand(session: String) -> String { "list-panes -s -t \(session) -F '#{pane_id}'" }

    public static func livePanes(_ lines: [String]) -> Set<String> {
        Set(lines.filter { $0.hasPrefix("%") && $0.dropFirst().allSatisfy(\.isNumber) && $0.count > 1 })
    }

    public static func build(state: TmuxPaneState, extra: Extra, history: [String], screen: [String],
                             savedNormal: [String]?, focusReporting: Bool, glyphs: TmuxGlyphOptions = .default) -> TermSnapshot {
        let cols = max(1, state.width), rows = max(1, state.height)
        let tabs = extra.tabStops.map { Array(Set($0.filter { $0 < cols })).sorted() } ?? TermSnapshot.defaultTabStops(cols: cols)
        func screenful(_ capture: [String]) -> [TermLine] {
            var st = CaptureState()
            let l = capture.prefix(rows).map { TermLine(cells: cut(trimmed(cells($0, state: &st, cols: cols, tabStops: tabs, glyphs: glyphs)), cols: cols)) }
            return l + Array(repeating: TermLine(cells: []), count: rows - l.count)
        }
        func buffer(_ l: [TermLine], top: Int, bottom: Int) -> TermBufferState {
            TermBufferState(lines: l, scrollTop: top, scrollBottom: bottom, tabStops: tabs, savedCursor: TermSavedCursor())
        }
        // `history_size` 0: tmux answers `-E -1` with the screen's first row, so the capture is not history.
        // On the alt screen tmux still holds (and reports) the NORMAL screen's history.
        let past: [TermLine] = state.historySize > 0 ? Array(historyRows(history, cols: cols, tabStops: tabs, glyphs: glyphs).suffix(historyLines)) : []
        let top = min(max(0, state.scrollTop), rows - 1), bottom = min(max(top, state.scrollBottom), rows - 1)
        let normal: TermBufferState
        let alt: TermBufferState?
        if state.modes.altScreen {
            normal = buffer(past + screenful(savedNormal ?? []), top: 0, bottom: rows - 1)
            alt = buffer(screenful(screen), top: top, bottom: bottom)
        } else {
            normal = buffer(past + screenful(screen), top: top, bottom: bottom)
            alt = nil
        }
        var modes = TermSnapshotModes()
        modes.applicationCursor = state.modes.applicationCursor
        modes.applicationKeypad = extra.keypad
        modes.insert = extra.insert
        modes.wraparound = extra.wraparound
        modes.origin = state.originMode
        modes.bracketedPaste = state.modes.bracketedPaste
        modes.focusReporting = focusReporting
        modes.mouse = state.modes.mouse
        modes.mouseEncoding = state.modes.mouseEncoding
        modes.synchronizedOutput = state.synchronizedOutput
        // `cursor_x == pane_width` is tmux's PENDING WRAP (measured) — the model's `x == cols`.
        return TermSnapshot(cols: cols, rows: rows, normal: normal, alt: alt,
                            cursor: TermCursor(x: min(max(0, state.cursorX), cols), y: min(max(0, state.cursorY), rows - 1),
                                               visible: state.modes.cursorVisible, style: extra.cursorStyle ?? .blinkBlock),
                            pen: TermAttrs(), modes: modes, charsets: TermCharsets(), title: nil)
    }

    /// The `-J` capture as ROWS: each joined line split at `cols`, its continuations `wrapped`. A wide
    /// glyph that would straddle the last column starts the next row, as a terminal wraps it.
    static func historyRows(_ capture: [String], cols: Int, tabStops: [Int], glyphs: TmuxGlyphOptions = .default) -> [TermLine] {
        var st = CaptureState()
        var out: [TermLine] = []
        for line in capture {
            var current: [TermCell] = []
            var width = 0
            var continuation = false
            for c in cells(line, state: &st, cols: cols, tabStops: tabStops, glyphs: glyphs) {
                if width + Int(c.width) > cols {
                    out.append(TermLine(cells: trimmed(current), wrapped: continuation))
                    current = []; width = 0; continuation = true
                }
                current.append(c); width += Int(c.width)
            }
            out.append(TermLine(cells: trimmed(current), wrapped: continuation))
        }
        return out
    }

    /// At most `cols` columns of a screen row. tmux never sends more; if it did, cutting keeps every
    /// other row where tmux has it.
    private static func cut(_ cells: [TermCell], cols: Int) -> [TermCell] {
        var width = 0
        var out: [TermCell] = []
        for c in cells {
            guard width + Int(c.width) <= cols else { break }
            out.append(c); width += Int(c.width)
        }
        return out
    }

    /// One row, trailing DEFAULT blanks dropped (a space tmux wrote for an erased or padded cell, or a
    /// `-N` pad), so a blank row is `TermSnapshot.blank`'s. A blank with a background is content.
    public static func row(_ line: String) -> [TermCell] {
        var st = CaptureState()
        return trimmed(cells(line, state: &st))
    }

    private static func trimmed(_ cells: [TermCell]) -> [TermCell] {
        var c = cells
        while let last = c.last, last.text.isEmpty || last.text == " ", last.attrs == TermAttrs() { c.removeLast() }
        return c
    }

    /// What one line of a capture leaves open for the next: tmux's capture is STATEFUL ACROSS LINES —
    /// it writes an SGR only where the attributes change, so a line inherits what the one above it left
    /// open (measured, tmux 3.7c) — and an SO without its SI would carry the same way.
    public struct CaptureState: Equatable, Sendable {
        public var pen = TermAttrs()
        /// Inside SO … SI: DEC special graphics.
        public var acs = false
        public init() {}
    }

    /// One `capture-pane -e` line → cells, starting from the default pen and default tab stops.
    public static func cells(_ line: String) -> [TermCell] {
        var st = CaptureState()
        return cells(line, state: &st)
    }

    /// One `capture-pane -e` line → cells, from `state` and leaving it as the line ends. A wide glyph is
    /// written ONCE (its padding cell is not printed). A TAB is one cell in tmux, printed as `\t`: it
    /// becomes the erased cells up to the next of `tabStops` (every 8 when nil) or, past the last stop,
    /// to the last of `cols` columns (the next multiple of 8 when `cols` is unknown) — never more than
    /// `maxTabAdvance` — counted from the start of the ROW it lands on (a glyph that does not fit starts the next
    /// row, as `historyRows` splits). A run between SO and SI is DEC special graphics (tmux keeps the
    /// ASCII byte), mapped as SwiftTerm maps it. Any other escape — an OSC 8 hyperlink from a newer tmux,
    /// a private CSI — is skipped; one cut short ends where it stops, and never eats the glyph after it.
    public static func cells(_ line: String, state: inout CaptureState, cols: Int = .max, tabStops: [Int]? = nil,
                             glyphs: TmuxGlyphOptions = .default) -> [TermCell] {
        var out: [TermCell] = []
        // SCALARS, not Characters: tmux's cells are not Swift's graphemes (TmuxGlyphs).
        let chars = Array(line.unicodeScalars)
        var i = 0
        var x = 0                                                           // column within the current row
        func ascii(_ k: Int) -> UInt8? { k < chars.count && chars[k].isASCII ? UInt8(chars[k].value) : nil }
        func place(_ c: TermCell) {
            if x + Int(c.width) > cols { x = 0 }
            out.append(c); x += Int(c.width)
        }
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "\u{1b}":
                break
            case "\t":
                // Past the last stop: the last column, or — `cols` unknown — the next multiple of 8. Never
                // past the last column, and never more than `maxTabAdvance`.
                let lastColumn = cols == .max ? Int.max : cols - 1
                let pastLastStop = cols == .max ? (x / 8 + 1) * 8 : lastColumn
                let next = tabStops.map { stops in stops.first { $0 > x } ?? pastLastStop } ?? (x / 8 + 1) * 8
                let gap = max(0, min(next, lastColumn, x + maxTabAdvance) - x)
                for _ in 0..<gap { place(TermCell(text: "", width: 1, attrs: TermAttrs())) }
                i += 1; continue
            case "\u{0e}": state.acs = true; i += 1; continue
            case "\u{0f}": state.acs = false; i += 1; continue
            default:
                let v = ch.value
                if v >= 0xA0, let last = out.indices.last, let widen = TmuxGlyphs.joins(ch, after: out[last].text, glyphs) {
                    // tmux JOINS it to the cell before (TmuxGlyphs): the capture prints the two together.
                    var cell = out[last]
                    cell.text.unicodeScalars.append(ch)
                    // A widening in the LAST column stays there, overhanging (x is past the cell).
                    if widen, cell.width < 2, x - Int(cell.width) + 2 <= cols { cell.width = 2; x += 1 }
                    out[last] = cell
                } else {
                    let w = TmuxGlyphs.width(ch, glyphs)
                    if w > 0 {                                   // zero-width with no cell before: tmux drops it
                        let mapped = state.acs && ch.isASCII ? decGraphics[UInt8(v)] : nil
                        place(TermCell(text: mapped ?? String(ch), width: UInt8(w), attrs: state.pen))
                    }
                }
                i += 1; continue
            }
            guard let kind = ascii(i + 1) else { i += 1; continue }        // a lone ESC, or ESC + a glyph
            switch kind {
            case 0x5B:                                                      // CSI
                var j = i + 2
                var params = ""
                while let a = ascii(j), (0x20...0x3F).contains(a) { params.unicodeScalars.append(chars[j]); j += 1 }
                guard let final = ascii(j), (0x40...0x7E).contains(final) else { i = j; continue }   // cut short
                if final == 0x6D, params.allSatisfy({ $0.isNumber || $0 == ";" || $0 == ":" }) { applySGR(params, to: &state.pen) }
                i = j + 1
            case 0x5D, 0x50, 0x58, 0x5E, 0x5F:                              // OSC / DCS / SOS / PM / APC
                var j = i + 2
                while j < chars.count, chars[j] != "\u{07}", !(chars[j] == "\u{1b}" && ascii(j + 1) == 0x5C) { j += 1 }
                i = j >= chars.count ? j : chars[j] == "\u{07}" ? j + 1 : j + 2
            default:                                                        // ESC [intermediates] final
                var j = i + 1
                while let a = ascii(j), (0x20...0x2F).contains(a) { j += 1 }
                if let a = ascii(j), (0x30...0x7E).contains(a) { j += 1 }
                i = j
            }
        }
        return out
    }

    /// DEC special graphics (`ESC ( 0`), as SwiftTerm and xterm.js map it (SwiftTerm's table is
    /// internal; `TmuxSnapshotTests` checks this one against it glyph by glyph).
    static let decGraphics: [UInt8: String] = {
        let glyphs = "◆▒\u{2409}\u{240c}\u{240d}\u{240a}°±\u{2424}\u{240b}┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·"
        return Dictionary(uniqueKeysWithValues: zip(UInt8(ascii: "`")...UInt8(ascii: "~"), glyphs.map(String.init)))
    }()

    /// SGR as xterm.js applies it. Unknown or malformed parameters are skipped; an extended colour with
    /// too few components sets nothing; numbers clamp to a byte.
    static func applySGR(_ params: String, to a: inout TermAttrs) {
        let groups = params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        func num(_ s: Substring) -> Int? { s.isEmpty ? 0 : Int(s) }
        func byte(_ n: Int) -> UInt8 { UInt8(clamping: n) }
        var i = 0
        while i < groups.count {
            let sub = groups[i].split(separator: ":", omittingEmptySubsequences: false)
            defer { i += 1 }
            guard let n = num(sub[0]) else { continue }
            switch n {
            case 0: a = TermAttrs()
            case 1: a.bold = true
            case 2: a.dim = true
            case 3: a.italic = true
            case 4:
                let style = sub.count > 1 ? (num(sub[1]) ?? 1) : 1
                a.underline = style == 0 && sub.count > 1 && sub[1].isEmpty ? 1 : (0...5).contains(style) ? UInt8(style) : 0
            case 5: a.blink = true
            case 7: a.inverse = true
            case 8: a.invisible = true
            case 9: a.strikethrough = true
            case 21: a.underline = 2
            case 22: a.bold = false; a.dim = false
            case 23: a.italic = false
            case 24: a.underline = 0
            case 25: a.blink = false
            case 27: a.inverse = false
            case 28: a.invisible = false
            case 29: a.strikethrough = false
            case 30...37: a.fg = .palette(UInt8(n - 30))
            case 39: a.fg = .default
            case 40...47: a.bg = .palette(UInt8(n - 40))
            case 49: a.bg = .default
            case 59: a.underlineColor = nil
            case 90...97: a.fg = .palette(UInt8(n - 90 + 8))
            case 100...107: a.bg = .palette(UInt8(n - 100 + 8))
            case 38, 48, 58:
                var c: TermColor? = nil
                if sub.count > 1 {
                    // Colon form: 38:5:n, 38:2:r:g:b, or 38:2:<colour space>:r:g:b.
                    let v = sub.dropFirst().map { num($0) ?? 0 }
                    if v[0] == 5, v.count >= 2 { c = .palette(byte(v[1])) }
                    else if v[0] == 2, v.count >= 4 { let rgb = Array(v.suffix(3)); c = .rgb(byte(rgb[0]), byte(rgb[1]), byte(rgb[2])) }
                } else if i + 1 < groups.count, let kind = num(Substring(groups[i + 1])) {
                    let rest = groups[(i + 1)...].dropFirst().map { num(Substring($0)) }
                    if kind == 5, let idx = rest.first ?? nil { c = .palette(byte(idx)); i += 2 }
                    else if kind == 2, rest.count >= 3, let r = rest[0], let g = rest[1], let b = rest[2] {
                        c = .rgb(byte(r), byte(g), byte(b)); i += 4
                    } else { i = groups.count }                         // malformed: the rest is its payload
                }
                if let c { if n == 38 { a.fg = c } else if n == 48 { a.bg = c } else { a.underlineColor = c } }
            default: break
            }
        }
    }
}

/// How TMUX counts and joins glyphs (docs/terminal.md, "tmux tabs count as tmux does") — MEASURED on tmux
/// 3.7c by scripts/measure_tmux_glyphs.py into protocol/fixtures/tmux-glyphs.json, which the client's
/// tmux provider (web/src/client/term-unicode.ts) reads and `TmuxSnapshotTests` holds these to. A tmux
/// tab's capture is cut into cells by these rules, and its instance on the client counts by them.
public enum TmuxGlyphs {
    /// The tmux version the model was measured on (protocol/fixtures/tmux-glyphs.json's `tmux`). The host
    /// logs once when an attached server reports another; TmuxGlyphsVersionTests fails when the local one does.
    public static let measuredVersion = "3.7c"

    /// tmux counts these TWO columns where the host's table does not: the text-default skin-tone bases
    /// it widens itself, a lone skin tone, the wide spacing marks.
    public static let wide: Set<UInt32> = [0x261D, 0x26F9, 0x270C, 0x270D, 0x302E, 0x302F, 0x16FF0, 0x16FF1, 0x1F3CB, 0x1F3CC, 0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF, 0x1F574, 0x1F575, 0x1F590]
    /// …and these none (the Hangul filler).
    public static let zero: Set<UInt32> = [0x3164]
    /// The bases a skin tone JOINS in tmux — its own list, not Unicode's (☝ and 🤚 are not on it).
    public static let modifierBases: Set<UInt32> = [0x1F44B, 0x1F44C, 0x1F44D, 0x1F44E, 0x1F44F, 0x1F450, 0x1F466, 0x1F467, 0x1F468, 0x1F469, 0x1F46E, 0x1F470, 0x1F471, 0x1F472, 0x1F473, 0x1F474, 0x1F475, 0x1F476, 0x1F477, 0x1F478, 0x1F47C, 0x1F481, 0x1F482, 0x1F483, 0x1F485, 0x1F486, 0x1F487, 0x1F4AA, 0x1F575, 0x1F57A, 0x1F590, 0x1F595, 0x1F596, 0x1F645, 0x1F646, 0x1F647, 0x1F64B, 0x1F64C, 0x1F64D, 0x1F64E, 0x1F64F, 0x1F6B4, 0x1F6B5, 0x1F6B6, 0x1F926, 0x1F937, 0x1F938, 0x1F939, 0x1F93D, 0x1F93E, 0x1F9B5, 0x1F9B6, 0x1F9B8, 0x1F9B9, 0x1F9CD, 0x1F9CE, 0x1F9CF, 0x1F9D1, 0x1F9D2, 0x1F9D3, 0x1F9D4, 0x1F9D5, 0x1F9D6, 0x1F9D7, 0x1F9D8, 0x1F9D9, 0x1F9DA, 0x1F9DB, 0x1F9DC, 0x1F9DD, 0x1F9DE, 0x1F9DF]

    /// A scalar's own width in tmux: the host's table (SwiftTerm's, protocol/fixtures/term-widths.json)
    /// with tmux's exceptions.
    public static func width(_ s: Unicode.Scalar, _ o: TmuxGlyphOptions = .default) -> Int {
        if s.value < 0x20 || (0x7F...0x9F).contains(s.value) { return 0 }
        if s.value < 0x7F { return 1 }
        if let w = o.width(s.value) { return w }
        if wide.contains(s.value) { return 2 }
        if zero.contains(s.value) { return 0 }
        return max(0, SwiftTerm.Terminal.rdevColumnWidth(s))
    }

    /// Whether tmux joins `s` to a cell holding `cell` (nil: it starts a cell of its own), and if so
    /// whether the cell WIDENS to two: a zero-width scalar joins, VS16 joins and widens, a skin tone
    /// joins a listed base, the second regional indicator of a pair joins and widens, and any non-ASCII
    /// scalar joins a cell ending in a ZWJ. ASCII never joins (the caller's to check).
    public static func joins(_ s: Unicode.Scalar, after cell: String, _ o: TmuxGlyphOptions = .default) -> Bool? {
        let v = s.value
        if v == 0xFE0F { return o.variationSelectorAlwaysWide }
        if (0x1F3FB...0x1F3FF).contains(v) {
            return cell.unicodeScalars.first.map { modifierBases.contains($0.value) } == true ? false : nil
        }
        if (0x1F1E6...0x1F1FF).contains(v) {
            let c = Array(cell.unicodeScalars)
            return c.count == 1 && (0x1F1E6...0x1F1FF).contains(c[0].value) ? true : nil
        }
        if width(s, o) == 0 { return false }
        return cell.unicodeScalars.last?.value == 0x200D ? false : nil
    }
}

/// The two tmux SERVER options that change `TmuxGlyphs`' model (measured on tmux 3.7c): read with the
/// snapshot (`TmuxSnapshot.commands`) and handed to the client in band (`osc`).
/// - `variation-selector-always-wide` (default on): off, VS16 still joins but no longer widens.
/// - `codepoint-widths` (default empty): `U+XXXX=W` or `U+XXXX-U+YYYY=W` entries, comma-separated or
///   one per array element, setting a scalar's width outright — a zero-width one set wider stops joining.
public struct TmuxGlyphOptions: Equatable, Sendable {
    public var variationSelectorAlwaysWide = true
    /// Ranges and widths, in the order tmux lists them; the LAST that covers a scalar wins.
    public var widths: [(range: ClosedRange<UInt32>, width: Int)] = []
    public static let `default` = TmuxGlyphOptions()
    public init() {}

    public var isDefault: Bool { variationSelectorAlwaysWide && widths.isEmpty }

    public static func == (a: Self, b: Self) -> Bool {
        a.variationSelectorAlwaysWide == b.variationSelectorAlwaysWide
            && a.widths.map { [$0.range.lowerBound, $0.range.upperBound, UInt32($0.width)] }
                == b.widths.map { [$0.range.lowerBound, $0.range.upperBound, UInt32($0.width)] }
    }

    public func width(_ v: UInt32) -> Int? {
        guard !widths.isEmpty else { return nil }
        return widths.last { $0.range.contains(v) }?.width
    }

    /// `show-options -sv` replies (nil: the option does not exist here — an older tmux). Malformed
    /// entries are skipped, as tmux itself skips them.
    public static func parse(variationSelectorAlwaysWide: [String]?, codepointWidths: [String]?) -> TmuxGlyphOptions {
        var o = TmuxGlyphOptions()
        if let v = variationSelectorAlwaysWide?.first?.trimmingCharacters(in: .whitespaces) { o.variationSelectorAlwaysWide = v != "off" }
        for entry in (codepointWidths ?? []).flatMap({ $0.split(separator: ",") }) {
            let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: "=")
            guard parts.count == 2, let w = Int(parts[1]), (0...2).contains(w) else { continue }
            let ends = parts[0].split(separator: "-").map { $0.uppercased().hasPrefix("U+") ? UInt32($0.dropFirst(2), radix: 16) : nil }
            guard (1...2).contains(ends.count), let lo = ends.first ?? nil, let hi = ends.last ?? nil, lo <= hi else { continue }
            o.widths.append((lo...hi, w))
        }
        return o
    }

    /// The in-band statement the client's tmux provider reads (`OSC 9910`, rdev's own number — xterm.js
    /// ignores an OSC it has no handler for): empty for tmux's defaults.
    public var osc: String {
        guard !isDefault else { return "" }
        let list = widths.map { e in
            e.range.lowerBound == e.range.upperBound ? String(format: "U+%04X=%d", e.range.lowerBound, e.width)
                : String(format: "U+%04X-U+%04X=%d", e.range.lowerBound, e.range.upperBound, e.width)
        }.joined(separator: ",")
        return "\u{1b}]9910;vs16wide=\(variationSelectorAlwaysWide ? "on" : "off");widths=\(list)\u{07}"
    }
}
