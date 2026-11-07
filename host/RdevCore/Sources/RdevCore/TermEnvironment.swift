import Foundation

/// The environment and argv[0] a terminal tab's shell is started with.
///
/// The shell used to inherit the host PROCESS's environment verbatim, which is right only when the
/// host was started from a terminal. The packaged app is launched by launchd, whose environment has
/// no `TERM`, no `COLORTERM` and no locale (measured on the Mac mini, 2026-09-25): zsh then has no
/// cursor-left capability and answers a backspace with a bare `" "` — characters are deleted
/// remotely but the screen gains spaces — and every `COLORTERM`/`TERM`-sniffing program (Claude
/// Code) renders grayscale, while vim, which falls back to a builtin ANSI table, stays coloured.
///
/// The peer on the other end of the PTY is always xterm.js, so the terminal description is
/// OVERRIDDEN, not defaulted: a host started from tmux or iTerm would otherwise describe the
/// terminal it was launched from, not the one the shell is drawing into.
public enum TermEnvironment {
    public static let term = "xterm-256color"
    public static let colorTerm = "truecolor"
    public static let fallbackLang = "en_US.UTF-8"

    /// Variables that describe the host process's OWN terminal and are false inside a tab.
    static let stripped: Set<String> = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TMUX", "TMUX_PANE",
        "ITERM_SESSION_ID", "ITERM_PROFILE", "LC_TERMINAL", "LC_TERMINAL_VERSION",
        // Agent/launcher shells suppress their own output with NO_COLOR. A tab is a new,
        // interactive terminal; its login shell can still set NO_COLOR explicitly itself.
        "NO_COLOR",
    ]

    /// `inherited` with the terminal described as xterm.js, and a UTF-8 locale when none is set.
    /// A locale the parent DID set is kept — it is the person's choice, not the launcher's accident.
    public static func environment(inherited: [String: String]) -> [String: String] {
        var env = inherited.filter { !stripped.contains($0.key) }
        env["TERM"] = term
        env["COLORTERM"] = colorTerm
        let hasLocale = ["LC_ALL", "LC_CTYPE", "LANG"].contains { !(env[$0] ?? "").isEmpty }
        if !hasLocale { env["LANG"] = fallbackLang }
        return env
    }

    /// `KEY=VALUE` strings for `execve`, sorted so the result is deterministic.
    public static func envp(_ env: [String: String]) -> [String] {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// argv[0] for a LOGIN shell — a leading `-` on the basename, as Terminal.app starts one — so
    /// `/etc/zprofile`'s `path_helper` and the person's `.zprofile` run. launchd's PATH is
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, which finds neither Homebrew nor anything installed per user.
    public static func loginArgv0(shell: String) -> String {
        "-" + (shell as NSString).lastPathComponent
    }
}
