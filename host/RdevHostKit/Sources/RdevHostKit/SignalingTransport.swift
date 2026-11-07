import Foundation
import RdevCore

public final class SignalingTransport: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private var task: URLSessionWebSocketTask!
    private let url: URL
    private let role: String
    private let resumeId: String?
    private let token: String
    private let onEvent: (SignalingEvent) -> Void
    public var onReconnect: (() -> Void)?

    private let lock = NSLock()
    private var closedByUs = false
    private var everOpened = false
    private var reconnecting = false
    private var backoff: TimeInterval = 0.5
    private let backoffMax: TimeInterval = 8.0
    private var session: URLSession!
    private var heartbeat: DispatchSourceTimer?
    /// When the CURRENT socket last received anything. **A weak network strands a socket rather than
    /// closing it** — the OS gives up on a dead TCP connection in minutes, and until then every send
    /// vanishes while the task reads running. The control plane answers every 15 s ping, so a socket
    /// that has heard nothing for `staleAfter` is abandoned and reconnected; the relay reclaims a
    /// live host socket on the new hello, so an early abandon is harmless.
    private var lastHeard = DispatchTime.now()
    private let staleAfter: TimeInterval = 40
    // Serializes ALL socket-lifecycle work (connect / reconnect continuation / close-cancel) so two
    // reconnect paths can't build two live sockets in parallel or race the `task` mutation. didClose
    // and receive's .failure can BOTH fire for one disconnect; the `reconnecting` guard (below) makes
    // only one reconnect pending, and this serial queue orders it against connect()/close().
    private let ioQueue = DispatchQueue(label: "rdev.signaling.io")

    /// `resumeId`: a CLIENT's identity across this transport's own reconnects (`helloJSON`), so a blip RESUMES it.
    public init(url: URL, role: String, token: String, resumeId: String? = nil,
                onEvent: @escaping (SignalingEvent) -> Void) {
        self.url = url; self.role = role; self.token = token; self.resumeId = resumeId; self.onEvent = onEvent
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        connect()
    }

    // Always runs on ioQueue (serial), so connect/close/reconnect never overlap. Bails if close()
    // already ran (checked under lock, atomically with the `task` assignment) — makes close()
    // terminal even against an in-flight scheduled reconnect. Each receive chain captures its own
    // task, so no shared `self.task` read races the reassignment here.
    private func connect() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.closedByUs { self.lock.unlock(); return }
            let t = self.session.webSocketTask(with: self.url)
            self.task = t
            self.lock.unlock()
            t.resume()
            self.receiveLoop(t)
        }
    }

    public func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        guard isCurrent(webSocketTask) else { return }
        // hello on the exact socket that just opened (not self.task, which a newer connect could hold).
        webSocketTask.send(.string(String(decoding: helloJSON(role: role, token: token, codecs: ["deflate"], resumeId: resumeId), as: UTF8.self))) { _ in }
        lock.lock(); backoff = 0.5; reconnecting = false; lastHeard = .now(); let reconnect = everOpened; everOpened = true; lock.unlock()
        startHeartbeat()
        if reconnect { onReconnect?() }
    }

    // Reconnect on close (server or transport initiated).
    public func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if isCurrent(webSocketTask) { scheduleReconnect() }
    }

    /// **Only the CURRENT socket's end is news.** An abandoned task reports its close whenever the
    /// OS gets round to it, and reconnecting on that would open a second live socket beside the one
    /// that replaced it.
    private func isCurrent(_ t: URLSessionWebSocketTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return task === t
    }

    // Signaling events are delivered SERIALLY: onEvent(e) runs to completion before
    // receiveLoop re-arms task.receive for the next message. PeerHub/ChannelHub depend on
    // this — their NSLock guards individual mutations, but the single-threaded delivery is
    // what keeps two signaling handlers (clientJoined/answer/ice/clientLeft) from
    // interleaving. Do NOT re-arm task.receive before onEvent returns, nor dispatch onEvent
    // asynchronously, without revisiting that concurrency assumption. The chain re-arms on the
    // captured `t` (not self.task) so a concurrent reconnect can't retarget it mid-flight.
    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.lock.lock(); if self.task === t { self.lastHeard = .now() }; self.lock.unlock()
                switch message {
                case .string(let s): if let e = SignalingRouter.route(Data(s.utf8)) { self.onEvent(e) }
                case .data(let d): if let e = SignalingRouter.route(d) { self.onEvent(e) }
                @unknown default: break
                }
                self.receiveLoop(t)
            case .failure:
                // transport error → reconnect (was: silently stop)
                if self.isCurrent(t) { self.scheduleReconnect() }
            }
        }
    }

    private func scheduleReconnect() {
        lock.lock()
        // Only one reconnect pending per disconnect: didClose + receive's .failure both land here for
        // a single drop, and the retry continuation below can also fail again — coalesce them.
        if closedByUs || reconnecting { lock.unlock(); return }
        reconnecting = true
        let delay = backoff
        backoff = min(backoff * 2, backoffMax)
        lock.unlock()
        stopHeartbeat()
        ioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.reconnecting = false; let stop = self.closedByUs; self.lock.unlock()
            if !stop { self.connect() }
        }
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.abandonIfStale() { return }
            self.send(pingJSON())
        }
        lock.lock(); let old = heartbeat; heartbeat = t; lock.unlock()
        old?.cancel()
        t.resume()
    }
    /// Cancel the current socket and reconnect if it has heard nothing for `staleAfter`. The cancel
    /// makes its receive fail, which `isCurrent` then ignores, because `task` no longer names it.
    private func abandonIfStale() -> Bool {
        lock.lock()
        let stale = DispatchTime.now().uptimeNanoseconds - lastHeard.uptimeNanoseconds
            > UInt64(staleAfter * 1_000_000_000)
        let t = stale && !closedByUs ? task : nil
        if t != nil { task = nil }
        lock.unlock()
        guard let t else { return false }
        NSLog("[signaling] no reply in %.0fs — abandoning the socket and reconnecting", staleAfter)
        t.cancel()
        scheduleReconnect()
        return true
    }

    private func stopHeartbeat() {
        lock.lock(); let t = heartbeat; heartbeat = nil; lock.unlock()
        t?.cancel()
    }

    public func send(_ data: Data) {
        lock.lock(); let t = task; lock.unlock()
        guard let t else { return }
        ioQueue.async { [weak self] in
            guard self?.isCurrent(t) == true else { return }
            t.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
        }
    }
    // NO PLAINTEXT OFFER: an offer leaves only sealed in the peer's §11 session (`SharingRoom.sendSealed`) — it
    // carries the session's tab bar (`offerJSON`'s `state`) — so nothing here can send one.
    public func sendAnswer(_ sdp: String) { send(answerJSON(sdp)) }
    public func sendIce(_ cand: [String: Any], peer: String) { send(iceJSON(cand, peer: peer)) }

    /// Emit one E2E envelope (§11.3). `mode` belongs on the INITIAL handshake message only — it
    /// selects the pattern, and repeating it later would invite a peer to think it can change.
    public func sendE2E(_ ct: String, peer: String, mode: E2EWire.Mode? = nil) {
        send(e2eJSON(ct, peer: peer, mode: mode))
    }

    /// One E2E envelope from a CLIENT (`role: "client"` — Add device by code joins the new Mac's room as one):
    /// no peer, since a client has exactly one and the relay tags it.
    public func sendE2E(_ ct: String) { send(e2eJSON(ct, peer: nil)) }

    public func sendE2EReset(peer: String) { send(e2eResetJSON(peer: peer)) }

    public func close() {
        lock.lock(); closedByUs = true; lock.unlock()
        stopHeartbeat()
        // Cancel on the same serial queue that owns connect(), so the cancel is ordered against any
        // in-flight/queued connect and reads the current socket. connect() bails on closedByUs, so
        // no socket survives this.
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let t = self.task; self.lock.unlock()
            t?.cancel()
        }
    }
}
