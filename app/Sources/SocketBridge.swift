import Foundation
import RdevHostKit
import WebKit

/// **THE LOCAL WINDOW'S BRIDGE SOCKETS** (docs/desktop-app.md, "The bridge socket"): the page's end of
/// each `BridgeSocket`, on its OWN message handler, `rdevSocket`.
///
/// It has NO reply, on purpose: WebKit calls a plain handler synchronously and IN ORDER, which a
/// socket's frames depend on. A reply handler's calls are async functions started as tasks, with no
/// order promised between them.
///
/// Only "This Mac"'s main frame may open one: the bridge is the socket's WHOLE authentication (only
/// this process's own `app://client` page can reach it), and every other client window reaches its
/// host through the relay and §11.
@MainActor
final class SocketBridge: NSObject, WKScriptMessageHandler {
    weak var windows: AppWindows?
    private let accept: @MainActor (MessageSocket) -> LocalSimulatorSession?
    private struct Key: Hashable { let page: ObjectIdentifier; let id: String }
    let nativeWindows = NativeSimulatorWindows()
    private var nativeKey: Key?
    private var sockets: [Key: BridgeSocket] = [:]

    init(accept: @escaping @MainActor (MessageSocket) -> LocalSimulatorSession?) { self.accept = accept }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let o = m.frameInfo.securityOrigin
        guard m.frameInfo.isMainFrame, o.protocol == "app", o.host == "client", let web = m.webView,
              let body = m.body as? [String: Any], let op = body["op"] as? String,
              let id = body["id"] as? String, (1...64).contains(id.utf8.count) else { return }
        let key = Key(page: ObjectIdentifier(web), id: id)
        switch op {
        case "open":
            guard sockets[key] == nil else { return }
            guard windows?.local?.webView === web else {
                // Not "This Mac": say no, so the page stops waiting on a socket nobody will answer.
                web.evaluateJavaScript("window.__rdevSocket?.closed(\(BridgeScripts.json(id)))")
                return
            }
            let socket = BridgeSocket(id: id, webView: web)
            socket.onEnded = { [weak self] in
                guard let self else { return }; self.sockets[key] = nil
                if self.nativeKey == key { self.nativeKey = nil; self.nativeWindows.unbind() }
            }
            sockets[key] = socket
            nativeKey = key
            if let session = accept(socket) { nativeWindows.bind(session) }
        case "send":
            guard let socket = sockets[key] else { return }
            guard let text = body["frame"] as? String, let frame = Data(base64Encoded: text) else {
                print("[socket] bridge socket \(id): a frame that is not base64; closing it")
                socket.close(reason: "a frame that is not base64")
                return
            }
            socket.receive(frame)
        case "close":
            sockets.removeValue(forKey: key)?.pageClosed()
        default:
            return
        }
    }

    /// The page is gone — its window closed, or its web content process died: every socket it held
    /// closes. (A RELOAD needs nothing here: the old page's `pagehide` closes its socket, and a hello
    /// for the same client id replaces one that is still open.)
    func pageEnded(_ web: WKWebView) {
        let page = ObjectIdentifier(web)
        for (key, socket) in sockets where key.page == page {
            sockets[key] = nil
            socket.pageClosed()
        }
    }
}
