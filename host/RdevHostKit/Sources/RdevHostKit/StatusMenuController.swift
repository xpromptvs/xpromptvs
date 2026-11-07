import AppKit

/// Menu-bar (status item) control for the host. Its one real action is "Lock Screen", which raises the
/// `CurtainController` shield (blackout + local-input lockout, session stays unlocked).
///
/// NOTE the curtain blacks out the whole display (gamma) AND suppresses local input, so once locked this
/// menu is both invisible and unclickable — it cannot be used to UNLOCK. Unlock happens remotely (an rdev
/// client drives through the curtain) or locally via the panic hotkey the curtain installs (⌃⌥⌘U). The
/// menu item title reflects state on open for the (rare) case the curtain is down but state is on.
///
/// Running the status item requires `NSApplication.shared.run()`, which registers RdevHost as its own
/// UIElement app — so the host needs its OWN Screen Recording (and Accessibility) grant, requested at
/// startup in main.swift. See the CGRequestScreenCaptureAccess call there.
@MainActor
public final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let lockItem: NSMenuItem

    public override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        lockItem = NSMenuItem(title: "Lock Screen", action: nil, keyEquivalent: "")
        super.init()

        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "lock.display", accessibilityDescription: "rdev host")
                ?? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "rdev host")
            img?.isTemplate = true
            button.image = img
            if img == nil { button.title = "rdev" }
            button.toolTip = "rdev host"
        }

        let menu = NSMenu()
        menu.delegate = self
        lockItem.target = self
        lockItem.action = #selector(toggleLock)
        menu.addItem(lockItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit rdev Host", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleLock() { CurtainController.shared.toggle() }

    @objc private func quit() {
        CurtainController.shared.lower()   // never exit leaving the shield up
        NSApp.terminate(nil)
    }

    // Reflect current state when the menu opens.
    public func menuWillOpen(_ menu: NSMenu) {
        let up = CurtainController.shared.isUp
        lockItem.title = up ? "Unlock Screen" : "Lock Screen"
        lockItem.state = up ? .on : .off
    }
}
