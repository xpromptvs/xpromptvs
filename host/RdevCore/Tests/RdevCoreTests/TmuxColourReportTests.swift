import XCTest
@testable import RdevCore

/// What a tmux tab tells tmux its panes' default colours are (`TmuxColourReport`): without it a control-mode
/// tmux answers OSC 10/11 with black (measured, tmux 3.7c).
final class TmuxColourReportTests: XCTestCase {
    private func palette(fg: (UInt8, UInt8, UInt8), bg: (UInt8, UInt8, UInt8)) -> TermPalette {
        var p = TermPalette.xtermDefault
        p.foreground = .init(r: fg.0, g: fg.1, b: fg.2)
        p.background = .init(r: bg.0, g: bg.1, b: bg.2)
        return p
    }

    /// The exact tmux command line — `\033` and `\\` are tmux's own escapes inside double quotes — measured
    /// to make tmux answer `10;?` / `11;?` with these colours.
    func testTheReportIsTheReplyATerminalWouldGiveInTmuxsQuoting() {
        let colours = TmuxColourReport.Colours(palette(fg: (0xd4, 0xd4, 0xd4), bg: (0x1e, 0x1e, 0x1e)))
        XCTAssertEqual(TmuxColourReport.commands(pane: "%12", colours: colours), [
            #"refresh-client -r "%12:\033]10;rgb:d4d4/d4d4/d4d4\033\\""#,
            #"refresh-client -r "%12:\033]11;rgb:1e1e/1e1e/1e1e\033\\""#,
        ])
    }

    /// The pane id is spliced into a command line: anything but `%` and digits is refused.
    func testOnlyAPaneIdIsAccepted() {
        let colours = TmuxColourReport.Colours(.xtermDefault)
        for bad in ["", "%", "12", "%1a", "%1\"; kill-server", "%１"] {
            XCTAssertNil(TmuxColourReport.commands(pane: bad, colours: colours), bad)
        }
    }

    /// One spelling of a colour for the host's own answers and for the report.
    func testAColourIsSpelledAsXtermJsReportsIt() {
        XCTAssertEqual(TermPalette.RGB(r: 0x0a, g: 0xff, b: 0x00).xtermSpec, "rgb:0a0a/ffff/0000")
    }
}
