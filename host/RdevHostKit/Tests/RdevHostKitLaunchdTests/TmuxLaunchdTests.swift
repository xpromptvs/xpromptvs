import XCTest
import RdevCore
import RdevTmuxRig
@testable import RdevHostKit

/// A tmux server rdev starts is launchd's (docs/terminal.md, "A tmux server rdev starts is launchd's"): on
/// macOS 27 a quitting foreground app that Background Task Management does not allow has its whole COALITION
/// SIGTERMed, a daemonized tmux server it forked included, so `TmuxRunner.newSession` starts the session from a
/// launchd job. These need launchd's
/// `gui/<uid>` domain, which Bazel's darwin-sandbox refuses — hence their own target, `no-sandbox`. REAL tmux
/// on a PRIVATE socket, never the user's server.
final class TmuxLaunchdTests: XCTestCase {
    private var runner: TmuxRunner!
    private let socket = "rdev-launchd-test-\(getpid())"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment.merging(["RDEV_TMUX_SOCKET": socket]) { $1 }
        guard let r = TmuxRunner.locate(environment: env) else {
            throw XCTSkip("tmux is not installed — TmuxLaunchdTests did NOT run")
        }
        runner = r.withConfigFile("/dev/null")
    }

    override func tearDown() {
        guard let runner else { return }
        _ = runner.run(["kill-server"])
        PrivateTmux.removeSocket(socket)
    }

    /// The server a new session starts is not in the caller's coalition — what loginwindow kills when the app
    /// quits. NEGATIVE CONTROL: a server the caller starts itself IS in it, or the read proves nothing.
    func testANewSessionsServerIsNotInTheCallersCoalition() throws {
        let mine = try XCTUnwrap(Coalition.id(of: getpid()), "proc_pidinfo cannot read a coalition here")
        _ = try XCTUnwrap(runner.newSession())
        let server = try XCTUnwrap(serverPid())
        XCTAssertNotEqual(try XCTUnwrap(Coalition.id(of: server)), mine,
                          "the server is in the caller's coalition: it ends when the app quits")
        XCTAssertEqual(runner.run(["kill-server"]).status, 0)
        XCTAssertEqual(runner.run(["new-session", "-d"]).status, 0)
        XCTAssertEqual(Coalition.id(of: try XCTUnwrap(serverPid())), mine, "negative control")
    }

    /// The server a launchd job started gets what the caller's would have: its environment (a pane's comes from
    /// it — TERM, COLORTERM, the locale) and the session's directory.
    func testANewSessionKeepsTheEnvironmentAndDirectory() throws {
        let dir = try realDirectory(FileManager.default.temporaryDirectory.path)
        let sid = try XCTUnwrap(runner.newSession(directory: dir))
        XCTAssertEqual(runner.run(["show-environment", "-g", "COLORTERM"]).stdout, "COLORTERM=truecolor\n")
        XCTAssertEqual(runner.run(["show-environment", "-g", "TERM"]).stdout, "TERM=\(TermEnvironment.term)\n")
        XCTAssertEqual(runner.panePath(sid), dir)
        for name in ["OSLogRateLimit", "XPC_SERVICE_NAME"] {
            let got = runner.run(["show-environment", "-g", name])
            if let mine = runner.environment[name] { XCTAssertEqual(got.stdout, "\(name)=\(mine)\n") }
            else { XCTAssertNotEqual(got.status, 0, "\(name) came from launchd: \(got.stdout)") }
        }
    }

    /// The job runner itself: the directory it is given, the program's exit status and stdout.
    func testAJobRunsInItsDirectory() throws {
        let dir = try realDirectory(FileManager.default.temporaryDirectory.path)
        let r = try XCTUnwrap(LaunchdJob.run(["/bin/sh", "-c", "pwd -P; exit 3"], environment: [:], directory: dir),
                              "no launchd gui domain")
        XCTAssertEqual(r, LaunchdJob.Result(status: 3, stdout: "\(dir)\n"))
        XCTAssertEqual(leftovers(), [], "a job's plist directory is removed")
    }

    /// The program sees EXACTLY the environment it is given: nothing launchd adds to every job (it FORCES
    /// `OSLogRateLimit` and `XPC_SERVICE_NAME`), and the caller's value where launchd sets its own.
    func testAJobSeesExactlyItsEnvironment() throws {
        let env = ["RDEV_JOB_PROBE": "it travelled = with spaces", "XPC_SERVICE_NAME": "the caller's",
                   "PATH": "/usr/bin:/bin"]
        let r = try XCTUnwrap(LaunchdJob.run(["/usr/bin/env"], environment: env, directory: "/"), "no launchd gui domain")
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(Set(r.stdout.split(separator: "\n").map(String.init)), Set(env.map { "\($0.key)=\($0.value)" }))
    }

    /// A job past its timeout reads -1 and is booted out — which stops it: nothing is left in launchd.
    func testAJobPastItsTimeoutIsStopped() throws {
        let marker = "30.\(getpid())"                       // a duration only this test sleeps
        let t0 = Date()
        let r = try XCTUnwrap(LaunchdJob.run(["/bin/sleep", marker], environment: [:], directory: "/",
                                             timeout: 0.5), "no launchd gui domain")
        XCTAssertEqual(r.status, -1)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        ps.arguments = ["-f", "sleep \(marker)"]
        try ps.run(); ps.waitUntilExit()
        XCTAssertEqual(ps.terminationStatus, 1, "the timed-out job's program is still running")
        XCTAssertEqual(leftovers(), [])
    }

    private func serverPid() -> pid_t? {
        pid_t(runner.run(["display", "-p", "#{pid}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// realpath, as tmux and `pwd -P` report it (Foundation's resolvingSymlinksInPath drops /private).
    private func realDirectory(_ path: String) throws -> String {
        try XCTUnwrap(realpath(path, nil).map { p in defer { free(p) }; return String(cString: p) })
    }

    private func leftovers() -> [String] {
        let tmp = FileManager.default.temporaryDirectory.path
        return ((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []).filter { $0.hasPrefix("ai.xpromptvs.job.") }
    }
}

/// A process's RESOURCE coalition — what loginwindow lists, and kills, when an app quits.
/// `proc_pidinfo(PROC_PIDCOALITIONINFO = 20)`; the layout is `<sys/proc_info_private.h>`'s.
private enum Coalition {
    private struct Info { var ids: (UInt64, UInt64) = (0, 0); var reserved: (UInt64, UInt64, UInt64) = (0, 0, 0) }
    static func id(of pid: pid_t) -> UInt64? {
        var info = Info()
        let size = Int32(MemoryLayout<Info>.size)
        guard proc_pidinfo(pid, 20, 0, &info, size) == size, info.ids.0 != 0 else { return nil }
        return info.ids.0
    }
}
