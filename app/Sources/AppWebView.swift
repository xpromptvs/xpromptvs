import AppKit
import ShellstormCore
import WebKit

/// EVERY APP WEB VIEW (`WebViewFactory.make`): WebKit's context menu, rebuilt as an edit menu just before it opens
/// (`WebContextMenu` has the reasoning; docs/desktop-app.md, "The context menu"). WebKit's own items that stay are
/// moved over as they are; Cut, Copy, Paste and Select All are the standard actions, aimed at THIS view — never the
/// responder chain, which a right-click need not have moved. WebKit's menu does not validate itself
/// (`autoenablesItems` is off — measured): each opens as `WebContextMenu.opensEnabled` says, and is handed to the
/// view's own validation (`validateUserInterfaceItem`, WKWebView's public `NSUserInterfaceValidations`), which asks
/// the web process and sets the item when it answers.
final class AppWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let offered = menu.items
        var byIdentifier: [String: NSMenuItem] = [:]
        for item in offered { if let id = item.identifier?.rawValue { byIdentifier[id] = item } }
        let ids = offered.compactMap { $0.identifier?.rawValue }
        menu.removeAllItems()
        for entry in WebContextMenu.plan(offered: ids) {
            let edit = { (title: String, action: Selector) in
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                // Asked first (it answers "enabled" now and SETS the item when the web process replies), then
                // opened as what WebKit offered says — or a greyed item would flash enabled.
                _ = self.validateUserInterfaceItem(item)
                item.isEnabled = WebContextMenu.opensEnabled(entry, offered: ids)
                menu.addItem(item)
            }
            switch entry {
            case .webKit(let id): if let item = byIdentifier[id] { menu.addItem(item) }
            case .cut: edit("Cut", #selector(NSText.cut(_:)))
            case .copy: edit("Copy", #selector(NSText.copy(_:)))
            case .paste: edit("Paste", #selector(NSText.paste(_:)))
            case .selectAll: edit("Select All", #selector(NSText.selectAll(_:)))
            case .separator: menu.addItem(.separator())
            }
        }
    }
}
