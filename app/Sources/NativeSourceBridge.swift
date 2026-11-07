import Foundation
import ShellstormCore
import WebKit

/// Source-only authority, structurally separate from identity/dashboard/socket handlers. Same-origin
/// opener code remains trusted application code; this is not a web security isolation principal.
@MainActor
final class NativeSourceBridge: NSObject, WKScriptMessageHandlerWithReply {
    private weak var registry: NativeSourceWindows?
    private weak var clipboard: ClientBridge?
    private let key: NativeSourceWindowKey
    private let ticket: String
    init(registry: NativeSourceWindows, key: NativeSourceWindowKey, ticket: String, clipboard: ClientBridge?) {
        self.registry = registry; self.key = key; self.ticket = ticket; self.clipboard = clipboard
    }
    func userContentController(_ content: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "app", origin.host == "client",
              NativeSourceDocument.ticket(url: message.frameInfo.request.url) == ticket,
              let registry, let child = registry.current(key), child.webView === message.webView,
              let request = BridgeRequest(body: message.body) else { return (nil, "refused-source-window") }
        if request.op == "ready" {
            do { try registry.ready(key); return (true, nil) } catch { return (nil, error.localizedDescription) }
        }
        // Clipboard work belongs to the presenting document and its actual web view's offered paths.
        // No identity, Worker request, sockets, fullscreen-owner or source creation operation is forwarded.
        if ["pasteboardFiles", "preparePaste", "discardPaste", "cancelPaste"].contains(request.op), let clipboard {
            return await clipboard.userContentController(content, didReceive: message)
        }
        return (nil, "refused-source-operation")
    }
    static func script(key: NativeSourceWindowKey) -> String { """
    (() => {
      const handler = window.webkit.messageHandlers.rdevSource;
      const call = op => (...args) => handler.postMessage({op, args});
      const resize = new Set();
      const scroll = new Set();
      Object.defineProperty(window, '__rdevNativeSourceScroll', { value: batch => { for (const cb of scroll) { try { cb(batch); } catch (e) { console.error(e); } } } });
      Object.defineProperty(window, '__rdevNativeSourceResize', { value: held => { for (const cb of resize) { try { cb(held === true); } catch (e) { console.error(e); } } } });
      Object.defineProperty(window, '__rdevNativeSource', { value: Object.freeze({
        key: Object.freeze(\(BridgeScripts.json(key.json))), ready: call('ready'),
        nativeScrollEnabled: \(NativeSourceScrollObserver.enabled ? "true" : "false"),
        pasteboardFiles: call('pasteboardFiles'), preparePaste: call('preparePaste'),
        discardPaste: call('discardPaste'), cancelPaste: call('cancelPaste'),
        onResizeHold: cb => { resize.add(cb); return () => resize.delete(cb); },
        onScroll: cb => { scroll.add(cb); return () => scroll.delete(cb); },
      }) });
    })();
    """ }
}
