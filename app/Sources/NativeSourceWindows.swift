import AppKit
import RdevCore
import ShellstormCore
import WebKit

extension NativeSourceWindowKey {
    var json: [String: Any] { ["owner": owner, "generation": generation, "source": source, "incarnation": incarnation] }
}

/// One registry per logical remote connection. It creates related presentation documents, not peers.
@MainActor
final class NativeSourceWindows {
    private weak var owner: ClientWindow?
    private let context: WebContext
    private var tickets = NativeSourceWindowTickets()
    private var snapshot: NativeSourceWindowManifest?
    private var children: [String: NativeSourceWindow] = [:]
    private var frames: [String: NSRect] = [:]
    private var pending: (ticket: String, key: NativeSourceWindowKey)?
    private var ended = false
    private(set) var generation: UInt64 = 1
    var onCreated: ((AppWindow) -> Void)?
    var all: [AppWindow] { Array(children.values) }

    init(owner: ClientWindow, context: WebContext) { self.owner = owner; self.context = context }
    var info: [String: Any] {
        ["supported": !ended, "generation": generation, "revision": snapshot?.revision ?? 0,
         "popupPermission": owner?.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically ?? false,
         "visible": owner.map { $0.window.isVisible && !$0.window.isMiniaturized && !NSApp.isHidden } ?? false,
         "keyWindow": owner?.window.isKeyWindow ?? false]
    }
    private func emit(_ object: [String: Any], allowEnded: Bool = false) {
        guard (!ended || allowEnded), let owner, !owner.pageGone else { return }
        owner.webView.evaluateJavaScript("window.__rdevNativeSourceEvent?.(\(BridgeScripts.json(object)))")
    }
    private func emit(_ type: String, key: NativeSourceWindowKey, values: [String: Any] = [:]) {
        var object = values; object["type"] = type; object["key"] = key.json; emit(object)
    }
    private func disablePending(retire: Bool = true) {
        owner?.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if retire, let pending { tickets.retire(key: pending.key) }
        pending = nil
    }
    func reset(reason: String, advance: Bool = true) {
        guard let owner else { return }
        disablePending()
        tickets.retire(owner: owner.id, generation: generation)
        let old = Array(children.values); children.removeAll(); snapshot = nil
        if advance {
            if generation < 9_007_199_254_740_991 { generation += 1 } else { ended = true }
        } else { ended = true }
        for child in old {
            frames[child.sourceKey.source] = child.window.frame
            (context.clientBridge as? ClientBridge)?.forget(child.webView)
            child.closeForOwner(reason)
        }
        emit(["type": "reset", "generation": generation, "reason": reason, "ended": ended], allowEnded: true)
    }
    func synchronize(_ value: NativeSourceWindowManifest) throws -> [String: Any] {
        guard !ended, value.generation == generation else { throw BridgeError("stale-source-generation") }
        guard value.sources.allSatisfy(Self.validSource) else { throw BridgeError("invalid-source") }
        if let previous = snapshot {
            guard value.revision >= previous.revision else { return info }
            if value.revision == previous.revision {
                guard value == previous else { throw BridgeError("stale-source-revision") }
                return info
            }
            if previous.driving && !value.driving { reset(reason: "handoff"); return info }
        }
        snapshot = value
        let members = Set(value.sources.map(\.source))
        if let pending, !value.driving || !members.contains(pending.key.source) { disablePending() }
        for child in Array(children.values) where !value.driving || !members.contains(child.sourceKey.source) { retire(child, reason: "removed") }
        for source in value.sources { children[source.source]?.apply(source: source, theme: value.theme) }
        return info
    }
    private static func validSource(_ source: NativeSourceWindowManifest.Source) -> Bool {
        switch (parseSourceID(source.source), source.kind) {
        case (.window(let id)?, .window), (.display(let id)?, .display): return UInt32(exactly: id) != nil
        case (.sim?, .simulator): return true
        default: return false
        }
    }
    func prepare(source: String, generation expected: UInt64) throws -> [String: Any] {
        guard !ended, expected == generation, let owner else { throw BridgeError("stale-source-generation") }
        guard snapshot?.driving == true, snapshot?.sources.contains(where: { $0.source == source }) == true else { throw BridgeError("source-unavailable") }
        guard pending == nil else { throw BridgeError("source-window-busy") }
        let ticket = UUID().uuidString
        guard let key = tickets.prepare(owner: owner.id, generation: generation, source: source, ticket: ticket),
              let url = NativeSourceDocument.url(ticket: ticket) else { throw BridgeError("source-window-exists") }
        pending = (ticket, key)
        // Permission exists only for this one pending internal URL. The UI delegate refuses all
        // unrelated automatic opens while it is enabled, including otherwise allowed http(s).
        owner.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.pending?.ticket == ticket else { return }
            self.disablePending(); self.emit("gone", key: key, values: ["reason": "prepare-timeout"])
        }
        return ["ticket": ticket, "url": url.absoluteString, "key": key.json]
    }
    var hasPending: Bool { pending != nil }
    func create(from web: WKWebView, configuration: WKWebViewConfiguration, action: WKNavigationAction) -> WKWebView? {
        guard !ended, let owner, owner.webView === web, let pending,
              action.targetFrame == nil, action.sourceFrame.securityOrigin.protocol == "app",
              action.sourceFrame.securityOrigin.host == "client",
              NativeSourceDocument.permitsOwner(url: action.sourceFrame.request.url,
                mainFrame: action.sourceFrame.isMainFrame, remoteOwner: true),
              NativeSourceDocument.ticket(url: action.request.url) == pending.ticket,
              snapshot?.driving == true,
              let source = snapshot?.sources.first(where: { $0.source == pending.key.source }),
              let key = tickets.consume(ticket: pending.ticket, owner: owner.id, generation: generation) else { return nil }
        disablePending(retire: false)
        // Keep WebKit's exact related-view configuration. Replace mutable handlers/preferences so
        // no dashboard, identity, socket or automatic-popup authority is inherited by the child.
        let content = WKUserContentController()
        let bridge = NativeSourceBridge(registry: self, key: key, ticket: pending.ticket, clipboard: context.clientBridge as? ClientBridge)
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: "rdevSource")
        content.addUserScript(WKUserScript(source: NativeSourceBridge.script(key: key), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #if RDEV_DEV_BUILD
        context.automation?.instrument(content, kind: .source)
        #endif
        configuration.userContentController = content
        configuration.preferences = configuration.preferences.copy() as! WKPreferences
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let child = NativeSourceWindow(key: key, source: source, theme: snapshot?.theme ?? "dark", frame: frames[source.source],
            ticket: pending.ticket, configuration: configuration)
        #if RDEV_DEV_BUILD
        child.webView.isInspectable = true
        #endif
        children[source.source] = child
        child.onEvent = { [weak self] type, values in
            guard let self, self.current(key) != nil else { return }
            self.emit(type, key: key, values: values)
        }
        child.onRetire = { [weak self] child, reason in self?.retire(child, reason: reason) }
        child.onGeometry = { [weak self] frame in
            guard let self, self.current(key) != nil else { return }
            self.frames[key.source] = frame
        }
        onCreated?(child)
        emit("created", key: key)
        return child.webView
    }
    func current(_ key: NativeSourceWindowKey) -> NativeSourceWindow? {
        guard !ended, snapshot?.driving == true, snapshot?.sources.contains(where: { $0.source == key.source }) == true, tickets.contains(key),
              let child = children[key.source], child.sourceKey == key else { return nil }
        return child
    }
    func ready(_ key: NativeSourceWindowKey) throws {
        guard let child = current(key) else { throw BridgeError("stale-source-window") }
        child.documentReady(); emit("ready", key: key)
    }
    private func retire(_ child: NativeSourceWindow, reason: String) {
        let key = child.sourceKey
        guard children[key.source] === child else { return }
        tickets.retire(key: key); children[key.source] = nil; frames[key.source] = child.window.frame
        (context.clientBridge as? ClientBridge)?.forget(child.webView)
        if !child.closing { child.closeForOwner(reason) }
        emit("gone", key: key, values: ["reason": reason])
    }
    func command(key: NativeSourceWindowKey, name: String, request: BridgeRequest) throws {
        guard let child = current(key) else { throw BridgeError("stale-source-window") }
        switch name {
        case "activate", "restore": child.activateSource()
        case "fit": child.fit()
        case "fullscreen": child.setFullscreen(request.bool(2))
        case "minimize": child.window.miniaturize(nil)
        case "close": retire(child, reason: "owner-command")
        case "confirmSize":
            guard let size = request.object(2), let values = BridgeRequest(body: ["op": "size", "args": [size["width"] ?? NSNull(), size["height"] ?? NSNull()]]),
                  let width = values.int(0, in: 1...32768), let height = values.int(1, in: 1...32768) else { throw BridgeError("malformed-source-size") }
            child.confirmSize(width: width, height: height)
        default: throw BridgeError("unknown-source-command")
        }
    }
    func key(_ object: [String: Any]) -> NativeSourceWindowKey? {
        guard let owner, let fields = BridgeRequest(body: ["op": "key", "args": [object["owner"] ?? NSNull(), object["generation"] ?? NSNull(), object["source"] ?? NSNull(), object["incarnation"] ?? NSNull()]]),
              fields.int(0, in: 1...9_007_199_254_740_991) == owner.id, let gen = fields.int(1, in: 1...9_007_199_254_740_991),
              let source = fields.string(2), let incarnation = fields.int(3, in: 1...9_007_199_254_740_991) else { return nil }
        return NativeSourceWindowKey(owner: owner.id, generation: UInt64(gen), source: source, incarnation: UInt64(incarnation))
    }
    func ownerVisibilityChanged() {
        for child in children.values { child.showIfReady() }
        emit(["type": "owner-visibility", "visible": info["visible"] ?? false, "keyWindow": info["keyWindow"] ?? false, "generation": generation])
    }
}
