import Foundation

/// What `display -p` tells us about the pane a tmux tab shows. tmux exposes most tracked modes as
/// formats — bracketed paste (?2004) only since 3.7 (`bracket_paste_flag`), and focus reporting (?1004)
/// not at all (3.7c: no format reads `MODE_FOCUSON`). What tmux does not say starts OFF and is learned
/// from the pane's output by `TermModeTracker` (a shell re-asserts ?2004h at its next prompt). Off is
/// the conservative default: never send the app bytes it did not ask for.
///
/// The scroll region, origin mode and synchronized output are NOT client-behaviour modes (`TermModes`)
/// — they decide what the next bytes DRAW — and for a tmux tab they come only from here, never from the
/// tracker: tmux resets the region on a resize and ends a synchronized update on its own after 1 s,
/// neither of which a stream follower can see. They are the format's LAST fields, in the order tmux
/// gained them (the region and `origin_flag` by 3.0, which rdev needs anyway for `send-keys -H`;
/// `synchronized_output_flag` later; `bracket_paste_flag` in 3.7), so a tmux too old for the newest
/// (it expands to nothing) still parses: no update in progress, bracketed paste left to the stream.
public struct TmuxPaneState: Equatable, Sendable {
    public var pane: String
    public var cursorX: Int
    public var cursorY: Int
    public var width: Int
    public var height: Int
    public var modes: TermModes
    /// Rows in the pane's history, and the most tmux keeps (`history-limit`).
    public var historySize: Int
    public var historyLimit: Int
    /// The scroll region's first and last row, 0-based (tmux's `rupper`/`rlower`).
    public var scrollTop: Int
    public var scrollBottom: Int
    /// DECOM (?6): cursor addressing is relative to the region's top. `cursorY` stays ABSOLUTE.
    public var originMode: Bool
    /// The app is inside a synchronized update (`?2026h` seen, `?2026l` not yet).
    public var synchronizedOutput: Bool

    public static let format = "#{pane_id} #{cursor_x} #{cursor_y} #{pane_width} #{pane_height} #{alternate_on} "
        + "#{cursor_flag} #{keypad_cursor_flag} #{mouse_standard_flag} #{mouse_button_flag} #{mouse_all_flag} #{mouse_sgr_flag} "
        + "#{history_size} #{history_limit} "
        + "#{scroll_region_upper} #{scroll_region_lower} #{origin_flag} #{synchronized_output_flag} #{bracket_paste_flag}"

    public static func parse(_ line: String) -> TmuxPaneState? {
        let f = line.split(separator: " ")
        guard [14, 17, 18, 19].contains(f.count), f[0].hasPrefix("%") else { return nil }
        let n = f.dropFirst().compactMap { Int($0) }
        guard n.count == f.count - 1 else { return nil }
        var m = TermModes()
        m.altScreen = n[4] == 1
        m.cursorVisible = n[5] == 1
        m.applicationCursor = n[6] == 1
        m.mouse = n[9] == 1 ? .anyEvent : n[8] == 1 ? .buttonEvent : n[7] == 1 ? .vt200 : .off
        m.mouseEncoding = n[10] == 1 ? .sgr : .standard
        m.bracketedPaste = n.count >= 18 && n[17] == 1
        let region = n.count >= 16 ? (n[13], n[14]) : (0, n[3] - 1)
        return TmuxPaneState(pane: String(f[0]), cursorX: n[0], cursorY: n[1], width: n[2], height: n[3], modes: m,
                             historySize: n[11], historyLimit: n[12],
                             scrollTop: region.0, scrollBottom: region.1,
                             originMode: n.count >= 16 && n[15] == 1,
                             synchronizedOutput: n.count >= 17 && n[16] == 1)
    }
}

