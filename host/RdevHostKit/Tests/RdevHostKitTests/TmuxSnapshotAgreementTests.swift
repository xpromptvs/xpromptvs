import XCTest
import RdevCore
@testable import RdevHostKit
import RdevTmuxRig

/// tmux and SwiftTerm fed the SAME stream agree, up to tmux's known limits (docs/terminal.md): what
/// `TmuxSnapshot` reads back from tmux — through the product's own control client and the exact
/// `TmuxSnapshot.commands` batch — emitted and replayed into SwiftTerm, shows the rows, attributes,
/// history, region, cursor and modes SwiftTerm has for that stream.
///
/// PRIVATE server (`PrivateTmux`: `-L`, every command `-f /dev/null`), so neither the user's server nor
/// their ~/.tmux.conf is ever touched; killed and its socket removed in teardown. Panes only `cat` fixed
/// bytes. Skips LOUDLY without tmux.
///
/// NEVER COMPARED, for any stream — tmux cannot report them, or rdev does not read them (the Known
/// limits in TmuxSnapshot's header): the pen, both saved cursors, charsets and GL, tab stops, the
/// title, `?45`, and the wrap flag of a SCREEN row. `?1004` is not tmux's either: it
/// is passed from a `TermModeTracker` fed the stream, as the product does.
///
/// Anything else a case may not compare is an `Exclusion`, named per case with the reason.
final class TmuxSnapshotAgreementTests: XCTestCase {
    private var server: PrivateTmux!
    private var runner: TmuxRunner { server.runner }
    /// The last `viaTmux` pane as tmux itself prints it — history and screen, attributes, and its cursor
    /// — read WITHOUT TmuxSnapshot, so a comparison of two of them does not share its mistakes.
    private var rawPane = ""
    /// The last `viaTmux` batch's server width options and version (the product reads the same replies).
    private var lastGlyphs = TmuxGlyphOptions.default
    private var lastVersion = ""

    override func setUpWithError() throws {
        // A failing setUp included, `PrivateTmux` kills what it started: it throws only after stopping.
        guard let t = try PrivateTmux(socket: "rdev-tsa-\(getpid())") else {
            throw XCTSkip("tmux is not installed — TmuxSnapshotAgreementTests did NOT run")
        }
        server = t
        addTeardownBlock { t.stop() }
    }

    @discardableResult
    private func tmux(_ args: [String]) -> (status: Int32, stdout: String) { server.run(args) }

    // MARK: the comparison

    enum Exclusion: Hashable {
        /// The visible rows' text.
        case screenText
        /// Attributes of the visible rows' cells.
        case screenAttrs
        /// How many history rows there are.
        case historyCount
        /// The history rows both hold (the newest): text, wrap flags and attributes.
        case history
        case region
        case cursor
        /// One mode, by name (`TermSnapshotModes` field).
        case mode(String)
        /// The saved normal screen under an alt screen.
        case savedNormal
    }

    private func text(_ l: TermLine) -> String {
        l.cells.map { $0.text.isEmpty ? " " : $0.text }.joined().replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    /// Attributes per COLUMN. A cell SwiftTerm holds as ERASED compares by background only: tmux stores
    /// an erased cell as a written space (a known limit), and all an erased cell shows is its background.
    private func attrDiffs(_ a: TermLine, _ b: TermLine) -> [String] {
        func columns(_ l: TermLine) -> [Int: TermCell] {
            var x = 0, out: [Int: TermCell] = [:]
            for c in l.cells { out[x] = c; x += Int(c.width) }
            return out
        }
        let ca = columns(a), cb = columns(b)
        var diffs: [String] = []
        for x in Set(ca.keys).union(cb.keys).sorted() {
            let l = ca[x], r = cb[x]
            let erased = (r?.text ?? "").isEmpty
            let la = l?.attrs ?? TermAttrs(), ra = r?.attrs ?? TermAttrs()
            if erased ? la.bg != ra.bg : la != ra { diffs.append("col \(x): tmux \(la) swiftterm \(ra)") }
        }
        return diffs
    }

    private func modes(_ s: TermSnapshot) -> [String: String] {
        let m = s.modes
        return ["applicationCursor": "\(m.applicationCursor)", "applicationKeypad": "\(m.applicationKeypad)",
                "insert": "\(m.insert)", "wraparound": "\(m.wraparound)", "origin": "\(m.origin)",
                "bracketedPaste": "\(m.bracketedPaste)", "focusReporting": "\(m.focusReporting)",
                "mouse": "\(m.mouse)", "mouseEncoding": "\(m.mouseEncoding)",
                "synchronizedOutput": "\(m.synchronizedOutput)", "cursorVisible": "\(s.cursor.visible)",
                "cursorStyle": "\(s.cursor.style)"]
    }

    /// Every difference between the two, by category — empty when they agree.
    private func differences(tmux t: TermSnapshot, swift s: TermSnapshot) -> [Exclusion: [String]] {
        var d: [Exclusion: [String]] = [:]
        func add(_ k: Exclusion, _ m: String) { d[k, default: []].append(m) }
        if t.activeIsAlt != s.activeIsAlt { add(.screenText, "alt screen: tmux \(t.activeIsAlt) swiftterm \(s.activeIsAlt)") }
        for (r, (a, b)) in zip(t.screen, s.screen).enumerated() {
            if text(a) != text(b) { add(.screenText, "row \(r): tmux \(text(a).debugDescription) swiftterm \(text(b).debugDescription)") }
            for m in attrDiffs(a, b) { add(.screenAttrs, "row \(r) \(m)") }
        }
        let th = Array(t.normal.lines.dropLast(t.rows)), sh = Array(s.normal.lines.dropLast(s.rows))
        if th.count != sh.count { add(.historyCount, "history rows: tmux \(th.count) swiftterm \(sh.count)") }
        for (i, (a, b)) in zip(th.suffix(min(th.count, sh.count)), sh.suffix(min(th.count, sh.count))).enumerated() {
            if text(a) != text(b) || a.wrapped != b.wrapped {
                add(.history, "history \(i): tmux \(text(a).debugDescription)/\(a.wrapped) swiftterm \(text(b).debugDescription)/\(b.wrapped)")
            }
            for m in attrDiffs(a, b) { add(.history, "history \(i) \(m)") }
        }
        if t.activeIsAlt, s.activeIsAlt {
            for (r, (a, b)) in zip(t.normal.lines.suffix(t.rows), s.normal.lines.suffix(s.rows)).enumerated() where text(a) != text(b) {
                add(.savedNormal, "saved row \(r): tmux \(text(a).debugDescription) swiftterm \(text(b).debugDescription)")
            }
        }
        let tb = t.alt ?? t.normal, sb = s.alt ?? s.normal
        if [tb.scrollTop, tb.scrollBottom] != [sb.scrollTop, sb.scrollBottom] {
            add(.region, "region: tmux \(tb.scrollTop)-\(tb.scrollBottom) swiftterm \(sb.scrollTop)-\(sb.scrollBottom)")
        }
        if [t.cursor.x, t.cursor.y] != [s.cursor.x, s.cursor.y] {
            add(.cursor, "cursor: tmux \(t.cursor.x),\(t.cursor.y) swiftterm \(s.cursor.x),\(s.cursor.y)")
        }
        let tm = modes(t), sm = modes(s)
        for k in tm.keys.sorted() where tm[k] != sm[k] { add(.mode(k), "\(k): tmux \(tm[k]!) swiftterm \(sm[k]!)") }
        return d
    }

    // MARK: driving tmux


    private func splitLines(_ s: String) -> [String] {
        var l = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if l.last == "" { l.removeLast() }
        return l
    }

    /// `bytes` into a fresh `cols × rows` pane, snapshotted as the product does (`PrivateTmux.capture`).
    private func viaTmux(_ bytes: [UInt8], cols: Int, rows: Int, name: String) throws -> TermSnapshot {
        record(try server.capture(bytes, cols: cols, rows: rows, name: name))
    }

    private func record(_ c: PrivateTmux.Capture) -> TermSnapshot {
        rawPane = c.rawPane
        lastGlyphs = c.glyphs
        lastVersion = c.version
        return c.snapshot
    }

    /// tmux's snapshot, emitted and replayed into a fresh SwiftTerm, against SwiftTerm fed `bytes`.
    /// `excluding`: differences this stream MUST show (a stale one fails). `tolerating`: differences that
    /// depend on timing and may or may not show.
    private func check(_ name: String, _ bytes: [UInt8], cols: Int, rows: Int, excluding: [Exclusion: String] = [:],
                       tolerating: [Exclusion: String] = [:]) throws {
        let fromTmux = try viaTmux(bytes, cols: cols, rows: rows, name: name)
        let replayed = Terminal(cols: cols, rows: rows)
        _ = replayed.feed(TermSnapshotEmitter.emit(fromTmux))
        let direct = Terminal(cols: cols, rows: rows)
        _ = direct.feed(bytes)
        let diffs = differences(tmux: replayed.snapshot(), swift: direct.snapshot())
        for (kind, lines) in diffs where excluding[kind] == nil && tolerating[kind] == nil {
            XCTFail("\(name) \(kind):\n  " + lines.prefix(8).joined(separator: "\n  ") + (lines.count > 8 ? "\n  … \(lines.count - 8) more" : ""))
        }
        // An exclusion that no longer excludes anything is stale: the limit it names has gone.
        for (kind, why) in excluding where diffs[kind] == nil { XCTFail("\(name): exclusion \(kind) (\(why)) excludes nothing") }
    }

    // MARK: the streams

    private let stream = "\u{1b}[2J\u{1b}[H\u{1b}[1;31mred bold\u{1b}[0m plain\r\n中文 wide\r\n\u{1b}[38;2;10;20;30mrgb\u{1b}[0m\r\n"
        + "\u{1b}[3;10r\u{1b}[10;1H" + (1...12).map { "\nr\($0)" }.joined() + "\u{1b}[1;1Htop"

    func testTmuxAndSwiftTermAgreeOnTheSameStream() throws {
        try check("brief", Array(stream.utf8), cols: 40, rows: 12, excluding: [.historyCount: Self.regionHistory])
        let direct = Terminal(cols: 40, rows: 12)
        _ = direct.feed(Array(stream.utf8))
        // LF without CR, so each `rN` starts where the last ended: r12 ends the region's bottom row.
        XCTAssertTrue(direct.snapshot().screen[9].cells.map(\.text).joined().hasSuffix("r12"), "non-vacuous: the region scrolled")
    }

    /// The shapes this task measured tmux doing differently from a line-by-line reading: the pen
    /// carried across capture lines, an erase with a background (`-N`), pending wrap at
    /// `cursor_x == width`, a wrapped history line split back into rows, and an emoji.
    func testTheMeasuredShapesAgree() throws {
        var s = "\u{1b}[1mbold\r\nstill bold\u{1b}[0m\r\n"
        s += String(repeating: "w", count: 25) + "\r\n" + "0123456789012345678中x\r\n😀 emoji 🚀\r\n"
        s += (1...10).map { "line \($0)\r\n" }.joined()
        s += "\u{1b}[44mx\u{1b}[K\u{1b}[0m\r\n" + "\u{1b}[43m" + String(repeating: "Z", count: 20)
        try check("measured", Array(s.utf8), cols: 20, rows: 6)
    }

    /// The same erase with a background, scrolled into HISTORY: tmux has trimmed the coloured tail from
    /// the line by then (measured: `-J` and `-J -N` both return `x` alone), so no flag brings it back.
    func testHistoryLosesAnErasedBackgroundTail() throws {
        let s = "\u{1b}[44mx\u{1b}[K\u{1b}[0m\r\n" + (1...8).map { "line \($0)\r\n" }.joined()
        try check("history-bg-tail", Array(s.utf8), cols: 20, rows: 4, excluding: [.history: Self.historyBgTail])
    }

    /// Every case of the serializer corpus (protocol/fixtures/term-corpus) that tmux can represent, each
    /// exclusion named with its reason.
    func testTheCorpusAgreesUpToTmuxsKnownLimits() throws {
        struct Case: Decodable { let name: String; let cols: Int; let rows: Int }
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/term-corpus")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(cases.count, 34, "the corpus changed: review this test's exclusions")
        for c in cases where !Self.tmuxModelOnly.contains(c.name) {
            let bytes = [UInt8](try Data(contentsOf: dir.appendingPathComponent("\(c.name).bin")))
            try check(c.name, bytes, cols: c.cols, rows: c.rows, excluding: Self.corpusExclusions[c.name] ?? [:],
                      tolerating: Self.corpusTimings[c.name] ?? [:])
        }
    }

    /// The cursor style tmux reports (`cursor_shape`, `cursor_blinking`) is the one SwiftTerm has for the
    /// same DECSCUSR — a TUI's bar cursor must not come back a block. (The corpus's `cursor-style` is
    /// the steady bar.)
    func testTheCursorStyleAgrees() throws {
        try check("blinking-bar", Array("\u{1b}[5 qinsert mode".utf8), cols: 20, rows: 3)
        try check("steady-underline", Array("\u{1b}[4 qreplace".utf8), cols: 20, rows: 3)
    }

    /// `ich-dch-gaps` without the DECIC/DECDC its exclusion is about: ICH and DCH with and without a
    /// background still agree.
    func testInsertAndDeleteCharacterAgree() throws {
        func csi(_ s: String) -> String { "\u{1b}[" + s }
        var s = (0..<6).map { "\($0) abcdefghijklmnopqrstuvwxyz\r\n" }.joined()
        s += csi("1;3H") + csi("2@") + csi("2;3H") + csi("44m") + csi("3@") + csi("0m")
        s += csi("3;3H") + csi("4P") + csi("4;3H") + csi("41m") + csi("2P") + csi("0m") + csi("8;1H") + "done"
        try check("ich-dch", Array(s.utf8), cols: 30, rows: 8)
    }

    // MARK: a tmux tab counts glyphs as tmux does

    /// The corpus cases whose glyphs tmux counts or joins differently from SwiftTerm (docs/terminal.md,
    /// "tmux tabs count as tmux does": it joins across sequences, overhangs a widening in the last
    /// column, keeps ☝🏽 apart, gives a zero-width scalar after a control no column, joins any non-ASCII
    /// scalar after a ZWJ). A tmux tab's client follows TMUX, so these are checked against tmux itself
    /// (`testATmuxTabCountsAsTmuxDoes`), not against SwiftTerm — where they differ by design.
    static let tmuxModelOnly: Set<String> = ["emoji-split", "emoji-margin", "emoji-margin-skin-tone", "grapheme-joins"]

    /// tmux's snapshot of each glyph case, emitted and fed to a FRESH tmux pane, comes back the same —
    /// so `TmuxSnapshot` cuts the capture into tmux's own cells and widths (`TmuxGlyphs`) and the
    /// emitter puts each back where tmux had it: joined, widened or overhanging. The emitted bytes and
    /// tmux's cursor are also the committed fixtures protocol/fixtures/tmux-snapshot/, which
    /// web/test/term-tmux-fidelity.test.ts replays into the client's tmux provider: produced by
    /// `//tools/TmuxSnapshotFixtures` through the SAME `TmuxSnapshotFixtures.fixture`, and a stale one
    /// fails here, naming it.
    func testATmuxTabCountsAsTmuxDoes() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures")
        XCTAssertEqual(TmuxSnapshotFixtures.caseNames, Self.tmuxModelOnly.union(["emoji-widths"]))
        let cases = try TmuxSnapshotFixtures.cases(fixtures: fixtures)
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            let f = try TmuxSnapshotFixtures.fixture(c, fixtures: fixtures, tmux: server)
            let a = record(f.capture)
            let rawA = rawPane
            let b = try viaTmux(f.emitted, cols: c.cols, rows: c.rows, name: "\(c.name) (replayed)")
            // tmux's OWN view of both panes, not TmuxSnapshot's: the same rows, cells and cursor.
            XCTAssertEqual(rawPane, rawA, "\(c.name): the replayed pane as tmux prints it")
            for (kind, lines) in differences(tmux: b, swift: a) {
                XCTFail("\(c.name) \(kind), tmux's snapshot replayed into tmux against tmux's own:\n  " + lines.prefix(8).joined(separator: "\n  "))
            }
            let have = (try? Data(contentsOf: fixtures.appendingPathComponent("tmux-snapshot/\(c.name).emitted.bin"))) ?? Data()
            let haveCursor = (try? Data(contentsOf: fixtures.appendingPathComponent("tmux-snapshot/\(c.name).cursor.json"))) ?? Data()
            XCTAssertTrue(have == Data(f.emitted) && haveCursor == f.cursor,
                          "protocol/fixtures/tmux-snapshot/\(c.name) is stale — run: \(TmuxSnapshotFixtures.regenerate)")
        }
    }

    /// The server's width options REACH the model (measured on 3.7c): each changes where tmux puts the
    /// cursor, and the snapshot built with the options read from that server puts it — and its cells —
    /// in the same place; the options go to the client first, in band.
    func testTheServersWidthOptionsReachTheModel() throws {
        for (option, value, text, x) in [("variation-selector-always-wide", "off", "x\u{FE0F}X", 2),
                                         ("codepoint-widths", "U+261D=1", "\u{261D}X", 2)] {
            let plain = try viaTmux(Array(text.utf8), cols: 20, rows: 3, name: "\(option) default")
            XCTAssertEqual([plain.cursor.x, lastGlyphs.isDefault ? 1 : 0], [3, 1], "\(option): tmux's default puts X at 2, the cursor at 3")
            XCTAssertEqual(tmux(["set-option", "-s", option, value]).status, 0)
            defer { tmux(["set-option", "-su", option]) }
            let snap = try viaTmux(Array(text.utf8), cols: 20, rows: 3, name: "\(option) \(value)")
            XCTAssertEqual(snap.cursor.x, x, "\(option) \(value): tmux's own cursor")
            XCTAssertFalse(lastGlyphs.isDefault, "\(option) \(value) was read from the server")
            let row = snap.screen[0].cells.reduce(0) { $0 + Int($1.width) }
            XCTAssertEqual(row, x, "\(option) \(value): the cells TmuxSnapshot cut come to tmux's columns")
            XCTAssertTrue(TmuxSnapshot.emit(snap, glyphs: lastGlyphs).starts(with: Array("\u{1b}]9910;".utf8)))
        }
    }

    /// The model is tmux 3.7c's on utf8proc 2.11.3, AS MEASURED (protocol/fixtures/tmux-glyphs.json): the
    /// local tmux must be that one, and every measured sample must still land where the fixture says —
    /// or the fixture, the client's provider and TmuxGlyphs are all out of date together.
    func testTheMeasuredModelIsThisTmux() throws {
        struct Sample: Decodable { let name: String; let text: String; let x: Int; let y: Int }
        struct Doc: Decodable { let tmux: String; let utf8proc: String; let samples: [Sample] }
        let doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/tmux-glyphs.json")))
        let remedy = "the glyph model was measured on tmux \(doc.tmux) / utf8proc \(doc.utf8proc): re-run "
            + "scripts/measure_tmux_glyphs.py, then the tmux-snapshot fixtures (\(TmuxSnapshotFixtures.regenerate))"
        XCTAssertEqual(runner.run(["-V"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "tmux \(doc.tmux)", remedy)
        XCTAssertEqual(doc.tmux, TmuxGlyphs.measuredVersion, remedy)
        _ = try viaTmux(Array("x".utf8), cols: 20, rows: 3, name: "version")
        XCTAssertEqual(lastVersion, doc.tmux, "the SERVER's version, as the product reads it: " + remedy)
        // utf8proc as tmux links it (tmux has no format for it): otool, then the library's own answer.
        let otool = Process()
        otool.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        otool.arguments = ["-L", URL(fileURLWithPath: runner.path).resolvingSymlinksInPath().path]
        let pipe = Pipe()
        otool.standardOutput = pipe
        try otool.run(); otool.waitUntilExit()
        let linked = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lib = try XCTUnwrap(linked.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.contains("libutf8proc") }?.split(separator: " ").first.map(String.init), "tmux links no utf8proc: " + remedy)
        let handle = try XCTUnwrap(dlopen(lib, RTLD_NOW), "cannot load \(lib)")
        defer { dlclose(handle) }
        typealias Version = @convention(c) () -> UnsafePointer<CChar>
        let version = String(cString: unsafeBitCast(try XCTUnwrap(dlsym(handle, "utf8proc_version")), to: Version.self)())
        XCTAssertEqual(version, doc.utf8proc, remedy)
        // Every sample, replayed on this private server: tmux's cursor where the fixture has it.
        var off: [String] = []
        for s in doc.samples {
            let snap = try viaTmux(Array(s.text.utf8), cols: 20, rows: 5, name: s.name)
            if snap.cursor.x != s.x || snap.cursor.y != s.y { off.append("\(s.name): tmux \(snap.cursor.x),\(snap.cursor.y) fixture \(s.x),\(s.y)") }
        }
        XCTAssertEqual(off, [], remedy)
        XCTAssertGreaterThan(doc.samples.count, 50)
    }

    // MARK: tmux's own behaviour, where it is not xterm.js's (for docs/terminal.md, Known limits)

    static let regionHistory = "tmux keeps a line scrolled out of ANY scroll region in its history "
        + "(grid_scroll_history_region); xterm.js and SwiftTerm keep only what leaves a region starting at the top row"
    static let historyBgTail = "tmux keeps no erased background tail on a HISTORY line; the screen's comes back with -N"
    static let historyChunk = "tmux at history-limit frees the oldest 10% at once (grid_collect_history), so it holds "
        + "4500-5000 rows where SwiftTerm holds exactly 5000; the rows both hold agree"

    static let corpusExclusions: [String: [Exclusion: String]] = [
        "scroll-region-origin": [.historyCount: regionHistory],
        "scrollback-overflow": [.historyCount: historyChunk],
        "recycled-wrapped-line": [.historyCount: historyChunk],
        "mouse-modes": [.mode("mouseEncoding"): "tmux does not implement ?1016 (SGR pixels): the pane's encoding stays standard"],
        "bracketed-insert-nowrap": [.cursor: "with ?7l tmux parks the cursor on the last column (x = width-1) where "
            + "SwiftTerm and xterm.js hold x == cols; the next glyph lands on the last column either way"],
        "alt-saved-cursor-bg": [.screenAttrs: "?1049h under a coloured pen: xterm.js (and patched SwiftTerm) fill the alt "
            + "screen with the pen's background, tmux with the default"],
        "continuation-bg": [.screenAttrs: "a wrap that SCROLLS: xterm.js (and patched SwiftTerm) fill the new row with the "
            + "pen's background, tmux with the default (screen_write_linefeed(…, 8))"],
        "ich-dch-gaps": [.screenText: decColumnOps, .screenAttrs: decColumnOps],
        "alt-screen-reentry": [.screenText: tabsPerPane, .cursor: tabsPerPane],
        "c1-controls": [.screenText: c1AsText, .cursor: c1AsText, .screenAttrs: c1AsText],
    ]
    static let c1AsText = "tmux reads BYTES: U+0080-U+009F are characters to it, not the C1 controls xterm.js "
        + "(and SwiftTerm through C1Translator) act on — measured, it answers no C1 query either"
    static let decColumnOps = "tmux does not implement DECIC/DECDC (CSI ' } / CSI ' ~); testInsertAndDeleteCharacterAgree "
        + "covers the rest of the case"
    static let tabsPerPane = "tmux keeps ONE set of tab stops per pane across alt-screen switches; xterm.js restores the "
        + "defaults when it clears the alt buffer, so a later tab lands elsewhere"

    static let corpusTimings: [String: [Exclusion: String]] = [
        "sync-open": [.mode("synchronizedOutput"): "tmux ends a synchronized update on its own 1 s after ?2026h "
            + "(screen_write_start_sync); a slow capture sees it ended, SwiftTerm never ends it"],
    ]
}
