import Foundation

/// **THE WEB VIEWS' CONTEXT MENU IS AN EDIT MENU** (2026-10-05, asked for: "remove the default web view 'reload, ...'
/// right click menu from the desktop app, and replace it with (macOS system one if possible) copy, paste, etc.";
/// docs/desktop-app.md, "The context menu"). WebKit's own menu is a BROWSER's — Back, Forward, Reload on an empty
/// spot, Inspect Element in a dev build, Open Link in New Window, Download Image — and a reload or a back in an app
/// window throws its session away. Every menu WebKit is about to show is rebuilt (`AppWebView.willOpenMenu`) into
/// what macOS's own text menu offers: WebKit's Look Up and Translate when text is selected — they lead the
/// system's menu too — then Cut, Copy, Paste and Select All, the standard actions aimed at the web view, which
/// enables each exactly when it applies (a selection, an editable field). Links also retain WebKit's Copy Link
/// item with its original target/action, so it copies the destination instead of the selected link text.
/// Everything else WebKit offered goes.
/// A page that shows its own menu — the terminal's, a tab's — prevents WebKit's, so it is never reached here.
public enum WebContextMenu {
    /// What the menu holds, in order.
    public enum Entry: Equatable, Sendable {
        /// The item WebKit offered under this identifier, as it is.
        case webKit(String)
        case cut, copy, paste, selectAll
        case separator
    }

    /// WebKit's items that stay: the system text actions and a link's native Copy Link action. Matched by
    /// VALUE — WebKit exports `WKMenuItemIdentifier…` with no public header, each the string of its own name; one
    /// renamed is merely not found, and the edit items stand regardless.
    public static let keptWebKitItems = ["WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate", "WKMenuItemIdentifierCopyLink"]

    /// The menu for the items WebKit `offered` (their identifiers, in its order).
    public static func plan(offered: [String]) -> [Entry] {
        let kept = keptWebKitItems.filter(offered.contains).map(Entry.webKit)
        return kept + (kept.isEmpty ? [] : [.separator]) + [.cut, .copy, .paste, .separator, .selectAll]
    }

    /// Whether an edit item opens ENABLED. WebKit validates them asynchronously — "enabled" until the web process
    /// answers, then it sets each item it was asked about (measured: an empty spot's Cut, Copy and Paste opened
    /// enabled and greyed a moment later) — so the menu would flash. What WebKit OFFERED says the same at once:
    /// its Copy with a selection, its Paste in an editable field, so Cut with both. Its answer still lands after.
    public static func opensEnabled(_ entry: Entry, offered: [String]) -> Bool {
        let copy = offered.contains("WKMenuItemIdentifierCopy"), paste = offered.contains("WKMenuItemIdentifierPaste")
        switch entry {
        case .cut: return copy && paste
        case .copy: return copy
        case .paste: return paste
        case .selectAll, .webKit, .separator: return true
        }
    }
}
