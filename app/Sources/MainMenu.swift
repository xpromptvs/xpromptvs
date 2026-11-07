import AppKit

/// No more than Electron's default menu claimed, minus View (reload/devtools). The EDIT menu is
/// LOAD-BEARING: without it ⌘C/⌘V do nothing in a WKWebView input.
///
/// **⌘W CLOSES THE TAB** (docs/desktop-app.md, "⌘W closes the tab"): a client window's page takes ⌘W first and
/// closes the terminal tab on screen; WebKit hands this menu only a ⌘W the page left alone — no tab to close, or the
/// dashboard — and then it closes the window, as Safari's Close Tab does with a window's last tab. ⇧⌘W always does.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(); let menu = NSMenu(title: title)
            items.forEach(menu.addItem); item.submenu = menu; main.addItem(item)
        }
        func i(_ t: String, _ a: Selector?, _ k: String, _ m: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let x = NSMenuItem(title: t, action: a, keyEquivalent: k); x.keyEquivalentModifierMask = m; return x
        }
        sub("Xpromptvs", [i("About Xpromptvs", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
                           .separator(),
                           i("Hide Xpromptvs", #selector(NSApplication.hide(_:)), "h"),
                           i("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                           .separator(),
                           i("Quit Xpromptvs", #selector(NSApplication.terminate(_:)), "q")])
        sub("File", [i("Macs…", #selector(AppDelegate.showMacs(_:)), "k", [.command, .shift]), .separator(), i("Close Tab", #selector(NSWindow.performClose(_:)), "w"),
                     i("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])])
        sub("Edit", [i("Undo", Selector(("undo:")), "z"), i("Redo", Selector(("redo:")), "z", [.command, .shift]),
                     .separator(),
                     i("Cut", #selector(NSText.cut(_:)), "x"), i("Copy", #selector(NSText.copy(_:)), "c"),
                     i("Paste", #selector(NSText.paste(_:)), "v"), i("Select All", #selector(NSText.selectAll(_:)), "a")])
        sub("Window", [i("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                       i("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")])
        NSApp.mainMenu = main
    }
}
