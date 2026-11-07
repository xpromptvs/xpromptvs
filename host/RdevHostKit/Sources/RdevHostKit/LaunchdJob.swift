import Foundation

/// A program run ONCE as a launchd job in the person's GUI domain (`gui/<uid>`), so that it — and anything it
/// forks, a daemon included — belongs to a coalition of launchd's, not to the process that asked.
///
/// WHY (docs/terminal.md, "A tmux server rdev starts is launchd's"): on macOS 27 a FOREGROUND app that quits
/// has every process left in its coalition SIGTERMed by loginwindow about a second later, unless Background
/// Task Management says the app may run in the background. Xpromptvs is allowed, and the allowance lapsed once
/// (`Error -98`, 2026-10-10, at a bundle swap). Membership survives `setsid` and daemonizing, so a tmux server
/// the app forked died with it then, and every session on it.
///
/// The job comes from a plist — its environment travels in that file, 0600 in a private directory, never on
/// argv — is polled with `launchctl print` until it has run and exited, then booted out and its files removed.
/// Booting a job out ends the JOB; a daemon it forked keeps running (measured).
enum LaunchdJob {
    struct Result: Equatable {
        /// The program's exit code; -1 for one that ran past the timeout (booted out, which stops it) or ended
        /// without one (a signal).
        let status: Int32
        let stdout: String
    }

    /// nil when the job could not be STARTED — no GUI domain (a host over ssh), or launchctl refused — and the
    /// caller must run the program itself.
    static func run(_ argv: [String], environment: [String: String], directory: String,
                    timeout: TimeInterval = 5) -> Result? {
        let label = "ai.xpromptvs.job.\(UUID().uuidString)"
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(label, isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? fm.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("job.plist"), out = dir.appendingPathComponent("stdout")
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": exactly(environment) + argv,
            "EnvironmentVariables": environment,
            "WorkingDirectory": directory,
            "StandardOutPath": out.path,
            "StandardErrorPath": "/dev/null",
            "RunAtLoad": true,
            // What it forks is not launchd's to kill when the job ends.
            "AbandonProcessGroup": true,
            // A tmux server's panes run what a tab runs — builds included — so no background throttling.
            "ProcessType": "Interactive",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
              fm.createFile(atPath: plist.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { return nil }
        let domain = "gui/\(getuid())", service = "\(domain)/\(label)"
        guard launchctl(["bootstrap", domain, plist.path]).status == 0 else { return nil }
        defer { _ = launchctl(["bootout", service]) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = exitStatus(launchctl(["print", service]).stdout) {
                return Result(status: status, stdout: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
            }
            usleep(5_000)
        }
        return Result(status: -1, stdout: "")
    }

    /// What launchd puts in EVERY job's environment (measured 2026-10-10). `OSLogRateLimit`, `XPC_SERVICE_NAME`
    /// and `XPC_FLAGS` it sets whatever `EnvironmentVariables` says; the rest only when the plist lacks them.
    /// A tmux server keeps its environment as the GLOBAL one every pane gets, so a pane would be rate-limited
    /// in os_log and named after a dead job.
    static let launchdAdds = ["OSLogRateLimit", "XPC_SERVICE_NAME", "XPC_FLAGS", "SSH_AUTH_SOCK", "PATH",
                              "LOGNAME", "USER", "HOME", "SHELL", "TMPDIR"]

    /// The program runs under `/usr/bin/env`, which unsets what launchd added and gives back the caller's own
    /// value where it has one (on argv: system values, nothing secret — the rest travel in the plist), so
    /// the program sees EXACTLY `environment`. `env` execs it: the same pid, the job's.
    static func exactly(_ environment: [String: String]) -> [String] {
        ["/usr/bin/env"] + launchdAdds.flatMap { ["-u", $0] }
            + launchdAdds.compactMap { k in environment[k].map { "\(k)=\($0)" } }
    }

    /// The job's exit status once it has run and is not running; nil while it has not. Read from `launchctl
    /// print`'s TOP-LEVEL fields, one tab deep (nested sections repeat `state`): `state = not running`,
    /// `runs = 1`, `last exit code = 0` — `(never exited)` before the first exit.
    static func exitStatus(_ print: String) -> Int32? {
        var fields: [String: String] = [:]
        for line in print.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        guard fields["state"] == "not running", let runs = fields["runs"].flatMap({ Int($0) }), runs > 0 else { return nil }
        // `(never exited)` after a run: the code is not recorded YET — keep polling, or a session tmux created
        // reads as failed. No code at all (a signal): -1.
        guard let code = fields["last exit code"] else { return -1 }
        return Int32(code)
    }

    private static func launchctl(_ args: [String]) -> (status: Int32, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
