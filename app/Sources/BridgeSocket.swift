import Foundation
import RdevHostKit
import ShellstormCore
import WebKit

/// **ONE BRIDGE SOCKET** — the host's `MessageSocket` for "This Mac" (docs/desktop-app.md, "The bridge
/// socket"). It is SIMULATED: the page's frames arrive through `SocketBridge`, on the main thread in the
/// page's order, and the host's go back as base64 in `__rdevSocket.deliver`, one batch per main-thread
/// turn.
///
/// It honours `MessageSocket`'s contract:
/// - frames reach the page in the order `send` was CALLED, across every thread (`FrameQueue`);
/// - nothing blocks;
/// - `onFrame`/`onClose` never run synchronously from inside `send` or `close`.
final class BridgeSocket: MessageSocket, @unchecked Sendable {
    let id: String
    /// MAIN THREAD ONLY.
    private weak var webView: WKWebView?
    /// MAIN THREAD ONLY: called once this socket is finished with — its close reached the page, or the
    /// page closed it — so `SocketBridge` forgets it.
    var onEnded: (() -> Void)?
    private let outbound = FrameQueue()
    private let lock = NSLock()
    private var onFrame: ((Data) -> Void)?
    private var onClose: (() -> Void)?
    private var finished = false

    init(id: String, webView: WKWebView) { self.id = id; self.webView = webView }

    func start(onFrame: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        lock.withLock {
            guard !finished else { return }
            self.onFrame = onFrame
            self.onClose = onClose
        }
    }

    func send(_ frame: Data) { if outbound.append(frame) { scheduleFlush() } }

    /// The host closes it: the page is told BEHIND every frame already sent.
    func close(reason: String) {
        if outbound.close() { scheduleFlush() }
        finish()
    }

    /// Page → host: one frame, on the main thread, in the page's order.
    func receive(_ frame: Data) { lock.withLock { onFrame }?(frame) }

    /// The page closed it, or the page is gone (`SocketBridge`, main thread): nothing more is sent to
    /// it, and the host is told.
    func pageClosed() {
        outbound.discard()
        finish()
        onEnded?()
        onEnded = nil
    }

    private func finish() {
        let handler: (() -> Void)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let h = onClose
            onFrame = nil
            onClose = nil
            return h
        }
        // NEVER synchronously from `send` or `close` (the `MessageSocket` contract).
        if let handler { DispatchQueue.global(qos: .userInitiated).async(execute: handler) }
    }

    private func scheduleFlush() {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { flush() } }
    }

    @MainActor private func flush() {
        let (frames, closing) = outbound.drain()
        guard let webView else { return }
        let idJS = BridgeScripts.json(id)
        if !frames.isEmpty {
            let batch = BridgeScripts.json(frames.map { $0.base64EncodedString() })
            webView.evaluateJavaScript("window.__rdevSocket?.deliver(\(idJS), \(batch))")
        }
        if closing {
            webView.evaluateJavaScript("window.__rdevSocket?.closed(\(idJS))")
            onEnded?()
            onEnded = nil
        }
    }
}
