import Foundation
import IOSurface
import RdevCore

/// Raw native pixels, not an encoder-sized copy. Retain the surface while a consumer uses it.
public struct SimulatorSurfaceFrame: @unchecked Sendable {
    public let surface: IOSurface
    public let rotation: SimRotation
    public let pointScale: Double
    public let sequence: UInt64
    public let callbackNanos: UInt64
}

/// Owns one simulator framebuffer lifecycle. Attach/detach and display metadata reads never block delivery or main.
public final class SimulatorFramebuffer: @unchecked Sendable {
    public typealias Attach = (_ queue: DispatchQueue, _ surface: @escaping (IOSurface?) -> Void,
                               _ frame: @escaping () -> Void, _ properties: @escaping () -> Void) -> SimFramebufferFeed?

    /// The SHOWN size in points, and the device's scale — at the first frame and after every rotation. On `queue`.
    public var onSizeChange: ((CGSize, CGFloat) -> Void)?
    /// The framebuffer appeared (true) or went away (false: shut down). On `queue`.
    public var onLiveChange: ((Bool) -> Void)?


    public let display: SimDisplayState
    private let attach: Attach
    private let readDisplay: () -> SimDisplayInfo?
    private let reattachInterval: TimeInterval
    private let queue = DispatchQueue(label: "rdev.sim.capture", qos: .userInteractive)
    /// Where the framebuffer is attached and DETACHED — CoreSimulator XPC with no deadline — and never `queue`, which
    /// `stop()` and `start()` wait on from main (Stop Sharing, Quit) and from ChannelHub's thread (final review C1).
    private let attachQueue = DispatchQueue(label: "rdev.sim.attach", qos: .userInitiated)
    private let infoQueue = DispatchQueue(label: "rdev.sim.display-info", qos: .utility)
    private let sizeLock = NSLock()
    private var _shownPoints: CGSize?, _shownPixels: CGSize?
    private let infoLock = NSLock()
    private var infoQueued = false
    // `queue`-confined:
    private var running = false
    private var receive: ((SimulatorSurfaceFrame?) -> Void)?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var feed: SimFramebufferFeed?
    private var attaching = false
    /// The surface went away while an attach was in flight: the feed it hands back is already dead.
    private var lostWhileAttaching = false
    private var surface: IOSurface?
    private var live: Bool?
    private var settledDisplay: DispatchWorkItem?
    private var reattach: DispatchSourceTimer?
    private var pointScale = 1.0

    public init(display: SimDisplayState, attach: @escaping Attach,
                readDisplay: @escaping () -> SimDisplayInfo?, reattachInterval: TimeInterval = 2,
                pointScale: Double = 1) {
        self.display = display; self.attach = attach; self.readDisplay = readDisplay
        self.reattachInterval = reattachInterval
        // SEEDED FROM THE LISTING (final review I2): the first surface arrives before `devicectl`'s read, and a size
        // reported in pixels-as-points opened a floating window at 3× — for good, when that read failed during a boot.
        self.pointScale = max(pointScale, 1)
    }

    public var shownPoints: CGSize? { sizeLock.withLock { _shownPoints } }
    public var nativePixelSize: CGSize? { sizeLock.withLock { _shownPixels } }

    public func start(onFrame: @escaping (SimulatorSurfaceFrame?) -> Void) {
        queue.sync {
            receive = onFrame
            if running { emit(); return }
            generation &+= 1
            running = true
            tryAttach()
            refreshDisplay()
        }
    }

    /// Delivery barrier; never waits for CoreSimulator attach/detach.
    public func stop() {
        queue.sync {
            generation &+= 1
            running = false
            settledDisplay?.cancel(); settledDisplay = nil
            reattach?.cancel(); reattach = nil
            detachOffQueue(feed); feed = nil
            surface = nil; receive = nil
            live = nil
        }
    }

    // MARK: - on `queue`

    private func tryAttach() {
        guard running, feed == nil, !attaching else { return }
        attaching = true
        lostWhileAttaching = false
        let epoch = generation
        attachQueue.async { [weak self] in
            guard let self else { return }
            let f = self.attach(self.queue, { [weak self] s in guard let self, self.generation == epoch else { return }; self.surfaceChanged(s) },
                                { [weak self] in guard let self, self.generation == epoch else { return }; self.frameReady() },
                                { [weak self] in guard let self, self.generation == epoch else { return }; self.refreshDisplay(settle: true) })
            self.queue.async {
                self.attaching = false
                // A feed that lands after `stop()`, or whose surface already went away, is detached.
                guard self.running, self.generation == epoch, self.feed == nil, !self.lostWhileAttaching else {
                    self.detachOffQueue(f)
                    if self.running { self.scheduleReattach() }
                    return
                }
                self.feed = f
                if f == nil { self.scheduleReattach() } else { self.reattach?.cancel(); self.reattach = nil }
            }
        }
    }

    private func detachOffQueue(_ f: SimFramebufferFeed?) {
        guard let f else { return }
        attachQueue.async { f.detach() }
    }

    private func scheduleReattach() {
        guard running, reattach == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + reattachInterval, repeating: reattachInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tryAttach() }
        t.resume()
        reattach = t
    }

    private func surfaceChanged(_ s: IOSurface?) {
        guard running else { return }
        surface = s
        setLive(s != nil)
        guard s != nil else {
            generation &+= 1   // callbacks from the dead IO port can no longer resurrect its pixels
            receive?(nil)
            // THE DEVICE SHUT DOWN — measured: the surface goes nil before the shutdown completes — and the ports it
            // came through are dead, so frames come back only through a FRESH attach once it boots.
            if attaching { lostWhileAttaching = true }
            detachOffQueue(feed); feed = nil
            scheduleReattach()
            return
        }
        reportSize()
        frameReady()
        // EVERY SURFACE RE-READS THE DISPLAY (final review I2): a device rebooted from a landscape app comes back
        // portrait, and whether a properties callback comes with a fresh attach is unmeasured.
        refreshDisplay(settle: true)
    }

    private func setLive(_ v: Bool) {
        guard v != live else { return }
        live = v
        onLiveChange?(v)
    }

    private func frameReady() { emit() }

    private func emit() {
        guard running, let surface, let receive else { return }
        sequence &+= 1
        receive(SimulatorSurfaceFrame(surface: surface, rotation: display.rotation, pointScale: pointScale,
                                      sequence: sequence, callbackNanos: DispatchTime.now().uptimeNanoseconds))
    }

    private func reportSize() {
        guard let surface else { return }
        let shown = display.rotation.shownSize(nativeW: IOSurfaceGetWidth(surface), nativeH: IOSurfaceGetHeight(surface))
        let px = CGSize(width: shown.w, height: shown.h)
        let pt = CGSize(width: Double(shown.w) / pointScale, height: Double(shown.h) / pointScale)
        let changed = sizeLock.withLock { () -> Bool in
            guard _shownPoints != pt || _shownPixels != px else { return false }
            _shownPoints = pt; _shownPixels = px
            return true
        }
        if changed { onSizeChange?(pt, CGFloat(pointScale)) }
    }

    /// Re-read the display's rotation and scale OFF `queue` (a subprocess), coalescing a burst of callbacks to one read.
    private func refreshDisplay(settle: Bool = false) {
        if settle {
            // CoreSimulator can notify BEFORE devicectl sees its new interface orientation.
            // One bounded trailing read converges after the guest animation, even at a static screen.
            settledDisplay?.cancel()
            let epoch = generation
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.running, self.generation == epoch else { return }
                self.settledDisplay = nil; self.refreshDisplay()
            }
            settledDisplay = item
            queue.asyncAfter(deadline: .now() + 0.5, execute: item)
        }
        let first = infoLock.withLock { () -> Bool in
            if infoQueued { return false }
            infoQueued = true
            return true
        }
        guard first else { return }
        let epoch = generation
        infoQueue.async { [weak self] in
            guard let self else { return }
            self.infoLock.withLock { self.infoQueued = false }
            guard let info = self.readDisplay() else { return }
            self.queue.async {
                guard self.running, self.generation == epoch else { return }
                let turned = info.rotation != self.display.rotation || info.pointScale != self.pointScale
                self.pointScale = info.pointScale
                self.display.rotation = info.rotation
                self.reportSize()
                if turned { self.frameReady() }   // the picture turns NOW, not at the next presented frame
            }
        }
    }
}

