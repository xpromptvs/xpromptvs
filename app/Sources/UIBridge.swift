import AppKit
import RdevAppHost
import ShellstormCore
import WebKit

/// `window.rdevApp` — every `ipcMain.handle("app:*")` from the retired Electron `index.ts`, same
/// argument checks, same results. Only the HOME window's controller has this handler, and it
/// checks the frame too: main frame of `app://ui`, nothing else.
@MainActor
final class UIBridge: NSObject, WKScriptMessageHandlerWithReply {
    let host: HostController
    let profile: AppProfile
    /// The control plane's base URL, as the delegate already resolved it once at launch — ONE
    /// source of truth, rather than a second `ShellEnvironment(env: ProcessInfo...)` read here that
    /// could disagree with the one `HostController` and the client bridge were built from.
    let environment: ShellEnvironment
    var attempts: ConnectAttempts!
    weak var windows: AppWindows?
    /// Pushes state to the page (`subscribe`); nudged after every op that mutates it.
    var publisher: StatePublisher!
    /// The Mac's own passkey prompt, on the dashboard that asked (`PasskeyAuthorizer`).
    lazy var passkeys = PasskeyAuthorizer { [weak self] in self?.windows?.home?.window ?? NSApp.keyWindow }

    init(host: HostController, profile: AppProfile, environment: ShellEnvironment) {
        self.host = host; self.profile = profile; self.environment = environment
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) async -> (Any?, String?) {
        let o = m.frameInfo.securityOrigin
        guard m.frameInfo.isMainFrame, o.protocol == "app", o.host == "ui" else { return (nil, "refused") }
        guard let r = BridgeRequest(body: m.body) else { return (nil, "malformed") }
        if r.op == "setChromeGap" {
            guard let web = m.webView, let home = windows?.home, home.webView === web,
                  let left = r.int(0, in: 0...100_000), let right = r.int(1, in: 0...100_000),
                  let width = r.int(2, in: 0...100_000) else { return (nil, "malformed") }
            home.setChromeGap(ChromeGap(left: Double(left), right: Double(right), width: Double(width)))
            return (nil, nil)
        }
        do { return (try await dispatch(r), nil) } catch { return (nil, error.localizedDescription) }
    }

    func dispatch(_ r: BridgeRequest) async throws -> Any? {
        let result = try await perform(r)
        switch r.op {
        case "share", "stop", "curtain", "setAutoShare", "setSmoothScroll", "e2eSignIn", "e2eCreatePasskey",
             "e2eAuthorise", "adoptStart", "adoptCancel", "e2eForget", "requestPermission",
             "addDeviceStart", "addDeviceConfirm", "addDeviceCancel":
            publisher.nudge()
        default: break
        }
        return result
    }

    private func perform(_ r: BridgeRequest) async throws -> Any? {
        switch r.op {
        case "subscribe": return publisher.subscribe()
        case "state": return host.state()
        case "launchStartup": return AppSettings.read(dir: profile.directory).showDashboardOnStartup
        case "setLaunchStartup": return try AppSettings.update(dir: profile.directory) { $0.showDashboardOnStartup = r.bool(0) }.showDashboardOnStartup
        case "dismissDashboard":
            windows?.home?.close()
            windows?.openLocal(showWhenReady: true, motion: nil)
            return nil
        case "openSharing": windows?.openSharing(); return nil
        case "share": await host.startSharing(); return nil
        case "settings":
            let s = AppSettings.read(dir: profile.directory)
            return ["autoShare": s.autoShare, "allowRemoteUpdates": s.allowRemoteUpdates]
        case "setAllowRemoteUpdates":
            let s = try AppSettings.update(dir: profile.directory) { $0.allowRemoteUpdates = r.bool(0) }
            host.updateSettingsChanged?()
            return ["allowRemoteUpdates": s.allowRemoteUpdates]
        case "setAutoShare":
            // ONE key: `AppSettings(autoShare:)` written whole would reset smooth scrolling.
            return ["autoShare": try AppSettings.update(dir: profile.directory) { $0.autoShare = r.bool(0) }.autoShare]
        case "smoothScroll": return SmoothScrollSetting.read(profile)
        case "setSmoothScroll": return try SmoothScrollSetting.write(r.bool(0), profile: profile, windows: windows)
        case "stop": host.stopSharing(); return nil
        case "curtain": host.setCurtain(r.bool(0)); return nil
        case "openClient":
            let pairing = r.pairing(0)
            try await attempts.connect(requestId: r.string(1), motion: r.motion(2)) { pairing }
            return nil
        case "openLocal":
            try await attempts.connectLocal(requestId: r.string(0), motion: r.motion(1))
            return nil
        case "connectSession":
            guard let code = r.string(0) else { throw BridgeError("Invalid device") }
            try await attempts.connect(requestId: r.string(1), motion: r.motion(2)) { [host] in
                try host.pairingForSession(code: code)
            }
            return nil
        case "cancelConnect":
            if let id = r.string(0) { attempts.cancel(requestId: id) }
            return nil
        case "sessions": return host.sessions(refresh: r.bool(0))
        case "openPermission":
            let pane = r.string(0) == "screen" ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
            return NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        case "requestPermission": return host.requestPermission(r.string(0) ?? "")
        case "e2eState": return host.e2eState()
        // The passkey ceremonies resolve when the prompt does, with the panel's outcome — no browser,
        // no courier, nothing to poll for (`docs/e2e.md`, "The Mac's own passkey ceremony").
        case "e2eSignIn": return await E2EHost.shared.signIn(base: environment.signalingBase, authenticator: passkeys).json
        case "e2eCreatePasskey":
            return await E2EHost.shared.createPasskey(base: environment.signalingBase, authenticator: passkeys).json
        case "e2eAuthorise": return await E2EHost.shared.authorise(base: environment.signalingBase, authenticator: passkeys).json
        // Asked when the panel opens — a file read, so never part of the state pushed every tick.
        case "e2ePending": _ = E2EHost.shared.service(base: environment.signalingBase); return E2EHost.shared.hasPendingRoot()
        case "e2eCapabilities": return Int(E2EHost.shared.capabilities())
        case "adoptStart": return AdoptHost.shared.start(base: environment.signalingBase)
        case "adoptStatus": return host.adoptStatus()
        case "adoptCancel": return AdoptHost.shared.cancel()
        // ADD DEVICE BY CODE — this Mac adds a new one (docs/pairing.md, "Add device by code"): the dialog starts
        // it with the code typed, answers "Add this Mac?", and follows `addDevice` in the pushed state.
        case "addDeviceStart":
            guard let carrier = r.string(0) else { throw BridgeError("Invalid code") }
            return AddDeviceHost.shared.start(base: environment.signalingBase, carrier: carrier, authenticator: passkeys)
        case "addDeviceConfirm": return AddDeviceHost.shared.confirm(r.bool(0))
        case "addDeviceCancel": return AddDeviceHost.shared.cancel()
        case "e2eForget": return E2EHost.shared.forget()
        case "accountState": return host.accountState()
        default: throw BridgeError("unknown op \(r.op)")
        }
    }
}
