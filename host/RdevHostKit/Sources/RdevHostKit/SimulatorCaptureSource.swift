import Accelerate
import CoreVideo
import Foundation
import IOSurface
import RdevCore

/// One simulator stream's display state, shared by its capture (which LEARNS the rotation) and its injector (which
/// turns every touch back through it). One per stream.
public final class SimDisplayState: @unchecked Sendable {
    private let lock = NSLock()
    private var _rotation = SimRotation.rot0
    public init() {}
    public var rotation: SimRotation {
        get { lock.withLock { _rotation } }
        set { lock.withLock { _rotation = newValue } }
    }
}

/// The remote encoding adapter. Raw/native consumers use `framebuffer` directly and never enter the renderer.
public final class SimulatorCaptureSource: StreamVideoSource, @unchecked Sendable {
    public typealias Attach = SimulatorFramebuffer.Attach
    public static let keepAliveSeconds = 0.5
    public let framebuffer: SimulatorFramebuffer
    public let display: SimDisplayState
    public var onSizeChange: ((CGSize, CGFloat) -> Void)? {
        get { framebuffer.onSizeChange }
        set { framebuffer.onSizeChange = newValue }
    }
    public var onLiveChange: ((Bool) -> Void)? {
        get { framebuffer.onLiveChange }
        set { framebuffer.onLiveChange = newValue }
    }
    public var shownPoints: CGSize? { framebuffer.shownPoints }
    public var nativePixelSize: CGSize? { framebuffer.nativePixelSize }
    private let queue = DispatchQueue(label: "rdev.sim.encode-feed", qos: .userInteractive)
    private var sink: VideoFrameSink?
    // The guest repaints its IOSurface: queued notifications are NOT retained snapshots like SCK buffers.
    // Keep only the newest notification, and at most one scheduled drain, independently of a busy encoder.
    private let handoffLock = NSLock()
    private var latest: SimulatorSurfaceFrame? // handoffLock, together with epoch and drainScheduled
    private var handoffEpoch: UInt64 = 0
    private var drainScheduled = false
    private var renderer = SimFrameRenderer()
    private var scaleFactor: Double
    private var minInterval: Double
    private var lastEmitNs: UInt64 = 0
    private var lastPtsNs: UInt64 = 0
    private var trailing: DispatchWorkItem?
    private var keepAlive: DispatchSourceTimer?
    private var generation: UInt64 = 0

    public init(scaleFactor: Double, fps: Int, display: SimDisplayState, attach: @escaping Attach,
                readDisplay: @escaping () -> SimDisplayInfo?, reattachInterval: TimeInterval = 2,
                pointScale: Double = 1) {
        self.display = display
        self.scaleFactor = min(max(scaleFactor, 0.05), 1)
        self.minInterval = 1 / Double(max(fps, 1))
        framebuffer = SimulatorFramebuffer(display: display, attach: attach, readDisplay: readDisplay,
                                           reattachInterval: reattachInterval, pointScale: pointScale)
    }

    public func start(into sink: VideoFrameSink) {
        let start: UInt64? = queue.sync {
            let first = self.sink == nil
            self.sink = sink
            guard first else { return nil }
            generation &+= 1
            lastEmitNs = 0; lastPtsNs = 0
            handoffLock.withLock { handoffEpoch = generation }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.keepAliveSeconds, repeating: Self.keepAliveSeconds)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                if Double(DispatchTime.now().uptimeNanoseconds &- self.lastEmitNs) / 1e9 >= Self.keepAliveSeconds {
                    // Idle refreshes represent the unchanged picture NOW; reusing its old PTS would reverse time.
                    if let frame = self.handoffLock.withLock({ self.drainScheduled ? nil : self.latest }) {
                        self.emit(frame, ptsNs: DispatchTime.now().uptimeNanoseconds)
                    }
                }
            }
            t.resume(); keepAlive = t
            return generation
        }
        guard let epoch = start else { return }
        framebuffer.start { [weak self] frame in
            guard let self else { return }
            let schedule = self.handoffLock.withLock {
                guard self.handoffEpoch == epoch else { return false }
                self.latest = frame
                guard !self.drainScheduled else { return false }
                self.drainScheduled = true
                return true
            }
            if schedule { self.queue.async { [weak self] in self?.drain(epoch: epoch) } }
        }
    }

    public func stop() {
        framebuffer.stop()
        queue.sync {
            generation &+= 1
            sink = nil
            handoffLock.withLock {
                handoffEpoch = generation; latest = nil; drainScheduled = false
            }
            trailing?.cancel(); trailing = nil
            keepAlive?.cancel(); keepAlive = nil
        }
    }
    public func setScale(_ v: Double) { queue.async { self.scaleFactor = min(max(v, 0.05), 1) } }
    public func setFpsCap(_ fps: Int) { queue.async { self.minInterval = 1 / Double(max(fps, 1)) } }
    private func drain(epoch: UInt64) {
        guard generation == epoch, sink != nil else { return }
        trailing = nil
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now &- lastEmitNs) / 1e9
        if elapsed < minInterval {
            // Leave drainScheduled set while waiting: incoming callbacks replace the picture, not the timer.
            let item = DispatchWorkItem { [weak self] in self?.drain(epoch: epoch) }
            trailing = item
            queue.asyncAfter(deadline: .now() + (minInterval - elapsed), execute: item)
            return
        }
        let frame = handoffLock.withLock {
            drainScheduled = false
            return latest
        }
        guard let frame else { return }
        emit(frame, ptsNs: frame.callbackNanos)
    }

    private func emit(_ frame: SimulatorSurfaceFrame, ptsNs: UInt64) {
        guard let sink else { return }
        lastEmitNs = DispatchTime.now().uptimeNanoseconds
        if let buffer = renderer.render(frame.surface, rotation: frame.rotation, scaleFactor: scaleFactor) {
            // A callback racing an idle refresh may have been timestamped just before that refresh.
            // Preserve capture time normally, but never let that race move the media clock backwards.
            lastPtsNs = max(ptsNs, lastPtsNs + 1)
            sink.encode(buffer, ptsNs: Int64(lastPtsNs))
        }
    }
}

/// The native surface → a fresh BGRA buffer, scaled and turned to the shown orientation. Reuses its pool and its
/// scratch buffer across frames; recreated whenever the output size changes. INTERNAL for the tests.
struct SimFrameRenderer {
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var scratch: UnsafeMutableRawPointer?
    private var scratchBytes = 0

    mutating func render(_ surface: IOSurface, rotation: SimRotation, scaleFactor: Double) -> CVPixelBuffer? {
        let srcW = IOSurfaceGetWidth(surface), srcH = IOSurfaceGetHeight(surface)
        guard srcW > 1, srcH > 1 else { return nil }
        let sf = min(max(scaleFactor, 0.05), 1.0)
        // EVEN, as every encoder path wants; at scale 1 an odd native size loses its last column or row.
        let w = max(2, Int((Double(srcW) * sf).rounded()) & ~1)
        let h = max(2, Int((Double(srcH) * sf).rounded()) & ~1)
        let shown = rotation.shownSize(nativeW: w, nativeH: h)
        guard let dst = buffer(shown.w, shown.h) else { return nil }

        IOSurfaceLock(surface, .readOnly, nil)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            IOSurfaceUnlock(surface, .readOnly, nil)
        }
        var src = vImage_Buffer(data: IOSurfaceGetBaseAddress(surface), height: vImagePixelCount(srcH),
                                width: vImagePixelCount(srcW), rowBytes: IOSurfaceGetBytesPerRow(surface))
        var out = vImage_Buffer(data: CVPixelBufferGetBaseAddress(dst), height: vImagePixelCount(shown.h),
                                width: vImagePixelCount(shown.w), rowBytes: CVPixelBufferGetBytesPerRow(dst))
        let scaled = w != srcW || h != srcH
        if rotation == .rot0 {
            if scaled {
                guard vImageScale_ARGB8888(&src, &out, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return nil }
            } else {
                let row = min(src.rowBytes, out.rowBytes)
                for y in 0..<h { memcpy(out.data + y * out.rowBytes, src.data + y * src.rowBytes, row) }
            }
            return dst
        }
        var from = src
        if scaled {
            let rowBytes = w * 4
            if scratchBytes < rowBytes * h {
                scratch?.deallocate()
                scratch = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * h, alignment: 64)
                scratchBytes = rowBytes * h
            }
            var mid = vImage_Buffer(data: scratch, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
            guard vImageScale_ARGB8888(&src, &mid, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return nil }
            from = mid
        }
        var black: [UInt8] = [0, 0, 0, 0xFF]
        guard vImageRotate90_ARGB8888(&from, &out, rotation.vImageRotationConstant, &black,
                                      vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        return dst
    }

    private mutating func buffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolW != w || poolH != h {
            let attrs: [String: Any] = [
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                    attrs as CFDictionary, &p)
            pool = p; poolW = w; poolH = h
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess else { return nil }
        return out
    }
}
