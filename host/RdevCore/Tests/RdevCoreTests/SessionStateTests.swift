import XCTest
@testable import RdevCore

/// The session's state is the one thing every client renders and the host reconciles against, so every
/// rule about it is pinned here: what a change DOES, what it refuses, and that `version` moves exactly
/// when the state does. Ported from `ViewSetTests` (whose type this replaces — its cap and per-sub prefs
/// are gone: the only caller ran unbounded, and video settings are the device's now) plus the new
/// parts: minimized windows, positions, the view, and windows whose app quit.
final class SessionStateTests: XCTestCase {

    func testAgentTabsSurviveTerminalSyncAndReuseIdentity() {
        var s = SessionState()
        s.syncTerminals(["pty:1"])
        XCTAssertTrue(s.openAgent("thread-1", title: "Build", cwd: "/project"))
        XCTAssertEqual(s.selectedAgent, "thread-1")
        XCTAssertEqual(s.view.surface, .agents)
        s.syncTerminals(["pty:1", "pty:2"])
        XCTAssertTrue(s.tabOrder.contains("agent:thread-1"))
        XCTAssertFalse(s.openAgent("thread-1", title: "Build", cwd: "/project"))
        XCTAssertEqual(s.agents.count, 1)
        XCTAssertTrue(s.moveTab("agent:thread-1", before: "pty:1"))
        XCTAssertTrue(s.setAgentName("thread-1", "Review"))
        XCTAssertEqual(s.agents.first?.name, "Review")
        XCTAssertTrue(s.closeAgent("thread-1"))
        XCTAssertNil(s.selectedAgent)
        XCTAssertEqual(s.view.surface, .terminal)
        XCTAssertFalse(s.tabOrder.contains("agent:thread-1"))
    }

    func testStartsEmpty() {
        let s = SessionState()
        XCTAssertEqual(s.windows, [])
        XCTAssertNil(s.focused)
        XCTAssertEqual(s.view, SessionView(surface: .terminal, fullscreen: nil))
        XCTAssertEqual(s.version, 0)
        XCTAssertEqual(s.streamed, [])
    }

    func testAgentStatusIsHostStateAndUnknownNeverMeansReady() {
        var s = SessionState()
        s.openAgent("one", title: "Build", cwd: "")
        XCTAssertNil(s.agents.first?.status)
        XCTAssertTrue(s.setAgentStatus("one", "active"))
        XCTAssertEqual(s.agents.first?.status, "active")
        XCTAssertFalse(s.setAgentStatus("one", "active"))
        XCTAssertTrue(s.setAgentStatus("one", "idle"))
        XCTAssertEqual(s.agents.first?.status, "idle")
        XCTAssertTrue(s.setAgentStatus("one", nil))
        XCTAssertNil(s.agents.first?.status)
        XCTAssertFalse(s.setAgentStatus("unknown", "active"))
    }

    func testClosingAgentLandsOnPreviousInterleavedTab() {
        var s = SessionState()
        s.syncTerminals(["pty:1"])
        s.openAgent("one", title: "One", cwd: "")
        s.openAgent("two", title: "Two", cwd: "")
        s.moveTab("pty:1", before: "agent:two")
        XCTAssertEqual(s.landing(leaving: "agent:two"), .terminal("pty:1"))
        s.closeAgent("two")
        XCTAssertEqual(s.view.surface, .terminal)
    }

    // MARK: - open / close (ViewSet's subscribe / unsubscribe)

    func testOpenAddsAndFocuses() {
        var s = SessionState()
        XCTAssertTrue(s.open("win:1"))
        XCTAssertTrue(s.contains("win:1"))
        XCTAssertEqual(s.window("win:1"), SessionWindow(source: "win:1", minimized: false, position: nil))
        XCTAssertEqual(s.focused, "win:1")
        XCTAssertEqual(s.streamed, ["win:1"])
    }

    /// No cap: every window stays, in the order it was opened (the TAB order), and focus follows the
    /// newest — ViewSet's unbounded behaviour, which was the only one ever used.
    func testOpenManyKeepsTabOrderAndFocusFollowsNewest() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B"); s.open("dsp:1")
        XCTAssertEqual(s.windows.map(\.source), ["win:A", "win:B", "dsp:1"])
        XCTAssertEqual(s.focused, "dsp:1")
    }

    func testReopeningAnOpenWindowRefocusesWithoutADuplicate() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B")
        XCTAssertTrue(s.open("win:A"), "focus moved: a change")
        XCTAssertEqual(s.windows.map(\.source), ["win:A", "win:B"])
        XCTAssertEqual(s.focused, "win:A")
        XCTAssertFalse(s.open("win:A"), "already open and focused: nothing changed")
    }

    func testCloseRemovesAndClearsFocus() {
        var s = SessionState()
        s.open("win:A")
        XCTAssertTrue(s.close("win:A"))
        XCTAssertEqual(s.windows, [])
        XCTAssertNil(s.focused)
        XCTAssertFalse(s.close("win:A"), "already gone")
    }

    func testClosingTheFocusedWindowRefocusesTheOneBeforeIt() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B")                       // focused == win:B
        XCTAssertTrue(s.close("win:B"))
        XCTAssertEqual(s.windows.map(\.source), ["win:A"])
        XCTAssertEqual(s.focused, "win:A")
    }

    /// Focus falls to the window BEFORE the one that held it — the tab to its left, as closing a terminal
    /// tab does (`TabPool.close`) — never to the first: from the middle of four, the first is two away.
    func testClosingAFocusedWindowInTheMiddleFocusesTheOneBeforeIt() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B"); s.open("win:C"); s.open("win:D")
        s.focus("win:C")
        s.close("win:C")
        XCTAssertEqual(s.focused, "win:B")
    }

    /// The FIRST window has none before it: the one after it.
    func testClosingTheFocusedFirstWindowFocusesTheOneAfterIt() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B"); s.open("win:C")
        s.focus("win:A")
        s.close("win:A")
        XCTAssertEqual(s.focused, "win:B")
    }

    /// Minimized windows are skipped both ways: the nearest STREAMED one before, else after.
    func testTheWindowBeforeSkipsMinimizedOnes() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B"); s.open("win:C"); s.open("win:D"); s.open("win:E")
        s.minimize("win:C")
        s.focus("win:D")
        s.close("win:D")
        XCTAssertEqual(s.focused, "win:B", "C is parked: B")
        s.minimize("win:A")
        s.focus("win:B")
        s.close("win:B")
        XCTAssertEqual(s.focused, "win:E", "nothing streamed before B: the nearest after it")
    }

    func testClosingAnUnfocusedWindowKeepsFocus() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B")                       // focused == win:B
        s.close("win:A")
        XCTAssertEqual(s.focused, "win:B")
    }

    // MARK: - focus

    func testFocusOnlyAnOpenStreamedWindow() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B")
        XCTAssertTrue(s.focus("win:A"))
        XCTAssertEqual(s.focused, "win:A")
        XCTAssertFalse(s.focus("win:9"), "not in the session")
        s.minimize("win:B")
        XCTAssertFalse(s.focus("win:B"), "a minimized window cannot hold focus")
        XCTAssertEqual(s.focused, "win:A")
        XCTAssertFalse(s.focus("win:A"), "already focused: no change")
    }

    // MARK: - minimize / restore

    func testMinimizeKeepsTheWindowButStopsStreamingIt() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B")
        XCTAssertTrue(s.minimize("win:B"))
        XCTAssertEqual(s.windows.map(\.source), ["win:A", "win:B"], "still in the session, same tab order")
        XCTAssertEqual(s.window("win:B")?.minimized, true)
        XCTAssertEqual(s.streamed, ["win:A"])
        XCTAssertEqual(s.focused, "win:A", "focus fell to the window before it")
        XCTAssertFalse(s.minimize("win:B"), "already minimized")
        XCTAssertFalse(s.minimize("win:9"), "unknown")
    }

    /// The fallback SKIPS minimized windows: focus must land on something the host is streaming.
    func testFocusFallbackSkipsMinimizedWindows() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B"); s.open("win:C")
        s.minimize("win:A")
        s.close("win:C")                                       // focused was win:C
        XCTAssertEqual(s.focused, "win:B")
        s.minimize("win:B")
        XCTAssertNil(s.focused, "nothing left streamed")
    }

    /// Parking the focused window hands focus to the one before it too.
    func testMinimizingAFocusedWindowInTheMiddleFocusesTheOneBeforeIt() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B"); s.open("win:C")
        s.focus("win:B")
        s.minimize("win:B")
        XCTAssertEqual(s.focused, "win:A")
        s.restore("win:B"); s.focus("win:C")
        s.minimize("win:C")
        XCTAssertEqual(s.focused, "win:B")
    }

    func testRestoreUnminimizesAndFocuses() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B")
        s.minimize("win:A")
        XCTAssertTrue(s.restore("win:A"))
        XCTAssertEqual(s.window("win:A")?.minimized, false)
        XCTAssertEqual(s.focused, "win:A")
        XCTAssertEqual(s.streamed, ["win:A", "win:B"])
        XCTAssertFalse(s.restore("win:9"), "unknown")
    }

    /// Opening a parked window is a restore — the palette picking a minimized source brings it back.
    func testOpeningAMinimizedWindowRestoresIt() {
        var s = SessionState()
        s.open("win:A"); s.minimize("win:A")
        XCTAssertTrue(s.open("win:A"))
        XCTAssertEqual(s.window("win:A")?.minimized, false)
        XCTAssertEqual(s.focused, "win:A")
        XCTAssertEqual(s.windows.count, 1)
    }

    // MARK: - position

    func testPositionIsKeptPerWindowIncludingWhileMinimized() {
        var s = SessionState()
        s.open("win:A")
        XCTAssertTrue(s.setPosition("win:A", x: 120, y: -40.5))
        XCTAssertEqual(s.window("win:A")?.position, WindowPosition(x: 120, y: -40.5))
        s.minimize("win:A")
        XCTAssertTrue(s.setPosition("win:A", x: 10, y: 20))
        s.restore("win:A")
        XCTAssertEqual(s.window("win:A")?.position, WindowPosition(x: 10, y: 20))
        XCTAssertFalse(s.setPosition("win:A", x: 10, y: 20), "same place: no change")
    }

    /// REFUSED, never clamped: clamping would put the window somewhere nobody dragged it.
    func testPositionIsValidated() {
        var s = SessionState()
        s.open("win:A")
        for (x, y) in [(Double.nan, 0.0), (0, Double.infinity), (100_000.5, 0), (0, -100_001)] {
            XCTAssertFalse(s.setPosition("win:A", x: x, y: y), "\(x),\(y)")
        }
        XCTAssertNil(s.window("win:A")?.position)
        XCTAssertTrue(s.setPosition("win:A", x: 100_000, y: -100_000), "the bound itself is allowed")
        XCTAssertFalse(s.setPosition("win:9", x: 1, y: 1), "unknown window")
    }

    // MARK: - view

    func testSurfaceAndFullscreen() {
        var s = SessionState()
        s.open("win:A")
        // `fullscreen: nil` is the OUTER nil: "leave it alone".
        XCTAssertTrue(s.setView(surface: .windows, fullscreen: nil))
        XCTAssertEqual(s.view, SessionView(surface: .windows, fullscreen: nil))
        XCTAssertTrue(s.setView(surface: nil, fullscreen: .some("win:A")))
        XCTAssertEqual(s.view.fullscreen, "win:A")
        XCTAssertEqual(s.view.surface, .windows, "an absent field is left alone")
        XCTAssertTrue(s.setView(surface: nil, fullscreen: .some(nil)))
        XCTAssertNil(s.view.fullscreen, ".some(nil) ends the mode")
        XCTAssertFalse(s.setView(surface: nil, fullscreen: nil), "nothing asked: no change")
        XCTAssertFalse(s.setView(surface: .windows, fullscreen: nil), "already so: no change")
    }

    /// Only a STREAMED window can be full screen, and a refusal is WHOLE: an invalid full-screen half
    /// changes nothing, not even the valid surface beside it.
    func testFullscreenMustBeAStreamedWindowAndARefusalChangesNothing() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B"); s.minimize("win:B")
        let before = s
        XCTAssertFalse(s.setView(surface: .windows, fullscreen: .some("win:B")), "minimized")
        XCTAssertFalse(s.setView(surface: .windows, fullscreen: .some("win:9")), "not in the session")
        XCTAssertEqual(s, before)
    }

    func testClosingOrMinimizingTheFullscreenWindowEndsTheMode() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B")
        s.setView(surface: nil, fullscreen: .some("win:A"))
        s.minimize("win:A")
        XCTAssertNil(s.view.fullscreen, "minimized")
        s.setView(surface: nil, fullscreen: .some("win:B"))
        s.close("win:B")
        XCTAssertNil(s.view.fullscreen, "closed")
    }

    func testAnotherWindowLeavingKeepsTheFullscreenWindow() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B")
        s.setView(surface: nil, fullscreen: .some("win:A"))
        s.close("win:B")
        XCTAssertEqual(s.view.fullscreen, "win:A")
    }

    // MARK: - retain (a window's app quit)

    func testRetainDropsWindowsThatNoLongerExist() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B"); s.open("win:C")
        s.minimize("win:A")
        s.setView(surface: nil, fullscreen: .some("win:C"))
        let v = s.version
        XCTAssertEqual(s.retain(onlyIn: ["win:B", "dsp:1"]), ["win:A", "win:C"], "minimized or not")
        XCTAssertEqual(s.windows.map(\.source), ["win:B"])
        XCTAssertEqual(s.focused, "win:B")
        XCTAssertNil(s.view.fullscreen)
        XCTAssertEqual(s.version, v + 1, "one change, however many windows it dropped")
        XCTAssertEqual(s.retain(onlyIn: ["win:B"]), [])
        XCTAssertEqual(s.version, v + 1, "nothing dropped: no change")
    }

    /// A focused window whose app quit hands focus to the nearest SURVIVING window before it, however many
    /// went with it.
    func testRetainFocusesTheSurvivingWindowBeforeTheFocusedOne() {
        var s = SessionState()
        s.open("win:A"); s.open("win:B"); s.open("win:C"); s.open("win:D")
        s.focus("win:D")
        s.retain(onlyIn: ["win:A", "win:B"])                  // C and D's app quit
        XCTAssertEqual(s.focused, "win:B")
    }

    // MARK: - landing: the bar's previous tab, terminal or window

    /// A bar the tests below arrange: `windows` opened in order, `terminals` synced in, then `order` set
    /// by moves (the bar a driver dragged), the windows SURFACE showing, and `focus` focused.
    private func bar(_ order: [String], focus: String, minimized: [String] = []) -> SessionState {
        // By PREFIX: these tests name windows `win:A`, which `TabKey` (canonical numbers only) would refuse.
        let isWindow = { (k: String) in k.hasPrefix("win:") || k.hasPrefix("dsp:") }
        var s = SessionState()
        for k in order where isWindow(k) { s.open(k) }
        s.syncTerminals(order.filter { !isWindow($0) })
        for k in order { s.moveTab(k, before: nil) }
        for k in minimized { s.minimize(k) }
        s.setView(surface: .windows, fullscreen: nil)
        s.focus(focus)
        XCTAssertEqual(s.tabOrder, order, "precondition: the bar")
        XCTAssertEqual(s.focused, focus, "precondition: the focus")
        return s
    }

    /// THE POINT (asked 2026-10-01): closing the window you are at lands on the tab to its LEFT in the bar —
    /// and since the bar interleaves them, that can be a TERMINAL tab. Given that landing (the CALLER decides
    /// whether the person was at the window — the client says so on the intent), the close shows the terminal
    /// surface in the same change; the window focus still falls back by the window rule, so the windows surface
    /// has a window to show when the person goes back to it.
    func testClosingTheFocusedWindowLandsOnTheTerminalTabBeforeIt() {
        var s = bar(["pty:1", "win:A", "pty:2", "win:B"], focus: "win:B")
        let landing = s.landing(leaving: "win:B")
        XCTAssertEqual(landing, .terminal("pty:2"))
        let v = s.version
        XCTAssertTrue(s.close("win:B", landing: landing))
        XCTAssertEqual(s.view.surface, .terminal, "the terminal is where the person is now")
        XCTAssertEqual(s.focused, "win:A", "the window focus falls back as it always has")
        XCTAssertEqual(s.version, v + 1, "ONE change: the close and the surface together")
    }

    /// WITHOUT a landing — the person was not at the window (the client said so, or said nothing) — a close is
    /// the window rule alone: the surface stays whatever it was, a terminal to the left or not.
    func testAClosePassedNoLandingIsTheWindowRuleAlone() {
        var s = bar(["pty:1", "win:A", "pty:2", "win:B"], focus: "win:B")
        s.close("win:B")
        XCTAssertEqual(s.view.surface, .windows)
        XCTAssertEqual(s.focused, "win:A")
        var m = bar(["pty:1", "win:A", "pty:2", "win:B"], focus: "win:B")
        m.minimize("win:B")
        XCTAssertEqual(m.view.surface, .windows, "a park passed no landing likewise")
    }

    /// A WINDOW to its left is today's rule, unchanged: that window takes focus and the surface stays.
    func testClosingTheFocusedWindowLandsOnTheWindowBeforeIt() {
        var s = bar(["pty:1", "win:A", "win:B", "pty:2"], focus: "win:B")
        let landing = s.landing(leaving: "win:B")
        XCTAssertEqual(landing, .window("win:A"))
        s.close("win:B", landing: landing)
        XCTAssertEqual(s.focused, "win:A")
        XCTAssertEqual(s.view.surface, .windows)
    }

    /// A PARKED window is skipped, as it was by the window rule: landing on it would mean restoring it.
    func testTheLandingSkipsMinimizedWindows() {
        var s = bar(["pty:1", "win:M", "win:A"], focus: "win:A", minimized: ["win:M"])
        let landing = s.landing(leaving: "win:A")
        XCTAssertEqual(landing, .terminal("pty:1"))
        s.close("win:A", landing: landing)
        XCTAssertEqual(s.view.surface, .terminal)
        XCTAssertNil(s.focused, "no window streams any more")
    }

    /// With nothing to its left the tab to its RIGHT, a terminal included.
    func testTheFirstTabLandsOnTheTabAfterIt() {
        var s = bar(["win:B", "pty:1", "win:A"], focus: "win:B")
        XCTAssertEqual(s.landing(leaving: "win:B"), .terminal("pty:1"))
    }

    /// Parking (−) lands the same way.
    func testMinimizingTheFocusedWindowLandsOnTheTerminalBeforeIt() {
        var s = bar(["win:A", "pty:1", "win:B"], focus: "win:B")
        let landing = s.landing(leaving: "win:B")
        XCTAssertEqual(landing, .terminal("pty:1"))
        s.minimize("win:B", landing: landing)
        XCTAssertEqual(s.view.surface, .terminal)
        XCTAssertEqual(s.focused, "win:A")
    }

    /// AN APP QUITTING NEVER LANDS (review, 2026-10-02): it is discovered on ANY client's listing, possibly
    /// long after the person moved on, so it must not move the terminal or the surface under them. Only the
    /// window focus falls back.
    func testAnAppQuittingNeverLands() {
        var s = bar(["win:A", "pty:1", "win:B"], focus: "win:B")
        s.retain(onlyIn: ["win:A"])
        XCTAssertEqual(s.view.surface, .windows)
        XCTAssertEqual(s.focused, "win:A")
    }

    /// The landing is decided by WHO WAS AT THE WINDOW, which only the client can tell (a desktop's surface
    /// means nothing — it stays "windows" after a palette pick while the person types in the terminal). So the
    /// host does not second-guess it with the surface: a focused window yields its landing whatever shows.
    func testTheLandingIsTheBarsAndIgnoresTheSurface() {
        var s = bar(["pty:1", "win:A", "pty:2", "win:B"], focus: "win:B")
        s.setView(surface: .terminal, fullscreen: nil)
        XCTAssertEqual(s.landing(leaving: "win:B"), .terminal("pty:2"))
    }

    /// An UNFOCUSED window going moves nobody, and the last tab of the bar has nothing to land on.
    func testAnUnfocusedWindowOrTheLastTabLandsNowhere() {
        let s = bar(["pty:1", "win:A", "pty:2", "win:B"], focus: "win:B")
        XCTAssertNil(s.landing(leaving: "win:A"))
        XCTAssertNil(s.landing(leaving: "win:Z"), "not in the session")
        XCTAssertNil(bar(["win:A"], focus: "win:A").landing(leaving: "win:A"))
    }

    /// A landing naming no terminal tab of the bar changes no surface: the state stays one the bar can show.
    func testALandingOnATabNotInTheBarChangesNoSurface() {
        var s = bar(["pty:1", "win:A", "win:B"], focus: "win:B")
        s.close("win:B", landing: .terminal("pty:9"))
        XCTAssertEqual(s.view.surface, .windows)
        var w = bar(["pty:1", "win:A", "win:B"], focus: "win:B")
        w.close("win:B", landing: .terminal("win:A"))
        XCTAssertEqual(w.view.surface, .windows, "a window's key is no terminal tab")
    }

    // MARK: - version

    /// `version` moves EXACTLY when the state does. A no-op that bumped it would read as a change nobody
    /// made; a change that did not would be indistinguishable from the state before it.
    func testVersionMovesExactlyWithTheState() {
        var s = SessionState()
        var expected: UInt64 = 0
        func check(_ changed: Bool, line: UInt = #line) {
            if changed { expected += 1 }
            XCTAssertEqual(s.version, expected, line: line)
        }
        check(s.open("win:A"))
        check(s.open("win:A"))                                  // no-op
        check(s.focus("win:A"))                                 // no-op
        check(s.setPosition("win:A", x: 1, y: 2))
        check(s.setPosition("win:A", x: 1, y: 2))               // no-op
        check(s.setView(surface: .windows, fullscreen: nil))
        check(s.minimize("win:A"))
        check(s.minimize("win:A"))                              // no-op
        check(s.restore("win:A"))
        check(s.close("win:A"))
        check(s.close("win:A"))                                 // no-op
        XCTAssertEqual(expected, 6, "the sequence above changes the state six times")
    }

    // MARK: - the bar's order (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §1.1)

    /// The invariants every mutator keeps, checked after each step of every test below: no duplicates;
    /// every window in it exactly once; its terminal keys exactly the last sync's set; and `windows` in
    /// the same RELATIVE order as the order's window keys.
    private func assertInvariants(_ s: SessionState, terminals: Set<String>, line: UInt = #line) {
        XCTAssertEqual(Set(s.tabOrder).count, s.tabOrder.count, "no duplicates: \(s.tabOrder)", line: line)
        let windowKeys = s.windows.map(\.source)
        XCTAssertEqual(s.tabOrder.filter { windowKeys.contains($0) }, windowKeys,
                       "windows follow the order's window keys", line: line)
        XCTAssertEqual(Set(s.tabOrder.filter { !windowKeys.contains($0) }), terminals,
                       "the terminal keys are the last sync's", line: line)
        XCTAssertEqual(Set(s.openingOrder), Set(windowKeys), "the opening order holds exactly the windows", line: line)
        XCTAssertEqual(s.openingOrder.count, windowKeys.count, "...once each", line: line)
    }

    func testAnEmptySessionHasAnEmptyOrder() {
        XCTAssertEqual(SessionState().tabOrder, [])
    }

    /// With nothing dragged the bar is today's: terminals, then windows, each in the order it opened.
    func testWithoutADragTheOrderIsTerminalsThenWindows() {
        var s = SessionState()
        s.open("win:1")
        XCTAssertTrue(s.syncTerminals(["pty:1", "pty:2"]))
        s.open("win:2")
        XCTAssertTrue(s.syncTerminals(["pty:1", "pty:2", "tmux:$3"]))
        XCTAssertEqual(s.tabOrder, ["pty:1", "pty:2", "tmux:$3", "win:1", "win:2"])
        assertInvariants(s, terminals: ["pty:1", "pty:2", "tmux:$3"])
    }

    /// DEFAULT PLACEMENT — a new WINDOW goes right after the last window, wherever that is; with none, LAST.
    func testANewWindowGoesAfterTheLastWindowElseLast() {
        var s = SessionState()
        s.syncTerminals(["pty:1", "pty:2"])
        s.open("win:1")
        XCTAssertEqual(s.tabOrder, ["pty:1", "pty:2", "win:1"], "no window yet: LAST")
        s.moveTab("win:1", before: "pty:2")                     // pty:1 win:1 pty:2
        s.open("win:2")
        XCTAssertEqual(s.tabOrder, ["pty:1", "win:1", "win:2", "pty:2"], "beside its sibling, not at the end")
        assertInvariants(s, terminals: ["pty:1", "pty:2"])
    }

    /// DEFAULT PLACEMENT — a new TERMINAL goes right after the last terminal; with none, FIRST.
    func testANewTerminalGoesAfterTheLastTerminalElseFirst() {
        var s = SessionState()
        s.open("win:1"); s.open("win:2")
        s.syncTerminals(["pty:1"])
        XCTAssertEqual(s.tabOrder, ["pty:1", "win:1", "win:2"], "no terminal yet: FIRST")
        s.moveTab("pty:1", before: nil)                          // win:1 win:2 pty:1
        s.moveTab("win:2", before: nil)                          // win:1 pty:1 win:2
        s.syncTerminals(["pty:1", "pty:2"])
        XCTAssertEqual(s.tabOrder, ["win:1", "pty:1", "pty:2", "win:2"], "beside its sibling")
        assertInvariants(s, terminals: ["pty:1", "pty:2"])
    }

    /// Several new terminals in one sync enter in POOL order, one after the other.
    func testNewTerminalsEnterInPoolOrder() {
        var s = SessionState()
        s.open("win:1")
        XCTAssertTrue(s.syncTerminals(["tmux:$4", "pty:2", "pty:1"]))
        XCTAssertEqual(s.tabOrder, ["tmux:$4", "pty:2", "pty:1", "win:1"])
        assertInvariants(s, terminals: ["tmux:$4", "pty:2", "pty:1"])
    }

    /// A terminal the pool no longer holds leaves; the rest keep their places — a sync never REORDERS
    /// what it already holds: the order is the state's, and the pool follows it, not the other way round.
    func testSyncDropsTheGoneAndKeepsTheOrderOfTheRest() {
        var s = SessionState()
        s.syncTerminals(["pty:1", "pty:2", "pty:3"])
        s.open("win:1")
        s.moveTab("pty:3", before: "pty:1")                     // pty:3 pty:1 pty:2 win:1
        XCTAssertTrue(s.syncTerminals(["pty:1", "pty:3"]))
        XCTAssertEqual(s.tabOrder, ["pty:3", "pty:1", "win:1"])
        XCTAssertFalse(s.syncTerminals(["pty:3", "pty:1"]), "the same SET in another order: no change")
        XCTAssertTrue(s.syncTerminals([]))
        XCTAssertEqual(s.tabOrder, ["win:1"])
        assertInvariants(s, terminals: [])
    }

    /// A title changes constantly and re-syncs every time: the same set must change NOTHING — no version,
    /// so no `view-set` to every client per keystroke of a prompt.
    func testTheSameSetAgainIsNoChange() {
        var s = SessionState()
        XCTAssertTrue(s.syncTerminals(["pty:1"]))
        let v = s.version
        XCTAssertFalse(s.syncTerminals(["pty:1"]))
        XCTAssertFalse(s.syncTerminals(["pty:1", "pty:1"]), "a repeated id counts once")
        XCTAssertEqual(s.version, v)
        var empty = SessionState()
        XCTAssertFalse(empty.syncTerminals([]), "nothing to nothing")
        XCTAssertEqual(empty.version, 0)
    }

    /// A sync never claims a WINDOW's key as a terminal: the two halves cannot collide.
    func testASyncIgnoresAKeyThatIsAWindow() {
        var s = SessionState()
        s.open("win:1")
        XCTAssertFalse(s.syncTerminals(["win:1"]))
        XCTAssertEqual(s.tabOrder, ["win:1"])
        assertInvariants(s, terminals: [])
    }

    /// A window leaves the order with the session — closed, or its app quit (`retain`) — minimized or not.
    func testAWindowLeavingTheSessionLeavesTheOrder() {
        var s = SessionState()
        s.syncTerminals(["pty:1"])
        s.open("win:1"); s.open("win:2"); s.open("win:3")
        s.minimize("win:2")
        XCTAssertEqual(s.tabOrder, ["pty:1", "win:1", "win:2", "win:3"], "a minimized window keeps its place")
        s.close("win:1")
        XCTAssertEqual(s.tabOrder, ["pty:1", "win:2", "win:3"])
        s.retain(onlyIn: ["win:3"])
        XCTAssertEqual(s.tabOrder, ["pty:1", "win:3"])
        assertInvariants(s, terminals: ["pty:1"])
    }

    /// Re-opening a window already in the session (or restoring a parked one) does not move it.
    func testReopeningAWindowKeepsItsPlace() {
        var s = SessionState()
        s.open("win:1"); s.open("win:2")
        s.moveTab("win:2", before: "win:1")
        s.minimize("win:2")
        s.open("win:2")
        XCTAssertEqual(s.tabOrder, ["win:2", "win:1"])
        s.open("win:1")
        XCTAssertEqual(s.tabOrder, ["win:2", "win:1"])
    }

    // MARK: moveTab

    func testMoveTabBeforeAnotherOrToTheEnd() {
        var s = SessionState()
        s.syncTerminals(["pty:1", "pty:2"])
        s.open("win:1")
        XCTAssertTrue(s.moveTab("win:1", before: "pty:1"))
        XCTAssertEqual(s.tabOrder, ["win:1", "pty:1", "pty:2"])
        XCTAssertTrue(s.moveTab("pty:1", before: nil))
        XCTAssertEqual(s.tabOrder, ["win:1", "pty:2", "pty:1"])
        XCTAssertTrue(s.moveTab("pty:1", before: "pty:2"))
        XCTAssertEqual(s.tabOrder, ["win:1", "pty:1", "pty:2"])
        assertInvariants(s, terminals: ["pty:1", "pty:2"])
    }

    /// A drag that moves a WINDOW moves it in `windows` too — `windows` keeps its meaning everywhere it is
    /// used (`streamed`, the focus fall-back), and that meaning is now the bar's order.
    func testMovingAWindowReordersWindows() {
        var s = SessionState()
        s.open("win:1"); s.open("win:2"); s.open("win:3")
        s.syncTerminals(["pty:1"])                              // pty:1 win:1 win:2 win:3
        XCTAssertTrue(s.moveTab("win:3", before: "pty:1"))
        XCTAssertEqual(s.tabOrder, ["win:3", "pty:1", "win:1", "win:2"])
        XCTAssertEqual(s.windows.map(\.source), ["win:3", "win:1", "win:2"])
        XCTAssertEqual(s.streamed, ["win:3", "win:1", "win:2"])
        XCTAssertTrue(s.moveTab("win:1", before: nil))
        XCTAssertEqual(s.windows.map(\.source), ["win:3", "win:2", "win:1"])
        assertInvariants(s, terminals: ["pty:1"])
    }

    /// A moved window carries everything it had: minimized, position, name.
    func testAMovedWindowKeepsItsState() {
        var s = SessionState()
        s.open("win:1"); s.open("win:2")
        s.setPosition("win:1", x: 5, y: 6); s.setName("win:1", "mail"); s.minimize("win:1")
        s.moveTab("win:1", before: nil)
        XCTAssertEqual(s.window("win:1"), SessionWindow(source: "win:1", minimized: true,
                                                         position: WindowPosition(x: 5, y: 6), name: "mail"))
    }

    /// The focus fall-back follows the MOVED order: the window to the left of the one that went, as the bar
    /// now shows it.
    func testTheFocusFallBackFollowsTheMovedOrder() {
        var s = SessionState()
        s.open("win:1"); s.open("win:2"); s.open("win:3")      // focused win:3
        s.moveTab("win:3", before: "win:1")                    // win:3 win:1 win:2
        s.focus("win:1")
        s.close("win:1")
        XCTAssertEqual(s.focused, "win:3", "the tab to its LEFT in the bar, not in opening order")
    }

    /// THE AUDIO ELECTION'S ORDER IS THE ORDER WINDOWS WERE OPENED, never the bar's ("first subscriber
    /// wins", docs/audio.md): rearranging tabs must not move where an application's sound comes from.
    /// Before the bar could be dragged the two were the same list; review I1 (2026-10-01) found a drag
    /// re-electing the carrier.
    func testTheElectionOrderIsTheOpeningOrderNotTheBars() {
        var s = SessionState()
        s.open("win:1"); s.open("win:2"); s.open("win:3")
        s.moveTab("win:3", before: "win:1")
        XCTAssertEqual(s.streamed, ["win:3", "win:1", "win:2"], "precondition: the bar moved")
        XCTAssertEqual(s.streamedByOpening, ["win:1", "win:2", "win:3"])
        s.minimize("win:2")
        XCTAssertEqual(s.streamedByOpening, ["win:1", "win:3"], "only what streams")
        s.restore("win:2")
        XCTAssertEqual(s.streamedByOpening, ["win:1", "win:2", "win:3"], "a restore keeps its place, as a subscription did")
        s.close("win:1"); s.open("win:1")
        XCTAssertEqual(s.streamedByOpening, ["win:2", "win:3", "win:1"], "closed and opened again is a NEW subscription: last")
        _ = s.retain(onlyIn: ["win:1", "win:3"])
        XCTAssertEqual(s.streamedByOpening, ["win:3", "win:1"])
    }

    /// REFUSED — false, and nothing changes, not even the version: an unknown tab, an unknown `before`,
    /// `before` naming the tab itself.
    func testMoveTabRefusals() {
        var s = SessionState()
        s.syncTerminals(["pty:1"])
        s.open("win:1")
        let before = s
        XCTAssertFalse(s.moveTab("pty:9", before: nil), "not in the order")
        XCTAssertFalse(s.moveTab("win:9", before: "pty:1"), "not in the order")
        XCTAssertFalse(s.moveTab("pty:1", before: "win:9"), "before is not in the order")
        XCTAssertFalse(s.moveTab("pty:1", before: "pty:1"), "before is the tab itself")
        XCTAssertEqual(s, before)
    }

    /// A move that leaves the order as it was is no change.
    func testAMoveToWhereItAlreadyIsIsNoChange() {
        var s = SessionState()
        s.syncTerminals(["pty:1", "pty:2"])
        let v = s.version
        XCTAssertFalse(s.moveTab("pty:2", before: nil), "already last")
        XCTAssertFalse(s.moveTab("pty:1", before: "pty:2"), "already just before it")
        XCTAssertEqual(s.version, v)
    }

    // MARK: names (§1.2)

    func testAWindowsNameIsSetAndClearedAndKeptWhileMinimized() {
        var s = SessionState()
        s.open("win:1")
        XCTAssertNil(s.window("win:1")?.name)
        XCTAssertTrue(s.setName("win:1", "mail"))
        XCTAssertEqual(s.window("win:1")?.name, "mail")
        XCTAssertFalse(s.setName("win:1", "mail"), "the same name: no change")
        s.minimize("win:1")
        XCTAssertEqual(s.window("win:1")?.name, "mail", "kept while minimized")
        s.restore("win:1")
        XCTAssertTrue(s.setName("win:1", ""))
        XCTAssertNil(s.window("win:1")?.name, "\"\" CLEARS")
        XCTAssertTrue(s.setName("win:1", "x"))
        XCTAssertTrue(s.setName("win:1", nil))
        XCTAssertNil(s.window("win:1")?.name, "nil CLEARS")
        XCTAssertFalse(s.setName("win:1", nil), "already clear")
    }

    /// A name goes WITH its window: reopened later, the window starts unnamed.
    func testANameIsGoneWithItsWindow() {
        var s = SessionState()
        s.open("win:1")
        s.setName("win:1", "mail")
        s.close("win:1")
        s.open("win:1")
        XCTAssertNil(s.window("win:1")?.name)
    }

    func testSetNameRefusals() {
        var s = SessionState()
        s.open("win:1")
        s.syncTerminals(["pty:1"])
        let before = s
        XCTAssertFalse(s.setName("win:9", "x"), "not in the session")
        XCTAssertFalse(s.setName("pty:1", "x"), "a terminal's name is the pool's, never the session's")
        XCTAssertFalse(s.setName("win:1", "a\nb"), "a control character")
        XCTAssertFalse(s.setName("win:1", String(repeating: "é", count: 129)), "past 256 bytes")
        XCTAssertEqual(s, before)
    }

    /// `version` moves by exactly one on each change these mutators make, and not at all on a refusal or a
    /// no-op.
    func testTheOrderAndNamesMoveTheVersionExactly() {
        var s = SessionState()
        var expected: UInt64 = 0
        func check(_ changed: Bool, line: UInt = #line) {
            if changed { expected += 1 }
            XCTAssertEqual(s.version, expected, line: line)
        }
        check(s.syncTerminals(["pty:1"]))
        check(s.syncTerminals(["pty:1"]))                       // no-op
        check(s.open("win:1"))
        check(s.moveTab("win:1", before: "pty:1"))
        check(s.moveTab("win:1", before: "pty:1"))              // no-op
        check(s.moveTab("win:9", before: nil))                  // refused
        check(s.setName("win:1", "mail"))
        check(s.setName("win:1", "mail"))                       // no-op
        check(s.setName("win:1", "a\tb"))                       // refused
        check(s.syncTerminals(["pty:1", "pty:2"]))
        check(s.close("win:1"))
        XCTAssertEqual(expected, 6, "the sequence above changes the state six times")
    }
}
