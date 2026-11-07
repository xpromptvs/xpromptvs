import AppKit
import RdevAppHost
import RdevCore
import ShellstormCore
import UniformTypeIdentifiers
import WebKit

/// `__rdevShell`'s calls, for `app://client` only. §10.3: two PUBLIC keys in, a connect-only chain
/// out; a refusal is a `-`-prefixed reason, never a throw. `request` is the exception: it answers
/// like `fetch`, so a refusal REJECTS (`WorkerRequest`, `docs/desktop-app.md`).
@MainActor
final class ClientBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var nativeSimulators: NativeSimulatorWindows?
    weak var windows: AppWindows?
    let host: HostController
    let profile: AppProfile
    let environment: ShellEnvironment
    /// What a page asked to send of what Finder copied, until it fetches it (`SchemeHandler`'s `__paste` route).
    let pastes: PreparedPastes
    /// Per web view, the paths the pasteboard last offered it: only those may be PREPARED — a page cannot have
    /// the app zip or serve a path it was never handed.
    private var offered: [ObjectIdentifier: Set<String>] = [:]
    /// Per web view, the zips it is having made: `cancelPaste`, its window closing and the app quitting kill them.
    private var jobs: [ObjectIdentifier: [ZipJob]] = [:]
    init(host: HostController, profile: AppProfile, environment: ShellEnvironment, pastes: PreparedPastes) {
        self.host = host; self.profile = profile; self.environment = environment; self.pastes = pastes
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) async -> (Any?, String?) {
        let o = m.frameInfo.securityOrigin
        guard m.frameInfo.isMainFrame, o.protocol == "app", o.host == "client" else { return (nil, "refused") }
        guard let r = BridgeRequest(body: m.body) else { return (nil, "malformed") }
        switch r.op {
        case "nativeSourceWindowsInfo", "syncSourceWindows", "prepareSourceWindow", "resetSourceWindows", "sourceWindowCommand":
            guard let web = m.webView, let owner = windows?.clientFor(webView: web),
                  owner !== windows?.local, let sources = owner.sourceWindows,
                  NativeSourceDocument.permitsOwner(url: m.frameInfo.request.url, mainFrame: true, remoteOwner: true) else { return (nil, "remote-owner-required") }
            do {
                switch r.op {
                case "nativeSourceWindowsInfo": return (sources.info, nil)
                case "syncSourceWindows":
                    guard let object = r.object(0), let manifest = NativeSourceWindowManifest.parse(object) else { return (nil, "malformed-source-manifest") }
                    return (try sources.synchronize(manifest), nil)
                case "prepareSourceWindow":
                    guard let source = r.string(0), let generation = r.int(1, in: 1...9_007_199_254_740_991) else { return (nil, "malformed-source-prepare") }
                    return (try sources.prepare(source: source, generation: UInt64(generation)), nil)
                case "resetSourceWindows":
                    guard let generation = r.int(0, in: 1...9_007_199_254_740_991), UInt64(generation) == sources.generation else { return (nil, "stale-source-generation") }
                    sources.reset(reason: "owner-reset"); return (sources.info, nil)
                default:
                    guard let object = r.object(0), let key = sources.key(object), let command = r.string(1) else { return (nil, "malformed-source-command") }
                    try sources.command(key: key, name: command, request: r); return (true, nil)
                }
            } catch { return (nil, error.localizedDescription) }
        case "activateSimulator", "simulatorTheme":
            guard let web = m.webView, windows?.local?.webView === web, let value = r.string(0) else { return (nil, "refused") }
            if r.op == "activateSimulator" { nativeSimulators?.activate(source: value) }
            else { nativeSimulators?.setTheme(value) }
            return (nil, nil)
        case "connectionState":
            guard let state = r.string(0), let web = m.webView else { return (nil, nil) }
            windows?.clientFor(webView: web)?.onConnectionState?(state, r.string(1))
            return (nil, nil)
        case "openMacs":
            windows?.openHome()
            return (nil, nil)
        case "e2eIdentity": return (E2EHost.shared.identityCode(), nil)
        case "issueGrant":
            guard let keys = r.string(0) else { return ("-malformed-device", nil) }
            return (host.issueGrant(keys), nil)
        case "request": return await request(r)
        // The page's full-screen window mode, as the WINDOW's macOS full screen (`FullScreenOwnership`).
        case "setChromeGap":
            guard let web = m.webView, let left = r.int(0, in: 0...100_000),
                  let right = r.int(1, in: 0...100_000), let width = r.int(2, in: 0...100_000) else { return (nil, "malformed") }
            windows?.clientFor(webView: web)?.chrome.setGap(ChromeGap(left: Double(left), right: Double(right), width: Double(width)))
            return (nil, nil)
        case "setFullscreen":
            guard let web = m.webView else { return (nil, nil) }
            windows?.clientFor(webView: web)?.pageAsksFullScreen(r.bool(0))
            return (nil, nil)
        // Whether the app is SHARING — This Mac's status bar says "remote access enabled" (2026-10-04). Asked once
        // as a page starts; every change after is pushed (`StatePublisher`, `__rdevSharing`).
        case "sharing": return (host.isSharing, nil)
        // The app's ONE smooth-scrolling value, shared with the dashboard (`SmoothScrollSetting`).
        case "smoothScroll": return (SmoothScrollSetting.read(profile), nil)
        case "setSmoothScroll":
            do { return (try SmoothScrollSetting.write(r.bool(0), profile: profile, windows: windows), nil) }
            catch { return (nil, error.localizedDescription) }
        // WHAT FINDER COPIED (docs/client-web.md, "A folder"): a page is never told a path, and a FOLDER reaches
        // it as a 0-byte file — so the app reads the pasteboard, and makes what a paste to another Mac sends.
        case "pasteboardFiles":
            guard let web = m.webView else { return ([Any](), nil) }
            let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let files = LocalPastes.files(urls)
            offered[ObjectIdentifier(web)] = Set(files.map(\.path))
            return (files.map(\.json), nil)
        case "writeClipboard":
            guard r.count == 1, let text = r.string(0), text.utf8.count <= TermClipboard.maxBytes,
                  let web = m.webView, let owner = windows?.clientFor(webView: web), owner.window.isKeyWindow else { return (nil, "clipboard-unavailable") }
            // Only the exact trusted owner document, on main. Source-only children do not expose this op.
            NSPasteboard.general.clearContents()
            return (NSPasteboard.general.setString(text, forType: .string), nil)
        case "preparePaste":
            guard let web = m.webView, let paths = r.strings(0), !paths.isEmpty else { return ("-malformed", nil) }
            guard paths.allSatisfy((offered[ObjectIdentifier(web)] ?? []).contains) else { return ("-not-offered", nil) }
            let key = ObjectIdentifier(web), job = ZipJob()
            jobs[key, default: []].append(job)
            defer { jobs[key]?.removeAll { $0 === job } }
            return (await prepare(paths, owner: AnyHashable(key), job: job), nil)
        case "discardPaste":
            guard let web = m.webView, let urls = r.strings(0) else { return (nil, nil) }
            pastes.discard(urls: urls, owner: AnyHashable(ObjectIdentifier(web)))
            return (nil, nil)
        // Stop sending while the app compresses: the zip is killed, and its `preparePaste` answers `-cancelled`.
        case "cancelPaste":
            guard let web = m.webView else { return (nil, nil) }
            jobs[ObjectIdentifier(web)]?.forEach { $0.cancel() }
            return (nil, nil)
        // THE BELL (docs/desktop-app.md, "The bell"): this window's count of terminal tabs with an unseen bell.
        case "setBell":
            guard let web = m.webView, let count = r.int(0, in: 0...BellBadge.maxCount) else { return (nil, "malformed") }
            if let windows, let client = windows.clientFor(webView: web) { windows.setBell(count, for: client) }
            return (nil, nil)
        // "This Mac"'s Disconnect closes its window. On the next turn: not from inside the web view's own message.
        case "closeWindow":
            guard let web = m.webView, let client = windows?.clientFor(webView: web) else { return (nil, nil) }
            DispatchQueue.main.async { client.close() }
            return (nil, nil)
        default: return (nil, "unknown op \(r.op)")
        }
    }

    /// Each path made sendable, OFF the main thread: a folder zipped as Finder's Compress makes it (into its own
    /// folder under the profile's `archiveDirectory`), a file registered as it is. `[{url, name, type, size}]`,
    /// or a `-`-prefixed reason with nothing left registered.
    /// A zip is STOPPED past the delivery cap (`ZipError.tooLarge` → `-too-large`), never made whole first.
    private func prepare(_ paths: [String], owner: AnyHashable, job: ZipJob) async -> Any {
        let archives = profile.archiveDirectory
        let pastes = self.pastes
        let out: Result<[[String: Any]], Error> = await Task.detached {
            var made: [[String: Any]] = []
            do {
                for path in paths {
                    let u = URL(fileURLWithPath: path)
                    var dir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &dir) else { throw BridgeError("gone") }
                    let file: URL, name: String, type: String
                    if dir.boolValue {
                        let into = archives.appendingPathComponent(UUID().uuidString)
                        do {
                            file = try LocalPastes.zip(folder: u, into: into, limit: Int64(PasteLimits.fileMaxBytes), job: job)
                        } catch {
                            try? FileManager.default.removeItem(at: into)
                            throw error
                        }
                        // On disk `archive.zip` (NAME_MAX); shown and sent as the folder's own name.
                        name = u.lastPathComponent + ".zip"
                        type = "application/zip"
                    } else {
                        file = u
                        name = u.lastPathComponent
                        type = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? ""
                    }
                    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                    let url = pastes.add(file: file, name: name, type: type, temporary: dir.boolValue, owner: owner)
                    made.append(["url": url, "name": name, "type": type, "size": size])
                }
                return .success(made)
            } catch {
                pastes.discard(urls: made.compactMap { $0["url"] as? String }, owner: owner)
                return .failure(error)
            }
        }.value
        switch out {
        case .success(let files): return files
        case .failure(LocalPastes.ZipError.tooLarge): return "-too-large"
        case .failure(LocalPastes.ZipError.cancelled): return "-cancelled"
        case .failure(let e as BridgeError): return "-\(e.message)"
        case .failure(let e): return "-\(e)"
        }
    }

    /// A client window has CLOSED: its zips in the making are killed, what it never read is deleted, and what the
    /// pasteboard offered it is forgotten — a later web view at the same address inherits none of it.
    func forget(_ web: WKWebView) {
        let key = ObjectIdentifier(web)
        jobs.removeValue(forKey: key)?.forEach { $0.cancel() }
        offered[key] = nil
        pastes.purge(owner: AnyHashable(key))
    }

    /// The app is quitting: every zip in the making is killed, so no `ditto` outlives it.
    func cancelAll() {
        for list in jobs.values { list.forEach { $0.cancel() } }
        jobs.removeAll()
    }

    /// Validated BEFORE anything leaves the process, and the URL is rebuilt from the parsed route on
    /// the app's own signalling origin — the page supplies a path, never an origin. Nothing is
    /// logged: a `list` answer carries room tokens.
    private func request(_ r: BridgeRequest) async -> (Any?, String?) {
        guard r.count == 3, let path = r.string(0), let method = r.string(1) else {
            return (nil, "refused: malformed request")
        }
        let body = r.string(2)
        if body == nil, !r.isNull(2) { return (nil, "refused: body must be text") }
        let route: WorkerRequest.Route
        switch WorkerRequest.validate(method: method, path: path) {
        case .failure(let why): return (nil, why.reason)
        case .success(let ok): route = ok
        }
        if let why = WorkerRequest.checkBody(body, route: route) { return (nil, why.reason) }
        guard let url = WorkerRequest.url(base: environment.signalingBase, route: route) else {
            return (nil, WorkerRequest.Refusal.base.reason)
        }
        switch await WorkerHTTP.shared.perform(url: url, method: route.method, body: body) {
        case .success(let a):
            var reply: [String: Any] = ["status": a.status, "body": a.body]
            if let type = a.contentType { reply["headers"] = ["content-type": type] }
            return (reply, nil)
        case .failure(let e): return (nil, e.message)
        }
    }
}
