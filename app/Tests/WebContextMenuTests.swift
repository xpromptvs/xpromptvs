import XCTest
@testable import ShellstormCore

/// The web views' context menu: an edit menu, never a browser's.
final class WebContextMenuTests: XCTestCase {
    private let edit: [WebContextMenu.Entry] = [.cut, .copy, .paste, .separator, .selectAll]

    /// An empty spot: WebKit offers navigation (and Inspect Element in a dev build) — none of it survives.
    func testABrowsersMenuBecomesTheEditMenu() {
        XCTAssertEqual(WebContextMenu.plan(offered: ["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
                                                     "WKMenuItemIdentifierReload", "WKMenuItemIdentifierInspectElement"]), edit)
    }

    /// A selection: Look Up and Translate lead, as in macOS's own text menu; searching the web and sharing go.
    func testASelectionKeepsLookUpAndTranslateFirst() {
        let offered = ["WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate", "WKMenuItemIdentifierSearchWeb",
                       "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierShareMenu", "WKMenuItemIdentifierSpeechMenu"]
        XCTAssertEqual(WebContextMenu.plan(offered: offered),
                       [.webKit("WKMenuItemIdentifierLookUp"), .webKit("WKMenuItemIdentifierTranslate"), .separator] + edit)
    }

    /// The kept items in the SYSTEM's order, whatever order WebKit offered them in.
    func testTheKeptItemsComeInTheSystemsOrder() {
        XCTAssertEqual(Array(WebContextMenu.plan(offered: ["WKMenuItemIdentifierTranslate", "WKMenuItemIdentifierLookUp"]).prefix(2)),
                       [.webKit("WKMenuItemIdentifierLookUp"), .webKit("WKMenuItemIdentifierTranslate")])
    }

    func testLinkKeepsNativeCopyLinkWithoutBrowserNavigationOrDownloads() {
        let offered = ["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierCopyLink",
                       "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierReload"]
        XCTAssertEqual(WebContextMenu.plan(offered: offered),
                       [.webKit("WKMenuItemIdentifierCopyLink"), .separator] + edit)
    }

    /// Opening enabled: as WebKit offered — an empty spot nothing but Select All, a selection Copy, a field all.
    func testItemsOpenEnabledAsWebKitOfferedThem() {
        func opens(_ offered: [String]) -> [Bool] {
            [WebContextMenu.Entry.cut, .copy, .paste, .selectAll].map { WebContextMenu.opensEnabled($0, offered: offered) }
        }
        XCTAssertEqual(opens(["WKMenuItemIdentifierReload"]), [false, false, false, true])
        XCTAssertEqual(opens(["WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierCopy"]), [false, true, false, true])
        XCTAssertEqual(opens(["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste"]), [true, true, true, true])
        XCTAssertEqual(opens(["WKMenuItemIdentifierPaste"]), [false, false, true, true], "a field with no selection")
    }

    /// Links, images, spelling, writing tools: gone; the edit menu stands even when WebKit offers nothing.
    func testEverythingElseGoes() {
        XCTAssertEqual(WebContextMenu.plan(offered: ["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadImage",
                                                     "WKMenuItemIdentifierSpellingMenu", "WKMenuItemIdentifierWritingTools"]), edit)
        XCTAssertEqual(WebContextMenu.plan(offered: []), edit)
    }
}
