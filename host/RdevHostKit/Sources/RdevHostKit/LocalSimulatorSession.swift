import Foundation
import RdevCore

public struct LocalSimulatorSnapshot: Sendable {
    public let generation: UInt64
    public let revision: UInt64
    public let driving: Bool
    public let state: SessionState
    public let sources: [SimInfo]
}

/// A cancellable observation; cancellation never waits for a callback or for CoreSimulator.
public final class LocalSimulatorObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    public func cancel() { let a = lock.withLock { let a = action; action = nil; return a }; a?() }
    deinit { cancel() }
}

/// Native windows belong to this ONE socket admission. Ordered control-state messages invalidate
/// input immediately; UI observations are delivered off the hub's locks and carry generations.
public final class LocalSimulatorSession: @unchecked Sendable {
    private let lock = NSLock()
    private weak var connection: SocketConnection?
    private weak var hub: ChannelHub?
    private weak var manager: SimManager?
    private let dispatch: (@escaping () -> Void) -> Void
    private let notifications = DispatchQueue(label: "rdev.native-simulator-state")
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var ownershipEpoch: UInt64?
    private var driving = false
    private var ended = false
    private var observers: [UUID: (LocalSimulatorSnapshot) -> Void] = [:]

    init(hub: ChannelHub, manager: SimManager?, dispatch: @escaping (@escaping () -> Void) -> Void) {
        self.hub = hub; self.manager = manager; self.dispatch = dispatch
    }
    func bind(_ connection: SocketConnection) { lock.withLock { self.connection = connection } }

    var afterStateReadForTests: (() -> Void)?

    public var snapshot: LocalSimulatorSnapshot? {
        guard let manager else { return nil }
        while true {
            let before = lock.withLock { (generation, revision) }
            let (state, sources) = manager.localSimulatorState
            afterStateReadForTests?()
            let value: LocalSimulatorSnapshot? = lock.withLock {
                guard before == (generation, revision) else { return nil }
                return LocalSimulatorSnapshot(generation: generation, revision: revision,
                    driving: driving && !ended, state: state, sources: sources)
            }
            if let value { return value }
        }
    }

    public func observe(_ receive: @escaping (LocalSimulatorSnapshot) -> Void) -> LocalSimulatorObservation {
        let id = UUID()
        lock.withLock { observers[id] = receive }
        changed()
        return LocalSimulatorObservation { [weak self] in self?.lock.withLock { self?.observers[id] = nil } }
    }
    /// Deliver a projection on the caller's UI executor.
    public func observeLatest(deliver: @escaping (@escaping () -> Void) -> Void,
                              receive: @escaping (LocalSimulatorSnapshot) -> Void) -> LocalSimulatorObservation {
        let deliveryLock = NSLock()
        var pending = false
        return observe { [weak self] _ in
            let schedule = deliveryLock.withLock { () -> Bool in
                guard !pending else { return false }; pending = true; return true
            }
            guard schedule else { return }
            deliver { [weak self] in
                deliveryLock.withLock { pending = false }
                guard let self, let value = self.snapshot else { return }
                // The ownership may have changed before its control-state has reached this socket.
                // A later notification will deliver it; never create windows for that old owner.
                guard !value.driving || self.current(value.generation) else { return }
                receive(value)
            }
        }
    }
    func control(_ data: Data) {
        guard let json = unwrapMessage(data),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
        let type = object["t"] as? String
        if type == "control-state", let active = object["active"] as? Bool {
            let epoch = hub?.currentDriverEpoch()
            lock.withLock {
                if driving != active || ownershipEpoch != epoch { generation &+= 1 }
                ownershipEpoch = epoch
                driving = active
            }
        }
        if type == "control-state" || type == "view-set" || type == "source-status" || type == "source-list" { changed() }
    }
    func close() {
        lock.withLock { ended = true; driving = false; generation &+= 1 }
        changed()
    }
    private func changed() {
        lock.withLock { revision &+= 1 }
        notifications.async { [weak self] in
            guard let self, let value = self.snapshot else { return }
            let callbacks = self.lock.withLock { Array(self.observers.values) }
            for callback in callbacks { callback(value) }
        }
    }
    public func current(_ epoch: UInt64) -> Bool {
        let owner = lock.withLock { (!ended && driving && generation == epoch ? connection : nil, ownershipEpoch) }
        guard let c = owner.0, let ownership = owner.1 else { return false }
        return hub?.isCurrentDriver(c, epoch: ownership) == true
    }
    public func perform(_ message: InboundMessage, source: String?, generation epoch: UInt64) {
        dispatch { [weak self] in
            guard let self, self.current(epoch), let c = self.connection, let manager = self.manager else { return }
            if let source {
                guard NativeSimulatorPolicy.isSimulator(source), manager.localSimulatorState.0.contains(source) else { return }
                // Focus is a separate host intent, ordered with the input that follows it.
                switch message {
                case .simTouch, .simText, .scroll, .scrollGesture, .winKey:
                    // Keep the source attached to this event. Never fall through to the hub's
                    // source-less injector if a minimize/focus change made it ineligible.
                    guard manager.localSimulatorState.0.streamed.contains(source),
                          let target = manager.pasteTarget(sourceID: source), self.current(epoch) else { return }
                    switch message {
                    case .simTouch(let phase, let points): target.simTouch(phase: phase, points: points)
                    case .simText(let text): target.simText(text)
                    case .scroll(let x, let y, let dx, let dy, let unit, let mods):
                        target.scroll(normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy, unit: unit, mods: mods)
                    case .scrollGesture(let x, let y, let phase, let vx, let vy, let mods):
                        target.scrollGesture(normalizedX: x, normalizedY: y, phase: phase, velocityX: vx, velocityY: vy, mods: mods)
                    case .winKey(let down, let code, let key, let repeated, let mods):
                        target.key(down: down, code: code, key: key, repeat: repeated, mods: mods)
                    default: break
                    }
                    return
                case .winKeysRelease:
                    manager.nativeInputTarget(source)?.releaseKeys()
                    return
                default: break
                }
            }
            self.hub?.receive(message, from: c)
        }
    }
    /// No input is posted. Preparation runs on the target's HID queue; the result is fenced back to this exact
    /// local admission and injector before a Metal view changes its event route.
    public func prepareScrollGestures(source: String, generation epoch: UInt64, completion: @escaping (Bool) -> Void) {
        dispatch { [weak self] in
            guard let self, self.current(epoch), NativeSimulatorPolicy.isSimulator(source), let manager = self.manager,
                  let target = manager.nativeInputTarget(source) as? SimulatorInputInjector else { completion(false); return }
            target.prepareNativeScroll { [weak self, weak target] ready in
                guard let self, let target, self.current(epoch), manager.nativeInputTarget(source) === target else { completion(false); return }
                completion(ready)
            }
        }
    }
    public func frames(source: String, generation epoch: UInt64,
                       receive: @escaping (SimulatorSurfaceFrame?) -> Void) -> LocalSimulatorObservation? {
        guard current(epoch), NativeSimulatorPolicy.isSimulator(source), let manager,
              manager.localSimulatorState.0.contains(source) else { return nil }
        return manager.observeNativeFrames(source: source) { [weak self] frame in
            guard self?.current(epoch) == true else { return }
            receive(frame)
        }
    }
}
