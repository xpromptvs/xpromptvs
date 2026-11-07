import Darwin

/// **WHAT RUNS IN A TERMINAL'S FOREGROUND**, from the kernel's process table — what `ps -t <tty>` shows of the processes
/// whose group is the terminal's foreground group (`pgid == tpgid`). Read for an agent's activity (`AgentProcess`,
/// docs/terminal.md, "An agent's activity"): a `pty:` tab names its group (`PtyProcess.foregroundGroup`, the host owns
/// the master), a `tmux:` tab its pane's tty (`#{pane_tty}`), whose foreground group only the table can say — a
/// process may ask `tcgetpgrp` of its OWN controlling terminal alone. Each process's arguments are read as `ps` reads
/// them (`KERN_PROCARGS2` — after a rename, the new name: Claude Code's `claude`), and its executable's path.
enum ForegroundProcesses {
    struct Process: Equatable { let pid: pid_t; let path: String?; let argv: [String] }

    /// The processes in process group `pgrp`.
    static func inGroup(_ pgrp: pid_t) -> [Process] {
        guard pgrp > 0 else { return [] }
        return table([CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgrp]).map(describe)
    }

    /// The processes in the FOREGROUND group of the terminal at `tty` (`/dev/ttys012`).
    static func onTerminal(_ tty: String) -> [Process] {
        var st = stat()
        guard stat(tty, &st) == 0 else { return [] }
        return table([CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(st.st_rdev)])
            .filter { $0.kp_eproc.e_tpgid > 0 && $0.kp_eproc.e_pgid == $0.kp_eproc.e_tpgid }
            .map(describe)
    }

    private static func table(_ name: [Int32]) -> [kinfo_proc] {
        var mib = name
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for a few more that start between the two calls.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 8)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    private static func describe(_ p: kinfo_proc) -> Process {
        let pid = p.kp_proc.p_pid
        return Process(pid: pid, path: executable(pid), argv: arguments(pid))
    }

    static func executable(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// `KERN_PROCARGS2`: `argc` (an int), the executable path, its padding of NULs, then `argc` NUL-ended arguments.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }
}
