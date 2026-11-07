import AppKit
import ShellstormCore
import WebKit

@MainActor
class AppWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private static var nextID = 1
    let id: Int
    let kind: WindowKind
    let window: NSWindow
    let webView: WKWebView
    var onClosedInternal: ((AppWindow) -> Void)?
    var onFocused: ((AppWindow) -> Void)?

    init(kind: WindowKind, window: NSWindow, webView: WKWebView) {
        id = Self.nextID; Self.nextID += 1
        self.kind = kind; self.window = window; self.webView = webView
        super.init()
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(red: 0x20 / 255, green: 0x20 / 255, blue: 0x1f / 255, alpha: 1)
        webView.navigationDelegate = self
    }

    func load(_ url: String) { webView.load(URLRequest(url: URL(string: url)!)) }
    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    func close() { window.close() }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }
    func windowDidBecomeKey(_ n: Notification) { onFocused?(self); keyChanged(true) }
    func windowDidResignKey(_ n: Notification) { keyChanged(false) }
    func windowWillClose(_ n: Notification) { willClose(); onClosedInternal?(self); closed() }
    func windowWillMiniaturize(_ n: Notification) { willMiniaturize() }
    func windowDidMiniaturize(_ n: Notification) { miniaturized(true) }
    func windowDidDeminiaturize(_ n: Notification) { miniaturized(false) }
    func windowDidChangeOcclusionState(_ n: Notification) { visibilityChanged() }
    func windowDidResize(_ n: Notification) { geometryChanged(resized: true) }
    func windowDidMove(_ n: Notification) { geometryChanged(resized: false) }
    func windowWillStartLiveResize(_ n: Notification) { liveResizeChanged(true) }
    func windowDidEndLiveResize(_ n: Notification) { liveResizeChanged(false) }
    // Full screen's transitions, from ANY source — the page's request, the green button.
    func windowWillEnterFullScreen(_ n: Notification) { fullScreenWillChange() }
    func windowWillExitFullScreen(_ n: Notification) { fullScreenWillChange() }
    func windowDidEnterFullScreen(_ n: Notification) { fullScreenDidChange(failed: false) }
    func windowDidExitFullScreen(_ n: Notification) { fullScreenDidChange(failed: false) }
    func windowDidFailToEnterFullScreen(_ w: NSWindow) { fullScreenDidChange(failed: true) }
    func windowDidFailToExitFullScreen(_ w: NSWindow) { fullScreenDidChange(failed: true) }

    // The delegate methods live HERE, on the class that declares the conformance, and forward to
    // overridable hooks: an optional ObjC protocol method implemented only in a Swift SUBCLASS is
    // not guaranteed to be visible to WebKit.
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { navigationPolicy(action, decisionHandler: decisionHandler) }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { didCommitLoad() }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { didFinishLoad() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: any Error) { loadFailed(e) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: any Error) { loadFailed(e) }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { processGone() }

    func navigationPolicy(_ action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(.allow) }
    func shouldClose() -> Bool { true }
    func willClose() {}
    func keyChanged(_ value: Bool) {}
    func willMiniaturize() {}
    func miniaturized(_ value: Bool) { visibilityChanged() }
    func visibilityChanged() {}
    func geometryChanged(resized: Bool) {}
    func liveResizeChanged(_ held: Bool) {}
    func didCommitLoad() {}
    func didFinishLoad() {}
    func loadFailed(_ e: any Error) {}
    func processGone() {}
    func closed() {}
    func fullScreenWillChange() {}
    func fullScreenDidChange(failed: Bool) {}
}

@MainActor
final class HomeWindow: AppWindow {
    private var chrome: ClientChrome!
    func setChromeGap(_ gap: ChromeGap) { chrome.setGap(gap) }
    override init(kind: WindowKind, window: NSWindow, webView: WKWebView) {
        super.init(kind: kind, window: window, webView: webView)
        chrome = ClientChrome(window: window, webView: webView)
        window.contentView = chrome
        chrome.onZoom = { [weak window] in window?.zoom(nil) }
        chrome.onToggleFullScreen = { [weak window] in window?.toggleFullScreen(nil) }
    }
    private var shown = false
    /// `ready-to-show`: reveal once the first navigation paints, not before.
    override func didFinishLoad() { if !shown { shown = true; show() } }
    /// A dashboard that fails to load must not leave the app with NO window and NO log: say why, and
    /// show the window anyway, so there is something to close or reopen. A superseded navigation
    /// (NSURLErrorCancelled) is routine and says nothing.
    override func loadFailed(_ e: any Error) {
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        print("[home] load failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        if !shown { shown = true; show() }
    }
    /// A dead web content process (a crash, a jetsam) left a blank dashboard that nothing pushed to
    /// again. Reloading is enough: the new page resubscribes and paints the current state
    /// (`e2e/app-push-check.mjs` arm 6).
    override func processGone() {
        print("[home] web content process terminated; reloading")
        webView.reload()
    }
}

@MainActor
final class ClientWindow: AppWindow, WKUIDelegate {
    var sourceWindows: NativeSourceWindows?
    var onFirstShow: (() -> Void)?
    var showWhenReady = true
    var onClosed: (() -> Void)?
    var onGone: (() -> Void)?
    /// The page is gone — closed, or its process dead: its bridge sockets go with it (`SocketBridge.pageEnded`).
    var onPageEnded: (() -> Void)?
    var onLoadFailed: ((ConnectFailure) -> Void)?
    var onConnectionState: ((String, String?) -> Void)?
    /// The window's own title — "Xpromptvs", "This Mac" — which a bell prefixes (`BellBadge.title`).
    var baseTitle = ""
    /// The page this window held is gone — a new one committed (a reload), or its process died: whatever it
    /// reported to the app (its bells) goes with it.
    var onPageReset: (() -> Void)?
    private var shown = false
    /// The page's web content process DIED (a crash, a jetsam) and nothing has loaded since: the window is
    /// blank and carries no session. `connectLocal` treats such a This Mac window as ABSENT — it is not
    /// reloaded by `processGone`, because a reload is a `connect` and would take control from a phone.
    private(set) var pageGone = false
    /// The page's full-screen window mode, made the WINDOW's full screen (`FullScreenOwnership`).
    private var fullScreen = FullScreenOwnership()
    private(set) var chrome: ClientChrome!
    /// Expand/restore, in lockstep with the page (docs/desktop-app.md, "Expand and restore").
    private(set) var zoom: LockstepZoom!
    private var normalFrame: NSRect?
    private var zoomed = false
    private var zoomAnimating = false
    private var resizeGeneration = 0
    private var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    override init(kind: WindowKind, window: NSWindow, webView: WKWebView) {
        super.init(kind: kind, window: window, webView: webView)
        webView.uiDelegate = self
        chrome = ClientChrome(window: window, webView: webView)
        window.contentView = chrome
        zoom = LockstepZoom(window: window, chrome: chrome)
        chrome.onZoom = { [weak self] in self?.animateZoom() }
        chrome.onToggleFullScreen = { [weak self] in
            self?.toggleNativeFullScreen()
        }
    }

    /// The page acknowledges the hold BEFORE the first animated layout. Only costly size reactions
    /// are held; WKWebView and all of its chrome continue to reflow on every animation frame.
    private func beginResize(_ run: @escaping @MainActor () -> Void) {
        webView.evaluateJavaScript("window.__rdevWindowResize?.(true)") { _, _ in run() }
    }

    private func toggleNativeFullScreen() {
        beginResize { [weak self] in
            guard let self else { return }
            self.window.toggleFullScreen(nil)
            // AppKit may decline a toggle without emitting any transition callbacks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.fullScreen.running, !self.zoomAnimating else { return }
                self.webView.evaluateJavaScript("window.__rdevWindowResize?.(false)")
            }
        }
    }

    func animateZoom() {
        guard !isFullScreen, !fullScreen.running, let screen = window.screen else { return }
        if !zoomed && !zoomAnimating { normalFrame = window.frame }
        zoomAnimating = true
        zoomed.toggle()
        let target = zoomed ? screen.visibleFrame : (normalFrame ?? window.frame)
        resizeGeneration += 1
        let generation = resizeGeneration
        zoom.cancel()   // a reversal starts from where the window is NOW
        beginResize { [weak self] in
            guard let self, generation == self.resizeGeneration else { return }
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
            self.zoom.run(to: target, duration: duration) { [weak self] in
                guard let self, generation == self.resizeGeneration else { return }
                self.zoomAnimating = false
                self.webView.evaluateJavaScript("window.__rdevWindowResize?.(false)")
            }
        }
    }

    override func didCommitLoad() { sourceWindows?.reset(reason: "owner-reload"); chrome.setGap(.none); chrome.setPictureFullScreen(false); onPageReset?() }
    override func didFinishLoad() {
        // A NEW page (a reload): the old one's full screen has nobody left to press Exit.
        apply(fullScreen.pageGone(isFullScreen: isFullScreen))
        pageGone = false
        if showWhenReady && !shown { shown = true; show(); let callback = onFirstShow; onFirstShow = nil; callback?() }
    }
    /// NSURLErrorCancelled is the -3 (ERR_ABORTED) of WebKit: a superseded navigation, routine.
    override func loadFailed(_ e: any Error) {
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        onLoadFailed?(.load(domain: ns.domain, code: ns.code, description: ns.localizedDescription))
    }
    override func processGone() {
        sourceWindows?.reset(reason: "owner-process")
        // A dead page cannot press Exit: its full screen goes with it, or the screen stays a blank window.
        apply(fullScreen.pageGone(isFullScreen: isFullScreen))
        chrome.setPictureFullScreen(false)
        pageGone = true
        onPageReset?()
        onGone?()
        onPageEnded?()
    }
    override func willClose() { sourceWindows?.reset(reason: "owner-closed", advance: false) }
    override func keyChanged(_ value: Bool) { sourceWindows?.ownerVisibilityChanged() }
    override func visibilityChanged() { sourceWindows?.ownerVisibilityChanged() }
    override func closed() { zoom.cancel(); onClosed?(); onPageEnded?() }

    /// The page's full-screen window mode came on (true) or went (false) — `__rdevShell.setFullscreen`.
    func pageAsksFullScreen(_ on: Bool) {
        chrome.setPictureFullScreen(on)
        apply(fullScreen.pageAsks(on, isFullScreen: isFullScreen))
    }

    private func apply(_ action: FullScreenOwnership.Action) {
        guard action == .toggle else { return }
        let id = fullScreen.requestID
        toggleNativeFullScreen()
        // A toggle AppKit declines begins nothing; left pending it would refuse every later ask.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.fullScreen.toggleIgnored(id: id, isFullScreen: self.isFullScreen)
        }
    }
    override func fullScreenWillChange() {
        resizeGeneration += 1
        zoom.cancel()
        zoomAnimating = false
        fullScreen.began()
        webView.evaluateJavaScript("window.__rdevWindowResize?.(true)")
    }
    override func fullScreenDidChange(failed: Bool) {
        webView.evaluateJavaScript("window.__rdevWindowResize?.(false)")
        let landing = fullScreen.landed(isFullScreen: isFullScreen, failed: failed)
        // The person left full screen with the page's mode on (the green button): the mode follows them out.
        if landing.pageLost {
            chrome.setPictureFullScreen(false)
            webView.evaluateJavaScript("window.__rdevFullscreenLeft?.()")
        }
        // ON THE NEXT TURN, never inside the delegate call, and DECIDED THEN: AppKit is still finishing the
        // transition that just landed, and a toggle from `windowDidEnterFullScreen` itself was ignored
        // (measured by `e2e/app-fullscreen-check.mjs`: Exit pressed during the animation left the window
        // full screen); and the page may change its mind again before the turn comes.
        guard landing.settle else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.apply(self.fullScreen.settle(isFullScreen: self.isFullScreen))
        }
    }

    /// The client's QR scanner (`getUserMedia`). WITHOUT this delegate WebKit denies silently.
    /// Only the client origin may ask, and macOS still shows its own camera prompt.
    /// A page's `window.open` — a terminal link (web/src/client/term-links.ts): no window of ours; an http or https
    /// URL goes to the default browser (`ExternalLink`), anything else nowhere. WebKit asks only for an open a
    /// user gesture made (`javaScriptCanOpenWindowsAutomatically` is off).
    func webView(_ w: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let sources = sourceWindows, sources.hasPending {
            return sources.create(from: w, configuration: configuration, action: action)
        }
        if let url = ExternalLink.openable(action.request.url) { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ w: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == "app" && origin.host == "client" && type == .camera ? .prompt : .deny)
    }
}

@MainActor
final class AppWindows {
    var context: WebContext
    private(set) var sharing: HomeWindow?
    private(set) var home: HomeWindow?
    private(set) var clients: [ClientWindow] = []
    /// "This Mac" — the ONE local window, while it exists (docs/desktop-app.md, "The local window").
    private(set) var local: ClientWindow?
    private weak var lastActive: AppWindow?
    /// The LAST window closed while it was never on screen (ordered out, not minimized). AppKit asks
    /// `applicationShouldTerminateAfterLastWindowClosed` only when a window it COUNTS closes, and it
    /// does not count an ordered-out one — so without this a pending client closed after the
    /// dashboard left a windowless app that nothing would ever quit.
    var onLastWindowClosedUnseen: (() -> Void)?

    init(context: WebContext) { self.context = context }

    func all() -> [AppWindow] { (home.map { [$0] } ?? []) + (sharing.map { [$0] } ?? []) + clients + clients.flatMap { $0.sourceWindows?.all ?? [] } }
    func find(id: Int) -> AppWindow? { all().first { $0.id == id } }
    func clientFor(webView: WKWebView) -> ClientWindow? { clients.first { $0.webView === webView } }
    /// A client window closed — what its page left with the app goes (`ClientBridge.forget`).
    var onClientClosed: ((WKWebView) -> Void)?
    /// Every client window's unseen terminal bells (docs/desktop-app.md, "The bell").
    private var bells = BellBadge()

    /// `c`'s page has `count` terminal tabs with an unseen bell (`__rdevShell.setBell`): its title says so, the
    /// Dock's badge shows every window's sum, and a count that GREW — a tab newly unseen — asks for attention
    /// while another app is in front (one bounce: `.informationalRequest`).
    func setBell(_ count: Int, for c: ClientWindow) {
        let news = bells.set(count, for: c.id)
        c.window.title = BellBadge.title(c.baseTitle, ringing: count > 0)
        NSApp.dockTile.badgeLabel = bells.label
        if news && !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func frameName(_ role: String) -> String {
        "Xpromptvs.\(context.profile.dataStoreID.uuidString).\(role)"
    }

    /// Let AppKit persist the frame and adjust restoration for the current screen arrangement.
    /// Roles do not share geometry; profile UUIDs also separate staging/public and test profiles.
    private func restoreFrame(_ window: NSWindow, role: String) {
        let name = frameName(role)
        _ = window.setFrameUsingName(name)
        _ = window.setFrameAutosaveName(name)
    }

    private func saveFrame(_ window: NSWindow) {
        let name = window.frameAutosaveName
        // The native full-screen frame is temporary; keep AppKit's last ordinary frame.
        if !name.isEmpty && !window.styleMask.contains(.fullScreen) { window.saveFrame(usingName: name) }
    }

    func saveFrames() { for page in all() { saveFrame(page.window) } }

    private func track(_ w: AppWindow) {
        w.onFocused = { [weak self] w in self?.lastActive = w }
        w.onClosedInternal = { [weak self] w in
            guard let self else { return }
            self.saveFrame(w.window)
            // Release the name before an immediate reopen can allocate the same role/slot.
            _ = w.window.setFrameAutosaveName("")
            let unseen = !w.window.isVisible && !w.window.isMiniaturized
            if self.lastActive === w { self.lastActive = nil }
            if self.home === w { self.home = nil }
            if self.sharing === w { self.sharing = nil }
            if self.local === w { self.local = nil }
            if let c = w as? ClientWindow {
                self.onClientClosed?(c.webView)
                self.bells.remove(c.id)
                NSApp.dockTile.badgeLabel = self.bells.label
            }
            self.clients.removeAll { $0 === w }
            if unseen && self.all().isEmpty { self.onLastWindowClosedUnseen?() }
        }
    }

    @discardableResult
    func openHome() -> HomeWindow {
        if let home { home.show(); return home }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true   // Electron's titleBarStyle: "hiddenInset"
        win.titleVisibility = .hidden
        win.minSize = NSSize(width: 480, height: 520)
        win.title = "Macs"
        win.center()
        let h = HomeWindow(kind: .home, window: win, webView: WebViewFactory.make(kind: .home, context: context))
        restoreFrame(win, role: "home")
        track(h); home = h
        h.load("app://ui/index.html?view=launch")
        return h
    }

    @discardableResult
    func openSharing() -> HomeWindow {
        if let sharing { sharing.show(); return sharing }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 800),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.minSize = NSSize(width: 440, height: 520)
        win.title = "Sharing"
        win.center()
        let page = HomeWindow(kind: .home, window: win, webView: WebViewFactory.make(kind: .home, context: context))
        restoreFrame(win, role: "sharing")
        track(page); sharing = page
        page.load("app://ui/index.html?view=share")
        return page
    }

    private func makeClient(title: String, showWhenReady: Bool, frameRole: String, nativeSources: Bool = true) -> ClientWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = false
        win.title = title
        win.center()
        let c = ClientWindow(kind: .client, window: win, webView: WebViewFactory.make(kind: .client, context: context))
        if nativeSources {
            let sources = NativeSourceWindows(owner: c, context: context)
            sources.onCreated = { [weak self] source in self?.track(source) }
            c.sourceWindows = sources
        }
        c.showWhenReady = showWhenReady
        c.baseTitle = title
        c.onPageReset = { [weak self, weak c] in if let self, let c { self.setBell(0, for: c) } }
        restoreFrame(win, role: frameRole)
        track(c); clients.append(c)
        return c
    }

    /// One window per remote Mac. The client's own welcome screen parses the pairing.
    func openClient(pairing: String?, showWhenReady: Bool, motion: Motion?) -> ClientWindow {
        var slot = 1
        while clients.contains(where: { $0.window.frameAutosaveName == frameName("remote-\(slot)") }) { slot += 1 }
        let c = makeClient(title: "Xpromptvs", showWhenReady: showWhenReady, frameRole: "remote-\(slot)")
        c.load(ClientURL.make(pairing: pairing, motion: motion))
        return c
    }

    /// "This Mac": a window-less session over the bridge socket to this app's own host. ONE — while it
    /// exists it is returned (and shown when asked), never a second. Its sockets close with its page.
    func openLocal(showWhenReady: Bool, motion: Motion?) -> ClientWindow {
        if let local { if showWhenReady { local.show() }; return local }
        let c = makeClient(title: "This Mac", showWhenReady: showWhenReady, frameRole: "local", nativeSources: false)
        local = c
        let web = c.webView
        c.onPageEnded = { [weak bridge = context.socketBridge, weak web] in
            if let bridge, let web { bridge.pageEnded(web) }
        }
        c.load(ClientURL.local(motion: motion))
        return c
    }

    /// The Dock icon clicked, or the app launched again: "This Mac" — the window the app opens at launch —
    /// comes back when it was CLOSED, whatever else is open (the dashboard, Sharing, another Mac's window);
    /// while it exists, `activate`.
    func reopen() {
        if local == nil { _ = openLocal(showWhenReady: true, motion: nil) } else { activate() }
    }

    /// Focused → last active → any visible or minimized → local terminal. A hidden PENDING client (neither
    /// visible nor minimized) is never revealed by this.
    func activate() {
        let ours = all()
        let target = ours.first { $0.window.isKeyWindow }
            ?? lastActive.flatMap { w in ours.contains { $0 === w } ? w : nil }
            ?? ours.first { $0.window.isVisible || $0.window.isMiniaturized }
            ?? home
        if let target { target.show() } else { _ = openLocal(showWhenReady: true, motion: nil) }
    }
}
