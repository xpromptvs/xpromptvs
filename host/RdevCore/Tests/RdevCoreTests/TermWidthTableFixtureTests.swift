import XCTest
import RdevTermCorpus

/// protocol/fixtures/term-widths.json is the width table the client's xterm.js BUNDLES
/// (web/src/client/term-unicode.ts). A SwiftTerm change (its Unicode data, or rdev's patch) that alters
/// a width without regenerating it would leave the two emulators counting different columns — every
/// cell after such a glyph misplaced on a restored screen. This test refuses that.
/// Regenerate: bazelisk run //tools/TermSnapshotFixtures -- "$PWD/protocol/fixtures"
final class TermWidthTableFixtureTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures/term-widths.json")

    func testTheWidthTableIsFresh() throws {
        let have = (try? Data(contentsOf: Self.fixture)) ?? Data()
        XCTAssertEqual(have, TermWidthTable.json(),
                       "term-widths.json is stale — run: bazelisk run //tools/TermSnapshotFixtures -- \"$PWD/protocol/fixtures\"")
    }

    /// Not vacuous: the table carries the classes it exists for.
    func testTheTableCarriesWhatTheClientNeeds() {
        let (wide, zero) = TermWidthTable.ranges()
        func has(_ r: [[UInt32]], _ c: UInt32) -> Bool { r.contains { $0[0] <= c && c <= $0[1] } }
        XCTAssertTrue(has(wide, 0x4E2D), "CJK")
        XCTAssertTrue(has(wide, 0x1F600), "emoji presentation")
        XCTAssertTrue(has(wide, 0x1FAE0), "Unicode 14 emoji — the graphemes addon's own data calls it narrow")
        XCTAssertFalse(has(wide, 0x1F1FA), "a lone regional indicator is one column")
        XCTAssertTrue(has(zero, 0x301), "a combining mark")
        XCTAssertTrue(has(zero, 0x200B), "ZWSP")
        XCTAssertFalse(has(wide, 0x2605) || has(zero, 0x2605), "East Asian Ambiguous is narrow")
    }
}
