import XCTest
@testable import RdevCore

/// §6's names and §4.1's typed form. The name is TYPED into a shell, so every character must be one a
/// shell reads as itself, and nothing a device sends may leave the folder.
final class PasteNamesTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21 14:13:20 UTC
    private func name(_ original: String, _ type: String = "", taken: Set<String> = []) -> String {
        PasteNames.savedName(original: original, type: type, at: at, timeZone: TimeZone(identifier: "UTC")!,
                             taken: { taken.contains($0) })
    }

    func testAnOrdinaryNameKeepsItsStemAndExtension() {
        XCTAssertEqual(name("IMG_0042.JPG", "image/jpeg"), "20260921-141320-IMG_0042.jpg")
    }

    func testHostileAndOddNamesStayInsideTheFolderAndTypeAsThemselves() {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let cases: [(String, String, String)] = [
            ("../../etc/passwd", "", "20260921-141320-etc-passwd"),
            ("..", "", "20260921-141320-paste"),
            ("", "image/png", "20260921-141320-paste.png"),
            ("notes v2.pdf", "application/pdf", "20260921-141320-notes-v2.pdf"),
            ("日本語の写真.heic", "image/heic", "20260921-141320-paste.heic"),
            ("😀 party!!.png", "image/png", "20260921-141320-party.png"),
            ("-rf .tar.gz", "", "20260921-141320-rf-.tar.gz"),
            ("archive", "application/zip", "20260921-141320-archive.zip"),
            ("lies.exe", "image/png", "20260921-141320-lies.exe"),
            ("weird.ext$", "text/plain", "20260921-141320-weird.ext.txt"),
        ]
        for (orig, type, want) in cases {
            let got = name(orig, type)
            XCTAssertEqual(got, want, orig)
            XCTAssertFalse(got.contains("/"), orig)
            XCTAssertTrue(got.unicodeScalars.allSatisfy { safe.contains($0) }, orig)
        }
    }

    func testALongNameIsCutTo48AndTrimmed() {
        let got = name(String(repeating: "a", count: 47) + "-" + String(repeating: "b", count: 200) + ".png", "image/png")
        XCTAssertEqual(got, "20260921-141320-" + String(repeating: "a", count: 47) + ".png")
    }

    func testACollisionCountsUp() {
        let first = "20260921-141320-a.png"
        XCTAssertEqual(name("a.png", "image/png", taken: [first]), "20260921-141320-a-2.png")
        XCTAssertEqual(name("a.png", "image/png", taken: [first, "20260921-141320-a-2.png"]), "20260921-141320-a-3.png")
    }

    func testAPathIsTypedAsIsWhenSafeAndSingleQuotedOtherwise() {
        XCTAssertEqual(PasteTyping.quoted("/Users/isaac/Library/Caches/ai.xpromptvs.app/default/Pastes/x.png"),
                       "/Users/isaac/Library/Caches/ai.xpromptvs.app/default/Pastes/x.png")
        XCTAssertEqual(PasteTyping.quoted("/Users/o'neil x/a.png"), #"'/Users/o'\''neil x/a.png'"#)
    }

    /// The SAME vectors the app's client types a folder's path with on This Mac (`paste-local.ts`).
    func testTypedPathsAreTheSharedFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/paste-typing.json")
        let f = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let quoted = try XCTUnwrap(f["quoted"] as? [[String: String]])
        XCTAssertFalse(quoted.isEmpty)
        for v in quoted { XCTAssertEqual(PasteTyping.quoted(v["path"]!), v["typed"]!, v["path"]!) }
        let pieces = try XCTUnwrap(f["pieces"] as? [String: [String]])
        XCTAssertEqual(PasteTyping.pieces(paths: pieces["paths"]!), pieces["typed"]!)
    }

    func testEachPathIsItsOwnPieceFollowedByASpace() {
        XCTAssertEqual(PasteTyping.pieces(paths: ["/a/x.png"]), ["/a/x.png "])
        XCTAssertEqual(PasteTyping.pieces(paths: ["/a/x.png", "/a/y.png"]), ["/a/x.png ", "/a/y.png "])
    }

    /// P3, measured 2026-10-01: Claude Code 2.1.286 attaches several paths in ONE bracketed paste, Codex
    /// 0.158.0 only one per paste, and Claude Code attaches nothing typed as plain keystrokes — so each path
    /// is its OWN bracketed paste.
    func testEachPieceIsItsOwnBracketedPasteOnlyWhenTheProgramAsked() {
        XCTAssertEqual(PasteTyping.asPastes(["/a/x.png ", "/a/y.png "], bracketed: true),
                       "\u{1b}[200~/a/x.png \u{1b}[201~\u{1b}[200~/a/y.png \u{1b}[201~")
        XCTAssertEqual(PasteTyping.asPastes(["/a/x.png ", "/a/y.png "], bracketed: false), "/a/x.png /a/y.png ")
    }
}
