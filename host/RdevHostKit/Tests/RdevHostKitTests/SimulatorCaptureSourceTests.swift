import CoreVideo
import IOSurface
import XCTest
import RdevCore
@testable import RdevHostKit

final class SimulatorCaptureSourceTests: XCTestCase {
    /// A BGRA IOSurface whose every pixel is distinct: (x, y, 0xAB).
    private func surface(_ w: Int, _ h: Int) -> IOSurface {
        let s = IOSurface(properties: [.width: w, .height: h, .bytesPerElement: 4, .bytesPerRow: w * 4,
                                       .pixelFormat: kCVPixelFormatType_32BGRA])!
        s.lock(options: [], seed: nil)
        let p = s.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let o = y * s.bytesPerRow + x * 4
            p[o] = UInt8(truncatingIfNeeded: x); p[o + 1] = UInt8(truncatingIfNeeded: y); p[o + 2] = 0xAB; p[o + 3] = 0xFF
        } }
        s.unlock(options: [], seed: nil)
        return s
    }

    private func pixel(_ b: CVPixelBuffer, _ x: Int, _ y: Int) -> (UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let o = y * CVPixelBufferGetBytesPerRow(b) + x * 4
        return (p[o], p[o + 1])
    }

    /// THE PICTURE AND THE TOUCHES TURN THROUGH ONE TYPE. Every native pixel must land where `SimRotation` says a
    /// touch at that pixel's centre is shown — for all four rotations — or a tap lands beside what it was aimed at.
    func testEveryPixelLandsWhereSimRotationShowsIt() throws {
        let W = 4, H = 2
        let src = surface(W, H)
        for r in [SimRotation.rot0, .rot90, .rot180, .rot270] {
            var renderer = SimFrameRenderer()
            let out = try XCTUnwrap(renderer.render(src, rotation: r, scaleFactor: 1))
            let shown = r.shownSize(nativeW: W, nativeH: H)
            XCTAssertEqual(CVPixelBufferGetWidth(out), shown.w, "\(r)")
            XCTAssertEqual(CVPixelBufferGetHeight(out), shown.h, "\(r)")
            for ny in 0..<H { for nx in 0..<W {
                let s = r.shownPoint(nativeX: (Double(nx) + 0.5) / Double(W), nativeY: (Double(ny) + 0.5) / Double(H))
                let sx = Int(s.x * Double(shown.w)), sy = Int(s.y * Double(shown.h))
                let (b, g) = pixel(out, sx, sy)
                XCTAssertEqual(b, UInt8(nx), "\(r): native (\(nx),\(ny)) → shown (\(sx),\(sy))")
                XCTAssertEqual(g, UInt8(ny), "\(r): native (\(nx),\(ny)) → shown (\(sx),\(sy))")
            } }
        }
    }

    /// MEASURED for rot270: the native top-RIGHT corner is the shown top-LEFT.
    func testRot270TurnsTheTopRightCornerToTheTopLeft() throws {
        var renderer = SimFrameRenderer()
        let out = try XCTUnwrap(renderer.render(surface(4, 2), rotation: .rot270, scaleFactor: 1))
        XCTAssertEqual(pixel(out, 0, 0).0, 3, "x of the native top-right pixel")
        XCTAssertEqual(pixel(out, 0, 0).1, 0, "y of the native top-right pixel")
    }

    func testAScaledFrameIsEvenAndSmaller() throws {
        var renderer = SimFrameRenderer()
        let out = try XCTUnwrap(renderer.render(surface(120, 260), rotation: .rot90, scaleFactor: 0.5))
        XCTAssertEqual(CVPixelBufferGetWidth(out), 130)   // shown width = native height × 0.5
        XCTAssertEqual(CVPixelBufferGetHeight(out), 60)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), kCVPixelFormatType_32BGRA, "LLVEncoderAdapter drops anything else")
    }

    // MARK: - the source

    private final class Feed: SimFramebufferFeed { var detached = false; func detach() { detached = true } }
    private final class Sink: VideoFrameSink, @unchecked Sendable {
        let lock = NSLock(); var sizes: [(Int, Int)] = []
        func encode(_ pb: CVPixelBuffer, ptsNs: Int64) {
            lock.withLock { sizes.append((CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))) }
        }
        var count: Int { lock.withLock { sizes.count } }
    }
    /// A framebuffer that is absent until `boot()`, then delivers a surface; `shutDown()` takes it away.
    private final class World: @unchecked Sendable {
        let lock = NSLock()
        var booted = false
        var attaches = 0
        var surface: ((IOSurface?) -> Void)?
        var frame: (() -> Void)?
        var queue: DispatchQueue?
        func attach(_ q: DispatchQueue, _ s: @escaping (IOSurface?) -> Void, _ f: @escaping () -> Void,
                    _ p: @escaping () -> Void) -> SimFramebufferFeed? {
            lock.withLock { attaches += 1 }
            guard lock.withLock({ booted }) else { return nil }
            lock.withLock { surface = s; frame = f; queue = q }
            return Feed()
        }
        func deliver(_ s: IOSurface?) { let (q, cb) = lock.withLock { (queue, surface) }; q?.async { cb?(s) } }
    }

    /// REVIEW FOCUS 5: shut down and booted again with the tab open — the picture comes back by itself.
    func testASurfaceThatGoesAwayIsReattached() {
        let world = World(), sink = Sink(), live = LiveLog()
        let src = SimulatorCaptureSource(scaleFactor: 1, fps: 60, display: SimDisplayState(),
                                         attach: world.attach, readDisplay: { nil }, reattachInterval: 0.1)
        src.onLiveChange = { live.append($0) }
        src.start(into: sink)
        wait("the first attach fails: not booted") { world.lock.withLock { world.attaches } >= 1 }
        world.lock.withLock { world.booted = true }
        wait("re-attached once booted") { world.lock.withLock { world.surface } != nil }
        world.deliver(surface(4, 2))
        wait("frames") { sink.count >= 1 }
        world.lock.withLock { world.booted = false }
        world.deliver(nil)                                    // the device shut down
        wait("not live") { live.values.last == false }
        let before = world.lock.withLock { world.attaches }
        world.lock.withLock { world.booted = true; world.surface = nil }
        wait("attached AGAIN after the shutdown") { world.lock.withLock { world.attaches } > before && world.surface != nil }
        world.deliver(surface(4, 2))
        wait("live again") { live.values.last == true }
        src.stop()
    }

    func testTheRotationTurnsTheFrameAndTheReportedSize() {
        let world = World(), sink = Sink(), display = SimDisplayState()
        world.booted = true
        let src = SimulatorCaptureSource(scaleFactor: 1, fps: 60, display: display, attach: world.attach,
                                         readDisplay: { SimDisplayInfo(rotation: .rot270, nativeW: 4, nativeH: 2, pointScale: 2) },
                                         reattachInterval: 0.1)
        let sizes = SizeLog()
        src.onSizeChange = { size, scale in sizes.append(size, scale) }
        src.start(into: sink)
        wait("attached") { world.lock.withLock { world.surface } != nil }
        world.deliver(surface(4, 2))
        wait("rotation read") { display.rotation == .rot270 }
        wait("a turned frame") { sink.lock.withLock { sink.sizes.last.map { $0 == (2, 4) } ?? false } }
        wait("the shown size in POINTS") { sizes.last?.0 == CGSize(width: 1, height: 2) && sizes.last?.1 == 2 }
        src.stop()
    }

    /// A codec change re-points a RUNNING capture at a new encoder by calling `start(into:)` again
    /// (`SimManager.commitStart`): the sink swaps, nothing attaches twice.
    func testASecondStartOnlySwapsTheSink() {
        let world = World(), first = Sink(), second = Sink()
        world.booted = true
        let src = SimulatorCaptureSource(scaleFactor: 1, fps: 60, display: SimDisplayState(), attach: world.attach,
                                         readDisplay: { nil }, reattachInterval: 0.1)
        src.start(into: first)
        wait("attached") { world.lock.withLock { world.surface } != nil }
        src.start(into: second)
        world.deliver(surface(4, 2))
        wait("the NEW sink gets the frame") { second.count >= 1 }
        XCTAssertEqual(world.lock.withLock { world.attaches }, 1, "one attach")
        src.stop()
    }

    /// FINAL REVIEW C1. An attach is CoreSimulator XPC with no deadline, and `stop()` runs on main (Stop Sharing, Quit) and
    /// on ChannelHub's thread (a close): it must never wait on one. An attach that lands after the stop is detached.
    func testStopNeverWaitsOnABlockedAttach() {
        let release = DispatchSemaphore(value: 0)
        let feed = Feed()
        let started = expectation(description: "attach entered")
        let src = SimulatorCaptureSource(scaleFactor: 1, fps: 60, display: SimDisplayState(),
                                         attach: { _, _, _, _ in started.fulfill(); release.wait(); return feed },
                                         readDisplay: { nil }, reattachInterval: 0.1)
        src.start(into: Sink())
        wait(for: [started], timeout: 5)
        let stopped = expectation(description: "stop returned")
        DispatchQueue.global().async { src.stop(); stopped.fulfill() }
        wait(for: [stopped], timeout: 0.5)
        release.signal()
        let deadline = Date().addingTimeInterval(2)
        while !feed.detached && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(feed.detached, "a feed that lands after stop() is detached")
    }

    /// FINAL REVIEW I2. The first surface arrives before `devicectl`'s ~110 ms read, so the first size must already be in
    /// POINTS — from the listing's scale — or a floating window opens at 3× its size (and stays there if the read fails,
    /// as it may while a device boots).
    func testTheFirstSizeIsInPointsBeforeTheDisplayIsRead() {
        let world = World(), sizes = SizeLog()
        world.booted = true
        let src = SimulatorCaptureSource(scaleFactor: 1, fps: 60, display: SimDisplayState(), attach: world.attach,
                                         readDisplay: { nil }, reattachInterval: 0.1, pointScale: 3)
        src.onSizeChange = { size, scale in sizes.append(size, scale) }
        src.start(into: Sink())
        wait("attached") { world.lock.withLock { world.surface } != nil }
        world.deliver(surface(6, 12))
        wait("a size") { sizes.last != nil }
        XCTAssertEqual(sizes.last?.0, CGSize(width: 2, height: 4))
        XCTAssertEqual(sizes.last?.1, 3)
        src.stop()
    }

    /// FINAL REVIEW I2. A device rebooted from a landscape app comes back portrait: every surface re-reads the display,
    /// not only `start()` and the properties callback.
    func testEverySurfaceReReadsTheDisplay() {
        let world = World(), reads = Counter()
        world.booted = true
        let src = SimulatorCaptureSource(scaleFactor: 1, fps: 60, display: SimDisplayState(), attach: world.attach,
                                         readDisplay: { reads.bump(); return nil }, reattachInterval: 0.1, pointScale: 3)
        src.start(into: Sink())
        wait("attached") { world.lock.withLock { world.surface } != nil }
        let atStart = reads.value
        world.deliver(surface(4, 2))
        wait("re-read on the surface") { reads.value > atStart }
        src.stop()
    }

    /// A slow encoder must not turn callback notifications into a queue of stale pictures.
    /// Unlike SCK buffers, retained IOSurfaces can be repainted by the guest while waiting.
    func testAnEncoderStallCoalescesToTheNewestFrameAndKeepsItsCaptureTime() {
        let world = World(), sink = StalledSink()
        world.booted = true
        let src = SimulatorCaptureSource(scaleFactor: 1, fps: 60, display: SimDisplayState(),
                                         attach: world.attach, readDisplay: { nil })
        src.start(into: sink)
        wait("attached") { world.lock.withLock { world.surface } != nil }
        world.deliver(surface(4, 2))
        XCTAssertEqual(sink.entered.wait(timeout: .now() + 2), .success)
        for n in 1...12 { world.deliver(surface(4 + n * 2, 2)) }
        // Drain the capture callbacks while encoding is blocked, proving capture remains independent.
        world.lock.withLock { world.queue }?.sync {}
        let capturedBy = Int64(DispatchTime.now().uptimeNanoseconds)
        Thread.sleep(forTimeInterval: 0.08)
        sink.release.signal()
        wait("newest picture") { sink.lock.withLock { sink.widths.contains(28) } }
        src.stop()
        let samples = sink.lock.withLock { (sink.widths, sink.timestamps) }
        XCTAssertEqual(samples.0, [4, 28], "encode only the newest pending picture after a stall")
        if samples.1.count > 1 {
            XCTAssertLessThanOrEqual(samples.1[1], capturedBy, "PTS is capture time, not when the encoder unblocked")
        }
    }

    private final class StalledSink: VideoFrameSink, @unchecked Sendable {
        let lock = NSLock(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var widths: [Int] = [], timestamps: [Int64] = []
        func encode(_ pb: CVPixelBuffer, ptsNs: Int64) {
            let first = lock.withLock {
                widths.append(CVPixelBufferGetWidth(pb)); timestamps.append(ptsNs)
                return widths.count == 1
            }
            if first { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            else { Thread.sleep(forTimeInterval: 0.02) }
        }
    }

    func testStopIsABarrier() {
        let world = World(), sink = Sink()
        world.booted = true
        let src = SimulatorCaptureSource(scaleFactor: 1, fps: 60, display: SimDisplayState(), attach: world.attach,
                                         readDisplay: { nil }, reattachInterval: 0.1)
        src.start(into: sink)
        wait("attached") { world.lock.withLock { world.surface } != nil }
        src.stop()
        let n = sink.count
        world.deliver(surface(4, 2))
        Thread.sleep(forTimeInterval: 0.7)                    // past a keep-alive
        XCTAssertEqual(sink.count, n, "nothing is encoded after stop() returns")
    }

    private func wait(_ what: String, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !cond() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(cond(), what)
    }
}

private final class LiveLog: @unchecked Sendable {
    private let lock = NSLock(); private var v: [Bool] = []
    func append(_ b: Bool) { lock.withLock { v.append(b) } }
    var values: [Bool] { lock.withLock { v } }
}
private final class SizeLog: @unchecked Sendable {
    private let lock = NSLock(); private var v: [(CGSize, CGFloat)] = []
    func append(_ s: CGSize, _ k: CGFloat) { lock.withLock { v.append((s, k)) } }
    var last: (CGSize, CGFloat)? { lock.withLock { v.last } }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
