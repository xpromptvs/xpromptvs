import AppKit
import ShellstormCore
import WebKit

enum WindowKind: String { case home, client, source }

@MainActor
struct WebContext {
    let profile: AppProfile
    let environment: ShellEnvironment
    let scheme: SchemeHandler
    var uiBridge: (any WKScriptMessageHandlerWithReply)?
    var clientBridge: (any WKScriptMessageHandlerWithReply)?
    /// The local window's bridge sockets (`SocketBridge`), registered on client views only.
    var socketBridge: SocketBridge?
    #if RDEV_DEV_BUILD
    /// Dev builds with automation on: console capture + the WebSocket hold hook. The type does not
    /// exist in a release build, so neither may this field.
    var automation: Automation?
    #endif
}

@MainActor
enum WebViewFactory {
    /// `app://` must be a secure context — without one there is no `crypto.subtle`, which the
    /// client's §10/§11 code needs, presenting as an E2E failure. Private API (the selector the
    /// design spike confirmed); acceptable outside the App Store.
    ///
    /// **On the pool the web view ACTUALLY USES** — `config.processPool`, before the web view is
    /// created — as the spike measured it. It was once called on a throwaway `WKProcessPool()` no
    /// web view ever used. EVERY configuration: measured 2026-09-25, each `WKWebViewConfiguration`
    /// hands back its own `WKProcessPool` OBJECT (the class is deprecated since macOS 12 — they all
    /// front one real pool), so dedupe by object identity would register only the first, or skip a
    /// new pool that reused a freed one's address. The call is idempotent and cheap.
    ///
    /// NOT fatal when missing: the spike ALSO measured that a scheme served by a
    /// `WKURLSchemeHandler` is already secure without this call, so a WebKit that drops the
    /// selector is not by itself a broken app. `e2e/app-smoke.mjs`'s `secure: true` is the guard.
    private static var reported = false
    static func registerSecureScheme(on pool: WKProcessPool) {
        let sel = NSSelectorFromString("_registerURLSchemeAsSecure:")
        let available = pool.responds(to: sel)
        if available { _ = pool.perform(sel, with: "app") }
        guard !reported else { return }
        reported = true
        print(available ? "[webview] app:// registered as secure on the web views' process pool"
                        : "[webview] _registerURLSchemeAsSecure: unavailable; relying on scheme-handler default")
    }

    /// WebKit's PRIVATE feature switches: `+[WKPreferences _features]` lists them (each `_WKFeature` has a
    /// `key`), `-_setEnabled:forFeature:` sets one — it takes a BOOL, so it is called through a typed IMP,
    /// not `perform`. Returns whether the switch exists; missing, WebKit's default stands.
    static func setFeature(_ key: String, _ on: Bool, _ prefs: WKPreferences) -> Bool {
        let listSel = NSSelectorFromString("_features"), setSel = NSSelectorFromString("_setEnabled:forFeature:")
        guard (WKPreferences.self as AnyObject).responds(to: listSel), prefs.responds(to: setSel),
              let features = (WKPreferences.self as AnyObject).perform(listSel)?.takeUnretainedValue() as? [NSObject],
              let feature = features.first(where: { ($0.value(forKey: "key") as? String) == key }) else { return false }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let set = unsafeBitCast(prefs.method(for: setSel), to: SetEnabled.self)
        set(prefs, setSel, on, feature)
        return true
    }

    /// **WEBGPU IS ON IN EVERY WEB VIEW, SAID HERE RATHER THAN LEFT TO WEBKIT'S DEFAULT** (2026-10-03): the
    /// client's terminals draw with the WebGPU renderer wherever a hardware adapter answers
    /// (web/src/client/webgpu/; docs/client-web.md, "The WebGPU renderer"). MEASURED on macOS 26 with an
    /// offscreen WKWebView set up as this one is (an `app://` handler, the secure registration above):
    /// `WebGPUEnabled` defaults on, `app://client/` is a secure context, and `requestAdapter()` answers
    /// Apple's hardware adapter. Enabled explicitly so a WebKit that flips the default does not silently put
    /// every terminal back on the DOM renderer. PRIVATE (`setFeature`); missing, the default stands and the
    /// page falls back to the DOM renderer itself.
    private static var webgpuReported = false
    static func enableWebGPU(_ prefs: WKPreferences) {
        let enabled = setFeature("WebGPUEnabled", true, prefs)
        guard !webgpuReported else { return }
        webgpuReported = true
        print(enabled ? "[webview] WebGPU enabled for the terminals' renderer"
                      : "[webview] WebKit's WebGPU feature switch unavailable; its default stands")
    }

    /// **RENDERING UPDATES RUN AT THE DISPLAY'S RATE, NOT NEAR 60 FPS** (2026-10-03, docs/desktop-app.md,
    /// "Rendering at the display's rate"): WebKit on macOS defaults `PreferPageRenderingUpdatesNear60FPSEnabled`
    /// ON ("Prefer Page Rendering Updates near 60fps" — MEASURED in `_features` on macOS 26, default 1), so on
    /// a 120 Hz ProMotion display every rendering update — `requestAnimationFrame`, so every smooth-scroll
    /// glide, resampled wheel and terminal frame — ran near 60 Hz. Off in EVERY web view; Safari keeps its own
    /// default. PRIVATE (`setFeature`); missing, the default stands.
    private static var displayRateReported = false
    static func renderAtDisplayRate(_ prefs: WKPreferences) {
        let set = setFeature("PreferPageRenderingUpdatesNear60FPSEnabled", false, prefs)
        guard !displayRateReported else { return }
        displayRateReported = true
        print(set ? "[webview] rendering updates follow the display's rate (near-60fps preference off)"
                  : "[webview] WebKit's near-60fps preference unavailable; its default stands")
    }

    private static var stores: [UUID: WKWebsiteDataStore] = [:]
    /// Cached: every `init(forIdentifier:)` call returns a new object.
    static func store(_ id: UUID) -> WKWebsiteDataStore {
        if let s = stores[id] { return s }
        let s = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = s
        return s
    }

    static func make(kind: WindowKind, context: WebContext) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store(context.profile.dataStoreID)
        config.setURLSchemeHandler(context.scheme, forURLScheme: "app")
        // The client plays a remote stream with audio; nothing there is a user gesture.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        enableWebGPU(config.preferences)
        renderAtDisplayRate(config.preferences)
        let ucc = config.userContentController
        switch kind {
        case .source: preconditionFailure("Source views require WebKit's supplied related-view configuration")
        case .home:
            // THROTTLED, NEVER SUSPENDED — kept, but NO LONGER LOAD-BEARING since 2026-09-26: the
            // dashboard's 500 ms poll used to ANSWER the browser-aided §12.1 (deleted 2026-10-06), and
            // minimized for 90 s under WebKit's default (`.suspend`) it stopped (measured 2026-09-25).
            // This keeps the shared dashboard's 15 s forced device refresh alive while minimized.
            config.preferences.inactiveSchedulingPolicy = .throttle
            // ONE controller per kind: a client window has no handler named rdevApp at all.
            if let b = context.uiBridge {
                ucc.addScriptMessageHandler(b, contentWorld: .page, name: "rdevApp")
                ucc.addUserScript(WKUserScript(source: BridgeScripts.ui, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        case .client:
            // A pending client is created ORDERED OUT; WebKit must not suspend it while it connects.
            config.preferences.inactiveSchedulingPolicy = .none
            // The local window's socket, on a handler WITHOUT a reply — only those arrive in order.
            // `SocketBridge` itself refuses every window but "This Mac".
            if let s = context.socketBridge { ucc.add(s, contentWorld: .page, name: "rdevSocket") }
            if let b = context.clientBridge {
                ucc.addScriptMessageHandler(b, contentWorld: .page, name: "rdevShell")
                ucc.addUserScript(WKUserScript(source: BridgeScripts.client(context.environment),
                                               injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        }
        #if RDEV_DEV_BUILD
        context.automation?.instrument(ucc, kind: kind)
        #endif
        registerSecureScheme(on: config.processPool)
        // Its context menu is an edit menu, never a browser's (AppWebView, WebContextMenu).
        let web = AppWebView(frame: .zero, configuration: config)
        #if RDEV_DEV_BUILD
        web.isInspectable = true
        #endif
        return web
    }
}
