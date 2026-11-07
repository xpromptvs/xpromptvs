import AppKit
import ShellstormCore
import RdevHostKit

// @MainActor is class-wide on purpose: later tasks add stored properties here
// (`host`, `ui`, …) that are read and written from delegate callbacks and from helper methods this
// class will grow, and all of that needs one consistent isolation domain rather than isolating
// methods one at a time. See main.swift for how a top-level (pre-run-loop) context constructs a
// main-actor-isolated type.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let profile: AppProfile
    let environment: ShellEnvironment
    private(set) var windows: AppWindows!
    private(set) var host: HostController!
    private(set) var ui: UIBridge!
    private var publisher: StatePublisher?
    /// What client pages asked to send of what Finder copied, until they read it (`ClientBridge`, `SchemeHandler`).
    let pastes = PreparedPastes()
    private(set) var nativeSimulators: NativeSimulatorWindows?
    private var client: ClientBridge?
    private var updater: HostUpdateCoordinator?
    private var statusItem: StatusItem?
    private var terminalTabs: TerminalTabsKeeper?
    #if RDEV_DEV_BUILD
    private var automation: Automation?
    #endif

    init(profile: AppProfile, environment: ShellEnvironment) {
        self.profile = profile; self.environment = environment
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Public and staging preserve the same bundle identity for TCC. Launch Services can reuse
        // another installed variant's cached icon; the running app must use its own bundled artwork.
        if let name=Bundle.main.object(forInfoDictionaryKey:"CFBundleIconFile") as? String,
           let url=Bundle.main.url(forResource:name,withExtension:name.hasSuffix(".icns") ? nil:"icns"),
           let image=NSImage(contentsOf:url) { NSApp.applicationIconImage=image }
        host = HostController(environment: environment, profile: profile)
        // The tabs saved at the last quit, back before any window can ask for one (docs/terminal.md).
        let terminalTabs = TerminalTabsKeeper(profile: profile)
        terminalTabs.restore()
        terminalTabs.start()
        self.terminalTabs = terminalTabs
        ui = UIBridge(host: host, profile: profile, environment: environment)
        // The zips a folder paste makes live only while a page reads them: whatever a crash left goes now.
        try? FileManager.default.removeItem(at: profile.archiveDirectory)
        let client = ClientBridge(host: host, profile: profile, environment: environment, pastes: pastes)
        let sockets = SocketBridge { [weak self] socket in self?.host.acceptLocal(socket) }
        nativeSimulators = sockets.nativeWindows
        client.nativeSimulators = sockets.nativeWindows
        sockets.nativeWindows.onTerminal = { [weak sockets] in sockets?.windows?.local?.window.makeKeyAndOrderFront(nil) }
        var context = WebContext(profile: profile, environment: environment, scheme: SchemeHandler(pastes: pastes),
                                 uiBridge: ui, clientBridge: client)
        context.socketBridge = sockets
        #if RDEV_DEV_BUILD
        automation = Automation.startIfRequested(delegate: self)
        context.automation = automation
        #endif
        windows = AppWindows(context: context)
        ui.windows = windows; client.windows = windows; sockets.windows = windows
        windows.onClientClosed = { [weak client] web in client?.forget(web) }
        self.client = client
        let publisher = StatePublisher(host: host, windows: windows)
        self.publisher = publisher; ui.publisher = publisher; publisher.start()
        ui.attempts = ConnectAttempts(windows: windows) { [weak self] requestId in
            let js = "window.__rdevAppClientClosed?.(\(BridgeScripts.json(requestId)))"
            self?.windows.home?.webView.evaluateJavaScript(js)
        }
        // Ways the app can end up with no window that AppKit never asks about: the last window
        // closed while ordered out (AppKit does not count it), and an attempt that kept the app
        // alive with NO window settling — a listed Mac's pairing that failed after the dashboard
        // closed. Both re-ask the one last-window rule.
        windows.onLastWindowClosedUnseen = { [weak self] in self?.quitIfWindowless() }
        ui.attempts.onSettled = { [weak self] in self?.quitIfWindowless() }
        // And a THIRD: a passkey ceremony that kept a windowless app alive settling (ready, or back
        // to unenrolled). The publisher is what sees e2e's status move, on every tick.
        publisher.onCeremonySettled = { [weak self] in self?.quitIfWindowless() }
        // And a FOURTH: the session's last tab going (a shell exiting) in an app kept alive only by its tabs.
        publisher.onSessionEmptied = { [weak self] in self?.quitIfWindowless() }
        if !automationSkipsHome {
            let local = windows.openLocal(showWhenReady: true, motion: nil)
            if AppSettings.read(dir: profile.directory).showDashboardOnStartup {
                local.onFirstShow = { [weak windows] in windows?.openHome() }
            }
        }

        updater = HostUpdateCoordinator(host: host, profile: profile, environment: environment)
        Task { await updater?.acknowledgeRestart() }

        MainMenu.install()
        statusItem = StatusItem(host: host, windows: windows)
        SingleInstance.observeActivation(profile) { [weak self] in self?.reopen() }
        NSApp.activate()

        if ApplicationCaptureFeature.enabled,ProcessInfo.processInfo.environment["RDEV_APPS_EXPERIMENTAL"]=="1",let menu=NSApp.mainMenu?.items.first?.submenu {
            let item=NSMenuItem(title:"Restore All Shared Apps",action:#selector(restoreApps(_:)),keyEquivalent:"");item.target=self;menu.addItem(item)
        }
        // AUTO SHARE: the same startSharing() the button calls; failures LOGGED, never thrown.
        let reason = AppSettings.autoShareReason(argv: CommandLine.arguments, env: ProcessInfo.processInfo.environment,
                                                 settings: AppSettings.read(dir: profile.directory))
        if let reason, !CommandLine.arguments.contains("--rdev-update-journal") {
            Task { @MainActor in
                await host.startSharing()
                if let e = host.state()["error"] as? String { print("[main] auto-share failed: \(e)") }
                else { print("[main] auto-share requested (\(reason))") }
            }
        }
    }

    @objc func showMacs(_ sender: Any?) { windows.openHome() }

    func reopen() {
        windows.reopen()
        nativeSimulators?.bringForward()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopen(); return false
    }

    /// Sharing keeps running in the status item when the last window closes (macOS convention), and
    /// a pending connect's ORDERED-OUT client window — which AppKit does not count — keeps the app
    /// alive too, as does a passkey ceremony in flight and the session's tabs (`AppLifecycle`).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if automationKeepsAlive { return false }
        return AppLifecycle.quitsAfterLastWindowClosed(sharing: host.isSharing, clientWindows: windows.clients.count,
                                                       pendingConnects: ui.attempts?.pendingCount ?? 0,
                                                       e2eStatus: host.e2eState()["status"] as? Int ?? -1,
                                                       sessionTabs: host.sessionTabs)
    }

    /// `applicationShouldTerminateAfterLastWindowClosed`'s rule, for the cases AppKit does not ask it:
    /// quit when NO window of ours is left and nothing keeps the app alive. ASYNC: a closing client's
    /// attempt settles AFTER `onClosedInternal`, in the same `windowWillClose`, and the rule must see
    /// it settled. With a window left this is a no-op, so calling it on every settlement is safe.
    private func quitIfWindowless() {
        Task { @MainActor in
            guard self.windows.all().isEmpty, self.applicationShouldTerminateAfterLastWindowClosed(NSApp) else { return }
            NSApp.terminate(nil)
        }
    }

    /// LOAD-BEARING: save the terminal tabs, then stop sharing (which lowers the curtain first) and END THE
    /// SESSION before the process exits — its shells are killed, not orphaned. In that order: ending the
    /// session closes every tab, and a save after it would remember none.
    private var workspaceQuitPending=false
    private var workspaceQuitReady=false
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard ProcessInfo.processInfo.environment["RDEV_APPS_EXPERIMENTAL"]=="1",!workspaceQuitReady else{return .terminateNow}
        guard !workspaceQuitPending else{return .terminateLater}
        workspaceQuitPending=true
        host.restoreWorkspace(forQuit:true) { [weak self] error in
            // terminateLater runs a nested AppKit loop. A quit entered from a main-dispatch block
            // cannot drain another block on that serial queue until terminate returns.
            RunLoop.main.perform(inModes:[.common,.default,.modalPanel,.eventTracking]) {
                MainActor.assumeIsolated {
                    guard let self else{return}
                    self.workspaceQuitPending=false
                    if let error {NSApp.reply(toApplicationShouldTerminate:false);let alert=NSAlert();alert.messageText="Apps could not be restored";alert.informativeText=error;alert.runModal()}
                    else {self.workspaceQuitReady=true;NSApp.reply(toApplicationShouldTerminate:true)}
                }
            }
        }
        return .terminateLater
    }

    @objc func restoreApps(_ sender:Any?) {
        host.restoreWorkspace { error in
            if let error {DispatchQueue.main.async {let alert=NSAlert();alert.messageText="Apps could not be restored";alert.informativeText=error;alert.runModal()}}
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        windows?.saveFrames()
        terminalTabs?.stop()
        host.endSession()
        client?.cancelAll()
        pastes.purge()
        try? FileManager.default.removeItem(at: profile.archiveDirectory)
    }

    /// With the automation port on, closing the last window never quits, so a check can close the
    /// dashboard — unless the check asks for the REAL rule (`RDEV_APP_REAL_LIFECYCLE=1`, dev builds
    /// only), which is how `e2e/app-lifecycle-check.mjs` sees what a person's app would do.
    var automationKeepsAlive: Bool {
        #if RDEV_DEV_BUILD
        return automation != nil && ProcessInfo.processInfo.environment["RDEV_APP_REAL_LIFECYCLE"] != "1"
        #else
        return false
        #endif
    }

    /// `RDEV_APP_NO_HOME=1` (dev builds, automation port on): launch with NO dashboard, so a check can
    /// open a client before any dashboard page has run — deterministically, where closing the
    /// dashboard as the first command was a race its first bridge call could win
    /// (`e2e/app-lifecycle-check.mjs` arm 1).
    var automationSkipsHome: Bool {
        #if RDEV_DEV_BUILD
        return automation != nil && ProcessInfo.processInfo.environment["RDEV_APP_NO_HOME"] == "1"
        #else
        return false
        #endif
    }

    #if RDEV_DEV_BUILD
    /// The automation port's `bridge` command: dispatched through the SAME `UIBridge.dispatch` a
    /// real `postMessage` from `app://ui` reaches, so a smoke exercising `app.bridge(...)` is
    /// exercising the real handler, not a stand-in for it.
    func automationBridge(op: String, args: [Any]) async throws -> Any? {
        guard let r = BridgeRequest(body: ["op": op, "args": args]) else { throw BridgeError("malformed") }
        return try await ui.dispatch(r)
    }
    #endif
}
