import XCTest
@testable import RdevCore

final class TabPoolTests: XCTestCase {

    func testStartsEmpty() {
        let p = TabPool()
        XCTAssertEqual(p.count, 0)
        XCTAssertNil(p.activeId)
    }

    func testOpenAssignsIdsOrdinalsAndActivates() {
        var p = TabPool()
        let a = p.open()
        let b = p.open()
        XCTAssertEqual(a, .pty(1))
        XCTAssertEqual(b, .pty(2))
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p.activeId, .pty(2))                 // newest is active
        XCTAssertEqual(p.tabs.map(\.ordinal), [1, 2])
        XCTAssertEqual(p.tabs.map(\.title), ["", ""])
    }

    /// A session holds 100 tabs, both kinds counted; the 101st is refused.
    func testTheDefaultCapIsAHundredTabsOfEitherKind() {
        var p = TabPool()
        XCTAssertEqual(p.maxTabs, 100)
        for _ in 0..<50 { XCTAssertNotNil(p.open()) }
        for n in 0..<50 { XCTAssertTrue(p.add(tmux: "$\(n)", title: "s\(n)")) }
        XCTAssertEqual(p.count, 100)
        XCTAssertNil(p.open())
        XCTAssertFalse(p.add(tmux: "$100", title: "one more"))
    }

    func testOpenRejectedAtCap() {
        var p = TabPool(maxTabs: 2)
        XCTAssertNotNil(p.open())
        XCTAssertNotNil(p.open())
        XCTAssertNil(p.open())                              // at cap
        XCTAssertEqual(p.count, 2)
    }

    /// No minimum: the last tab closes and the pool is EMPTY, with no active tab. Nothing replaces it
    /// — a shell appears only when a driver asks for one.
    func testCloseLastTabEmptiesThePool() {
        var p = TabPool()
        _ = p.open()
        XCTAssertEqual(p.close(.pty(1)), .some(nil))
        XCTAssertEqual(p.count, 0)
        XCTAssertNil(p.activeId)
    }

    func testCloseUnknownIdRejected() {
        var p = TabPool()
        _ = p.open(); _ = p.open()
        XCTAssertTrue(p.close(.pty(99)) == nil)
        XCTAssertTrue(p.close(.tmux("$1")) == nil)                  // same number, different kind
        XCTAssertEqual(p.count, 2)
    }

    func testCloseActiveSelectsPreviousNeighbor() {
        var p = TabPool()
        _ = p.open(); _ = p.open(); _ = p.open()           // ids 1,2,3 ; active 3
        XCTAssertTrue(p.switchTo(.pty(2)))                  // active 2 (index 1)
        XCTAssertEqual(p.close(.pty(2)), .some(.pty(1)))    // previous neighbor = id 1
        XCTAssertEqual(p.activeId, .pty(1))
        XCTAssertEqual(p.tabs.map(\.id), [.pty(1), .pty(3)])
    }

    func testCloseActiveAtFrontSelectsNextNeighbor() {
        var p = TabPool()
        _ = p.open(); _ = p.open()                         // ids 1,2
        XCTAssertTrue(p.switchTo(.pty(1)))                  // active 1 (index 0)
        XCTAssertEqual(p.close(.pty(1)), .some(.pty(2)))    // no previous → the old next (now index 0)
        XCTAssertEqual(p.activeId, .pty(2))
    }

    func testCloseInactiveKeepsActive() {
        var p = TabPool()
        _ = p.open(); _ = p.open(); _ = p.open()           // active 3
        XCTAssertEqual(p.close(.pty(1)), .some(.pty(3)))    // active unchanged
        XCTAssertEqual(p.activeId, .pty(3))
    }

    func testSwitchToUnknownIsFalse() {
        var p = TabPool()
        _ = p.open()
        XCTAssertFalse(p.switchTo(.pty(42)))
        XCTAssertEqual(p.activeId, .pty(1))
    }

    func testOrdinalsMonotonicAcrossClose() {
        var p = TabPool()
        _ = p.open(); _ = p.open()                         // ordinals 1,2
        _ = p.close(.pty(1))
        let c = p.open()                                    // id 3, ordinal 3 (never reused)
        XCTAssertEqual(c, .pty(3))
        XCTAssertEqual(p.tabs.first(where: { $0.id == .pty(3) })?.ordinal, 3)
    }

    func testSetTitle() {
        var p = TabPool()
        _ = p.open()
        XCTAssertTrue(p.setTitle(.pty(1), "~/build/rdev"))
        XCTAssertEqual(p.tabs.first?.title, "~/build/rdev")
        XCTAssertFalse(p.setTitle(.pty(1), "~/build/rdev")) // unchanged → false
        XCTAssertFalse(p.setTitle(.pty(99), "x"))           // unknown → false
    }

    /// A tmux tab joins the same pool: same active-tab selection, same cap, its own id kind.
    func testAddTmuxTab() {
        var p = TabPool(maxTabs: 2)
        _ = p.open()
        XCTAssertTrue(p.add(tmux: "$4", title: "work"))
        XCTAssertEqual(p.activeId, .tmux("$4"))
        XCTAssertEqual(p.tabs.last, TabDescriptor(id: .tmux("$4"), ordinal: 2, title: "work"))
        XCTAssertFalse(p.add(tmux: "$5", title: "x"))       // at cap
        XCTAssertFalse(p.add(tmux: "$4", title: "dup"))     // already a tab
        XCTAssertEqual(p.count, 2)
    }

    // MARK: - names (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §1.3)

    /// A `pty:` tab's user name: set, changed, cleared by nil OR "", and reported as a change only when it
    /// is one. The title is untouched — the name sits beside it, it does not replace it.
    func testAPtyTabsName() {
        var p = TabPool()
        _ = p.open()
        p.setTitle(.pty(1), "~/build")
        XCTAssertNil(p.tabs[0].name, "no name until one is given")
        XCTAssertTrue(p.setName(.pty(1), "build"))
        XCTAssertEqual(p.tabs[0].name, "build")
        XCTAssertEqual(p.tabs[0].title, "~/build", "the title is kept beside the name")
        XCTAssertFalse(p.setName(.pty(1), "build"), "the same name: no change")
        XCTAssertTrue(p.setName(.pty(1), ""))
        XCTAssertNil(p.tabs[0].name, "\"\" CLEARS — stored as nil, never as an empty name")
        XCTAssertFalse(p.setName(.pty(1), nil), "already clear")
        XCTAssertTrue(p.setName(.pty(1), "x"))
        XCTAssertTrue(p.setName(.pty(1), nil))
        XCTAssertNil(p.tabs[0].name)
    }

    /// A tmux tab NEVER has a name: its label is its session's name (`title`, which `%session-renamed`
    /// updates). An unknown tab and an invalid name are refused too, and a refusal changes nothing.
    func testANameIsRefusedForATmuxTabAnUnknownTabOrAnInvalidName() {
        var p = TabPool()
        _ = p.open()
        p.add(tmux: "$3", title: "work")
        let before = p
        XCTAssertFalse(p.setName(.tmux("$3"), "build"), "a tmux tab is renamed through tmux")
        XCTAssertFalse(p.setName(.pty(9), "x"), "unknown")
        XCTAssertFalse(p.setName(.pty(1), "a\tb"), "a control character")
        XCTAssertFalse(p.setName(.pty(1), String(repeating: "a", count: 257)), "past 256 bytes")
        XCTAssertEqual(p, before)
        XCTAssertTrue(p.setName(.pty(1), String(repeating: "a", count: 256)), "the bound itself")
    }

    // MARK: - arrange / move

    /// The pool's tabs in the order given. Nothing else moves: the active tab and every ordinal stay.
    func testArrangeReordersOnlyTheOrder() {
        var p = TabPool()
        _ = p.open(); _ = p.open(); p.add(tmux: "$3", title: "work")   // pty:1 pty:2 tmux:$3, active tmux:$3
        XCTAssertTrue(p.arrange([.tmux("$3"), .pty(1), .pty(2)]))
        XCTAssertEqual(p.tabs.map(\.id), [.tmux("$3"), .pty(1), .pty(2)])
        XCTAssertEqual(p.tabs.map(\.ordinal), [3, 1, 2], "ordinals travel with their tabs")
        XCTAssertEqual(p.activeId, .tmux("$3"))
        XCTAssertFalse(p.arrange([.tmux("$3"), .pty(1), .pty(2)]), "the same order: no change")
    }

    /// Ids the pool does not hold are ignored; tabs the list omits keep their relative order AFTER the
    /// listed ones; a repeated id counts once.
    func testArrangeIgnoresUnknownIdsAndKeepsTheOmittedAfter() {
        var p = TabPool()
        _ = p.open(); _ = p.open(); _ = p.open(); _ = p.open()          // 1 2 3 4
        XCTAssertTrue(p.arrange([.pty(9), .pty(3), .tmux("$1"), .pty(3), .pty(1)]))
        XCTAssertEqual(p.tabs.map(\.id), [.pty(3), .pty(1), .pty(2), .pty(4)])
        XCTAssertFalse(p.arrange([]), "an empty list moves nothing")
        XCTAssertFalse(p.arrange([.pty(9)]), "nor does a list of strangers")
    }

    /// Closing the active tab activates the neighbour the person SEES — the pool's order is the bar's.
    func testCloseFollowsTheArrangedOrder() {
        var p = TabPool()
        _ = p.open(); _ = p.open(); _ = p.open()                        // 1 2 3
        p.arrange([.pty(3), .pty(1), .pty(2)])
        XCTAssertTrue(p.switchTo(.pty(1)))
        XCTAssertEqual(p.close(.pty(1)), .some(.pty(3)), "the tab to its left in the ARRANGED order")
    }

    /// A move within the pool: before another tab, or to the end with nil.
    func testMove() {
        var p = TabPool()
        _ = p.open(); _ = p.open(); _ = p.open()                        // 1 2 3
        XCTAssertTrue(p.move(.pty(3), before: .pty(1)))
        XCTAssertEqual(p.tabs.map(\.id), [.pty(3), .pty(1), .pty(2)])
        XCTAssertTrue(p.move(.pty(3), before: nil))
        XCTAssertEqual(p.tabs.map(\.id), [.pty(1), .pty(2), .pty(3)])
        XCTAssertFalse(p.move(.pty(3), before: nil), "already last: no change")
        XCTAssertFalse(p.move(.pty(1), before: .pty(2)), "already just before it: no change")
        XCTAssertEqual(p.activeId, .pty(3), "a move never changes the active tab")
    }

    /// Refused, and nothing changes: an unknown tab, an unknown `before`, or `before` naming the tab itself.
    func testMoveRefusals() {
        var p = TabPool()
        _ = p.open(); _ = p.open()
        let before = p
        XCTAssertFalse(p.move(.pty(9), before: nil))
        XCTAssertFalse(p.move(.pty(1), before: .pty(9)))
        XCTAssertFalse(p.move(.pty(1), before: .pty(1)))
        XCTAssertEqual(p, before)
    }
}
