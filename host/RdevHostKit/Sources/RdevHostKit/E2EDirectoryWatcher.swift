import Foundation
import RdevCore

/// **The Mac's `/watch` socket** — `E2EDirectoryWatch` driven by a `URLSessionWebSocketTask`.
///
/// Everything here is timers and the socket; every protocol rule is in the machine. It follows the
/// rules `SignalingTransport` learned on 2026-09-24: ONLY THE CURRENT TASK'S END IS NEWS (an
/// abandoned task reports its close whenever the OS gets round to it), and a socket that has HEARD
/// NOTHING for `staleSeconds` is abandoned rather than awaited.
public final class E2EDirectoryWatcher: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let url: URL
    private let onSessions: @Sendable ([E2EDirectory.Session]) -> Void
    private let onDown: @Sendable () -> Void
    private let onStopped: @Sendable (E2EDirectoryWatch.Stop) -> Void
    private let queue = DispatchQueue(label: "rdev.directory.watch")
    private var machine: E2EDirectoryWatch
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var heartbeat: DispatchSourceTimer?
    private var renew: DispatchWorkItem?
    private var lastHeard = DispatchTime.now()
    private var stopped = false
    private let backoffMin: TimeInterval
    private var backoff: TimeInterval

    public init(url: URL, credentials: E2EDirectoryWatch.Credentials,
                onSessions: @escaping @Sendable ([E2EDirectory.Session]) -> Void,
                onDown: @escaping @Sendable () -> Void,
                onStopped: @escaping @Sendable (E2EDirectoryWatch.Stop) -> Void,
                backoffMin: TimeInterval = 0.5) {
        self.url = url
        self.machine = E2EDirectoryWatch(credentials: credentials,
                                         operationID: { E2EOperation.newID() })
        self.onSessions = onSessions; self.onDown = onDown; self.onStopped = onStopped
        self.backoffMin = backoffMin; self.backoff = backoffMin
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10          // the connect timeout
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func start() { queue.async { self.connect() } }

    public func stop() {
        queue.async {
            self.stopped = true
            self.teardownTimers()
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
        }
    }

    // MARK: - socket

    private func connect() {
        guard !stopped else { return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t)
    }

    public func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol p: String?) {
        queue.async {
            guard webSocketTask === self.task else { return }
            self.backoff = self.backoffMin
            self.lastHeard = .now()
            self.apply(self.machine.handle(.opened))
            self.startHeartbeat()
        }
    }

    public func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { self.ended(webSocketTask, code: code.rawValue) }
    }

    public func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            guard let ws = t as? URLSessionWebSocketTask else { return }
            self.ended(ws, code: nil)
        }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard t === self.task else { return }
                switch result {
                case .success(.string(let text)):
                    self.lastHeard = .now()
                    self.apply(self.machine.handle(.message(text)))
                    self.receive(t)
                case .success:
                    self.lastHeard = .now()
                    self.receive(t)
                case .failure:
                    self.ended(t, code: t.closeCode == .invalid ? nil : t.closeCode.rawValue)
                }
            }
        }
    }

    /// Always on `queue`. Only the CURRENT task's end moves the machine.
    private func ended(_ t: URLSessionWebSocketTask, code: Int?) {
        guard t === task, !stopped else { return }
        task = nil
        teardownTimers()
        apply(machine.handle(.closed(code: code)))
    }

    // MARK: - effects

    private func apply(_ effects: [E2EDirectoryWatch.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let text):
                task?.send(.string(text)) { _ in }
            case .renew(let after, let challenge):
                renew?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.apply(self.machine.handle(.renewDue(challenge: challenge)))
                }
                renew = item
                queue.asyncAfter(deadline: .now() + after, execute: item)
            case .sessions(let rows):
                onSessions(rows)
            case .down:
                onDown()
                scheduleReconnect(after: backoff)
                backoff = min(backoff * 2, 8)
            case .reconnectNow:
                scheduleReconnect(after: 0)
            case .stop(let reason):
                stopped = true
                task?.cancel(with: .normalClosure, reason: nil)
                task = nil
                onStopped(reason)
            }
        }
    }

    private var reconnectPending = false
    private func scheduleReconnect(after delay: TimeInterval) {
        guard !stopped else { return }
        if delay == 0 { reconnectPending = false; connect(); return }
        guard !reconnectPending else { return }
        reconnectPending = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.reconnectPending else { return }
            self.reconnectPending = false
            if self.task == nil { self.connect() }
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + E2EDirectoryWatch.pingSeconds,
                   repeating: E2EDirectoryWatch.pingSeconds)
        t.setEventHandler { [weak self] in
            guard let self, let current = self.task else { return }
            let silent = DispatchTime.now().uptimeNanoseconds - self.lastHeard.uptimeNanoseconds
            if silent > UInt64(E2EDirectoryWatch.staleSeconds * 1_000_000_000) {
                current.cancel(with: .goingAway, reason: nil)
                self.ended(current, code: nil)
                return
            }
            current.send(.string(#"{"t":"ping"}"#)) { _ in }
        }
        heartbeat = t
        t.resume()
    }

    private func teardownTimers() {
        heartbeat?.cancel(); heartbeat = nil
        renew?.cancel(); renew = nil
    }
}
