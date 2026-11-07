import XCTest
@testable import RdevHostKit

/// Drives the REAL spawn path — `forkpty` + `execve` — with `/usr/bin/env` standing in for the shell,
/// so the child prints exactly the environment and argv[0] a tab's shell receives. The pure policy is
/// `TermEnvironmentTests` (RdevCore); this is the check that `PtyProcess` actually hands it over.
final class PtyProcessTests: XCTestCase {
    func testChildReceivesTheTerminalEnvironment() {
        let pty = PtyProcess()
        let lock = NSLock()
        var out = Data()
        let exited = expectation(description: "env printed TERM and COLORTERM")
        exited.assertForOverFulfill = false
        pty.onOutput = { data in
            lock.lock(); out.append(data); let s = String(decoding: out, as: UTF8.self); lock.unlock()
            // A COMPLETE line STARTING with "TERM=" — `contains("TERM=")` also matched inside
            // "COLORTERM=", which `env` prints first, so the test could stop before TERM arrived.
            // (Split on `isNewline`: the pty writes "\r\n", which Swift holds as ONE Character.)
            let parts = s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let complete = (s.last?.isNewline == true ? parts[...] : parts.dropLast())
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if complete.contains(where: { $0.hasPrefix("TERM=") }) && s.contains("COLORTERM=") { exited.fulfill() }
        }
        pty.start(shell: "/usr/bin/env", cols: 80, rows: 24)
        wait(for: [exited], timeout: 5)
        pty.stop()
        lock.lock(); let lines = String(decoding: out, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        lock.unlock()
        XCTAssertTrue(lines.contains("TERM=xterm-256color"), "\(lines)")
        XCTAssertTrue(lines.contains("COLORTERM=truecolor"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("NO_COLOR=") }, "Launcher color suppression leaked into the terminal")
        XCTAssertTrue(lines.contains { $0.hasPrefix("LANG=") || $0.hasPrefix("LC_ALL=") || $0.hasPrefix("LC_CTYPE=") },
                      "\(lines)")
    }

    /// A shell that ENDS ON ITS OWN is reported (and reaped) — the hook TerminalManager closes the tab
    /// on. Nothing noticed before 2026-09-29: the tab stayed listed for the life of the host.
    func testOnExitFiresWhenTheShellEndsOnItsOwn() {
        let pty = PtyProcess()
        let exited = expectation(description: "onExit")
        pty.onExit = { exited.fulfill() }
        pty.start(shell: "/usr/bin/true", cols: 80, rows: 24)
        wait(for: [exited], timeout: 5)
    }

    /// `stop()` ends the shell ON PURPOSE: that is not news, and must not close a tab twice.
    func testOnExitIsSilentAfterStop() {
        let pty = PtyProcess()
        let exited = expectation(description: "onExit after stop()")
        exited.isInverted = true
        pty.onExit = { exited.fulfill() }
        pty.start(shell: "/bin/cat", cols: 80, rows: 24)   // waits on its terminal until killed
        Thread.sleep(forTimeInterval: 0.2)
        pty.stop()
        wait(for: [exited], timeout: 1)
    }
}
