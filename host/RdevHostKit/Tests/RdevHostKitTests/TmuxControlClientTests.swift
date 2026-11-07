import XCTest
import RdevCore
@testable import RdevHostKit

/// Drives REAL tmux on a PRIVATE socket (`RDEV_TMUX_SOCKET`) — never the user's server. Skips LOUDLY
/// when tmux is not installed.
final class TmuxControlClientTests: XCTestCase {
    private var runner: TmuxRunner!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment.merging(["RDEV_TMUX_SOCKET": "rdev-test-\(getpid())"]) { $1 }
        guard let r = TmuxRunner.locate(environment: env) else {
            throw XCTSkip("tmux is not installed — TmuxControlClientTests did NOT run")
        }
        // EVERY command carries `-f /dev/null`, so whichever one starts the private server, the user's
        // ~/.tmux.conf never shapes what is measured (as TerminalManagerTmuxTests does).
        runner = r.withConfigFile("/dev/null")
    }

    override func tearDown() {
        guard let runner else { return }
        _ = runner.run(["kill-server"])
        TmuxTestSocket.remove("rdev-test-\(getpid())")
    }

    func testLocateHonoursTheTestSocketAndSearchOrder() {
        let r = TmuxRunner.locate(environment: ["PATH": "/nope", "RDEV_TMUX_SOCKET": "s1"],
                                  fileExists: { $0 == "/usr/local/bin/tmux" || $0 == "/opt/homebrew/bin/tmux" })
        XCTAssertEqual(r?.path, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(r?.socketArgs, ["-L", "s1"])
        XCTAssertEqual(TmuxRunner.locate(environment: ["PATH": "/x"], fileExists: { $0 == "/x/tmux" })?.path, "/x/tmux")
        XCTAssertEqual(TmuxRunner.locate(environment: ["PATH": "/x"], fileExists: { $0 == "/x/tmux" })?.socketArgs, [])
        XCTAssertNil(TmuxRunner.locate(environment: ["PATH": "/x"], fileExists: { _ in false }))
    }

    func testNoServerMeansAnEmptyList() { XCTAssertEqual(runner.listSessions(), []) }

    func testTypeAndReadBack() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let got = expectation(description: "echo came back")
        got.assertForOverFulfill = false
        let lock = NSLock()
        var out: [UInt8] = []
        let client = try XCTUnwrap(TmuxControlClient(runner: runner, session: sid, onEvent: { e in
            if case .output(_, let b) = e {
                lock.lock(); out += b; let s = String(decoding: out, as: UTF8.self); lock.unlock()
                if s.contains("rdevmark42") { got.fulfill() }
            }
        }, onExit: {}))
        // Typed as "rdevmark4" + "2" so the ECHO of the command line cannot satisfy the wait — only the
        // command's output can. Mutation check: dropping `-H` sends the hex digits as literal text.
        let hex = Array("echo rdevmark4''2\r".utf8).map { String(format: "%02x", $0) }.joined(separator: " ")
        client.command("send-keys -H -t \(sid) \(hex)") { _ in }
        wait(for: [got], timeout: 10)
        client.stop()
    }

    func testDetachLeavesTheSessionRunning() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let client = try XCTUnwrap(TmuxControlClient(runner: runner, session: sid, onEvent: { _ in }, onExit: {}))
        let replied = expectation(description: "reply")
        client.command("display -p -t \(sid) '#{session_id}'") { r in
            XCTAssertEqual(try? r.get(), [sid]); replied.fulfill()
        }
        wait(for: [replied], timeout: 5)
        client.stop()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(runner.listSessions().contains { $0.id == sid })
    }

    func testErrorsAndDeathAreReported() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let exited = expectation(description: "onExit")
        let client = try XCTUnwrap(TmuxControlClient(runner: runner, session: sid, onEvent: { _ in },
                                                     onExit: { exited.fulfill() }))
        let failed = expectation(description: "error reply")
        client.command("bogus-command") { r in
            if case .failure(.failed) = r { failed.fulfill() }
        }
        wait(for: [failed], timeout: 5)
        XCTAssertTrue(runner.killSession(sid))
        wait(for: [exited], timeout: 5)
        let dead = expectation(description: "dead")
        client.command("display -p x") { r in if case .failure(.dead) = r { dead.fulfill() } }
        wait(for: [dead], timeout: 5)
    }

    func testRefusesAMalformedSessionId() {
        XCTAssertNil(TmuxControlClient(runner: runner, session: "alpha; kill-server", onEvent: { _ in }, onExit: {}))
        XCTAssertFalse(runner.killSession("alpha"))
    }

    /// Commands arrive from several threads (the peer dispatcher, tmux's own callback queue). Each
    /// reply must reach ITS command: registering and writing must be one step, or two racing callers
    /// swap replies.
    func testConcurrentCommandsGetTheirOwnReplies() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let client = try XCTUnwrap(TmuxControlClient(runner: runner, session: sid, onEvent: { _ in }, onExit: {}))
        let n = 200
        let done = expectation(description: "all replies")
        done.expectedFulfillmentCount = n
        let lock = NSLock()
        var wrong: [String] = []
        DispatchQueue.concurrentPerform(iterations: n) { i in
            client.command("display -p 'r\(i)'") { r in
                if (try? r.get()) != ["r\(i)"] { lock.lock(); wrong.append("\(i): \(r)"); lock.unlock() }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(wrong, [], "replies matched to the wrong command")
        client.stop()
    }

    /// A batch is written as ONE write, and each line gets its own result in order.
    func testBatchReturnsOneResultPerCommand() throws {
        let sid = try XCTUnwrap(runner.newSession())
        let client = try XCTUnwrap(TmuxControlClient(runner: runner, session: sid, onEvent: { _ in }, onExit: {}))
        let done = expectation(description: "batch")
        client.batch(["display -p one", "bogus-command", "display -p three"]) { rs in
            XCTAssertEqual(rs.count, 3)
            XCTAssertEqual(try? rs[0].get(), ["one"])
            if case .failure(.failed) = rs[1] {} else { XCTFail("the middle command must fail") }
            XCTAssertEqual(try? rs[2].get(), ["three"])
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        client.stop()
    }

    /// `LaunchdJob` reads `launchctl print`'s top-level fields only (its own tests, which need launchd, are
    /// //host/RdevHostKit:RdevHostKitLaunchdTests).
    func testLaunchctlPrintIsReadAtTheTopLevelOnly() {
        let running = "gui/501/x = {\n\tstate = running\n\truns = 1\n\tpid = 9\n\tlast exit code = (never exited)\n\t\tstate = active\n}"
        XCTAssertNil(LaunchdJob.exitStatus(running))
        XCTAssertNil(LaunchdJob.exitStatus("x = {\n\tstate = not running\n\truns = 0\n\tlast exit code = (never exited)\n}"))
        XCTAssertEqual(LaunchdJob.exitStatus("x = {\n\tstate = not running\n\truns = 1\n\tlast exit code = 3\n\t\tstate = active\n}"), 3)
        XCTAssertEqual(LaunchdJob.exitStatus("x = {\n\t\tstate = not running\n\tstate = running\n\truns = 1\n}"), nil)
        XCTAssertEqual(LaunchdJob.exitStatus("x = {\n\tstate = not running\n\truns = 2\n}"), -1)
        XCTAssertNil(LaunchdJob.exitStatus("x = {\n\tstate = not running\n\truns = 1\n\tlast exit code = (never exited)\n}"),
                     "run, code not recorded yet: keep polling")
    }
}

/// The read loop's chunks must not outlive their read. It runs inside one GCD block that never returns,
/// and `availableData` autoreleases: without a pool per read, every chunk lived as long as the tab
/// (2026-10-13: 46 GB, all 16 KB NSConcreteData). No tmux needed — the loop is read through a pipe.
final class TmuxReadLoopTests: XCTestCase {
    func testTheReadLoopKeepsNoChunkAliveAfterItsRead() {
        let pipe = Pipe()
        let total = 64 << 20
        let writer = Thread {
            let piece = Data(repeating: 0x61, count: 64 << 10)
            var sent = 0
            while sent < total { pipe.fileHandleForWriting.write(piece); sent += piece.count }
            try? pipe.fileHandleForWriting.close()
        }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        let before = Int(stats.size_in_use)
        writer.start()
        var got = 0
        // Measured INSIDE the loop's caller, before anything outer can drain: the chunks still alive
        // when the last read returns are exactly what the production loop would be holding.
        TmuxControlClient.readChunks(from: pipe.fileHandleForReading) { d in got += d.count; return true }
        malloc_zone_statistics(nil, &stats)
        let grew = Int(stats.size_in_use) - before
        XCTAssertEqual(got, total, "every byte written was read — the bound below is not vacuous")
        XCTAssertLessThan(grew, 16 << 20,
                          "\(grew >> 20) MiB still allocated after reading \(total >> 20) MiB: the read loop keeps its chunks alive")
    }
}
