import Foundation
import IOSurface
import RdevCore
import RdevSimKit

/// What a simulator capture needs of its framebuffer — `RSKFramebuffer` in the product, a fake in tests.
public protocol SimFramebufferFeed: AnyObject {
    func detach()
}

/// What a simulator injector needs of its HID connection — `RSKHIDConnection` in the product, a fake in tests.
/// Points are 0…1 in the NATIVE frame.
public protocol SimHIDSink: AnyObject {
    var invalidated: Bool { get }
    func touch(_ event: SimTouchEvent)
    func key(_ usage: UInt32, down: Bool)
    func button(_ button: SimButton, down: Bool)
}

/// Dedicated cancellable digitizer; ordinary touch/key/button input keeps its existing transport.
public protocol SimScrollHIDSink: AnyObject {
    var invalidated: Bool { get }
    func touch(_ event: SimScrollTouchEvent)
}

/// The simulators, as SimManager sees them: the real catalog, or a fake in tests.
public protocol SimulatorDevices: AnyObject, Sendable {
    /// Every available iOS simulator; nil when CoreSimulator is unavailable or did not answer within `deadline`.
    func list(deadline: TimeInterval) -> [SimInfo]?
    /// `onChange` fires with the new listing whenever a device is added or removed or changes state — while observing.
    func observe(_ onChange: @escaping @Sendable ([SimInfo]) -> Void)
    /// Start or stop watching for changes (a poll). Off at first: nothing of CoreSimulator runs until asked.
    func setObserving(_ on: Bool)
    func boot(_ udid: String, completion: @escaping @Sendable (_ error: String?) -> Void)
    func shutdown(_ udid: String, completion: @escaping @Sendable (_ error: String?) -> Void)
    /// nil unless the device is booted. Callbacks on `queue`.
    func attachFramebuffer(_ udid: String, queue: DispatchQueue,
                           surface: @escaping (IOSurface?) -> Void, frame: @escaping () -> Void,
                           properties: @escaping () -> Void) -> SimFramebufferFeed?
    /// BLOCKS for the liveness barrier. nil unless booted and answering.
    func connectHID(_ udid: String) -> SimHIDSink?
    func connectScrollHID(_ udid: String) -> SimScrollHIDSink?
}

public extension SimulatorDevices {
    func connectScrollHID(_ udid: String) -> SimScrollHIDSink? { nil }
}

final class RSKScrollHIDSink: SimScrollHIDSink {
    private let connection: RSKHIDConnection
    init(_ connection: RSKHIDConnection) { self.connection = connection }
    var invalidated: Bool { connection.invalidated }
    func touch(_ event: SimScrollTouchEvent) {
        let phase: RSKScrollTouchPhase, p: SimPoint
        switch event {
        case .contact(let point): phase = .contact; p = point
        case .end(let point): phase = .end; p = point
        case .cancel(let point): phase = .cancel; p = point
        }
        connection.sendScrollTouch(phase, point: CGPoint(x: p.x, y: p.y))
    }
    deinit { connection.close() }
}

extension RSKFramebuffer: SimFramebufferFeed {}

/// `RSKHIDConnection` as a `SimHIDSink`: the event → DTUHID dictionary step.
final class RSKHIDSink: SimHIDSink {
    private let connection: RSKHIDConnection
    init(_ c: RSKHIDConnection) { connection = c }
    var invalidated: Bool { connection.invalidated }
    func touch(_ event: SimTouchEvent) {
        let (phase, points): (RSKTouchPhase, [SimPoint]) = switch event {
        case .start(let p): (.start, p)
        case .move(let p): (.position, p)
        case .end(let p): (.end, p)
        }
        guard let one = points.first else { return }
        let two = points.count > 1 ? points[1] : nil
        connection.send(RSKDigitizerMessage(phase, CGPoint(x: one.x, y: one.y), two != nil,
                                            CGPoint(x: two?.x ?? 0, y: two?.y ?? 0)))
    }
    func key(_ usage: UInt32, down: Bool) { connection.send(RSKKeyboardMessage(usage, down, false)) }
    func button(_ button: SimButton, down: Bool) { connection.send(RSKButtonMessage(button.page, button.usage, down)) }
    deinit { connection.close() }
}

/// The simulators rdev can see, through RdevSimKit (spec, "Architecture").
///
/// CREATED LAZILY: nothing here runs until the first listing, so a Mac without Xcode pays nothing at launch.
/// EVERY CORESIMULATOR CALL RUNS ON `queue`, and `list` gives up at its deadline: a wedged CoreSimulatorService lists
/// no simulators in THAT listing, logs one line, and never holds up the caller. A failed load is retried at most once
/// a minute.
///
/// CHANGES ARE POLLED (1 s) while anyone observes. The device set's notification API is declared in idb's headers but
/// was never measured here, and a state read is a local property read; a missed notification would leave a tab
/// reading "Booting…" forever, which a poll cannot.
public final class SimulatorCatalog: SimulatorDevices, @unchecked Sendable {
    private let queue = DispatchQueue(label: "rdev.sim.catalog", qos: .userInitiated)
    private let developerDir: @Sendable () -> String?
    /// The loaded set, for an attach or a connect to read WITHOUT the queue (final review C1): those run on capture and
    /// input queues that `stop()` and paste wait on, so a `queue.sync` onto a catalog queue wedged in a listing — or
    /// one whose poll was itself stopping that capture — hung or deadlocked them.
    private let setLock = NSLock()
    private var loadedSet: RSKDeviceSet?
    /// Where observers are called: NEVER the catalog queue — SimManager's observer stops captures.
    private let notifyQueue = DispatchQueue(label: "rdev.sim.catalog.notify")
    // `queue`-confined:
    private var set: RSKDeviceSet?
    private var lastLoadFailure: Date?
    private var observers: [@Sendable ([SimInfo]) -> Void] = []
    private var last: [SimInfo]?
    private var poll: DispatchSourceTimer?
    private let logLock = NSLock()
    private var lastLog: [String: Date] = [:]

    public init(developerDir: @escaping @Sendable () -> String? = SimulatorCatalog.xcodeSelect) {
        self.developerDir = developerDir
    }

    public static func simInfo(udid: String, name: String, runtime: String, state: Int,
                               pixels: CGSize, scale: Double) -> SimInfo? {
        guard let st = SimState(coreSimulator: state), pixels.width > 0, pixels.height > 0, scale > 0 else { return nil }
        return SimInfo(udid: udid, name: name, os: runtime, state: st,
                       w: Int((pixels.width / scale).rounded()), h: Int((pixels.height / scale).rounded()),
                       pxW: Int(pixels.width), pxH: Int(pixels.height))
    }

    @Sendable public static func xcodeSelect() -> String? {
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["-p"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    public func list(deadline: TimeInterval) -> [SimInfo]? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        queue.async { box.set(self.listOnQueue()); done.signal() }
        guard done.wait(timeout: .now() + deadline) == .success else {
            log("timeout", "[sim] CoreSimulator did not list within \(deadline) s — no simulators in this listing")
            return nil
        }
        return box.get()
    }

    public func observe(_ onChange: @escaping @Sendable ([SimInfo]) -> Void) {
        queue.async { self.observers.append(onChange) }
    }

    public func setObserving(_ on: Bool) {
        // `[self]` for this one-shot block; the poll's own handler holds the catalog WEAKLY.
        queue.async { [self] in
            guard on else { self.poll?.cancel(); self.poll = nil; return }
            guard self.poll == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in
                guard let self, let now = self.listOnQueue(), now != self.last else { return }
                self.last = now
                let observers = self.observers
                self.notifyQueue.async { for o in observers { o(now) } }
            }
            t.resume()
            self.poll = t
        }
    }

    public func boot(_ udid: String, completion: @escaping @Sendable (String?) -> Void) {
        lifecycle(udid, completion) { set, q, done in set.bootDevice(udid, queue: q, completion: done) }
    }

    public func shutdown(_ udid: String, completion: @escaping @Sendable (String?) -> Void) {
        lifecycle(udid, completion) { set, q, done in set.shutdownDevice(udid, queue: q, completion: done) }
    }

    public func attachFramebuffer(_ udid: String, queue cb: DispatchQueue,
                                  surface: @escaping (IOSurface?) -> Void, frame: @escaping () -> Void,
                                  properties: @escaping () -> Void) -> SimFramebufferFeed? {
        guard let set = setForCallers() else { return nil }
        do {
            let fb = try RSKFramebuffer.attach(toDevice: udid, in: set, queue: cb,
                                               surfaceChanged: { surface($0) }, framePresented: frame,
                                               propertiesChanged: properties)
            log("fb-\(fb.callbackPath)", "[sim] framebuffer attached through \(fb.callbackPath) callbacks, CoreSimulator \(set.coreSimulatorVersion)")
            return fb
        } catch {
            log("fb-\((error as NSError).code)", "[sim] framebuffer attach for \(udid) failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func connectHID(_ udid: String) -> SimHIDSink? {
        guard let set = setForCallers() else { return nil }
        // ONE attempt (final review I3): five took up to ~36 s on the input queue while taps piled up behind it; the
        // injector retries on its own backoff instead.
        do { return RSKHIDSink(try RSKHIDConnection.connect(toDevice: udid, in: set, attempts: 1)) } catch {
            log("hid-\((error as NSError).code)", "[sim] HID connect for \(udid) failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func connectScrollHID(_ udid: String) -> SimScrollHIDSink? {
        guard let set = setForCallers() else { return nil }
        do { return RSKScrollHIDSink(try RSKHIDConnection.connectScroll(toDevice: udid, in: set)) }
        catch {
            log("scroll-hid-\((error as NSError).code)", "[sim] cancellable scroll HID for \(udid) unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// The loaded set, without waiting: nil while none is loaded, and then a load is asked for (the caller retries).
    private func setForCallers() -> RSKDeviceSet? {
        if let s = setLock.withLock({ loadedSet }) { return s }
        queue.async { _ = self.loadOnQueue() }
        return nil
    }

    // MARK: - on `queue`

    private func loadOnQueue() -> RSKDeviceSet? {
        if let set { return set }
        if let at = lastLoadFailure, Date().timeIntervalSince(at) < 60 { return nil }
        guard let dir = developerDir() else {
            lastLoadFailure = Date()
            log("no-xcode", "[sim] no developer directory (xcode-select -p) — no simulators")
            return nil
        }
        do {
            let s = try RSKDeviceSet.load(withDeveloperDir: dir)
            set = s
            setLock.withLock { loadedSet = s }
            print("[sim] CoreSimulator \(s.coreSimulatorVersion) loaded for \(dir)")
            return s
        } catch {
            lastLoadFailure = Date()
            log("load", "[sim] CoreSimulator unavailable: \(error.localizedDescription) — no simulators")
            return nil
        }
    }

    /// TESTS: what a listing returns, in place of CoreSimulator's. Set before use.
    var listOverride: (() -> [SimInfo]?)?

    private func listOnQueue() -> [SimInfo]? {
        if let listOverride { return listOverride() }
        guard let set = loadOnQueue() else { return nil }
        do {
            return try set.iOSDevices().compactMap {
                Self.simInfo(udid: $0.udid, name: $0.name, runtime: $0.runtimeName, state: $0.state,
                             pixels: $0.screenPixels, scale: $0.screenScale)
            }
        } catch {
            log("list", "[sim] listing failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// A boot or shutdown with the 120 s deadline; `completion` fires exactly once.
    private func lifecycle(_ udid: String, _ completion: @escaping @Sendable (String?) -> Void,
                           _ start: @escaping (RSKDeviceSet, DispatchQueue, @escaping (Error?) -> Void) -> Void) {
        let once = OnceFlag()
        queue.async {
            guard let set = self.loadOnQueue() else { return completion("CoreSimulator is unavailable") }
            start(set, self.queue) { err in if once.claim() { completion(err?.localizedDescription) } }
            self.queue.asyncAfter(deadline: .now() + 120) { if once.claim() { completion("timed out after 120 s") } }
        }
    }

    private func log(_ key: String, _ line: String) {
        let now = Date()
        let due = logLock.withLock { () -> Bool in
            if let at = lastLog[key], now.timeIntervalSince(at) < 60 { return false }
            lastLog[key] = now
            return true
        }
        if due { print(line) }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [SimInfo]?
    func set(_ v: [SimInfo]?) { lock.withLock { value = v } }
    func get() -> [SimInfo]? { lock.withLock { value } }
}

/// True for the first caller only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
}
