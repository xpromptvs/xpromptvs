import Foundation

/// **WHETHER AN AGENT IS WORKING IN A TAB** (2026-10-05, asked: "Is it possible to know when an agent (codex/claude)
/// in a tab (terminal or tmux) [is] thinking, and when it's idle?" — "This can be tracked on a host";
/// docs/terminal.md, "An agent's activity").
///
/// MEASURED 2026-10-05 against every live agent on the dev Mac (Claude Code 2.1.283–2.1.289, Codex 0.160.0), by
/// reading their panes: both print "esc to interrupt" in a STATUS LINE at the bottom of what they draw, and only
/// while a turn runs — Claude Code in its footer (`⏵⏵ auto mode on · esc to interrupt · ← 2 agents`), Codex above
/// its composer (`• Working (15m 56s • esc to interrupt)`) — and drop it when the turn ends (`⏵⏵ auto mode on
/// (shift+tab to cycle) · ← 2 agents`, `Worked for 1m 34s`). Two panes whose footers said it with an empty prompt
/// were checked twice, 5 s apart: both were working (their spinners' timers moved). The TITLE serves Codex only (a
/// braille spinner while it works): Claude Code's `✳` stayed through a running turn. So the SCREEN is read.
///
/// **AND ONLY WHERE AN AGENT RUNS** (asked the same day: "To rule out false positives, can we detect that we are indeed
/// running a claude or codex or another agent"): the tab's FOREGROUND process group must hold one (`AgentProcess`) —
/// else the tab has no agent, whatever its screen says (a grep of these words, a log, a document).
public enum AgentActivity {
    public enum State: String, Sendable { case working, idle }

    /// How many rows are read, up from the last one with anything on it: Codex's line sits about seven rows above
    /// its last (its tip, the composer and two footer lines below it). From the last NON-BLANK row, because a short
    /// conversation leaves the agent's footer high on the screen with empty rows below.
    public static let rows = 12

    /// Whether `screen` (its rows, top to bottom) shows `agent` (`AgentProcess.kind`) at work — read WHERE THAT AGENT
    /// DRAWS ITS STATUS, never in the conversation above its input box, which may QUOTE the words (asked 2026-10-05:
    /// "We have an 'esc to interrupt' string here in this chat. Will it cause false positive?" — with the general rule
    /// it would have: an idle Claude Code whose last reply quoted Codex's status line read as working):
    ///   - `claude`: its SPINNER LINE by its SHAPE (`isClaudeSpinnerLine`) — the technique Codex's status line uses —
    ///     or its FOOTER's hint, the rows below the last rule (`────`) under its input box. Reported 2026-10-06: "on
    ///     smaller screens our in-progress detection does not always work, because 'esc to interrupt' is cut short".
    ///     Since 2.1.28x the hint is in the footer ALONE (measured: `✳ Finagling… (9m 3s · ↓ 51.4k tokens · …)` above
    ///     the box, `⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← 2 agents` below it), and a phone's
    ///     grid cuts the footer before it — while the spinner line's START survives any width.
    ///   - `codex`: its TITLE spinning (`titleSpins`), or a whole line of its status's shape,
    ///     `• <header> (<elapsed> • esc to interrupt)`. Asked the same day: "Codex not always prints 'Working' —
    ///     sometimes it's a description of the current task". The header is that description at times, so only the
    ///     line's SHAPE is held; and a long one on a narrow pane (a phone's grid) can push the hint off the edge, which
    ///     the title does not care about — measured: a braille spinner frame leads Codex's title the whole time it
    ///     works (`⠦ Select tools for world generation | turingstown`, 30 samples in 3 s) and is gone when it is idle.
    ///   - any other: the general rule (`hasHint`).
    public static func working(screen: [String], agent: String?, title: String? = nil) -> Bool {
        if agent == "codex", let title, titleSpins(title) { return true }
        let rows = lastRows(screen)
        switch agent {
        case "claude":
            if let rule = rows.lastIndex(where: isRule), rows[(rule + 1)...].contains(where: hasHint) { return true }
            return rows.contains(where: isClaudeSpinnerLine)
        case "codex":
            return rows.contains(where: isCodexStatusLine)
        default:
            return rows.contains(where: hasHint)
        }
    }

    /// The general rule alone, for an agent this does not know the layout of.
    public static func working(screen: [String]) -> Bool { working(screen: screen, agent: nil) }

    /// The last `rows` rows up from the last one with anything on it.
    static func lastRows(_ screen: [String]) -> ArraySlice<String> {
        var end = screen.count
        while end > 0, screen[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return screen[max(0, end - rows)..<end]
    }

    /// A rule Claude Code draws above and below its input box: nothing but `─`.
    static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 8 && t.allSatisfy { $0 == "─" }
    }

    /// Codex's title while it works: a braille spinner frame first (`⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`, any of U+2801…U+28FF),
    /// then a space. The blank pattern U+2800 is no frame.
    static func titleSpins(_ title: String) -> Bool {
        var it = title.unicodeScalars.makeIterator()
        guard let first = it.next(), (0x2801...0x28FF).contains(first.value) else { return false }
        return it.next() == " "
    }

    /// Claude Code's spinner glyphs (its own list: `· ✢ ✳ ✶ ✻ ✽`, `*` on some terminals).
    static let claudeSpinner: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽", "*"]

    /// Claude Code's line while a turn runs, by its SHAPE: a spinner glyph FIRST on the line (a reply is indented, a
    /// tool's output sits under `⎿`), a space, then a header ending in `…` before its parenthesis — a verb it picks at
    /// random (`✻ Roosting… (52s · ↓ 3.5k tokens)`, 2.1.287; `✻ Thinking… (3s · esc to interrupt)`, older). Its
    /// finished form says what it did, in the past tense and with no ellipsis (`✻ Brewed for 29s · done 2:10 AM`).
    /// Only the START is read, so a grid that cuts the rest off changes nothing (measured on the dev Mac's panes,
    /// 2026-10-06: the shape held in 30 of 30 samples of two working panes, across the glyph's frames `·` and `✽`).
    static func isClaudeSpinnerLine(_ line: String) -> Bool {
        let c = Array(line.prefix(2))
        guard c.count == 2, claudeSpinner.contains(c[0]), c[1] == " " else { return false }
        let rest = line.dropFirst(2)
        let header = (rest.range(of: " (").map { rest[..<$0.lowerBound] } ?? rest).trimmingCharacters(in: .whitespaces)
        guard header.hasSuffix("…") else { return false }
        let words = header.dropLast()
        return words.contains(where: \.isLetter) && words.allSatisfy { $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" }
    }

    /// `• Working (15m 56s • esc to interrupt)`, `• Exploring the codebase (2m 3s • esc to interrupt)` — any header,
    /// its bullet `•` or `◦`, the line ENDING with the hint inside the status's parentheses.
    static func isCodexStatusLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        let end = "esc to interrupt)"
        guard t.hasPrefix("• ") || t.hasPrefix("◦ "), t.hasSuffix(end), let open = t.lastIndex(of: "(") else { return false }
        let inside = t[t.index(after: open)...].dropLast(end.count).trimmingCharacters(in: .whitespaces)
        return inside.count > 1 && inside.hasSuffix("•")
    }

    /// "esc to interrupt", case aside, where a STATUS LINE puts it: after one of its separators (`·`, `•`, `(`) or
    /// at the line's start. Output that merely says it — a grep, a document — has a word before it.
    static func hasHint(_ line: String) -> Bool {
        let lower = line.lowercased()
        var from = lower.startIndex
        while let r = lower.range(of: "esc to interrupt", range: from..<lower.endIndex) {
            let before = lower[lower.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            if before.isEmpty || before.hasSuffix("·") || before.hasSuffix("•") || before.hasSuffix("(") { return true }
            from = r.upperBound
        }
        return false
    }
}

/// **WHICH AGENT A PROCESS IS**, from what it says it is (`ps` shows the same): its arguments and its executable's
/// path. MEASURED 2026-10-05 (`ps -t` on every agent pane of the dev Mac): Codex runs as `codex`; Claude Code's
/// executable is `~/.local/share/claude/versions/2.1.283` — its NAME a version number, which is all tmux's
/// `pane_current_command` shows — and it renames itself `claude` (its arguments: `claude --resume …`); the processes
/// it starts (`caffeinate`, MCP servers) join its group. Installed through npm, an agent is `node` running its
/// package's script — named in the arguments.
public enum AgentProcess {
    /// Each agent: the names its arguments' first word or its executable may carry, and the package paths a launcher's
    /// arguments name.
    static let known: [(kind: String, names: Set<String>, packages: [String])] = [
        ("claude", ["claude"], ["@anthropic-ai/claude-code", "/claude/versions/"]),
        ("codex", ["codex"], ["@openai/codex"]),
        ("gemini", ["gemini"], ["@google/gemini-cli"]),
        ("opencode", ["opencode"], ["opencode-ai"]),
        ("cursor-agent", ["cursor-agent"], []),
        ("amp", ["amp"], ["@sourcegraph/amp"]),
        ("qwen", ["qwen"], ["@qwen-code/qwen-code"]),
        ("aider", ["aider"], []),
    ]

    /// The runtimes an agent installed through a package manager runs on: their script names the agent.
    static let runtimes: Set<String> = ["node", "bun", "deno", "python", "python3"]

    /// The agent `argv` and `path` name, or nil. A NAME counts as the first argument (after a rename too) or the
    /// executable's own name — a native agent's may carry its platform after a dash (`codex-aarch64-apple-darwin`); a
    /// PACKAGE PATH counts in the executable's path or the script a runtime runs. Never anywhere else in the arguments:
    /// `less codex.log` or `ls ~/.local/share/claude/versions/` is no agent.
    public static func kind(argv: [String], path: String?) -> String? {
        func base(_ s: String) -> String { String(s.split(separator: "/").last ?? "") }
        var names = [argv.first.map(base) ?? "", path.map(base) ?? ""]
        var paths = [path ?? ""]
        if let first = argv.first, runtimes.contains(base(first)), let script = argv.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            names.append(base(script)); paths.append(script)
        }
        for a in known {
            if names.contains(where: { n in a.names.contains(n) || a.names.contains { n.hasPrefix($0 + "-") } }) { return a.kind }
            if paths.contains(where: { p in a.packages.contains { p.contains($0) } }) { return a.kind }
        }
        return nil
    }
}

/// One tab's agent: nil when none runs in its foreground — a plain shell, an agent that exited — else `.working` or
/// `.idle` as its screen says (an agent at its prompt is idle before its first turn).
public struct AgentTracker: Equatable, Sendable {
    public private(set) var state: AgentActivity.State?
    public init() {}

    /// What the latest look said: whether an agent runs in the tab's foreground, and whether its screen shows it
    /// working. Whether the state changed.
    @discardableResult
    public mutating func observe(agent: Bool, working: Bool) -> Bool {
        let next: AgentActivity.State? = agent ? (working ? .working : .idle) : nil
        guard next != state else { return false }
        state = next
        return true
    }
}
