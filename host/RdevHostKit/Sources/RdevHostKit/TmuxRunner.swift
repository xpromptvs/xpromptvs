import Foundation
import RdevCore

/// Finding and invoking `tmux`.
///
/// The packaged app's PATH is `/usr/bin:/bin:/usr/sbin:/sbin` (launchd), so Homebrew's locations are
/// checked BEFORE the PATH. `RDEV_TMUX_SOCKET=<name>` points every invocation at a private server
/// (`-L <name>`) — for tests and the e2e check only; the product always uses the DEFAULT server,
/// because reaching the user's own sessions is the point. `-L`, never `-S <path>`: a socket path
/// under a long temp directory overflows `sun_path` (104 bytes) and tmux cannot connect.
public struct TmuxRunner: Sendable {
    public let path: String
    public let socketArgs: [String]
    /// `-f <file>` on EVERY invocation, or none (the product: tmux reads the user's own config).
    public private(set) var configArgs: [String] = []
    private let inherited: [String: String]

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              fileExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> TmuxRunner? {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/tmux" }
        guard let path = candidates.first(where: fileExists) else { return nil }
        let sock = environment["RDEV_TMUX_SOCKET"].flatMap { $0.isEmpty ? nil : ["-L", $0] } ?? []
        return TmuxRunner(path: path, socketArgs: sock, inherited: environment)
    }

    /// The same runner with `-f <path>` on every command — tests, whose private server must never read
    /// the user's `~/.tmux.conf`, whichever command happens to start it.
    public func withConfigFile(_ path: String) -> TmuxRunner {
        var r = self
        r.configArgs = ["-f", path]
        return r
    }

    /// A tmux SERVER that rdev starts inherits this, so its panes get what a plain tab's shell gets
    /// (`TermEnvironment`: TERM, COLORTERM, a locale).
    public var environment: [String: String] { TermEnvironment.environment(inherited: inherited) }

    func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = socketArgs + configArgs + args
        p.environment = environment
        return p
    }

    /// One-shot, capped at 5 s. The termination handler is installed BEFORE `run()` (a fast exit would
    /// otherwise be missed), and stdout is drained CONCURRENTLY so a large output cannot fill the pipe
    /// and deadlock the child against our wait.
    public func run(_ args: [String]) -> (status: Int32, stdout: String) {
        let p = process(args)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        let drained = DispatchSemaphore(value: 0)
        let box = DataBox()
        DispatchQueue.global().async { box.data = out.fileHandleForReading.readDataToEndOfFile(); drained.signal() }
        do { try p.run() } catch { try? out.fileHandleForWriting.close(); return (-1, "") }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            _ = drained.wait(timeout: .now() + 1)
            return (-1, "")
        }
        drained.wait()
        return (p.terminationStatus, String(decoding: box.data, as: UTF8.self))
    }

    /// Exact bytes, bounded before accumulation. Separate from line-oriented control replies so trailing
    /// newlines, percent-prefixed text and UTF8 are never reinterpreted as control protocol.
    func readPasteBuffer(_ name: String, limit: Int = TermClipboard.maxBytes) -> Data? {
        guard !name.isEmpty, name.utf8.count <= 1024, limit >= 0, limit <= TermClipboard.maxBytes else { return nil }
        // Foundation normalizes Unicode argv on macOS. Feed an ASCII-only tmux command instead:
        // each quoted byte is octal, so names cannot inject commands and NFC names stay exact.
        let quoted = name.utf8.map { String(format: "\\%03o", Int($0)) }.joined()
        let command = Data("save-buffer -b \"\(quoted)\" -\n".utf8)
        let p = process(["source-file", "-"]), out = Pipe(), input = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = input
        let done = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0), box = ClipboardDataBox()
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        do {
            try input.fileHandleForWriting.write(contentsOf: command)
            try input.fileHandleForWriting.close()
        } catch { if p.isRunning { p.terminate() }; return nil }
        DispatchQueue.global().async {
            while let chunk = try? out.fileHandleForReading.read(upToCount: 16 * 1024), !chunk.isEmpty {
                if chunk.count > limit - box.data.count { box.overflow = true; if p.isRunning { p.terminate() }; break }
                box.data.append(chunk)
            }
            drained.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success else { if p.isRunning { p.terminate() }; return nil }
        guard drained.wait(timeout: .now() + 1) == .success, !box.overflow, p.terminationStatus == 0,
              String(data: box.data, encoding: .utf8) != nil else { return nil }
        return box.data
    }

    /// Every session on the server. `no server running` exits non-zero and is an EMPTY list, not an
    /// error: it is simply the state before anyone has used tmux.
    public func listSessions() -> [TmuxSessionInfo] { listSessionsIfReachable() ?? [] }

    /// Like `listSessions`, but nil when the listing could not be TAKEN (tmux would not start, or hung
    /// past the cap). "Unreachable" is not "no sessions": a caller that would close tabs or tell a
    /// client to forget sessions must use this and do nothing on nil.
    public func listSessionsIfReachable() -> [TmuxSessionInfo]? {
        let r = run(["list-sessions", "-F", TmuxList.format])
        guard r.status >= 0 else { return nil }
        return r.status == 0 ? TmuxList.parse(r.stdout) : []
    }

    /// A new detached session; its id (`$N`), or nil. Starts the server if none is running.
    /// `directory`: where its first window starts (`-c`; TerminalManager's new-tab rule). nil: tmux's own
    /// choice.
    ///
    /// **Run as a launchd job (`LaunchdJob`), never as this process's child** — the one tmux command that
    /// can START a server does it from launchd's coalition, so the server, and every pane on it, outlives the
    /// app (docs/terminal.md, "A tmux server rdev starts is launchd's"). It carries the environment a child
    /// would have had (`environment`) and this process's directory. Without a GUI domain (a host over ssh)
    /// the session is started directly, as before, and ends when this process's coalition is killed.
    public func newSession(directory: String? = nil) -> String? {
        var args = ["new-session", "-d", "-P", "-F", "#{session_id}", "-e", "COLORTERM=truecolor"]
        if let directory { args += ["-c", directory] }
        let r: (status: Int32, stdout: String)
        if let job = LaunchdJob.run([path] + socketArgs + configArgs + args, environment: environment,
                                    directory: FileManager.default.currentDirectoryPath) {
            r = (job.status, job.stdout)
        } else {
            print("[tmux] no launchd GUI domain: a server this session starts ends with this app")
            r = run(args)
        }
        let id = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && TmuxList.isSessionId(id) ? id : nil
    }

    /// The directory of the session's ACTIVE pane (`#{pane_current_path}`: its foreground process's), or nil.
    public func panePath(_ session: String) -> String? {
        guard TmuxList.isSessionId(session) else { return nil }
        let r = run(["display-message", "-p", "-t", session, "#{pane_current_path}"])
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && path.hasPrefix("/") ? path : nil
    }

    public func killSession(_ id: String) -> Bool {
        guard TmuxList.isSessionId(id) else { return false }
        return run(["kill-session", "-t", id]).status == 0
    }

    /// Rename a session; whether tmux took the name. `--` ends the options, so a name starting with `-`
    /// is a name (measured on 3.7c: `-n` and `--` both renamed). The name goes as ARGV, never through a
    /// control client's command line (which tmux parses as syntax), as `TmuxList.renameArgument` — tmux
    /// format-expands the name and its argv parse strips a trailing `;`. A duplicate name, a session that
    /// is gone, and a name tmux refuses (a control character: "invalid session name") exit non-zero.
    /// Refused HERE without running tmux: an id that is not `$<n>`, and an empty or invalid name (tmux
    /// would take `""` and leave the session with no name).
    public func renameSession(_ id: String, _ name: String) -> Bool {
        guard TmuxList.isSessionId(id), !name.isEmpty, TabName.isValid(name) else { return false }
        return run(["rename-session", "-t", id, "--", TmuxList.renameArgument(name)]).status == 0
    }
}

/// The drain closure writes, `run` reads after `drained` signals — ordered by the semaphore.
private final class DataBox: @unchecked Sendable { var data = Data() }
private final class ClipboardDataBox: @unchecked Sendable { var data = Data(); var overflow = false }
