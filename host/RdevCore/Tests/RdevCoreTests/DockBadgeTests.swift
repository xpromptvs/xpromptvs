import XCTest
@testable import RdevCore

/// A WINDOW TAB'S BELL: what a Dock badge's change means (docs/window-capture-and-input.md, "A window's bell").
final class DockBadgeTests: XCTestCase {
    func testANumberIsTheLabelsDigits() {
        XCTAssertEqual(DockBadge.number("1"), 1)
        XCTAssertEqual(DockBadge.number("..21"), 21, "Telegram's label, as the Dock reads it (measured 2026-10-02)")
        XCTAssertEqual(DockBadge.number("99+"), 99)
        XCTAssertEqual(DockBadge.number("1,234"), 1234)
        XCTAssertNil(DockBadge.number("•"))
        XCTAssertNil(DockBadge.number(""))
        XCTAssertNil(DockBadge.number("1234567890"), "ten digits is not a count")
    }

    func testABadgeAppearingRingsAndOneGoingAwayNever() {
        XCTAssertTrue(DockBadge.rose(from: nil, to: "1"))
        XCTAssertTrue(DockBadge.rose(from: nil, to: "•"))
        XCTAssertTrue(DockBadge.rose(from: "", to: "1"), "an empty label is no badge")
        XCTAssertFalse(DockBadge.rose(from: "3", to: nil))
        XCTAssertFalse(DockBadge.rose(from: "3", to: "  "))
        XCTAssertFalse(DockBadge.rose(from: nil, to: nil))
    }

    func testACountRingsOnlyWhenItGrows() {
        XCTAssertTrue(DockBadge.rose(from: "..21", to: "..22"))
        XCTAssertFalse(DockBadge.rose(from: "..21", to: "..20"), "a message read elsewhere is not news")
        XCTAssertFalse(DockBadge.rose(from: "5", to: "5"))
        XCTAssertTrue(DockBadge.rose(from: "9", to: "10"), "compared as numbers, not as text")
        XCTAssertFalse(DockBadge.rose(from: "99+", to: "99+"))
    }

    func testAnyOtherLabelRingsWhenItChanges() {
        XCTAssertTrue(DockBadge.rose(from: "•", to: "!"))
        XCTAssertTrue(DockBadge.rose(from: "•", to: "1"))
        XCTAssertFalse(DockBadge.rose(from: "•", to: "•"))
        XCTAssertFalse(DockBadge.rose(from: " • ", to: "•"), "whitespace is not a change")
    }

    /// A reading of Dock `dock` with these items: a String label is a badge, nil none, `U` unreadable.
    private func r(_ dock: Int32 = 1, _ items: [(String, DockLabel)]) -> DockReading {
        DockReading(dock: dock, items: items.map { DockItemReading(path: $0.0, bundleID: nil, label: $0.1) })
    }
    private let U = DockLabel.unreadable

    func testTheFirstReadingIsTheBaselineNeverNews() {
        var b = DockBadgeBaseline()
        XCTAssertEqual(b.observe(r(1, [("/A.app", .badge("3")), ("/B.app", .none)])), [], "a badge already showing is not news")
        XCTAssertEqual(b.observe(r(1, [("/A.app", .badge("4")), ("/B.app", .none)])), ["/A.app"])
        XCTAssertEqual(b.observe(r(1, [("/A.app", .badge("4")), ("/B.app", .badge("1"))])), ["/B.app"])
        XCTAssertEqual(b.observe(r(1, [("/A.app", .badge("4")), ("/B.app", .badge("1"))])), [], "the same reading again rings nothing")
    }

    /// REVIEW F1: a FAILED label read is not "no badge". Recorded as none, the next good read of the SAME label
    /// was a rise — every window of the application marked.
    func testAnUnreadableLabelKeepsItsBaseline() {
        var b = DockBadgeBaseline()
        _ = b.observe(r(1, [("/A.app", .badge("..21"))]))
        XCTAssertEqual(b.observe(r(1, [("/A.app", U)])), [])
        XCTAssertEqual(b.observe(r(1, [("/A.app", .badge("..21"))])), [], "21 → (unread) → 21 is no change")
        XCTAssertEqual(b.observe(r(1, [("/A.app", U)])), [])
        XCTAssertEqual(b.observe(r(1, [("/A.app", .badge("..22"))])), ["/A.app"], "a real rise across an unread tick still rings")
        var fresh = DockBadgeBaseline()
        _ = fresh.observe(r(1, [("/A.app", U)]))
        XCTAssertEqual(fresh.observe(r(1, [("/A.app", .badge("2"))])), [], "an item never READ has no baseline yet")
    }

    /// REVIEW F1: an EMPTY reading — the Dock relaunching, its tree not built — changes nothing; it used to
    /// forget every baseline.
    func testAnEmptyReadingChangesNothing() {
        var b = DockBadgeBaseline()
        _ = b.observe(r(1, [("/A.app", .badge("3"))]))
        XCTAssertEqual(b.observe(r(1, [])), [])
        XCTAssertEqual(b.observe(r(1, [])), [])
        XCTAssertEqual(b.observe(r(1, [("/A.app", .badge("4"))])), ["/A.app"], "its baseline survived the empty readings")
    }

    /// An item missing from ONE reading (its own subrole or bundle read failed) keeps its baseline; missing from
    /// two in a row, its application quit, and it starts over.
    func testAnItemMissingOnceIsKeptAndTwiceForgotten() {
        var b = DockBadgeBaseline()
        _ = b.observe(r(1, [("/A.app", .badge("3")), ("/F.app", .none)]))
        _ = b.observe(r(1, [("/F.app", .none)]))                              // A unread this once
        XCTAssertEqual(b.observe(r(1, [("/A.app", .badge("4")), ("/F.app", .none)])), ["/A.app"], "kept: 3 → 4 rings")
        _ = b.observe(r(1, [("/F.app", .none)]))
        _ = b.observe(r(1, [("/F.app", .none)]))                              // twice: quit
        XCTAssertEqual(b.observe(r(1, [("/A.app", .badge("5")), ("/F.app", .none)])), [], "relaunched: its first reading again")
    }

    /// REVIEW F1: A NEW DOCK (`killall Dock`) can list its items before their badges. Each badge arriving then is
    /// not news: every baseline starts over and nothing rings for `settleReadings` readings.
    func testADockRelaunchStartsOverAndRingsNothingWhileItSettles() {
        var b = DockBadgeBaseline()
        _ = b.observe(r(100, [("/A.app", .badge("5")), ("/B.app", .none)]))
        XCTAssertEqual(b.observe(r(200, [("/A.app", .none), ("/B.app", .none)])), [], "items before their badges")
        XCTAssertEqual(b.observe(r(200, [("/A.app", .badge("5")), ("/B.app", .none)])), [], "A's badge arriving a tick later")
        XCTAssertEqual(b.observe(r(200, [("/A.app", .badge("5")), ("/B.app", .none)])), [])
        XCTAssertEqual(b.observe(r(200, [("/A.app", .badge("6")), ("/B.app", .none)])), ["/A.app"], "settled: a real rise rings")
    }

    func testAResetForgetsEverythingTheDockIncluded() {
        var b = DockBadgeBaseline()
        _ = b.observe(r(100, [("/A.app", .none)]))
        b.reset()
        XCTAssertEqual(b.observe(r(200, [("/A.app", .badge("5"))])), [], "after a reset, the first reading is the baseline")
        XCTAssertEqual(b.observe(r(200, [("/A.app", .badge("6"))])), ["/A.app"], "and a reset is no relaunch: nothing settles")
    }

    func testARisenApplicationRingsEveryOneOfItsWindowsMatchedByPathElseIdentifier() {
        let items = [
            DockItemReading(path: "/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal", label: .badge("1")),
            DockItemReading(path: "/Applications/Telegram.app", bundleID: "ru.keepcoder.Telegram", label: .badge("..22")),
            DockItemReading(path: "/Applications/Safari.app", bundleID: "com.apple.Safari", label: .badge("3")),
        ]
        let windows = [
            WindowOwnerApp(source: "win:1", path: "/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal"),
            WindowOwnerApp(source: "win:2", path: "/Applications/Telegram.app", bundleID: nil),
            WindowOwnerApp(source: "win:3", path: "/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal"),
            // The same application at another path — matched by its identifier.
            WindowOwnerApp(source: "win:4", path: "/System/Cryptexes/App/System/Applications/Safari.app", bundleID: "com.apple.Safari"),
            WindowOwnerApp(source: "win:5", path: nil, bundleID: nil),
        ]
        let all: Set<String> = ["/Applications/Utilities/Terminal.app", "/Applications/Telegram.app", "/Applications/Safari.app"]
        XCTAssertEqual(DockBadge.ringing(windows: windows, items: items, rose: all), [["win:1", "win:3"], ["win:2"], ["win:4"]])
        XCTAssertEqual(DockBadge.ringing(windows: windows, items: items, rose: ["/Applications/Telegram.app"]), [["win:2"]])
        XCTAssertEqual(DockBadge.ringing(windows: windows, items: items, rose: []), [])
        XCTAssertEqual(DockBadge.ringing(windows: [windows[4]], items: items, rose: all), [], "an owner it cannot name rings nothing")
    }

    /// REVIEW F3: the identifier is the fallback ONLY when no Dock item has the window's path — two bundles with
    /// one identifier (Xcode and Xcode-beta, a dev build and an installed copy) must not ring each other's windows.
    func testTheIdentifierFallbackNeverCrossesToAnotherCopyTheDockLists() {
        let items = [
            DockItemReading(path: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode", label: .none),
            DockItemReading(path: "/Applications/Xcode-beta.app", bundleID: "com.apple.dt.Xcode", label: .badge("1")),
        ]
        let windows = [
            WindowOwnerApp(source: "win:1", path: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode"),
            WindowOwnerApp(source: "win:2", path: "/Applications/Xcode-beta.app", bundleID: "com.apple.dt.Xcode"),
            WindowOwnerApp(source: "win:3", path: "/Volumes/Dev/Xcode-beta.app", bundleID: "com.apple.dt.Xcode"),
        ]
        XCTAssertEqual(DockBadge.ringing(windows: windows, items: items, rose: ["/Applications/Xcode-beta.app"]),
                       [["win:2", "win:3"]], "win:1's own bundle is listed and did not rise; win:3's path is listed nowhere")
    }

    func testAnApplicationWithNoWindowInTheSessionRingsNothing() {
        let items = [DockItemReading(path: "/Applications/Mail.app", bundleID: "com.apple.mail", label: .badge("7"))]
        let windows = [WindowOwnerApp(source: "win:1", path: "/Applications/Notes.app", bundleID: "com.apple.Notes")]
        XCTAssertEqual(DockBadge.ringing(windows: windows, items: items, rose: ["/Applications/Mail.app"]), [])
    }

    func testTheMessage() throws {
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: windowBellJSON(sources: ["win:1", "win:3"])) as? [String: Any])
        XCTAssertEqual(o["t"] as? String, "window-bell")
        XCTAssertEqual(o["sources"] as? [String], ["win:1", "win:3"])
    }
}
