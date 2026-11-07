import AppKit
import ApplicationServices
import CoreGraphics
import RdevAppHost
import RdevHostKit
import ShellstormCore

/// The retired Electron `host.ts`, typed: the sharing session this app owns, and the reads the
/// dashboard polls. Returns plain dictionaries because they cross to the page as JSON.
@MainActor
final class HostController {
    private let env: ShellEnvironment
    private var session: (code: String, token: String, pairingCode: String, connectUrl: String, qrDataUrl: String)?
    private var error: String?
    private var starting = false
    /// Which permissions this run has ASKED for — macOS cannot say ("never asked" and "declined"
    /// preflight identically). In memory: after a relaunch Grant is offered again, harmlessly.
    private var asked: Set<String> = []
    /// The adopt QR for the current carrier. Rendering one (CIFilter → PNG → base64) is not free
    /// and the publisher reads `adoptStatus()` four times a second, so it is made once per carrier.
    private var adoptQR: (carrier: String, dataURL: String)?

    init(environment: ShellEnvironment, profile: AppProfile) {
        env = environment
        // NAME THE SIGNALLING BASE ONCE, AT STARTUP. `E2EHost`'s client-facing reads —
        // `identityCode()` and `issueSubordinateGrant` behind `__rdevShell` — act on the service
        // for the last base a caller named, and until 2026-09-25 only dashboard ops named one: a
        // client window opened before the dashboard's first bridge call (the status item, auto share, a
        // dashboard closed early) read "" and "-not-enrolled" on an enrolled Mac and could not
        // certify itself. `e2e/app-lifecycle-check.mjs` arm 1. Building the service also runs its
        // once-per-process publication retry (§12.2), which is wanted at startup anyway.
        _ = E2EHost.shared.service(base: environment.signalingBase)
        // THE SESSION BELONGS TO THE APP, NOT TO SHARING (docs/desktop-app.md, "The local window"): its
        // tabs and the local window live from launch to quit, and Share only opens the door to them.
        // Its paste folder is the PROFILE's, so a second profile's launch cannot empty this one's.
        SharingHost.shared.beginSession(pasteDirectory: profile.pasteDirectory)
    }

    var updateSettingsChanged: (() -> Void)?

    var isSharing: Bool { session != nil }

    func state() -> [String: Any] {
        var s: [String: Any]
        if let error { s = ["status": -1, "error": error] }
        else if starting { s = ["status": 1] }
        else if let session {
            s = ["status": Int(SharingHost.shared.status.rawValue), "code": session.code,
                 "pairingCode": session.pairingCode, "connectUrl": session.connectUrl, "qrDataUrl": session.qrDataUrl]
        } else { s = ["status": 0] }
        // Advisory, never blocking — and NEVER the prompting variants: `StatePublisher` reads this 4× a second.
        s["permissions"] = [
            "screen": CGPreflightScreenCaptureAccess() ? "granted" : "denied",
            "accessibility": AXIsProcessTrusted(),
            "asked": ["screen": asked.contains("screen"), "accessibility": asked.contains("accessibility")],
        ]
        s["curtain"] = curtainIsUp
        return s
    }

    var updatePairingCarrier: String? { session?.pairingCode }

    func startSharing(restoringCarrier: String? = nil) async {
        if session != nil || starting { return }
        starting = true; error = nil
        defer { starting = false }
        let base = env.signalingBase
        switch await SharingHost.shared.openPairing(base: base, restoringCarrier: restoringCarrier) {
        case .failed(let why):
            error = "could not open a pairing window at \(base): \(why)"
        case .opened(let p):
            let rc = SharingHost.shared.start(base: base, code: p.code, token: p.token)
            guard rc.rawValue >= 0 else { error = "the host did not start (\(rc.rawValue))"; return }
            // THE SEED RIDES IN THE FRAGMENT (§9.1): a query would reach the Control Plane.
            let enc = ClientURL.encodeURIComponent
            let url = "\(base)/?code=\(enc(p.code))&token=\(enc(p.token))#pair=\(enc(p.carrier))"
            session = (p.code, p.token, p.carrier, url, QRImage.dataURL(url))
        }
    }

    /// The door closes: `SharingRoom.stop()` lowers the curtain first and makes every relay client leave.
    /// The session — its tabs, the local window — is untouched.
    func stopSharing() {
        guard session != nil else { return }
        SharingHost.shared.stop()
        session = nil
    }

    /// Quitting: sharing stops (the curtain first), then the session ends — every shell killed, every tmux
    /// tab detached, every socket client closed.
    func restoreWorkspace(forQuit:Bool=false,completion:@escaping @Sendable(String?)->Void) {
        SharingHost.shared.restoreWorkspace(forQuit:forQuit,completion:completion)
    }

    func endSession() { SharingHost.shared.endSession() }

    /// "This Mac": a bridge socket from the local window, into the app's own session.
    func acceptLocal(_ socket: MessageSocket) -> LocalSimulatorSession? { SharingHost.shared.acceptLocal(socket) }

    /// Open terminal tabs in the app's session — what keeps it alive with no window (`AppLifecycle`).
    var sessionTabs: Int { SharingHost.shared.tabCount }

    func setCurtain(_ on: Bool) { if session != nil { SharingHost.shared.setCurtain(on) } }
    var curtainIsUp: Bool { session != nil && SharingHost.shared.curtainIsUp }

    func accountState() -> [String: Any] {
        ["publish": session == nil ? Publication.off.rawValue : SharingHost.shared.publication.rawValue]
    }

    /// FALSE IS NOT A REFUSAL — grants usually arrive later through the state poll.
    func requestPermission(_ which: String) -> Bool {
        let bit: PermissionSet
        switch which { case "screen": bit = .screenRecording; case "accessibility": bit = .accessibility; default: return false }
        asked.insert(which)
        return SharingHost.shared.requestPermissions(bit).contains(bit)
    }

    func e2eState() -> [String: Any] {
        let host = E2EHost.shared
        return ["status": Int(host.status(base: env.signalingBase).rawValue),
                "detail": host.detail(), "identity": host.identityCode()]
    }

    /// Names and codes only — THE TOKEN NEVER REACHES THE PAGE.
    func sessions(refresh: Bool) -> [String: Any] {
        let l = E2EHost.shared.listSessions(base: env.signalingBase, refresh: refresh)
        return ["state": l.state.rawValue, "error": l.error, "refreshing": l.refreshing,
                "sessions": l.display.map { ["name": $0.name, "code": $0.code] }]
    }

    /// The pairing query for a listed Mac, resolved from a fresh read of the listing.
    func pairingForSession(code: String) throws -> String {
        let l = E2EHost.shared.listSessions(base: env.signalingBase, refresh: false)
        guard let row = l.display.first(where: { $0.code == code }) else {
            throw BridgeError("This Mac is no longer sharing. Refresh your devices.")
        }
        let enc = ClientURL.encodeURIComponent
        return "?code=\(enc(row.code))&token=\(enc(row.token))"
    }

    /// The Add device dialog's run (`AddDeviceHost`), or nil while none has started since the last close.
    func addDeviceStatus() -> Any? {
        let s = AddDeviceHost.shared.status()
        guard s.phase != "idle" else { return nil }
        var o: [String: Any] = ["phase": s.phase]
        if let v = s.identity { o["identity"] = v }
        if let v = s.reason { o["reason"] = v }
        if let v = s.publication { o["publication"] = v }
        return o
    }

    func adoptStatus() -> Any {
        let s = AdoptHost.shared.status()
        var o: [String: Any] = ["phase": s.phase]
        if let c = s.carrier {
            o["carrier"] = c
            // THE SEED RIDES THE FRAGMENT, which no browser transmits.
            let qr = adoptQR?.carrier == c ? adoptQR!.dataURL : QRImage.dataURL("\(env.signalingBase)/#adopt=\(c)")
            adoptQR = (c, qr)
            o["qrDataUrl"] = qr
        }
        if let c = s.code { o["code"] = c }
        if let r = s.reason { o["reason"] = r }
        return o
    }

    func issueGrant(_ keys: String) -> String { E2EHost.shared.issueSubordinateGrant(keysB64: keys) }
}
