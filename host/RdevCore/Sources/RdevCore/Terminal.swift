import Foundation
import SwiftTerm

/// Headless terminal emulator. Feeds PTY bytes into SwiftTerm (which does the full VT/xterm work —
/// colors, cursor addressing, scroll regions, alt-screen, wrapping, …); what leaves the host is a
/// SNAPSHOT of its whole state (`snapshot()`, TermSnapshotEmitter) followed by the raw bytes. The
/// cell-frame projection the legacy terminal renderer drew is gone with that renderer.
public final class Terminal {
    public private(set) var cols: Int
    public private(set) var rows: Int
    /// Bytes the emulator wants to send back to the PTY (e.g. responses to device-status queries).
    public var onRespond: ((Data) -> Void)?
    /// Fired when the shell sets the window/icon title via OSC 0/2. Fires synchronously inside `feed`.
    public var onTitle: ((String) -> Void)?
    /// Fired for every BEL the emulator EXECUTES — the one xterm.js rings, never the BEL that ends an OSC
    /// (docs/terminal.md, "The bell"). Fires synchronously inside `feed`.
    public var onBell: (() -> Void)?

    private let term: SwiftTerm.Terminal
    private let delegate: Delegate
    private var lastTitle: String?

    /// History the host keeps per tab — equal to the client's xterm.js `scrollback`, because a restore
    /// rebuilds everything the host holds (docs/terminal.md, "Serialized state").
    public static let scrollbackLines = 5000

    public init(cols: Int, rows: Int) {
        self.cols = cols; self.rows = rows
        let d = Delegate()
        self.delegate = d
        self.term = SwiftTerm.Terminal(delegate: d, options: TerminalOptions(cols: cols, rows: rows, scrollback: Terminal.scrollbackLines))
        // SwiftTerm `print()`s an "Info: Unhandled DEC Private Mode …" line for every sequence it does not
        // implement, and its `silentLog` defaults to false in DEBUG — which is what `swift run` builds. The
        // host's stdout is a UI (pairing code, QR, status), so a TUI probing for, say, mode 2031 (the
        // contour colour-scheme-change extension, unimplemented by SwiftTerm AND by xterm.js) scribbles
        // over it. Nothing is broken when this fires; flip it back to see what a shell is asking for.
        self.term.silentLog = true
        d.onSend = { [weak self] data in self?.onRespond?(Data(data)) }
        d.onTitle = { [weak self] title in self?.lastTitle = title; self?.onTitle?(title) }
        d.onBell = { [weak self] in self?.onBell?() }
    }

    /// Feed raw PTY output into the emulator. `onRespond` / `onTitle` fire synchronously in here.
    /// 8-bit C1 code points reach SwiftTerm as the 7-bit sequences xterm.js makes of them (`C1Translator`):
    /// the host's emulator must read the stream as the client's does.
    public func feed(_ bytes: [UInt8]) {
        term.feed(byteArray: c1.translate(bytes))
    }
    private var c1 = C1Translator()

    /// The emulator's whole state — screen, history (capped at `TermSnapshot.historyCap`), modes,
    /// regions, saved cursors — for `TermSnapshotEmitter`. Same threading rule as `feed`.
    public func snapshot() -> TermSnapshot { SwiftTermSnapshot.capture(term, title: lastTitle) }
    /// The text of the last `count` rows of the screen it SHOWS (the alternate one while it is up), top to bottom —
    /// what an agent's activity is read from (`AgentActivity`). Read as `snapshot()` is: on the feeding path.
    public func screenRows(last count: Int) -> [String] { SwiftTermSnapshot.screenRows(term, last: count) }

    /// The modes that decide which input a client can LEGITIMATELY produce for this tab (`ModeInput`),
    /// read straight off the emulator's own accessors — the same ones `SwiftTermSnapshot.capture`'s
    /// `modes` block reads — rather than building a whole `TermSnapshot` per keystroke batch.
    public func inputModes() -> TermModes {
        var m = TermModes()
        m.applicationCursor = term.applicationCursor
        m.mouse = SwiftTermSnapshot.mouse(term.mouseMode)
        switch term.rdevMouseEncoding {
        case .sgr: m.mouseEncoding = .sgr
        case .sgrPixel: m.mouseEncoding = .sgrPixels
        case .x10, .utf8, .urxvt: m.mouseEncoding = .standard     // xterm.js implements neither of the last two
        }
        m.focusReporting = term.rdevSendFocus
        m.bracketedPaste = term.bracketedPasteMode
        m.cursorVisible = !term.rdevCursorHidden
        m.altScreen = term.isCurrentBufferAlternate
        return m
    }

    /// Resize the emulator (and its scrollback buffers). The PTY winsize is updated separately.
    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        self.cols = cols; self.rows = rows
        term.resize(cols: cols, rows: rows)
    }

    /// Current cursor position in visible (col, row) coordinates.
    public func cursorLocation() -> (col: Int, row: Int) { let c = term.getCursorLocation(); return (c.x, c.y) }
}

/// Minimal headless delegate — SwiftTerm's `TerminalDelegate` extension defaults the rest; we only
/// route the emulator's outbound bytes (query responses) back to the PTY.
private final class Delegate: TerminalDelegate {
    var onSend: ((ArraySlice<UInt8>) -> Void)?
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?
    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) { onSend?(data) }
    func bell(source: SwiftTerm.Terminal) { onBell?() }
    func setTerminalTitle(source: SwiftTerm.Terminal, title: String) { onTitle?(title) }
}
