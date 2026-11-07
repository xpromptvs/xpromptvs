import Foundation
import RdevCore

/// **A MESSAGE SOCKET** — ordered, reliable, message-framed bytes; WebSocket semantics — carrying one
/// window-less client (docs/sources-and-focus.md, "Window-less clients"). The app's bridge socket
/// implements it; tests use an in-memory one.
public protocol MessageSocket: AnyObject {
    /// Called ONCE, by `SocketClients.accept`, BEFORE any frame can arrive: every inbound frame in
    /// order, then at most one close (either end's). Either may run on any thread. A socket drops both
    /// handlers once it has closed — they capture the socket's admission.
    func start(onFrame: @escaping (Data) -> Void, onClose: @escaping () -> Void)
    /// One frame out. Thread-safe, and ORDERED BY CALL: the socket delivers frames in the order `send`
    /// was CALLED, across every thread. Callers serialize their own sends — `TermWire.emit` sends one
    /// wire's frames from several threads under the wire's lock, and the per-tab DEFLATE stream and the
    /// "WIRE START first" rule depend on that order — so the socket must never reorder them (no hop
    /// per calling thread). It never blocks on the network, and never calls `onFrame`/`onClose`
    /// synchronously from inside `send` or `close`.
    func send(_ frame: Data)
    /// Close from this end, with a reason for a log. Idempotent; `onClose` still runs once.
    func close(reason: String)
}

/// One window-less client's connection: the three logical channels over its socket, and no media.
final class SocketConnection: ClientConnection, @unchecked Sendable {
    let clientId: String
    let socket: MessageSocket
    var nativeSession: LocalSimulatorSession?
    let presentation: ClientPresentation
    init(clientId: String, socket: MessageSocket, presentation: ClientPresentation = .terminalOnly) {
        self.clientId = clientId; self.socket = socket; self.presentation = presentation
    }
    var mediaPeer: PionPeer? { nil }
    func send(_ ch: PionChannel, _ data: Data) {
        if ch == .control { nativeSession?.control(data) }
        socket.send(SocketFrame.encode(ch.socketChannel, data))
    }
}

extension PionChannel {
    /// The socket frame's channel byte for this logical channel.
    var socketChannel: SocketChannel {
        switch self {
        case .terminal: return .terminal
        case .input: return .input
        case .control: return .control
        case .bulk: return .bulk
        }
    }
}

/// **ADMITS CLIENTS ARRIVING OVER MESSAGE SOCKETS.** A socket's FIRST frame must be its `hello`: it
/// registers the client with `ChannelHub` under `sock:<id>` — claiming control when its intent is
/// `connect`, as `RdevHostRuntime.admit` does for a relay peer — and OPENS its channels. Every later
/// frame goes to the hub; anything malformed closes the socket; the socket closing unregisters the
/// client at once (a socket that cannot blip needs no grace).
///
/// ONE SERIAL QUEUE FOR EVERY SOCKET CLIENT: a socket's frames reach the hub in order, none of the
/// hub's work runs on the thread that delivered them (the app's main thread), and admission,
/// replacement and close are ordered against each other. Per-socket queues let a reloading tab's old
/// close unregister its NEW socket (its `unregister` landing after the new hello's `register`).
public final class SocketClients: @unchecked Sendable {
    private let hub: ChannelHub
    private let lock = NSLock()
    /// The CURRENT connection for each registered id. Guarded by `lock`.
    private var current: [String: SocketConnection] = [:]
    /// Every socket accepted and not yet closed. Guarded by `lock`.
    private var open: [ObjectIdentifier: MessageSocket] = [:]
    /// Set by `closeAll`: why every later socket is refused at `accept`. Guarded by `lock`.
    private var ended: String?
    /// The one queue every frame, admission and close runs on.
    private let queue = DispatchQueue(label: "rdev.socket-clients")

    /// A socket's admission. Touched ONLY on `queue`.
    private final class Admission {
        var nativeSession: LocalSimulatorSession?
        let presentation: ClientPresentation
        init(_ presentation: ClientPresentation) { self.presentation = presentation }
        var connection: SocketConnection?
        var closed = false
    }

    public init(hub: ChannelHub) { self.hub = hub }

    /// Take a new socket. Call before any frame can arrive on it. After `closeAll` it is closed at once
    /// and never started: the session it would join has ended.
    public func accept(_ socket: MessageSocket, presentation: ClientPresentation = .terminalOnly) {
        accept(socket, presentation: presentation, nativeSession: nil)
    }

    func acceptLocal(_ socket: MessageSocket, manager: SimManager?) -> LocalSimulatorSession {
        let native = LocalSimulatorSession(hub: hub, manager: manager, dispatch: { [weak self] work in
            self?.queue.async(execute: DispatchWorkItem(block: work))
        })
        accept(socket, presentation: .nativeSimulators, nativeSession: native)
        return native
    }

    private func accept(_ socket: MessageSocket, presentation: ClientPresentation, nativeSession: LocalSimulatorSession?) {
        let key = ObjectIdentifier(socket)
        let admission = Admission(presentation)
        admission.nativeSession = nativeSession
        // UNDER THE LOCK, `start` included: a `closeAll` either finds this socket in `open` and closes it,
        // or has already refused it here — never a socket started after the end, whose hello would admit a
        // client into a session that is over. `start` never calls back synchronously (`MessageSocket`), so
        // holding the lock across it cannot deadlock.
        let refused: String? = lock.withLock {
            if let ended { return ended }
            open[key] = socket
            socket.start(onFrame: { [weak self, weak socket] frame in
                self?.queue.async { if let self, let socket { self.receive(frame, on: socket, admission) } }
            }, onClose: { [weak self, weak socket] in
                self?.queue.async { if let self, let socket { self.closed(socket, admission) } }
            })
            return nil
        }
        if let refused { socket.close(reason: refused) }
    }

    /// **THE SESSION ENDING**: every socket client is closed, and every socket accepted AFTER this is
    /// refused (`HostSession.end`). Their closes unregister them.
    public func closeAll(reason: String) {
        let all: [MessageSocket] = lock.withLock {
            if ended == nil { ended = reason }
            return Array(open.values)
        }
        for socket in all { socket.close(reason: reason) }
    }

    /// Tests: wait for everything queued so far on the shared queue — a few passes, because work a pass
    /// runs can queue more (closing a socket — a refusal, a replacement — is one more hop onto the queue).
    func drainForTests() {
        for _ in 0..<3 { queue.sync {} }
    }

    /// Tests: hold the shared queue, so a socket's frames pile up behind one another exactly as they do
    /// when the socket delivers faster than the queue runs. Pair with `resumeForTests`.
    func suspendForTests() { queue.suspend() }
    func resumeForTests() { queue.resume() }

    private func receive(_ frame: Data, on socket: MessageSocket, _ admission: Admission) {
        // A frame that raced the close is dropped: it must never register, or act for, a client the
        // hub has already let go.
        guard !admission.closed else { return }
        guard let (channel, payload) = SocketFrame.decode(frame) else { return refuse(socket, admission, "malformed frame") }
        guard let connection = admission.connection else {
            guard channel == .meta, let hello = SocketHello.parse(payload) else { return refuse(socket, admission, "expected a hello") }
            return admit(hello, on: socket, admission)
        }
        // A socket REPLACED by a newer one for the same client speaks for nobody.
        guard lock.withLock({ current[connection.clientId] === connection }) else { return }
        switch channel {
        case .meta: refuse(socket, admission, "a second hello")
        case .control: hub.connection(connection, didReceive: payload, on: .control)
        case .input: hub.connection(connection, didReceive: payload, on: .input)
        case .terminal: hub.connection(connection, didReceive: payload, on: .terminal)
        case .bulk: hub.connection(connection, didReceive: payload, on: .bulk)
        }
    }

    /// A REFUSAL TAKES EFFECT HERE, not when the close comes back: the socket's close handler is one more
    /// hop onto the shared queue, BEHIND whatever frames the socket had already delivered — and those ran
    /// first with the admission still open ([a malformed frame, then `hello(connect)`] admitted the client
    /// and took control, only to unregister it a hop later; keys or an `open-terminal` queued behind a
    /// second hello still reached the hub). So the teardown runs first, synchronously, and marks the
    /// admission closed; the close's own hop then finds it done (`closed` is idempotent).
    private func refuse(_ socket: MessageSocket, _ admission: Admission, _ why: String) {
        print("[socket] closing a client socket: \(why)")
        closed(socket, admission)                   // unregisters whatever it had admitted, at once
        socket.close(reason: why)
    }

    private func admit(_ hello: SocketHello, on socket: MessageSocket, _ admission: Admission) {
        let id = SocketClientID.make(hello.client)
        let connection = SocketConnection(clientId: id, socket: socket, presentation: admission.presentation)
        admission.connection = connection
        connection.nativeSession = admission.nativeSession
        admission.nativeSession?.bind(connection)
        let replaced: SocketConnection? = lock.withLock {
            let old = current[id]; current[id] = connection; return old
        }
        let claim = hello.intent == .connect
        if let replaced {
            // THE SAME CLIENT ON A NEW SOCKET: it keeps its place (`rebindPeer`), the old socket is
            // closed rather than left half-registered, and a connect still takes control.
            hub.rebindPeer(clientId: id, peer: connection)
            replaced.socket.close(reason: "replaced by a new socket")
            if claim { hub.claim(clientId: id) }
        } else {
            hub.register(clientId: id, peer: connection, claim: claim)
        }
        print("[socket] \(id) admitted (\(hello.intent.rawValue))")
        // THE CHANNELS OPEN WITH THE HELLO, in the order WebRTC opens them.
        hub.connection(connection, didOpen: .terminal)
        hub.connection(connection, didOpen: .input)
        hub.connection(connection, didOpen: .control)
    }

    private func closed(_ socket: MessageSocket, _ admission: Admission) {
        guard !admission.closed else { return }
        admission.closed = true
        admission.nativeSession?.close()
        lock.withLock { open[ObjectIdentifier(socket)] = nil }
        guard let connection = admission.connection else { return }
        // ONLY THE CURRENT connection unregisters: a socket REPLACED for the same client closes after its
        // successor registered, and must not take it down.
        let wasCurrent: Bool = lock.withLock {
            guard current[connection.clientId] === connection else { return false }
            current[connection.clientId] = nil
            return true
        }
        guard wasCurrent else { return }
        hub.unregister(clientId: connection.clientId)
        print("[socket] \(connection.clientId) left")
    }
}
