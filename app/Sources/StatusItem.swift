import AppKit

/// Text-only status item (`tray.ts`). Rebuilt when it OPENS, so sharing and the curtain — both
/// changed from outside this file — cannot be stale. The harness's StatusMenuController is NOT
/// created here: in-process both would show.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let host: HostController
    private let windows: AppWindows

    init(host: HostController, windows: AppWindows) {
        self.host = host; self.windows = windows
        super.init()
        item.button?.title = "Xpromptvs"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        handlers.removeAll()
        let sharing = host.isSharing
        let status = NSMenuItem(title: sharing ? "Sharing this Mac" : "Not sharing", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(action("Open Xpromptvs") { [windows] in windows.openHome() })
        menu.addItem(action("Connect to a Mac…") { [windows] in _ = windows.openClient(pairing: nil, showWhenReady: true, motion: nil) })
        menu.addItem(.separator())
        let lock = action("Lock Screen") { [host] in host.setCurtain(!host.curtainIsUp) }
        lock.isEnabled = sharing; lock.state = host.curtainIsUp ? .on : .off
        menu.addItem(lock)
        let stop = action("Stop sharing") { [host] in host.stopSharing() }
        stop.isEnabled = sharing
        menu.addItem(stop)
        menu.addItem(.separator())
        menu.addItem(action("Quit Xpromptvs") { NSApp.terminate(nil) })
    }

    private var handlers: [ClosureTarget] = []
    private func action(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let t = ClosureTarget(run); handlers.append(t)
        let m = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: "")
        m.target = t
        return m
    }
}

@MainActor
private final class ClosureTarget: NSObject {
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @objc func fire() { run() }
}
