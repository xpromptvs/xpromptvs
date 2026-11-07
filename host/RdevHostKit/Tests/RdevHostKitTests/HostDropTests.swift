import AppKit
import CoreGraphics
import XCTest
import RdevCore
@testable import RdevHostKit

/// The real drop's PURE parts (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §5): where its
/// panel sits, the path the cursor takes, the window a point is over, and the two decisions that keep a
/// drop on its target. Nothing here posts an event — a real drop moves the real cursor, and the live
/// check proves it end to end.
final class HostDropTests: XCTestCase {
    func testTheSourcePanelSitsOnTheStartPointInCocoaCoordinates() {
        XCTAssertEqual(HostDrop.cocoaRect(around: CGPoint(x: 100, y: 50), size: 8, screenHeight: 1000),
                       NSRect(x: 96, y: 946, width: 8, height: 8))
    }

    func testThePathEndsExactlyOnTheDropPoint() {
        let p = HostDrop.path(from: CGPoint(x: 124, y: 74), to: CGPoint(x: 100, y: 50), steps: 12)
        XCTAssertEqual(p.count, 12)
        XCTAssertEqual(p.last, CGPoint(x: 100, y: 50))
        XCTAssertEqual(p.first, CGPoint(x: 122, y: 72))
    }

    /// The panel goes 24 points below and right of the drop point — and to the OTHER side near an edge of
    /// the display, or the posted mouse-down lands where the system clamps the cursor, which is not the panel.
    func testTheStartPointStaysOnTheDropPointsDisplay() {
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertEqual(HostDrop.startPoint(for: CGPoint(x: 500, y: 400), on: main), CGPoint(x: 524, y: 424))
        XCTAssertEqual(HostDrop.startPoint(for: CGPoint(x: 1710, y: 400), on: main), CGPoint(x: 1686, y: 424))
        XCTAssertEqual(HostDrop.startPoint(for: CGPoint(x: 500, y: 1100), on: main), CGPoint(x: 524, y: 1076))
        // A second display to the LEFT has a negative origin; its own right edge is the one that counts.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(HostDrop.startPoint(for: CGPoint(x: -10, y: 10), on: left), CGPoint(x: -34, y: 34))
    }

    // MARK: windowUnder

    /// One entry as `CGWindowListCopyWindowInfo` returns it: the bounds a dictionary `CGRect(dictionaryRepresentation:)` reads.
    private func win(_ n: Int, pid: Int, layer: Int = 0, alpha: Double = 1, _ r: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: n, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
         kCGWindowAlpha as String: alpha, kCGWindowBounds as String: r.dictionaryRepresentation as NSDictionary]
    }
    private let big = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let p = CGPoint(x: 300, y: 300)

    func testTheFrontMostContainingWindowWins() {
        let list = [win(5, pid: 10, CGRect(x: 600, y: 0, width: 100, height: 100)),   // in front, elsewhere
                    win(7, pid: 11, CGRect(x: 200, y: 200, width: 300, height: 300)),
                    win(9, pid: 12, big)]
        XCTAssertEqual(HostDrop.windowUnder(p, in: list, excludingPID: nil), 7)
    }

    func testThisProcesssOwnWindowsAreSkippedOnlyWhenAsked() {
        let list = [win(3, pid: 42, big), win(9, pid: 12, big)]
        XCTAssertEqual(HostDrop.windowUnder(p, in: list, excludingPID: 42), 9)
        XCTAssertEqual(HostDrop.windowUnder(p, in: list, excludingPID: nil), 3)
    }

    /// The Dock's full-screen layer-20 window is in every list and the menu bar (24) and the cursor's
    /// windows sit above it: a bounds walk over them would find the Dock everywhere. Below the Dock's layer a
    /// FLOATING window (3) takes a drop over the target like any other, so it counts.
    func testTheDocksLayerAndAboveAreSkippedAndAFloatingWindowCounts() {
        let list = [win(1, pid: 1, layer: 2_147_483_630, big), win(2, pid: 2, layer: 24, big),
                    win(3, pid: 3, layer: 20, big), win(4, pid: 4, layer: 3, big), win(9, pid: 12, big)]
        XCTAssertEqual(HostDrop.windowUnder(p, in: list, excludingPID: nil), 4)
        XCTAssertEqual(HostDrop.windowUnder(p, in: Array(list.prefix(3)) + [win(9, pid: 12, big)], excludingPID: nil), 9)
        XCTAssertNil(HostDrop.windowUnder(p, in: [win(6, pid: 6, layer: -2_147_483_603, big)], excludingPID: nil),
                     "the desktop's own windows are BEHIND every window: a point over the desktop is over none")
    }

    /// A window with no alpha takes no click (the panel's own background is 0.02 for exactly that reason).
    func testAnInvisibleWindowIsSkipped() {
        XCTAssertEqual(HostDrop.windowUnder(p, in: [win(2, pid: 2, alpha: 0, big), win(9, pid: 12, big)], excludingPID: nil), 9)
    }

    func testAPointOutsideEveryWindowIsOverNone() {
        XCTAssertNil(HostDrop.windowUnder(CGPoint(x: 1200, y: 10), in: [win(9, pid: 12, big)], excludingPID: nil))
        XCTAssertNil(HostDrop.windowUnder(p, in: [], excludingPID: nil))
    }

    /// The source panel sits at the screen saver's level (1000): ANY layer counts for it, because what is in
    /// front of it at any layer is what a posted mouse-down would click.
    func testAtAnyLayerThePanelIsFoundAndWhatCoversItWins() {
        let panel = win(77, pid: 42, layer: 1000, CGRect(x: 296, y: 296, width: 8, height: 8))
        let dock = win(3, pid: 3, layer: 20, big)
        XCTAssertEqual(HostDrop.windowUnder(p, in: [panel, dock, win(9, pid: 12, big)], excludingPID: nil, anyLayer: true), 77)
        XCTAssertEqual(HostDrop.windowUnder(p, in: [win(5, pid: 5, layer: 1500, big), panel, dock], excludingPID: nil, anyLayer: true), 5)
        XCTAssertNil(HostDrop.windowUnder(p, in: [panel, dock], excludingPID: nil), "not at the normal layers")
    }

    // MARK: the decisions

    /// THE DROP LANDS ONLY ON ITS TARGET: the window in front at the point must BE the target — this host's
    /// own included, which takes a drop like any window does (P4's unguarded wrong drop may have gone into
    /// one). A display has no target window, but its picture never shows this host's windows,
    /// so a drop must not land on one; anything else under the point is what the picture shows there.
    func testTheDropLandsOnlyOnItsTarget() {
        let own: pid_t = 42
        let target = win(9, pid: 12, big)
        let other = win(5, pid: 5, CGRect(x: 250, y: 250, width: 100, height: 100))
        let mine = win(3, pid: 42, CGRect(x: 250, y: 250, width: 100, height: 100))
        XCTAssertTrue(HostDrop.landsOnTarget(p, in: [target], target: 9, ownPID: own))
        XCTAssertFalse(HostDrop.landsOnTarget(p, in: [other, target], target: 9, ownPID: own))
        XCTAssertFalse(HostDrop.landsOnTarget(p, in: [mine, target], target: 9, ownPID: own))
        XCTAssertFalse(HostDrop.landsOnTarget(p, in: [], target: 9, ownPID: own))
        XCTAssertTrue(HostDrop.landsOnTarget(p, in: [other, target], target: nil, ownPID: own))
        XCTAssertFalse(HostDrop.landsOnTarget(p, in: [mine, target], target: nil, ownPID: own))
        XCTAssertTrue(HostDrop.landsOnTarget(p, in: [], target: nil, ownPID: own), "a display's bare desktop takes it")
    }

    /// A window this process OPENED SINCE THE PRESS — the drag's own image, under the cursor — takes nothing and
    /// is looked through; one it already had is not. Only this process's own new windows are.
    func testTheDragsOwnWindowsAreLookedThrough() {
        let own: pid_t = 42
        let target = win(9, pid: 12, big)
        let image = win(4, pid: 42, CGRect(x: 298, y: 298, width: 4, height: 4))
        let before = HostDrop.ownWindows(in: [win(3, pid: 42, big), win(8, pid: 8, big)], pid: own)
        XCTAssertEqual(before, [3])
        let now = [image, target]
        let opened = HostDrop.ownWindows(in: now, pid: own).subtracting(before)
        XCTAssertEqual(opened, [4])
        XCTAssertTrue(HostDrop.landsOnTarget(p, in: now, target: 9, ownPID: own, lookingThrough: opened))
        XCTAssertFalse(HostDrop.landsOnTarget(p, in: now, target: 9, ownPID: own), "not looked through, it is in front")
        XCTAssertTrue(HostDrop.landsOnTarget(p, in: now, target: nil, ownPID: own, lookingThrough: opened))
        XCTAssertFalse(HostDrop.landsOnTarget(p, in: [win(3, pid: 42, big), target], target: 9, ownPID: own, lookingThrough: opened),
                       "a window this host already had still takes the drop")
        XCTAssertFalse(HostDrop.landsOnTarget(p, in: [win(4, pid: 5, big), target], target: 9, ownPID: own, lookingThrough: opened),
                       "another app's window with that number is not this host's")
    }

    /// THE PRESS ASKS GUARD 1 FIRST, from the same window list as guard 2, before anything is posted: a drop
    /// point something else covers ALREADY — paste-live-check D2's floating Picture-in-Picture window over the
    /// target — is refused with nothing posted, and the delivery pastes instead. Guard 2 still decides whether
    /// the panel is on top; a drop point that is the target's and a panel on top is the one press that goes.
    func testThePressRefusesADropPointSomethingElseAlreadyCovers() {
        let own: pid_t = 42
        let start = CGPoint(x: 324, y: 324)
        let panel = win(77, pid: 42, layer: 1000, CGRect(x: 320, y: 320, width: 8, height: 8))
        let target = win(9, pid: 12, big)
        let pip = win(5, pid: 13, layer: 3, CGRect(x: 250, y: 250, width: 100, height: 100))   // floating, over the point
        XCTAssertEqual(HostDrop.pressVerdict(start: start, panel: 77, target: p, targetWindowID: 9, ownPID: own,
                                             in: [panel, target]), .press)
        XCTAssertEqual(HostDrop.pressVerdict(start: start, panel: 77, target: p, targetWindowID: 9, ownPID: own,
                                             in: [panel, pip, target]), .notOnTarget)
        XCTAssertEqual(HostDrop.pressVerdict(start: start, panel: 77, target: p, targetWindowID: 9, ownPID: own,
                                             in: [win(6, pid: 6, layer: 1500, big), panel, target]), .panelCovered)
        XCTAssertEqual(HostDrop.pressVerdict(start: start, panel: 77, target: p, targetWindowID: nil, ownPID: own,
                                             in: [panel, pip, target]), .press, "a display: what the picture shows takes it")
        XCTAssertEqual(HostDrop.pressVerdict(start: start, panel: 77, target: p, targetWindowID: nil, ownPID: own,
                                             in: [panel, win(3, pid: 42, big), target]), .notOnTarget,
                       "but never this host's own window, which its picture does not show")
    }

    // MARK: the events

    /// HELD MODIFIERS MUST NOT CHANGE THE OPERATION: ⌘ or ⌥ held on the strip would turn the copy into a move
    /// or a link, or make the target refuse it. Every event the drop posts says NO modifier, and every one
    /// carries the curtain's marker — the curtain swallows everything else, and a drop with it up is the
    /// ordinary case for a remote driver. And the drop posts NO KEY at all: its one cancel is not to press
    /// (guard 1 before the press), never Escape, which would go to the active app.
    func testEveryPostedEventCarriesNoModifierAndTheCurtainsMarker() throws {
        let a = CGPoint(x: 10, y: 10), b = CGPoint(x: 12, y: 13)
        let events = try [HostDrop.mouseEvent(.leftMouseDown, at: a, from: nil),
                          HostDrop.mouseEvent(.leftMouseDragged, at: b, from: a),
                          HostDrop.mouseEvent(.leftMouseUp, at: b, from: b)].map { try XCTUnwrap($0) }
        for e in events {
            XCTAssertEqual(e.flags, [], "\(e.type.rawValue)")
            XCTAssertEqual(e.getIntegerValueField(.eventSourceUserData), curtainInputMarker)
        }
        XCTAssertEqual(events[1].getDoubleValueField(.mouseEventDeltaX), 2)
        XCTAssertEqual(events[1].getDoubleValueField(.mouseEventDeltaY), 3)
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
    }

    // MARK: the carry

    /// A DROP IS CARRYING from its own press until its mouse-up, process-wide: the window injector reads it and
    /// posts none of the driver's pointer events meanwhile (`DropCarryGate`). Held by ITS drop — only that drop's
    /// end clears it: a drop let go at 30 s whose session AppKit ends later still runs `end`, and must not clear the
    /// NEXT drop's carry, nor may a second end of the same drop.
    func testACarryIsHeldByItsDropAndOnlyItsOwnEndClearsIt() {
        let c = DropCarry()
        XCTAssertFalse(c.isCarrying)
        let first = c.begin()
        XCTAssertTrue(c.isCarrying)
        c.end(first)
        XCTAssertFalse(c.isCarrying)
        let second = c.begin()
        c.end(first)
        XCTAssertTrue(c.isCarrying, "the earlier drop's late end leaves the next drop's carry alone")
        c.end(second)
        c.end(second)
        XCTAssertFalse(c.isCarrying)
    }

    /// Read from the injector's queue while main and the carry's thread write it.
    func testTheCarryIsReadAndWrittenFromAnyThread() {
        let c = DropCarry()
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            if i % 2 == 0 { c.end(c.begin()) } else { _ = c.isCarrying }
        }
        XCTAssertFalse(c.isCarrying)
    }

    // MARK: the answer, and the bounds

    /// THE ANSWER IS WHETHER A DROP HAPPENED — never where it was meant to. A drop that landed on a window that
    /// came over the point mid-drag landed: answering false would make the caller paste it AGAIN. A session that never ended is
    /// answered as dropped once its mouse-up has gone (a paste on top could deliver twice), and as not dropped
    /// when no session ever began.
    func testTheAnswerIsWhetherADropHappened() {
        XCTAssertTrue(HostDrop.answer(endedWith: .copy, sessionBegan: true, released: true))
        XCTAssertFalse(HostDrop.answer(endedWith: [], sessionBegan: true, released: true))
        XCTAssertTrue(HostDrop.answer(endedWith: nil, sessionBegan: true, released: true))
        XCTAssertFalse(HostDrop.answer(endedWith: nil, sessionBegan: true, released: false))
        XCTAssertFalse(HostDrop.answer(endedWith: nil, sessionBegan: false, released: true))
    }

    /// What is due while a drop has not ended, by the time since its press: a press that began no session is
    /// released and refused at 1 s; a session that has not ended is answered at 10 s and LET GO at 30 s — or
    /// one AppKit never ends would refuse every later drop in the process as "another drop is under way".
    func testWhatIsDueWhileADropHasNotEnded() {
        XCTAssertEqual(HostDrop.overdue(elapsed: 0.9, began: false), .nothing)
        XCTAssertEqual(HostDrop.overdue(elapsed: 1.0, began: false), .noSession)
        XCTAssertEqual(HostDrop.overdue(elapsed: 31, began: false), .noSession)
        XCTAssertEqual(HostDrop.overdue(elapsed: 1.0, began: true), .nothing)
        XCTAssertEqual(HostDrop.overdue(elapsed: 9.9, began: true), .nothing)
        XCTAssertEqual(HostDrop.overdue(elapsed: 10, began: true), .answerWithoutEnd)
        XCTAssertEqual(HostDrop.overdue(elapsed: 29.9, began: true), .answerWithoutEnd)
        XCTAssertEqual(HostDrop.overdue(elapsed: 30, began: true), .letGo)
    }
}
