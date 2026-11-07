#!/usr/bin/env python3
"""The terminal serializer's corpus: DETERMINISTIC byte streams, one per case, that the differential
fidelity check (web/test/term-snapshot-fidelity.test.ts) replays into xterm.js and that the Swift
fixture writer (//tools/TermSnapshotFixtures) replays into SwiftTerm.

Everything here is SYNTHESISED. The "Claude-like TUI" is an Ink-style redraw loop written by hand —
no model is called, and nothing is recorded from a real session.

A case avoids exactly the documented Known limits of the serializer (docs/terminal.md): hyperlinks,
`38;5;n` for n < 16, and an erased tail on a wrapped line. Glyph WIDTHS are not a limit since
2026-09-27 (docs/terminal.md, "Glyph widths"): the four `emoji-*` cases cover emoji, VS16, ZWJ, skin
tones, flags, graphemes split by a sequence and widening at the margin, with no exclusion. What still
differs in TEXT but not in columns stays out: a zero-width format character (ZWSP) SwiftTerm drops
and xterm.js keeps in the previous cell, and a joiner at the right margin under ?7l. Everything else is fair game. (Bold with a 0–15 colour is P16 here; the fidelity
check compares palette colours by index, so the P16-vs-P256 rendering limit does not reach it.)

The cases after "cursor-style" are the shapes the emitter's reviews found — each once corrupted the
emitted screen or is a place SwiftTerm and xterm.js were suspected to disagree — and stay in the corpus
for that reason. Deterministic: two runs write identical bytes. After a change, regenerate the Swift
fixtures too (`bazelisk run //tools/TermSnapshotFixtures -- "$PWD/protocol/fixtures"`) and update the
count in host/RdevCore/Tests/RdevCoreTests/TermSnapshotFixtureTests.swift.

Usage: python3 scripts/gen_term_corpus.py   (writes protocol/fixtures/term-corpus/)
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "protocol", "fixtures", "term-corpus")
ESC = "\x1b"


def csi(s):
    return ESC + "[" + s


CASES = []


def case(name, cols, rows):
    def register(fn):
        CASES.append((name, cols, rows, fn))
        return fn
    return register


@case("sgr-torture", 80, 24)
def sgr_torture():
    out = []
    for i, s in enumerate(["1", "2", "3", "4", "4:2", "4:3", "4:4", "4:5", "5", "7", "8", "9", "1;3;4", "2;9"]):
        out.append(csi(s + "m") + "s%d" % i + csi("0m") + " ")
    out.append("\r\n")
    for n in range(16):
        out.append(csi("%dm" % (30 + n if n < 8 else 90 + n - 8)) + "f%d" % n)
        out.append(csi("%dm" % (40 + n if n < 8 else 100 + n - 8)) + "b" + csi("0m"))
    out.append("\r\n")
    for n in range(16, 256, 7):
        out.append(csi("38;5;%dm" % n) + "x" + csi("48;5;%dm" % n) + "y")
    out.append(csi("0m") + "\r\n")
    for r in range(0, 256, 51):
        out.append(csi("38;2;%d;%d;%dm" % (r, 255 - r, r // 2)) + "t" + csi("48;2;%d;%d;7m" % (255 - r, r)) + "u")
    out.append(csi("0m") + "\r\n")
    out.append(csi("4;58;5;196m") + "ulc" + csi("58;2;1;2;3m") + "ulrgb" + csi("0m") + "\r\n")
    out.append(csi("44m") + "blue-bg-erased" + csi("K") + csi("0m") + "\r\n")   # erased cells with a background
    out.append("mid" + csi("10C") + "gap\r\n")                                    # cells never written, mid-line
    out.append(csi("41m") + csi("5X") + csi("0m") + "\r\n")                       # ECH with a background
    out.append(csi("1;31m") + "open pen")                                          # the pen stays bold red
    return "".join(out)


@case("wide-cjk", 40, 10)
def wide_cjk():
    return ("中文字符テスト한국어\r\n"
            + "a" * 39 + "中\r\n"                         # a wide glyph that does not fit wraps
            + "e\u0301 cafe\u0301 n\u0303\r\n"             # combining marks
            + "全角ＡＢＣ" * 5 + "\r\n"
            + csi("33m") + "黄色" + csi("0m"))


@case("wrapped-lines", 80, 24)
def wrapped_lines():
    body = "".join("%03d" % i + ("abcdefghij" * 25)[: 150 + i] + "\r\n" for i in range(20))
    return body + "x" * 160 + "\r\n" + "y" * 80 + "\r\n" + "tail"


@case("scroll-region-origin", 80, 24)
def scroll_region_origin():
    out = csi("2J") + csi("1;1H") + "HEADER" + csi("24;1H") + "FOOTER" + csi("3;20r") + csi("?6h") + csi("1;1H")
    out += "".join("\r\nregion line %d" % i for i in range(60))
    return out + csi("5;10H") + "here"


@case("alt-screen-vim", 80, 24)
def alt_screen_vim():
    out = "".join("shell history %d\r\n" % i for i in range(300)) + "$ vim" + csi("1;33m")
    out += csi("?1049h") + csi("0m") + csi("H") + csi("2J")
    for r in range(1, 23):
        out += csi("%d;1H" % r) + csi("34m") + "~" + csi("0m") + ("  line %d" % r if r < 12 else "")
    out += csi("23;1H") + csi("7m") + " NORMAL  file.txt" + " " * 40 + csi("0m") + csi("24;1H") + ":wq"
    return out + csi("1;22r") + csi("5;9H") + ESC + "7" + csi("7;3H")


@case("less-like", 80, 24)
def less_like():
    out = "".join("before less %d\r\n" % i for i in range(30))
    out += csi("?1049h") + csi("?1h") + ESC + "=" + csi("H") + csi("2J")
    out += "".join(csi("%d;1H" % r) + "less page line %d" % r for r in range(1, 24))
    return out + csi("24;1H") + csi("7m") + "(END)" + csi("0m") + csi("?25l")


@case("htop-like", 100, 30)
def htop_like():
    out = csi("?1049h") + csi("?1000h") + csi("?1006h") + csi("?25l") + csi("H") + csi("2J")
    for r in range(1, 30):
        pct = (r * 37) % 100
        out += csi("%d;1H" % r) + "%3d [" % r + csi("42m") + " " * (pct // 2) + csi("0m") + " " * (50 - pct // 2) + "] %d%%" % pct
    return out + csi("30;1H") + csi("46;30m") + "F1Help F2Setup F10Quit" + csi("K") + csi("0m")


@case("claude-like-tui", 100, 30)
def claude_like_tui():
    """An Ink-style TUI on the NORMAL screen: history above, a live region redrawn in place inside
    synchronized updates, the prompt box drawn in box-drawing glyphs. Glyphs are ones SwiftTerm and
    xterm.js 6 agree are one column wide."""
    def box(w, lines):
        return ("╭" + "─" * (w - 2) + "╮\r\n"
                + "".join("│ " + l.ljust(w - 4) + " │\r\n" for l in lines)
                + "╰" + "─" * (w - 2) + "╯\r\n")
    out = "".join("$ earlier command %d\r\n" % i for i in range(200))
    out += csi("?2004h") + csi("?1004h") + csi("?25l")
    height = 0
    for frame in range(6):
        out += csi("?2026h")
        if height:
            out += csi("%dA" % height) + "\r" + csi("J")
        part = (csi("38;5;174m") + "✻ " + csi("0m") + csi("1m") + "Thinking…" + csi("0m")
                + csi("2;3m") + " (%ds · esc to interrupt)" % frame + csi("0m") + "\r\n"
                + "⏺ " + csi("38;2;215;119;87m") + "Read" + csi("0m") + "(src/main.ts)\r\n"
                + "  ⎿  " + csi("2m") + "Read %d lines" % (frame * 10) + csi("0m") + "\r\n"
                + box(98, ["› typed text %d" % frame, ""])
                + csi("2m") + "  ? for shortcuts" + csi("0m") + "\r\n")
        height = part.count("\r\n")
        out += part + csi("?2026l")
    return out


@case("charsets", 80, 24)
def charsets():
    out = ESC + "(0" + "lqqqk\r\nx   x\r\nmqqqj" + ESC + "(B" + " ascii\r\n"
    out += ESC + ")0" + "\x0e" + "lqk" + "\x0f" + " back\r\n"
    out += ESC + "(0" + ESC + "7" + ESC + "(B" + "saved-under-dec\r\n"        # DECSC while G0 is DEC graphics
    return out + ESC + "*A" + ESC + "+0" + "\x0e"                                # end: G1 DEC, G2 UK, G3 DEC, GL = G1


@case("tab-stops", 80, 24)
def tab_stops():
    return csi("3g") + "".join(csi("1;%dH" % c) + ESC + "H" for c in (5, 13, 30, 61)) + csi("H") + "a\tb\tc\td\te\r\n"


@case("mouse-modes", 80, 24)
def mouse_modes():
    return csi("?1002h") + csi("?1016h") + csi("?1003h") + "mouse on"


@case("bracketed-insert-nowrap", 80, 24)
def bracketed_insert_nowrap():
    return csi("?2004h") + "prompt> " + csi("4h") + "ins" + csi("?45h") + csi("?7l") + "x" * 100


@case("pending-wrap", 20, 5)
def pending_wrap():
    return "".join("row%d\r\n" % i for i in range(3)) + csi("31m") + "Z" * 20


@case("scrollback-overflow", 40, 10)
def scrollback_overflow():
    return "".join("line %d\r\n" % i for i in range(6000)) + "end"


@case("sync-open", 80, 24)
def sync_open():
    return "before\r\n" + csi("?2026h") + "inside an update"


@case("cursor-style", 80, 24)
def cursor_style():
    return csi("6 q") + csi("?25l") + "bar cursor hidden"


# --- Shapes the emitter reviews found (Task 2, Task 3) -------------------------------------------
# Each of these once corrupted the emitted screen, or is a place SwiftTerm and xterm.js 6 were shown
# to disagree. They are here so the differential check sees them every run.


@case("wrapped-erased-start", 20, 8)
def wrapped_erased_start():
    """A continuation row that STARTS with erased cells: the emitter must not let the write that
    wraps into it land on the previous row. ECH (default and coloured) and EL 1 at a wrapped row."""
    out = "a" * 30 + csi("2;1H") + csi("3X")                                     # ECH 3, default bg
    out += csi("3;1H") + "b" * 25 + csi("4;1H") + csi("44m") + csi("2X") + csi("0m")   # ECH 2, blue
    out += csi("5;1H") + "c" * 28 + csi("6;4H") + csi("45m") + csi("1K") + csi("0m")   # EL 1 through col 4
    return out + csi("8;1H") + "end"


@case("pending-wrap-dec-saved", 20, 5)
def pending_wrap_dec_saved():
    """Pending wrap while the SAVED cursor's charset is DEC graphics and G0 is ASCII: the emitter
    rewrites the last glyph to leave the cursor at x == cols, and must not do it through the saved
    charset (where q is a line)."""
    return ESC + "(0" + ESC + "7" + ESC + "(B" + "row0\r\n" + "q" * 20


@case("pending-wrap-dec-active", 20, 5)
def pending_wrap_dec_active():
    """Pending wrap with DEC graphics INVOKED, ending on a line-drawing glyph."""
    return "row0\r\n" + ESC + "(0" + "lqqqqqqqqqqqqqqqqqqk"


@case("alt-saved-cursor-bg", 40, 10)
def alt_saved_cursor_bg():
    """Saved cursors carrying a non-default background, in BOTH buffers, with the alt screen up.
    ?1049h saves the pen (magenta bg) into the normal slot; DECSC in the alt screen saves cyan."""
    out = "normal text\r\n" + csi("45m") + csi("?1049h") + csi("0m") + csi("H") + "alt text"
    return out + csi("46;31m") + csi("4;7H") + ESC + "7" + csi("0m") + csi("8;2H") + "after"


@case("short-then-wrapped", 20, 10)
def short_then_wrapped():
    """A short line immediately before a wrapped group, repeatedly, on both screens."""
    out = "s1\r\n" + "w" * 27 + "\r\nshort\r\n" + "v" * 45 + "\r\n\r\n" + "u" * 20 + "\r\n"
    out += csi("?1049h") + csi("H") + "alt short\r\n" + "A" * 33 + csi("6;1H") + "x\r\n" + "B" * 21
    return out


@case("continuation-bg", 20, 6)
def continuation_bg():
    """A continuation whose first glyph has a coloured background — once without scrolling and once
    where the wrap SCROLLS (xterm.js fills the new row with the pen's background)."""
    out = "p" * 20 + csi("42m") + "G" + csi("0m") + "g\r\n"                        # no scroll
    out += csi("6;1H") + "q" * 20 + csi("41m") + "R" + csi("0m") + "r"               # scrolls
    return out


@case("decsc-pending-wrap", 20, 5)
def decsc_pending_wrap():
    """DECSC while in pending wrap (x == cols): both emulators save x == cols, and the capture must keep
    it (it once clamped it to cols - 1)."""
    return "top\r\n" + csi("33m") + "y" * 20 + ESC + "7" + csi("0m") + csi("4;1H") + "moved"


@case("pending-wrap-erased-row", 20, 5)
def pending_wrap_erased_row():
    """EL 1 IN pending wrap: the row is erased and the cursor stays at x == cols. The emitter's rewrite
    has no glyph to rewrite, writes a space and must erase it again (EL 1), or the row gains a written
    space the original never had."""
    return "top\r\n" + csi("31m") + "Z" * 20 + csi("1K") + csi("0m")


@case("decsc-pending-wrap-erased-row", 20, 5)
def decsc_pending_wrap_erased_row():
    """The same row erased with a BACKGROUND, and DECSC taken there: the saved cursor's stance is the
    same rewrite, on a row whose every cell carries the blue."""
    return "top\r\n" + "Z" * 20 + csi("44m") + csi("1K") + ESC + "7" + csi("0m") + csi("4;1H") + "moved"


@case("ich-dch-gaps", 30, 8)
def ich_dch_gaps():
    """Insert/delete character and column gaps, default and coloured erase background. The
    column operations are DECIC/DECDC (CSI ' } / CSI ' ~), which rdev's SwiftTerm patch aligns with
    xterm.js (erased cells, erase background)."""
    out = "".join("%d abcdefghijklmnopqrstuvwxyz\r\n" % r for r in range(6))
    out += csi("1;3H") + csi("2@")                                     # ICH 2, default
    out += csi("2;3H") + csi("44m") + csi("3@") + csi("0m")            # ICH 3, blue
    out += csi("3;3H") + csi("4P")                                     # DCH 4, default
    out += csi("4;3H") + csi("41m") + csi("2P") + csi("0m")            # DCH 2, red
    out += csi("5;10H") + csi("43m") + csi("2'}") + csi("0m")          # DECIC 2, yellow
    out += csi("5;20H") + csi("2'~")                                   # DECDC 2, default
    return out + csi("8;1H") + "done"


@case("alt-screen-reentry", 40, 10)
def alt_screen_reentry():
    """Leaving and re-entering the alternate screen, as xterm.js 6 does it: every leave (?47l too)
    CLEARS the alt buffer, which also restores its default tab stops, and neither entering nor leaving
    touches cursor visibility (a TUI that hides the cursor before ?1049h stays hidden). SwiftTerm
    kept ?47's contents, kept the alt buffer's stops and SHOWED the cursor on every switch; rdev's
    SwiftTerm patch aligns all three."""
    out = "shell prompt\r\n" + csi("?25l") + csi("?1049h")
    out += csi("3g") + csi("1;6H") + ESC + "H" + csi("2;1H") + "custom\tstop"   # alt-only tab stops
    out += csi("?1049l") + "back\r\n"
    out += csi("?47h") + csi("4;4H") + "kept by ?47" + csi("?47l") + "again\r\n"
    out += csi("?1047h") + csi("2;1H") + "fresh\ttab"
    return out


@case("recycled-wrapped-line", 20, 5)
def recycled_wrapped_line():
    """One line that wraps, then enough short lines to push it out of a FULL 5000-line scrollback. Once
    scrollback is full SwiftTerm recycles the oldest line as the new bottom line, and it kept that
    line's wrap flag: the evicted continuation planted a stale `isWrapped` on a fresh line, and the
    snapshot joined two unrelated lines with a run of spaces. xterm.js copies a blank, unwrapped line
    into the recycled one; rdev's SwiftTerm patch does the same."""
    return "x" * 25 + "".join("\r\nl%d" % i for i in range(5100))


@case("emoji-widths", 40, 12)
def emoji_widths():
    """Every glyph-width class the client and the host once counted differently (xterm.js 6's Unicode 6
    table, SwiftTerm's own rules), each followed by a marker so a column's disagreement moves it: emoji
    presentation across Unicode versions, VS16 on text-presentation bases, VS15, keycaps, skin tones
    (one on a text-default base), ZWJ sequences, a tag sequence, flags and a lone regional indicator,
    East Asian Wide since Unicode 16, and the combining and spacing marks that join. Then a Claude-like
    TUI's shapes: a cursor placed after emoji by CUP and an erase that must land in the right columns,
    and a wide glyph half overwritten."""
    rows = [
        "\U0001F600|\U0001F970|\U0001FAE0|\U0001FA77|\u2630|\u2705|\u26A1|",
        "\u2764\uFE0F|\u2600\uFE0F|\u2714\uFE0F|x\uFE0F|1\uFE0F\u20E3|\u231A\uFE0E|\u2764|",
        "\U0001F44D\U0001F3FD|\u261D\U0001F3FD|\U0001F9D1\U0001F3FD\u200D\U0001F4BB|",
        "\U0001F469\u200D\U0001F4BB|\U0001F468\u200D\U0001F469\u200D\U0001F467|\u2764\u200D\U0001F525|",
        "\U0001F3F3\uFE0F\u200D\U0001F308|\U0001F3F4\U000E0067\U000E0062\U000E0073\U000E0063\U000E0074\U000E007F|",
        "\U0001F1FA\U0001F1F8|\U0001F1FA|\U0001F1FA\U0001F1F8\U0001F1EC|\u4E2D\u6587|e\u0301|\u0915\u093F|",
    ]
    out = "".join(r + "\r\n" for r in rows)
    out += csi("8;1H") + "\u23FA \U0001F680 Deploying\u2026 \u2728" + csi("8;12H") + csi("K") + "done \u2705"
    out += csi("9;1H") + "\U0001F600\U0001F600\U0001F600" + csi("9;3H") + "ab"     # overwrites the second's first half
    return out + csi("10;1H") + "\u2764\uFE0F\U0001F1FA\U0001F1F8" + csi("10;4H")


@case("emoji-split", 40, 5)
def emoji_split():
    """A grapheme SPLIT by an escape sequence: a pen change between ❤ and its VS16, 👍 and its skin
    tone, 🇺 and 🇸; an SGR that changes nothing between e and its accent; cursor steps between ❤ and
    VS16; orphan ZWSP, WJ and a jamo vowel after BEL, SGR and BS. xterm.js ends a join at every
    control and escape sequence, so each joiner stands alone —
    rdev's SwiftTerm patch agrees, and the emitter keeps two same-pen cells apart with a NUL (tmux
    joins them: docs/terminal.md, "Glyph widths")."""
    out = "\u2764" + csi("31m") + "\uFE0F" + csi("0m") + "|" + "\U0001F44D" + csi("44m") + "\U0001F3FD" + csi("0m") + "|"
    out += "\U0001F1FA" + csi("32m") + "\U0001F1F8" + csi("0m") + "|\r\n"
    out += "e" + csi("m") + "\u0301" + "\u2764" + csi("C") + csi("D") + "\uFE0F|\r\n"
    # Zero-width scalars Swift does not join (ZWSP, WJ, a jamo vowel) as ORPHANS after a control or a
    # sequence: one column each on both sides, and the client must not fold them into the letter.
    return out + "a\x07\u200BX" + csi("m") + "\u2060Y\x08\x1b[C\u1161Z|"


@case("emoji-margin", 20, 6)
def emoji_margin():
    """Glyphs that widen or do not fit at the right margin: a VS16 (under a background) and a flag's
    second indicator arriving while the base sits in the LAST column (xterm.js moves the glyph to the
    next row and erases the cell it left with the pen — rdev's SwiftTerm patch does the same), a wide
    emoji that does not fit, and a ZWJ sequence that wraps whole."""
    out = "a" * 19 + csi("44m") + "\u2764\uFE0F" + csi("0m") + "z\r\n"
    out += "c" * 19 + "\U0001F1FA\U0001F1F8" + "\r\n"
    out += "d" * 19 + "\U0001F600" + "|" + "\r\n"
    return out + "e" * 19 + "\U0001F469\u200D\U0001F4BB" + "|"


@case("emoji-margin-skin-tone", 20, 4)
def emoji_margin_skin_tone():
    """A skin tone arriving while its TEXT-DEFAULT base (☝) sits in the last column: one wide glyph moved
    to the next row in xterm.js and patched SwiftTerm; tmux does not join the two at all."""
    return "b" * 19 + "\u261D\U0001F3FD" + "|"


@case("grapheme-joins", 80, 40)
def grapheme_joins():
    """Every ordered PAIR of grapheme-break classes (UAX #29) printed back to back, then a marker, so
    any pair the host and the client join differently moves the marker: Other (a, 中), Prepend (U+0D4E),
    Extend (U+0301), a regional indicator, SpacingMark (U+093F), Hangul L/V/T/LV/LVT, ZWJ and two
    pictographs (😀, text-default ❤). Then the GB11 triples: a pictograph or a letter, ZWJ, a pictograph.
    Where the addon's rules and SwiftTerm's differ the client follows SwiftTerm (docs/terminal.md): no
    join after a ZWJ unless a pictograph began the cluster, none for Hangul L + L/LV/LVT, and none of a
    spacing glyph after a Prepend character."""
    reps = ["a", "\u4E2D", "\u0D4E", "\u0301", "\U0001F1FA", "\u093F", "\u1100", "\u1161", "\u11A8",
            "\uAC00", "\uAC01", "\u200D", "\U0001F600", "\u2764"]
    # A conjoining vowel or final after anything it cannot join (UAX #29 GB7/GB8) — the separator
    # included, so never FIRST in a pair — is a zero-width
    # scalar that joins nothing: SwiftTerm drops it, xterm.js keeps it in the previous cell — the
    # TEXT-only Known limit, left out here (the columns agree; `term-unicode.test.ts` covers them).
    joins_v = {"\u1100", "\u1161", "\uAC00"}
    joins_t = {"\u1161", "\u11A8", "\uAC00", "\uAC01"}
    cells = [x + y + "|" for x in reps for y in reps
             if x not in ("\u1161", "\u11A8") and not (y == "\u1161" and x not in joins_v) and not (y == "\u11A8" and x not in joins_t)]
    cells += [b + "\u200D" + e + "|" for b in ["a", "\u4E2D", "\U0001F600", "\u2764", "\u2764\uFE0F", "\u0915"]
              for e in ["\U0001F600", "\u2764", "\U0001F4BB"]]
    # Every line starts with "> ": a zero-width scalar at COLUMN 0 is dropped by tmux and written as a
    # cell by xterm.js (a tmux-tab Known limit), which is not what this case is about.
    out, line = "", "> "
    for c in cells:
        if len(line) >= 20:
            out += line + "\r\n"
            line = "> "
        line += c
    return out + line

@case("c1-controls", 40, 10)
def c1_controls():
    """8-bit C1 as CODE POINTS (UTF-8 C2 80-C2 9F), which xterm.js 6 treats as controls in every state
    and the host hands SwiftTerm as their 7-bit forms (C1Translator, docs/terminal.md "8-bit C1"): a C1
    CSI's SGR, NEL, IND, HTS, SOS/PM/APC strings (ignored), a C1 aborting a CSI and a C1 CSI aborting an
    OSC, C1 controls that execute nothing, and a 7-bit SOS beside them."""
    out = ["a\x9b31mred\x9b0mb\r\n",                             # CSI introduced by U+009B
           "nel\x85ind\x84x\r\n",                                 # NEL, IND
           "\x9b3g  \x88\r\tH\r\n",                                 # clear stops; HTS at column 2
           "s\x98hidden\x9cp\x9ehidden\x9ca\x9fhidden\x9c!\r\n",       # SOS, PM, APC with text
           ESC + "[31\x85m-not-red\r\n",                             # a C1 (NEL) aborts a CSI
           ESC + "]0;t\x9b32mgreen\x9b0m\r\n",                        # a C1 CSI drops an OSC
           "q\x80\x81\x99\x9az" + ESC + "Xsos" + ESC + "\\end"]         # C1s that execute nothing; 7-bit SOS
    return "".join(out)


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".bin"):
            os.remove(os.path.join(OUT, f))
    manifest = []
    for name, cols, rows, fn in CASES:
        with open(os.path.join(OUT, name + ".bin"), "wb") as fh:
            fh.write(fn().encode("utf-8"))
        manifest.append({"name": name, "cols": cols, "rows": rows})
    with open(os.path.join(OUT, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
        fh.write("\n")
    print("wrote %d cases to %s" % (len(manifest), OUT))


if __name__ == "__main__":
    main()
