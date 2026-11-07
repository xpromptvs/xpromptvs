import Foundation
import SwiftTerm

/// protocol/fixtures/term-widths.json: the column count SwiftTerm gives every scalar ON ITS OWN, as
/// ranges — `wide` (2) and `zero` (0: marks, format characters, conjoining vowels and finals, skin-tone
/// modifiers). Controls (below U+00A0) are left out: a parser executes them, nothing prints them.
///
/// The client's xterm.js reads it (web/src/client/term-unicode.ts), so the two emulators on either end
/// of a snapshot count the same columns for every scalar; what JOINS a grapheme is decided on each
/// side by the grapheme rules both follow (docs/terminal.md, "Glyph widths"). Written by
/// //tools/TermSnapshotFixtures; RdevCoreTests' `TermWidthTableFixtureTests` fails when it is stale.
///
/// TEST-ONLY code (the `testonly` RdevTermCorpus target), writing a file the product bundles.
public enum TermWidthTable {
    public static func ranges() -> (wide: [[UInt32]], zero: [[UInt32]]) {
        var wide: [[UInt32]] = [], zero: [[UInt32]] = []
        func add(_ into: inout [[UInt32]], _ c: UInt32) {
            if let last = into.last, last[1] + 1 == c { into[into.count - 1][1] = c } else { into.append([c, c]) }
        }
        for c in UInt32(0xA0)...0x10FFFF {
            guard let s = UnicodeScalar(c) else { continue }                    // surrogates
            switch SwiftTerm.Terminal.rdevColumnWidth(s) {
            case 2: add(&wide, c)
            case 0: add(&zero, c)
            default: break
            }
        }
        return (wide, zero)
    }

    /// The fixture's exact bytes: one range per line, so a diff names the ranges that moved.
    public static func json() -> Data {
        let (wide, zero) = ranges()
        func list(_ r: [[UInt32]]) -> String { r.map { "    [\($0[0]), \($0[1])]" }.joined(separator: ",\n") }
        let text = """
        {
          "source": "SwiftTerm v1.13.0 + third_party/swiftterm/rdev-snapshot-access.patch, Terminal.rdevColumnWidth; written by //tools/TermSnapshotFixtures",
          "wide": [
        \(list(wide))
          ],
          "zero": [
        \(list(zero))
          ]
        }

        """
        return Data(text.utf8)
    }
}
