import XCTest
@testable import RdevCore

/// An agent's activity, read off the bottom of its screen. The screens are MEASURED (2026-10-05): the rows below
/// are copied from live panes of Claude Code 2.1.287 and Codex 0.160.0 (`tmux capture-pane`).
final class AgentActivityTests: XCTestCase {
    private let rule = String(repeating: "─", count: 60)

    func testClaudeCodeWorkingShowsTheHintInItsFooter() {
        let screen = ["  ⎿  Running…", "✽ Concocting… (1m 40s · ↓ 6.7k tokens · thought for 38s)", rule, "❯", rule,
                      "  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← 2 agents"]
        XCTAssertTrue(AgentActivity.working(screen: screen))
    }

    func testClaudeCodeIdleHasNone() {
        let screen = ["❯ launch on iPhone 18 Pro sim", rule, "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents", ""]
        XCTAssertFalse(AgentActivity.working(screen: screen))
    }

    func testCodexWorkingShowsTheHintAboveItsComposer() {
        let screen = ["• Viewed image plan.png", "• Working (15m 56s • esc to interrupt)",
                      "  └ Tip: Use /init to create an AGENTS.md with project-specific guidance.", "", "› Ask Codex to do anything", "",
                      "  GPT-6-Astra medium · ~/build/turingstown · Select tools for world generation · Main [default]",
                      "  ← for agents · ? for shortcuts"]
        XCTAssertTrue(AgentActivity.working(screen: screen))
    }

    func testCodexIdleHasNone() {
        let screen = ["  Worked for 1m 34s • 02:14", "• Opened https://pmc.ncbi.nlm.nih.gov/articles/PMC9349224/ in your browser.",
                      "› Ask a follow-up question", "  GPT-6-Astra medium · ~/build/motionbricks-web · Kill and manage server · Agent",
                      "  ← for agents · ? for shortcuts"]
        XCTAssertFalse(AgentActivity.working(screen: screen))
    }

    /// The older spinner line's form, and the hint opening a line.
    func testTheHintAfterAParenthesisOrAtTheStartOfALine() {
        XCTAssertTrue(AgentActivity.working(screen: ["✻ Thinking… (esc to interrupt)"]))
        XCTAssertTrue(AgentActivity.working(screen: ["  Esc to interrupt"]))
    }

    /// Output that merely SAYS it — a grep, a document — has a word before it.
    func testPlainOutputThatSaysItIsNoAgent() {
        XCTAssertFalse(AgentActivity.working(screen: ["docs/terminal.md:12: both print esc to interrupt in a status line", "$ "]))
    }

    /// A short conversation leaves the footer high on the screen: the rows read are the last ones WITH something.
    func testTheRowsReadEndAtTheLastNonBlankOne() {
        let screen = ["❯", "  ⏵⏵ auto mode on · esc to interrupt"] + Array(repeating: "   ", count: 30)
        XCTAssertTrue(AgentActivity.working(screen: screen))
    }

    /// Only the last `rows` non-blank rows: a hint scrolled further up is history, not a status line.
    func testAHintFurtherUpIsHistory() {
        let screen = ["• Working (3s • esc to interrupt)"] + (1...AgentActivity.rows).map { "line \($0)" }
        XCTAssertFalse(AgentActivity.working(screen: screen))
        XCTAssertFalse(AgentActivity.working(screen: []))
    }

    // MARK: where each agent draws it — the conversation above the input box may QUOTE it (asked 2026-10-05: "We have
    // an 'esc to interrupt' string here in this chat. Will it cause false positive?" — it would have)

    /// THIS CHAT: an idle Claude Code whose last reply, right above its input box, quotes Codex's status line.
    func testAnIdleClaudeWhoseReplyQuotesTheHintIsIdle() {
        let screen = ["⏺ Confirmed on screen:", "  - Codex working: • Working (15m 56s • esc to interrupt), above the prompt.",
                      "  - Claude working: ⏵⏵ auto mode on · esc to interrupt · ← 2 agents", rule, "❯", rule,
                      "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents"]
        XCTAssertFalse(AgentActivity.working(screen: screen, agent: "claude"))
        XCTAssertTrue(AgentActivity.working(screen: screen, agent: nil), "the general rule alone is fooled — why it is per agent")
    }

    func testClaudeCodesFooterBelowItsInputBoxIsWhatCounts() {
        let screen = ["  ⎿  • Working (15m 56s • esc to interrupt)", "✽ Concocting… (1m 40s · ↓ 6.7k tokens)", rule, "❯", rule,
                      "  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← 2 agents"]
        XCTAssertTrue(AgentActivity.working(screen: screen, agent: "claude"))
    }

    /// The older form: the spinner line, its glyph at the line's START (a reply is indented, a tool's output under `⎿`).
    func testClaudeCodesOlderSpinnerLineCounts() {
        XCTAssertTrue(AgentActivity.working(screen: ["✻ Thinking… (3s · esc to interrupt)", rule, "> ", rule], agent: "claude"))
        XCTAssertFalse(AgentActivity.working(screen: ["  ✻ Thinking… (3s · esc to interrupt)", rule, "> ", rule], agent: "claude"),
                       "indented: a reply quoting it")
    }

    /// Reported 2026-10-06 — "on smaller screens our in-progress detection does not always work, because 'esc to
    /// interrupt' is cut short". A working Claude Code 2.1.289 (the dev Mac's `telegram` pane), as a phone's 44
    /// columns cut it: the footer's hint gone, the spinner line's start whole.
    func testClaudeCodesSpinnerLineCountsWhenANarrowGridCutsTheHint() {
        let narrow = String(repeating: "─", count: 44)
        let footer = "  ⏵⏵ auto mode on (shift+tab to cycle) · esc"
        let screen = ["  ⎿  Denied by auto mode classifier ∙ [Security", "✳ Finagling… (9m 3s · ↓ 51.4k tokens · thi",
                      narrow, "❯ ", narrow, footer]
        XCTAssertTrue(AgentActivity.working(screen: screen, agent: "claude"))
        XCTAssertFalse(AgentActivity.working(screen: Array(screen.dropFirst(2)), agent: "claude"),
                       "the cut footer alone says nothing — why the spinner line is read by its shape")
        XCTAssertTrue(AgentActivity.working(screen: ["· Finagling…", narrow, "❯ ", narrow, footer], agent: "claude"),
                      "cut right after its ellipsis, another frame of the glyph")
        XCTAssertTrue(AgentActivity.working(screen: ["✽ Compacting conversation… (12s)", narrow, "❯ ", narrow], agent: "claude"),
                      "a header of several words")
    }

    /// Its finished form, a quoted one and a reply's are not a turn running.
    func testClaudeCodesFinishedOrQuotedSpinnerLineIsIdle() {
        let idle = ["⏺ I'll write it up when the settlement lands.", "✻ Brewed for 29s · done 2:10 AM · 1 shell still running",
                    rule, "❯ ", rule, "  ⏵⏵ auto mode on · 1 shell · ⧉ ton-settlement · ← 2 agents · ↓ to manage"]
        XCTAssertFalse(AgentActivity.working(screen: idle, agent: "claude"), "past tense, no ellipsis (crworld, 2.1.283)")
        XCTAssertFalse(AgentActivity.working(screen: ["  ✳ Finagling… (9m 3s)", rule, "❯ ", rule], agent: "claude"), "indented: quoted")
        XCTAssertFalse(AgentActivity.working(screen: ["* … (3s)", rule, "❯ ", rule], agent: "claude"), "no word before the ellipsis")
        XCTAssertFalse(AgentActivity.working(screen: ["* 3 files… (3s)", rule, "❯ ", rule], agent: "claude"), "not a header of words")
    }

    func testCodexsStatusLineIsAWholeLineOfItsShape() {
        let working = ["• I'll look at the planner.", "• Working (15m 56s • esc to interrupt)", "  └ Tip: Use /init", "",
                       "› Ask Codex to do anything", "  ← for agents · ? for shortcuts"]
        XCTAssertTrue(AgentActivity.working(screen: working, agent: "codex"))
        XCTAssertTrue(AgentActivity.working(screen: ["• Exploring the codebase (2m 3s • esc to interrupt)", "› "], agent: "codex"),
                      "its header is the model's own words at times")
        let quoting = ["• It prints • Working (15m 56s • esc to interrupt) while it works, and drops it after.",
                       "  Worked for 1m 34s", "› Ask a follow-up question"]
        XCTAssertFalse(AgentActivity.working(screen: quoting, agent: "codex"), "a message QUOTING it is no status line")
    }

    /// "Codex not always prints 'Working' — sometimes it's a description of the current task": a long one on a narrow
    /// pane pushes the hint off the edge; its TITLE still spins (measured: a braille frame first the whole time it works).
    func testCodexsSpinningTitleCountsWhateverItsStatusLineSays() {
        let cut = ["• Investigating why the planner drops its cached tiles after a reloa", "", "› Ask Codex to do anything"]
        XCTAssertTrue(AgentActivity.working(screen: cut, agent: "codex", title: "⠦ Select tools for world generation | turingstown"))
        XCTAssertFalse(AgentActivity.working(screen: cut, agent: "codex", title: "Select tools for world generation | turingstown"),
                       "idle: no frame in the title, no status line")
        XCTAssertFalse(AgentActivity.working(screen: ["❯", rule, "  ⏵⏵ auto mode on"], agent: "claude", title: "⠦ topic"),
                       "only Codex's title is read: Claude Code's never changes")
    }

    func testCodexsBulletMayBeTheHollowOne() {
        XCTAssertTrue(AgentActivity.working(screen: ["◦ Planning the change (45s • esc to interrupt)", "› "], agent: "codex"))
    }

    func testATitlesSpinnerFrame() {
        XCTAssertTrue(AgentActivity.titleSpins("⠋ Exploring | repo"))
        XCTAssertTrue(AgentActivity.titleSpins("⠏ x"))
        XCTAssertFalse(AgentActivity.titleSpins("\u{2800} blank pattern"), "U+2800 is no frame")
        XCTAssertFalse(AgentActivity.titleSpins("⠋Exploring"), "a frame, then a space")
        XCTAssertFalse(AgentActivity.titleSpins("Optimize model for edge playground | build"))
        XCTAssertFalse(AgentActivity.titleSpins(""))
    }

    // MARK: which agent a process is — the arguments and paths `ps -t` showed on the dev Mac's agent panes (2026-10-05)

    func testClaudeCodeRenamesItselfAndItsExecutableIsAVersion() {
        XCTAssertEqual(AgentProcess.kind(argv: ["claude", "--resume", "f6f76192-2e5a-4e7e-9096-0b777c106f7d"],
                                         path: "/Users/u/.local/share/claude/versions/2.1.283"), "claude")
        XCTAssertEqual(AgentProcess.kind(argv: [], path: "/Users/u/.local/share/claude/versions/2.1.289"), "claude",
                       "its executable alone — the version tmux's pane_current_command shows")
    }

    func testCodexAndItsNativeBinary() {
        XCTAssertEqual(AgentProcess.kind(argv: ["codex"],
                                         path: "/Users/u/.codex/packages/standalone/releases/0.160.0-aarch64-apple-darwin/bin/codex"), "codex")
        XCTAssertEqual(AgentProcess.kind(argv: ["/x/codex-aarch64-apple-darwin"], path: "/x/codex-aarch64-apple-darwin"), "codex")
    }

    /// Installed through npm: `node` running the package's script.
    func testARuntimeRunningAnAgentsScript() {
        XCTAssertEqual(AgentProcess.kind(argv: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"],
                                         path: "/opt/homebrew/bin/node"), "codex")
        XCTAssertEqual(AgentProcess.kind(argv: ["node", "--no-warnings", "/opt/homebrew/bin/claude"], path: "/opt/homebrew/bin/node"), "claude")
        XCTAssertEqual(AgentProcess.kind(argv: ["node", "/n/@google/gemini-cli/dist/index.js"], path: "/n/node"), "gemini")
    }

    /// What ran beside the agents, and words that merely MENTION one: no agent.
    func testEverythingElseIsNoAgent() {
        XCTAssertNil(AgentProcess.kind(argv: ["-zsh"], path: "/bin/zsh"))
        XCTAssertNil(AgentProcess.kind(argv: ["caffeinate", "-i", "-t", "300"], path: "/usr/bin/caffeinate"))
        XCTAssertNil(AgentProcess.kind(argv: ["node", "/Users/u/.npm/_npx/9933/node_modules/.bin/xcodebuildmcp", "mcp"], path: "/n/node"))
        XCTAssertNil(AgentProcess.kind(argv: ["less", "codex.log"], path: "/usr/bin/less"))
        XCTAssertNil(AgentProcess.kind(argv: ["ls", "/Users/u/.local/share/claude/versions/"], path: "/bin/ls"))
        XCTAssertNil(AgentProcess.kind(argv: ["grep", "-r", "claude", "."], path: "/usr/bin/grep"))
    }

    // MARK: the tracker

    func testATrackerHasAStateOnlyWhileAnAgentRuns() {
        var t = AgentTracker()
        XCTAssertFalse(t.observe(agent: false, working: true), "the words with no agent: nothing — the false positive ruled out")
        XCTAssertNil(t.state)
        XCTAssertTrue(t.observe(agent: true, working: false))
        XCTAssertEqual(t.state, .idle, "an agent at its prompt, before its first turn")
        XCTAssertTrue(t.observe(agent: true, working: true))
        XCTAssertEqual(t.state, .working)
        XCTAssertFalse(t.observe(agent: true, working: true), "no change, no news")
        XCTAssertTrue(t.observe(agent: true, working: false))
        XCTAssertEqual(t.state, .idle)
        XCTAssertTrue(t.observe(agent: false, working: false))
        XCTAssertNil(t.state, "the agent exited: the tab has none")
    }
}
