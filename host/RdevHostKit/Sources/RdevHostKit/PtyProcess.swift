import Foundation
import Darwin
import RdevCore

public final class PtyProcess: @unchecked Sendable {
    /// Guards `master`, `pid` and `stopped`: `stop()`, `write`, `resize` and the read loop's end run on
    /// different threads.
    private let lock = NSLock()
    private var master: Int32 = -1
    private var pid: pid_t = -1
    /// `stop()` was called: the shell ending now is OURS, and says nothing.
    private var stopped = false
    private let queue = DispatchQueue(label: "pty.read")
    public var onOutput: ((Data) -> Void)?
    /// The shell ended ON ITS OWN — it exited, or the last process holding its terminal went — never
    /// after `stop()`. Called once, on the read queue, after its last output. TerminalManager closes
    /// the tab: until 2026-09-29 nothing noticed, the tab stayed listed for the life of the host, and
    /// its zombie was never reaped.
    public var onExit: (() -> Void)?

    public init() {}

    /// A PtyProcess dropped without `stop()` must not leave its shell running with nothing attached —
    /// which is what Stop Sharing did before it closed the tabs.
    deinit { stop() }

    /// `cwd`: the directory the shell starts in (TerminalManager's rule: home for the first tab, the active
    /// tab's directory after — docs/terminal.md, "Tabs that come back"); nil keeps the host's own, which for
    /// an app launched from Finder or the Dock is `/`. One that cannot be entered leaves the host's too.
    public func start(shell: String = "/bin/zsh", cols: UInt16, rows: UInt16, cwd: String? = nil) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var amaster: Int32 = 0
        // Every C string is built BEFORE the fork: the child of a multithreaded process may only call
        // async-signal-safe functions, and allocating there can deadlock on a lock another thread held.
        // The environment describes xterm.js, not whatever launched the host — see `TermEnvironment`.
        var env = TermEnvironment.environment(inherited: ProcessInfo.processInfo.environment)
        if let cwd { env["PWD"] = cwd }                    // a login shell trusts a PWD that names its directory
        var envp: [UnsafeMutablePointer<CChar>?] = TermEnvironment.envp(env).map { strdup($0) } + [nil]
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(TermEnvironment.loginArgv0(shell: shell)), nil]
        let path = strdup(shell)
        let dir: UnsafeMutablePointer<CChar>? = cwd.flatMap { strdup($0) }
        defer { (envp + argv + [path, dir]).forEach { free($0) } }
        let pid = forkpty(&amaster, nil, nil, &size)
        if pid == 0 {
            if let dir { _ = chdir(dir) }                  // async-signal-safe
            execve(path, &argv, &envp)
            _exit(1)
        }
        lock.lock(); master = amaster; self.pid = pid_t(pid); lock.unlock()
        let masterFd = amaster
        queue.async { [weak self] in
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            // Each chunk's handling in its own autorelease pool: this block never returns while the
            // shell lives, GCD drains a queue's pool only when a block ends, and `onOutput` runs the
            // terminal pipeline inline — anything it autoreleases would live as long as the tab (the
            // tmux read loop leaked exactly that way; `TmuxControlClient.readChunks`).
            while true {
                let n = read(masterFd, buf, bufSize)
                if n < 0 && errno == EINTR { continue }      // a signal, not the end
                if n <= 0 { break }                          // EOF/EIO: the terminal closed
                autoreleasepool { self?.onOutput?(Data(bytes: buf, count: n)) }
            }
            self?.readEnded()
        }
    }

    /// The read loop saw the terminal close: reap the shell and report it — unless `stop()` got here
    /// first, in which case the ending is ours.
    private func readEnded() {
        lock.lock()
        let deliberate = stopped
        let p = pid
        let m = master
        if !deliberate { pid = -1; master = -1 }
        lock.unlock()
        guard !deliberate else { return }
        if m >= 0 { close(m) }
        if p > 0 { var s: Int32 = 0; _ = waitpid(p, &s, 0) }   // the zombie goes now, not with the host
        onExit?()
    }

    /// The directory of what runs in the terminal NOW: its FOREGROUND process group's leader (a program the
    /// shell started, a shell started inside it — what tmux's `pane_current_path` reads too), else the
    /// shell. nil once the shell has ended, or where the OS will not say.
    public func currentDirectory() -> String? {
        lock.lock(); let m = master, p = pid; lock.unlock()
        guard p > 0 else { return nil }
        let foreground = m >= 0 ? tcgetpgrp(m) : -1
        if foreground > 0, let d = Self.directory(of: foreground) { return d }
        return Self.directory(of: p)
    }

    /// The terminal's FOREGROUND process group — what runs in it now (an agent, a program, the shell itself) — or nil
    /// once the shell has ended. What an agent's activity is gated on (`ForegroundProcesses`).
    public func foregroundGroup() -> pid_t? {
        lock.lock(); let m = master, p = pid; lock.unlock()
        guard p > 0 else { return nil }
        let foreground = m >= 0 ? tcgetpgrp(m) : -1
        return foreground > 0 ? foreground : p
    }

    static func directory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
    }

    public func write(_ data: Data) {
        lock.lock(); let m = master; lock.unlock()
        guard m >= 0 else { return }
        data.withUnsafeBytes { _ = Darwin.write(m, $0.baseAddress, data.count) }
    }

    /// Kill the shell and close the master fd. Closing the fd makes the read loop's read() return, so
    /// its thread exits (and, `stopped` being set, reports nothing); the SIGKILL + detached waitpid
    /// reaps the child so it doesn't linger as a zombie. Idempotent.
    public func stop() {
        lock.lock()
        stopped = true
        let p = pid; pid = -1
        let m = master; master = -1
        lock.unlock()
        if p > 0 {
            kill(p, SIGKILL)
            DispatchQueue.global().async { var s: Int32 = 0; _ = waitpid(p, &s, 0) }
        }
        if m >= 0 { close(m) }
    }

    /// Update the PTY window size so the foreground program reflows (delivers SIGWINCH).
    /// No-op until `start(...)` has opened the master fd.
    public func resize(cols: UInt16, rows: UInt16) {
        lock.lock(); let m = master; lock.unlock()
        guard m >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(m, TIOCSWINSZ, &size)
    }

    /// Tests: the shell's pid while it runs, -1 otherwise.
    var processIDForTests: pid_t { lock.withLock { pid } }
}
