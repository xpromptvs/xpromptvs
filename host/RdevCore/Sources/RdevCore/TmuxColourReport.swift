import Foundation

/// **A control-mode tmux answers OSC 10/11 with BLACK unless its client tells it otherwise.** tmux answers
/// a pane's single default-colour queries itself (rdev strips them from the stream, so xterm.js never
/// sees them), from the terminal its client is attached to — and a `tmux -C` client is attached to none:
/// measured on tmux 3.7c, both `10;?` and `11;?` came back `rgb:0000/0000/0000`. A program that blends
/// its colours from those two drew them wrong; Codex's "Working" shimmer was black on the dark theme
/// (2026-10-03).
///
/// `refresh-client -r %pane:<report>` hands tmux the REPLY a terminal would have given for that pane,
/// and tmux answers from it (measured, same version). So each tmux tab reports the DRIVER's foreground
/// and background — its xterm.js's theme, the `term-palette` the host already answers from
/// (`TermHostReplies`) — for every pane.
public enum TmuxColourReport {
    /// The two colours a report carries.
    public struct Colours: Equatable, Sendable {
        public let foreground: TermPalette.RGB
        public let background: TermPalette.RGB
        public init(_ palette: TermPalette) {
            foreground = palette.foreground; background = palette.background
        }
    }

    /// The `refresh-client -r` commands that tell tmux `pane`'s default colours, in tmux's command syntax
    /// (`\033` and `\\` inside double quotes). Nil for anything but a pane id (`%` and digits): the id is
    /// spliced into a command line.
    public static func commands(pane: String, colours: Colours) -> [String]? {
        guard pane.count > 1, pane.first == "%", pane.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return [(10, colours.foreground), (11, colours.background)].map { slot, colour in
            "refresh-client -r \"\(pane):\\033]\(slot);\(colour.xtermSpec)\\033\\\\\""
        }
    }
}
