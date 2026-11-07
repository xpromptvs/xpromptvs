import Foundation
import RdevCore
@testable import RdevHostKit

/// An in-memory `MessageSocket`. The TEST plays the client: `hello`/`sends`/`deliver` are the client
/// sending, `clientClose` is it going away, and `sent` is what the host sent it.
final class MemorySocket: MessageSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var onFrame: ((Data) -> Void)?
    private var onClose: (() -> Void)?
    /// The frame handler kept past the close, for a test of a socket that misbehaves after it.
    private var retainedOnFrame: ((Data) -> Void)?
    private var sent: [Data] = []
    private var reason: String?
    /// Opt-in: `close` records its reason but does NOT call `onClose` or drop the handlers, so the host's
    /// admission for this socket stays open (a close still in flight while a newer socket is admitted).
    var holdsClose = false

    func start(onFrame: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        lock.withLock { self.onFrame = onFrame; self.onClose = onClose; retainedOnFrame = onFrame }
    }
    func send(_ frame: Data) { lock.withLock { if reason == nil { sent.append(frame) } } }
    func close(reason why: String) {
        let handler: (() -> Void)? = lock.withLock {
            guard reason == nil else { return nil }
            reason = why
            if holdsClose { return nil }
            let h = onClose; onFrame = nil; onClose = nil
            return h
        }
        handler?()
    }

    // MARK: the client's side
    func deliver(_ frame: Data) { let h = lock.withLock { onFrame }; h?(frame) }
    func deliverEvenAfterClose(_ frame: Data) { let h = lock.withLock { retainedOnFrame }; h?(frame) }
    func hello(_ client: String, _ intent: String = "connect") {
        deliver(SocketFrame.encode(.meta, Data(#"{"t":"hello","v":1,"client":"\#(client)","intent":"\#(intent)"}"#.utf8)))
    }
    func sends(_ channel: SocketChannel, _ json: String) { deliver(SocketFrame.encode(channel, wrapMessage(Data(json.utf8)))) }
    func clientClose() { close(reason: "the client went away") }

    // MARK: what the host did
    var closedReason: String? { lock.withLock { reason } }
    var controlMessages: [String] {
        lock.withLock { sent }.compactMap { frame in
            guard let (ch, payload) = SocketFrame.decode(frame), ch == .control,
                  let json = unwrapMessage(payload) else { return nil }
            return String(data: json, encoding: .utf8)
        }
    }
    var terminalFrames: [Data] {
        lock.withLock { sent }.compactMap { frame in
            guard let (ch, payload) = SocketFrame.decode(frame), ch == .terminal else { return nil }
            return payload
        }
    }
    /// The last `control-state` the host sent, parsed.
    var controlState: (active: Bool, clients: Int)? {
        for json in controlMessages.reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  o["t"] as? String == "control-state",
                  let active = o["active"] as? Bool, let clients = o["clients"] as? Int else { continue }
            return (active, clients)
        }
        return nil
    }
}
