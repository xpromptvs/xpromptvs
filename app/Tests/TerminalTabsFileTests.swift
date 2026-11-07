import XCTest
@testable import ShellstormCore

final class TerminalTabsFileTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testNoFileIsNothingToRestore() {
        XCTAssertNil(TerminalTabsFile(dir: dir).read())
    }

    /// The profile directory may not exist yet; the file is created inside it.
    func testItWritesThenReadsBack() {
        var f = TerminalTabsFile(dir: dir)
        XCTAssertTrue(f.write(Data("one".utf8)))
        XCTAssertEqual(TerminalTabsFile(dir: dir).read(), Data("one".utf8))
        XCTAssertEqual(f.url.lastPathComponent, "terminal-tabs.json")
    }

    /// The keeper saves every few seconds: the same bytes again touch nothing.
    func testTheSameBytesAreNotWrittenAgain() throws {
        var f = TerminalTabsFile(dir: dir)
        XCTAssertTrue(f.write(Data("a".utf8)))
        try FileManager.default.removeItem(at: f.url)
        XCTAssertFalse(f.write(Data("a".utf8)), "unchanged: no write")
        XCTAssertNil(f.read())
        XCTAssertTrue(f.write(Data("b".utf8)))
        XCTAssertEqual(f.read(), Data("b".utf8))
    }
}
