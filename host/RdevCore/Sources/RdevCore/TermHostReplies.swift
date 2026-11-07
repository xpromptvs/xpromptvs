import Foundation

/// The colours the DRIVER's xterm.js reports to OSC 4/10/11/12 queries: its theme's foreground,
/// background, cursor and 16 ANSI colours (the client sends them, `term-palette`), and xterm.js 6's
/// fixed 6x6x6 cube and grey ramp for 16-255 — except the slots its theme REPLACES (`extended`, the
/// wire's `ext`: Claude Code's diff backgrounds on the dark theme). Until a client has said, xterm.js's
/// own defaults.
public struct TermPalette: Equatable, Sendable {
    public struct RGB: Equatable, Sendable {
        public var r: UInt8, g: UInt8, b: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    }
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    /// Exactly 16.
    public var ansi: [RGB]
    /// The 16-255 slots the theme replaces, by index; every other one is the fixed cube and greys.
    public var extended: [Int: RGB]

    public init(foreground: RGB, background: RGB, cursor: RGB, ansi: [RGB], extended: [Int: RGB] = [:]) {
        precondition(ansi.count == 16)
        self.foreground = foreground; self.background = background; self.cursor = cursor; self.ansi = ansi
        self.extended = extended
    }

    /// xterm.js 6 with no theme (`ThemeService`'s DEFAULT_FOREGROUND/BACKGROUND/CURSOR and
    /// `DEFAULT_ANSI_COLORS`) — measured in `term-client-queries.json`'s `palettes.default`.
    public static let xtermDefault = TermPalette(
        foreground: RGB(r: 0xff, g: 0xff, b: 0xff), background: RGB(r: 0, g: 0, b: 0), cursor: RGB(r: 0xff, g: 0xff, b: 0xff),
        ansi: [0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
               0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec].map(RGB.init(hex:)))

    /// `index` 0-255 as xterm.js reports it: the 16 from the palette, then xterm.js's fixed cube and greys.
    public func color(_ index: Int) -> RGB {
        if index < 16 { return ansi[index] }
        if let replaced = extended[index] { return replaced }
        if index < 232 {
            let v: [UInt8] = [0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff]
            let i = index - 16
            return RGB(r: v[(i / 36) % 6], g: v[(i / 6) % 6], b: v[i % 6])
        }
        let c = UInt8(8 + (index - 232) * 10)
        return RGB(r: c, g: c, b: c)
    }

    /// The `term-palette` control message: `fg`, `bg`, `cursor` and 16 `ansi`, each `#rrggbb`, and
    /// optionally `ext` — an object of "16"…"255" → `#rrggbb`, the slots the theme replaces (absent is
    /// none). Anything else is malformed (nil).
    public init?(wire obj: [String: Any]) {
        guard let fg = (obj["fg"] as? String).flatMap(RGB.init(css:)),
              let bg = (obj["bg"] as? String).flatMap(RGB.init(css:)),
              let cursor = (obj["cursor"] as? String).flatMap(RGB.init(css:)),
              let list = obj["ansi"] as? [Any], list.count == 16 else { return nil }
        let ansi = list.compactMap { ($0 as? String).flatMap(RGB.init(css:)) }
        guard ansi.count == 16 else { return nil }
        var extended: [Int: RGB] = [:]
        if let raw = obj["ext"] {
            guard let map = raw as? [String: Any] else { return nil }
            for (key, value) in map {
                guard let index = Int(key), (16...255).contains(index), String(index) == key,
                      let colour = (value as? String).flatMap(RGB.init(css:)) else { return nil }
                extended[index] = colour
            }
        }
        self.init(foreground: fg, background: bg, cursor: cursor, ansi: ansi, extended: extended)
    }
}

extension TermPalette.RGB {
    /// `rgb:rrrr/gggg/bbbb`, as xterm.js reports a colour: each byte doubled to 16 bits.
    public var xtermSpec: String {
        "rgb:" + [r, g, b].map { String(format: "%02x%02x", $0, $0) }.joined(separator: "/")
    }

    init(hex: Int) { self.init(r: UInt8((hex >> 16) & 0xff), g: UInt8((hex >> 8) & 0xff), b: UInt8(hex & 0xff)) }
    /// `#rrggbb` (either case), nothing else.
    init?(css: String) {
        let u = Array(css.utf8)
        guard u.count == 7, u[0] == 0x23, let v = Int(String(css.dropFirst()), radix: 16),
              u.dropFirst().allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) })
        else { return nil }
        self.init(hex: v)
    }
}

/// What the host knows of a tmux tab's pane when it answers a C1 DECRQM or DECRQSS the client never saw
/// (docs/terminal.md, "tmux answers device queries itself") — what the client's xterm.js would report.
/// Its MODES come from the tab's stream tracker (`TermModeTracker`), seeded from tmux's formats by every
/// snapshot (exactly what the client's instance is built with) and fed every byte of the pane since,
/// with xterm.js 6's semantics: tmux's own formats are exact at a snapshot but diverge from xterm.js
/// after a DECSTR (tmux ignores it), `?66h`, `?9h` or `?1016h` (tmux ignores those too, and keeps
/// `?1000` set under a later `?9h`), and tmux reads `?12` as the cursor's blink where xterm.js reads it
/// as an OPTION — measured, 3.7c. The scroll region and `?2026` come from TMUX, read with the answer's
/// `display` after every byte tmux had parsed: tmux resets the region on a resize, and an update in
/// progress expires on a timer in both — neither is in the stream. nil: tmux did not say (an older tmux
/// expands `synchronized_output_flag` to nothing), answered as not recognised.
public struct TermHostState: Equatable, Sendable {
    /// The stream tracker's modes.
    public var tracked: TermModes
    /// The scroll region, 0-based, and whether an update is in progress (`?2026`).
    public var scrollTop: Int?
    public var scrollBottom: Int?
    public var synchronizedOutput: Bool?

    public init(tracked: TermModes = TermModes()) { self.tracked = tracked }

    /// The `display -p` format the host answers with: the CPR's cursor first (row, column), then the
    /// region and `?2026` (LAST: a tmux too old for it expands it to nothing).
    public static let format = "#{cursor_y} #{cursor_x} #{scroll_region_upper} #{scroll_region_lower} #{synchronized_output_flag}"

    /// A `format` line → the cursor (nil if even that is unreadable) and the state (whatever fields read).
    public static func parse(_ line: String, tracked: TermModes) -> (cursor: (row: Int, col: Int)?, state: TermHostState) {
        let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        func int(_ i: Int) -> Int? { i < f.count ? Int(f[i]) : nil }
        var s = TermHostState(tracked: tracked)
        if let top = int(2), let bottom = int(3), top >= 0, bottom >= top { s.scrollTop = top; s.scrollBottom = bottom }
        if let sync = int(4), sync == 0 || sync == 1 { s.synchronizedOutput = sync == 1 }
        let cursor = int(0).flatMap { r in int(1).map { (row: r, col: $0) } }
        return (cursor, s)
    }
}

/// xterm.js 6's ANSWERS to the device queries a tmux tab leaves for the client (docs/terminal.md, "tmux
/// answers device queries itself") — produced by the HOST when their bytes reached no client, so each
/// still gets exactly one. Byte for byte what `InputHandler`/`CoreBrowserTerminal` send (7-bit, colours
/// ended by `ESC \`), checked against a real xterm.js's answers (`TermClientQueriesFixtureTests`).
/// `query` is one whole sequence as the scanner found it (`StreamingQueryStripper.feedCounting`'s
/// `left`), 7-bit or C1.
public enum TermHostReplies {
    /// The answers, in order — empty when xterm.js answers nothing — or nil when the answer needs state
    /// the host was not given (a cursor for a CPR; `state` for DECRQM and DECRQSS). Never a guess: what
    /// `state` cannot say exactly is answered as xterm.js answers a request it does not recognise.
    public static func answer(_ query: [UInt8], palette: TermPalette, cursor: (row: Int, col: Int)?,
                              state: TermHostState? = nil) -> [UInt8]? {
        guard let (kind, body) = split(query) else { return nil }
        switch kind {
        case 0x5b:
            if let q = CSIParts(body), q.final == 0x70, q.inter == [0x24] {
                return state.map { Array(decrqm(q, $0).utf8) }
            }
            return csi(body, cursor: cursor)
        case 0x5d: return Array(osc(body, palette: palette).utf8)
        case 0x50: return state.flatMap { decrqss(body, $0) }.map { Array($0.utf8) }
        default: return nil
        }
    }

    /// DECRPM, as xterm.js 6's `requestMode` answers `CSI [?] Ps $ p` (its first parameter): the
    /// product's options fixed (no `windowOptions`, `convertEol` off), the modes from `state`, and
    /// `0` (not recognised) for any mode `state` cannot say.
    private static func decrqm(_ q: CSIParts, _ s: TermHostState) -> String {
        let ansi = q.prefix == nil
        let p = q.first
        let m = s.tracked
        func b(_ v: Bool?) -> Int { v.map { $0 ? 1 : 2 } ?? 0 }
        let v: Int
        if ansi {
            switch p {
            case 2: v = 4
            case 4: v = b(m.insert)
            case 12: v = 3
            case 20: v = b(m.convertEol)
            default: v = 0
            }
        } else {
            switch p {
            case 1: v = b(m.applicationCursor)
            case 6: v = b(m.origin)
            case 7: v = b(m.wraparound)
            case 8: v = 3
            case 9: v = b(m.mouse == .x10)
            case 12: v = b(m.cursorBlink)
            case 25: v = b(m.cursorVisible)
            case 45: v = b(m.reverseWraparound)
            case 66: v = b(m.applicationKeypad)
            case 67: v = 4
            case 1000: v = b(m.mouse == .vt200)
            case 1002: v = b(m.mouse == .buttonEvent)
            case 1003: v = b(m.mouse == .anyEvent)
            case 1004: v = b(m.focusReporting)
            case 1005, 1015: v = 4
            case 1006: v = b(m.mouseEncoding == .sgr)
            case 1016: v = b(m.mouseEncoding == .sgrPixels)
            case 1048: v = 1
            case 47, 1047, 1049: v = b(m.altScreen)
            case 2004: v = b(m.bracketedPaste)
            case 2026: v = b(s.synchronizedOutput)
            default: v = 0                                  // 3 (no windowOptions), anything else
            }
        }
        return "\u{1b}[\(ansi ? "" : "?")\(p);\(v)$y"
    }

    /// DECRPSS, as xterm.js 6's `requestStatusString` answers `DCS $ q Pt ST`: `DCS 1 $ r … ST` for the
    /// settings it reports (its SGR report is always `0m`, its conformance level `61;1"p`, its cursor
    /// style the OPTIONS — a block, blinking per `?12` — whatever DECSCUSR said), `DCS 0 $ r ST` for
    /// anything else — and for DECSCA's protection, which nothing the host keeps can say: that is
    /// xterm.js's answer to a request it does not support.
    private static func decrqss(_ body: ArraySlice<UInt8>, _ s: TermHostState) -> String? {
        var b = Array(body)
        // The terminator the scanner ended it at: an ESC (of ST or the next sequence), C1 ST.
        if b.last == 0x1b { b.removeLast() }
        else if b.count >= 2, b[b.count - 2] == 0xC2, b[b.count - 1] == 0x9c { b.removeLast(2) }
        // The header up to its final `q` (C0 and DEL are ignored there), then the data (DEL ignored).
        var j = 0
        while j < b.count, b[j] != 0x71 { j += 1 }
        guard j < b.count else { return nil }
        let data = b[(j + 1)...].filter { $0 != 0x7f }
        let ok = "\u{1b}P1$r", bad = "\u{1b}P0$r\u{1b}\\", st = "\u{1b}\\"
        switch String(decoding: data, as: UTF8.self) {
        case "\"p": return ok + "61;1\"p" + st
        case "m": return ok + "0m" + st
        case "r":
            guard let top = s.scrollTop, let bottom = s.scrollBottom else { return bad }
            return ok + "\(top + 1);\(bottom + 1)r" + st
        case " q": return ok + "\(s.tracked.cursorBlink ? 1 : 2) q" + st   // the style OPTION: a block
        default: return bad                                 // `"q` (DECSCA) included: not kept
        }
    }

    /// The answer to a COLOUR query (OSC 4/10/11/12, 7-bit or C1) from `palette`, or nil when `query`
    /// is not an OSC. A `pty:` tab's emulator answers from its OWN palette (SwiftTerm's `reportColor`),
    /// which is not the driver's theme: when the host answers a colour query there, it is this.
    public static func colourAnswer(_ query: [UInt8], palette: TermPalette) -> [UInt8]? {
        guard let (kind, body) = split(query), kind == 0x5d else { return nil }
        return Array(osc(body, palette: palette).utf8)
    }

    /// Whether `answer` needs the cursor (a CPR: DSR 6 or DECDSR 6).
    public static func needsCursor(_ query: [UInt8]) -> Bool {
        guard let (kind, body) = split(query), kind == 0x5b, let q = CSIParts(body) else { return false }
        return q.final == 0x6e && q.inter.isEmpty && (q.prefix == nil || q.prefix == 0x3f) && q.first == 6
    }

    /// The introducer's kind (`[`, `]`, `P`) and the bytes after it.
    private static func split(_ q: [UInt8]) -> (UInt8, ArraySlice<UInt8>)? {
        guard let first = q.first else { return nil }
        if first == 0xC2 {
            guard q.count >= 2 else { return nil }
            switch q[1] {
            case 0x9b: return (0x5b, q[2...])
            case 0x9d: return (0x5d, q[2...])
            case 0x90: return (0x50, q[2...])
            default: return nil
            }
        }
        guard first == 0x1b else { return nil }
        var j = 1
        while j < q.count, StreamingQueryStripper.isExecuted(q[j]) || q[j] == 0x7f { j += 1 }
        guard j < q.count, [0x5b, 0x5d, 0x50].contains(q[j]) else { return nil }
        return (q[j], q[(j + 1)...])
    }

    /// A CSI's identity as xterm.js dispatches it: C0 and DEL are executed/ignored in place.
    private struct CSIParts {
        var prefix: UInt8?, first = 0, inter: [UInt8] = [], final: UInt8 = 0
        init?(_ body: ArraySlice<UInt8>) {
            let b = body.filter { $0 >= 0x20 && $0 != 0x7f }
            guard let last = b.last else { return nil }
            final = last
            var firstDone = false
            for (i, c) in b.dropLast().enumerated() {
                if i == 0, (0x3c...0x3f).contains(c) { prefix = c; continue }
                if (0x20...0x2f).contains(c) { inter.append(c); continue }
                if c == 0x3b || c == 0x3a { firstDone = true; continue }
                if (0x30...0x39).contains(c), !firstDone, inter.isEmpty {
                    first = min(first * 10 + Int(c - 0x30), 0x7fff_ffff)
                }
            }
        }
    }

    private static func csi(_ body: ArraySlice<UInt8>, cursor: (row: Int, col: Int)?) -> [UInt8]? {
        guard let q = CSIParts(body), q.inter.isEmpty else { return nil }
        let s: String
        switch (q.final, q.prefix) {
        case (0x63, nil): s = q.first == 0 ? "\u{1b}[?1;2c" : ""                 // DA1
        case (0x63, 0x3e): s = q.first == 0 ? "\u{1b}[>0;276;0c" : ""            // DA2
        case (0x6e, nil) where q.first == 5: s = "\u{1b}[0n"
        case (0x6e, nil) where q.first == 6, (0x6e, 0x3f) where q.first == 6:
            guard let cursor else { return nil }
            s = "\u{1b}[\(q.prefix == nil ? "" : "?")\(cursor.row + 1);\(cursor.col + 1)R"
        case (0x6e, nil), (0x6e, 0x3f): s = ""
        default: return nil
        }
        return Array(s.utf8)
    }

    /// OSC 4 (`index ; ?` pairs) and OSC 10/11/12 (stacking `?` slots), as `setOrReportIndexedColor` and
    /// `_setOrReportSpecialColor` read them; answered `ESC ] id ; rgb:rrrr/gggg/bbbb ESC \`.
    private static func osc(_ body: ArraySlice<UInt8>, palette: TermPalette) -> String {
        var b = Array(body)
        // The terminator the scanner ended it at: BEL, an ESC (of ST or the next sequence), C1 ST.
        if b.last == 0x07 || b.last == 0x1b { b.removeLast() }
        else if b.count >= 2, b[b.count - 2] == 0xC2, b[b.count - 1] == 0x9c { b.removeLast(2) }
        b.removeAll { $0 < 0x20 }                                   // C0 is dropped from an OSC body
        let slots = b.split(separator: 0x3b, omittingEmptySubsequences: false).map { Array($0) }
        guard let idSlot = slots.first, !idSlot.isEmpty, idSlot.allSatisfy({ (0x30...0x39).contains($0) }),
              let id = Int(String(decoding: idSlot.prefix(8), as: UTF8.self)) else { return "" }
        func report(_ ident: String, _ c: TermPalette.RGB) -> String {
            "\u{1b}]\(ident);\(c.xtermSpec)\u{1b}\\"
        }
        let q: [UInt8] = [0x3f]
        var out = ""
        if id == 4 {
            var i = 1
            while i + 1 < slots.count {
                let idx = slots[i], spec = slots[i + 1]
                i += 2
                guard !idx.isEmpty, idx.allSatisfy({ (0x30...0x39).contains($0) }) else { continue }
                let n = idx.reduce(0) { min($0 * 10 + Int($1 - 0x30), 1000) }
                if n <= 255, spec == q { out += report("4;\(n)", palette.color(n)) }
            }
        } else if (10...12).contains(id) {
            let colours = [palette.foreground, palette.background, palette.cursor]
            for (i, slot) in slots.dropFirst().enumerated() {
                let offset = id - 10 + i
                if offset >= 3 { break }
                if slot == q { out += report("\(10 + offset)", colours[offset]) }
            }
        }
        return out
    }
}
