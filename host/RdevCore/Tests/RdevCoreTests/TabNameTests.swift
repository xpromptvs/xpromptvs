import XCTest
@testable import RdevCore

/// A tab NAME and a tab KEY (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §1.1 and
/// §2.3).
///
/// THE NAME RULE IS ASSERTED AGAINST `protocol/fixtures/tab-names.json`, which the TypeScript side
/// asserts too: the client refuses to send what the host would refuse, so the two must draw the same
/// line — in BYTES, which both languages count the same way, never in characters, which they do not.
final class TabNameTests: XCTestCase {

    private struct Fixture: Decodable { let valid: [String]; let invalid: [String] }

    // protocol/fixtures live at repo root, five dirs up from this test file.
    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/tab-names.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testTheSharedVectors() throws {
        let f = try fixture()
        XCTAssertGreaterThanOrEqual(f.valid.count, 5, "a near-empty fixture would pass every assertion below")
        XCTAssertGreaterThanOrEqual(f.invalid.count, 5)
        for name in f.valid { XCTAssertTrue(TabName.isValid(name), "valid: \(name.debugDescription)") }
        for name in f.invalid { XCTAssertFalse(TabName.isValid(name), "invalid: \(name.debugDescription)") }
    }

    /// The fixture's boundary cases are what they claim to be — a vector that drifted to 255 bytes would
    /// still pass, and test nothing.
    func testTheFixturesBoundaryIsExactlyAtTheLimit() throws {
        let f = try fixture()
        XCTAssertEqual(TabName.maxBytes, 256)
        XCTAssertTrue(f.valid.contains { $0.utf8.count == 256 && $0.unicodeScalars.count < 256 },
                      "a MULTIBYTE name of exactly 256 bytes is valid")
        XCTAssertTrue(f.invalid.contains { $0.utf8.count == 257 && $0.unicodeScalars.count < 257 },
                      "and one byte more is not")
        XCTAssertTrue(f.valid.contains(""), "empty is a valid name: it CLEARS")
    }

    /// Every control character (Cc) is refused, both ranges, and nothing either side of them.
    func testControlCharactersAreExactlyCc() {
        for v: UInt32 in Array(0x00...0x1F) + Array(0x7F...0x9F) {
            XCTAssertFalse(TabName.isValid("a" + String(Unicode.Scalar(v)!) + "b"), String(format: "U+%04X", v))
        }
        for v: UInt32 in [0x20, 0x7E, 0xA0, 0x2028, 0x200D, 0xFEFF] {
            XCTAssertTrue(TabName.isValid("a" + String(Unicode.Scalar(v)!) + "b"), String(format: "U+%04X", v))
        }
    }

    // MARK: - keys

    /// A key is a terminal tab id's wire form or a window/display source id — CANONICAL, because the
    /// host compares keys as strings: `pty:01` names no tab the host keeps, and is malformed, not a miss.
    func testAKeyIsACanonicalTerminalOrWindowId() {
        for key in ["pty:1", "pty:42", "tmux:$0", "tmux:$17", "win:4711", "dsp:1", "win:0"] {
            XCTAssertTrue(TabKey.isValid(key), key)
        }
        for key in ["", "pty:", "pty:0", "pty:01", "pty:x", "tmux:3", "tmux:$", "tmux:$x",
                    "win:", "win:x", "win:+5", "win:05", "dsp:", "sim:ABC", "terminal", "1", "WIN:5"] {
            XCTAssertFalse(TabKey.isValid(key), key)
        }
    }

    func testAKeysKind() {
        XCTAssertTrue(TabKey.isTerminal("pty:1"))
        XCTAssertTrue(TabKey.isTerminal("tmux:$3"))
        XCTAssertFalse(TabKey.isTerminal("win:1"))
        XCTAssertFalse(TabKey.isTerminal("dsp:1"))
        XCTAssertFalse(TabKey.isTerminal("pty:01"), "not canonical: not a key at all")
    }
}
