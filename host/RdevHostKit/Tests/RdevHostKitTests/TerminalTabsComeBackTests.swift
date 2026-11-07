import XCTest
import RdevCore
@testable import RdevHostKit

/// Where a new tab starts, ⌘⇧T, and the app's save and restore — through the REAL `TerminalManager` with
/// real shells (`/bin/cat`, which never changes directory, so where it STARTED is where it stays)
/// (docs/terminal.md, "Tabs that come back").
final class TerminalTabsComeBackTests: XCTestCase {
    private var dirs: [String] = []
    private var managers: [TerminalManager] = []

    override func tearDown() {
        for tm in managers { tm.closeAll() }
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    }

    /// A fresh directory, as the OS names it (`/private/var/…`): what `proc_pidinfo` reads back.
    private func dir(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rdev-tabs-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let real = try XCTUnwrap(realpath(url.path, &buf).map { String(cString: $0) })
        dirs.append(real)
        return real
    }

    private func manager(maxTabs: Int = 8, home: String) -> TerminalManager {
        let tm = TerminalManager(cols: 80, rows: 24, maxTabs: maxTabs)
        tm.shell = "/bin/cat"
        tm.home = home
        managers.append(tm)
        return tm
    }

    /// `savedTabs()` once every shell has STARTED where it was told — the fork returns before the child's
    /// `chdir`, so a read straight after `open` can still see the host's own directory.
    private func saved(_ tm: TerminalManager, becomes want: SavedTerminalTabs) -> SavedTerminalTabs {
        let deadline = Date().addingTimeInterval(5)
        var got = tm.savedTabs()
        while got != want && Date() < deadline { Thread.sleep(forTimeInterval: 0.02); got = tm.savedTabs() }
        return got
    }

    func testTheFirstTabStartsAtHomeAndTheNextWhereTheActiveTabIs() throws {
        let home = try dir("home"), work = try dir("work")
        let tm = manager(home: home)
        XCTAssertTrue(tm.open())
        XCTAssertEqual(saved(tm, becomes: .init(tabs: [.pty(cwd: home, name: nil)], active: 0)).tabs,
                       [.pty(cwd: home, name: nil)], "the first tab: home")
        XCTAssertTrue(tm.open(directory: work))
        _ = saved(tm, becomes: .init(tabs: [.pty(cwd: home, name: nil), .pty(cwd: work, name: nil)], active: 1))
        XCTAssertTrue(tm.open())
        let want = SavedTerminalTabs(tabs: [.pty(cwd: home, name: nil), .pty(cwd: work, name: nil), .pty(cwd: work, name: nil)],
                                     active: 2)
        XCTAssertEqual(saved(tm, becomes: want), want, "a new tab starts where the ACTIVE tab is")
        XCTAssertEqual(tm.newTabDirectory(), work)
        _ = tm.switchTo(.pty(1))
        XCTAssertEqual(tm.newTabDirectory(), home)
    }

    /// A saved directory that is gone (deleted since) starts the shell at home — never the host's own `/`.
    func testADirectoryThatIsGoneStartsAtHome() throws {
        let home = try dir("home")
        let tm = manager(home: home)
        XCTAssertTrue(tm.open(directory: home + "/no-such-directory"))
        let want = SavedTerminalTabs(tabs: [.pty(cwd: home, name: nil)], active: 0)
        XCTAssertEqual(saved(tm, becomes: want), want)
    }

    func testAClosedTabComesBackInItsDirectoryUnderItsName() throws {
        let home = try dir("home"), work = try dir("work")
        let tm = manager(home: home)
        XCTAssertTrue(tm.open(directory: work))
        XCTAssertTrue(tm.rename(.pty(1), "server"))
        _ = saved(tm, becomes: .init(tabs: [.pty(cwd: work, name: "server")], active: 0))
        XCTAssertTrue(tm.closeRemembering(.pty(1)))
        XCTAssertTrue(tm.isEmpty)
        XCTAssertEqual(tm.reopenClosed(), .reopened)
        let want = SavedTerminalTabs(tabs: [.pty(cwd: work, name: "server")], active: 0)
        XCTAssertEqual(saved(tm, becomes: want), want, "a NEW shell, where the closed one was, under its name")
        XCTAssertEqual(tm.descriptors().activeId, .pty(2))
        XCTAssertEqual(tm.reopenClosed(), .nothingClosed, "each closed tab comes back once")
    }

    /// Newest first, and only what the DRIVER closed: `close` (a shell that exits, `closeAll`) remembers nothing.
    func testReopeningGoesNewestFirstAndOnlyThroughWhatTheDriverClosed() throws {
        let home = try dir("home"), a = try dir("a"), b = try dir("b")
        let tm = manager(home: home)
        XCTAssertTrue(tm.open(directory: a)); XCTAssertTrue(tm.open(directory: b)); XCTAssertTrue(tm.open(directory: home))
        _ = saved(tm, becomes: .init(tabs: [.pty(cwd: a, name: nil), .pty(cwd: b, name: nil), .pty(cwd: home, name: nil)], active: 2))
        XCTAssertTrue(tm.closeRemembering(.pty(1)))
        XCTAssertTrue(tm.closeRemembering(.pty(2)))
        XCTAssertTrue(tm.close(.pty(3)))                                   // not the driver's: not remembered
        XCTAssertEqual(tm.reopenClosed(), .reopened)
        XCTAssertEqual(tm.reopenClosed(), .reopened)
        XCTAssertEqual(tm.reopenClosed(), .nothingClosed)
        let want = SavedTerminalTabs(tabs: [.pty(cwd: b, name: nil), .pty(cwd: a, name: nil)], active: 1)
        XCTAssertEqual(saved(tm, becomes: want), want)
    }

    func testAtTheCapNothingIsTakenOffTheList() throws {
        let home = try dir("home")
        let tm = manager(maxTabs: 1, home: home)
        XCTAssertTrue(tm.open())
        XCTAssertTrue(tm.closeRemembering(.pty(1)))
        XCTAssertTrue(tm.open())
        XCTAssertEqual(tm.reopenClosed(), .full)
        XCTAssertTrue(tm.close(.pty(2)))
        XCTAssertEqual(tm.reopenClosed(), .reopened, "still there once a tab is free")
    }

    func testSavedTabsComeBackInOrderWithTheActiveOne() throws {
        let home = try dir("home"), a = try dir("a"), b = try dir("b")
        let first = manager(home: home)
        XCTAssertTrue(first.open(directory: a)); XCTAssertTrue(first.open(directory: b))
        XCTAssertTrue(first.rename(.pty(2), "two"))
        _ = first.switchTo(.pty(1))
        let want = SavedTerminalTabs(tabs: [.pty(cwd: a, name: nil), .pty(cwd: b, name: "two")], active: 0)
        let saved = saved(first, becomes: want)
        XCTAssertEqual(saved, want)
        first.closeAll()

        // The file between them, as the app writes it.
        let file = try XCTUnwrap(SavedTerminalTabs(json: saved.json()))
        let next = manager(home: home)
        XCTAssertEqual(next.restore(file), 2)
        XCTAssertEqual(self.saved(next, becomes: want), want)
        XCTAssertEqual(next.descriptors().activeId, .pty(1))
        XCTAssertEqual(next.restore(file), 0, "never into a session that has tabs")
    }
}
