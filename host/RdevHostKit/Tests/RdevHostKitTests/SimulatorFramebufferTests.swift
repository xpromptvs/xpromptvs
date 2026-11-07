import CoreVideo
import IOSurface
import XCTest
import RdevCore
@testable import RdevHostKit

final class SimulatorFramebufferTests: XCTestCase {
    private final class Feed: SimFramebufferFeed, @unchecked Sendable {
        let detached = DispatchSemaphore(value: 0)
        func detach() { detached.signal() }
    }

    func testRawFramesKeepOddNativeSizeAndAreNotCappedOrRepeated() {
        let frames = expectation(description: "all presented frames"); frames.expectedFulfillmentCount = 4
        let attached = expectation(description: "attached")
        let feed = Feed()
        let s = IOSurface(properties: [.width: 5, .height: 3, .bytesPerElement: 4, .bytesPerRow: 20,
                                       .pixelFormat: kCVPixelFormatType_32BGRA])!
        let fb = SimulatorFramebuffer(display: SimDisplayState(), attach: { q, surface, frame, _ in
            q.async { surface(s); frame(); frame(); frame(); attached.fulfill() }
            return feed
        }, readDisplay: { nil })
        let lock = NSLock(); var sequences: [UInt64] = []
        fb.start { value in
            guard let value else { return }
            XCTAssertTrue(value.surface === s)
            XCTAssertEqual(value.surface.width, 5)
            XCTAssertEqual(value.surface.height, 3)
            lock.withLock { sequences.append(value.sequence) }
            frames.fulfill()
        }
        wait(for: [attached, frames], timeout: 3)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(lock.withLock { sequences }, [1, 2, 3, 4], "no encoder cap or keep-alive")
        fb.stop()
    }

    func testPropertiesCanPrecedeTheDisplayServicesNewOrientation() {
        let turned = expectation(description: "settled orientation without another callback")
        let lock = NSLock(); var orientation = SimRotation.rot0
        let s = IOSurface(properties: [.width: 4, .height: 2, .bytesPerElement: 4, .bytesPerRow: 16,
                                       .pixelFormat: kCVPixelFormatType_32BGRA])!
        let fb = SimulatorFramebuffer(display: SimDisplayState(), attach: { q, surface, _, properties in
            q.async { surface(s); properties() }
            q.asyncAfter(deadline: .now() + 0.2) { lock.withLock { orientation = .rot270 } }
            return Feed()
        }, readDisplay: {
            SimDisplayInfo(rotation: lock.withLock { orientation }, nativeW: 4, nativeH: 2, pointScale: 1)
        })
        var seen = false
        fb.start { frame in if frame?.rotation == .rot270, !seen { seen = true; turned.fulfill() } }
        wait(for: [turned], timeout: 2)
        fb.stop()
    }

    func testStopDoesNotWaitForAttachAndLateFeedIsDetached() {
        let entered = expectation(description: "attach entered")
        let unblock = DispatchSemaphore(value: 0), feed = Feed()
        let fb = SimulatorFramebuffer(display: SimDisplayState(), attach: { _, _, _, _ in
            entered.fulfill(); unblock.wait(); return feed
        }, readDisplay: { nil })
        fb.start { _ in XCTFail("stopped feed must not deliver") }
        wait(for: [entered], timeout: 3)
        let t = Date(); fb.stop()
        XCTAssertLessThan(Date().timeIntervalSince(t), 0.2)
        unblock.signal()
        XCTAssertEqual(feed.detached.wait(timeout: .now() + 3), .success)
    }
    func testCallbacksFromALostFeedCannotResurrectItsSurface() {
        let delivered = expectation(description: "callbacks delivered")
        let s = IOSurface(properties: [.width: 4, .height: 2, .bytesPerElement: 4, .bytesPerRow: 16,
                                       .pixelFormat: kCVPixelFormatType_32BGRA])!
        let lock = NSLock(); var live: [Bool] = []
        let fb = SimulatorFramebuffer(display: SimDisplayState(), attach: { q, surface, frame, _ in
            q.async { surface(s); surface(nil); surface(s); frame(); delivered.fulfill() }
            return Feed()
        }, readDisplay: { nil }, reattachInterval: 10)
        fb.start { value in lock.withLock { live.append(value != nil) } }
        wait(for: [delivered], timeout: 3)
        fb.stop()
        XCTAssertEqual(lock.withLock { live }, [true, false], "the dead IO port cannot restore stale pixels")
    }

}
