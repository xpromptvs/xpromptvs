import XCTest
import RdevCore
@testable import RdevHostKit

/// FINAL REVIEW C1. The catalog's queue is where CoreSimulator can wedge, so nothing may WAIT on it: observers are
/// called off it (theirs stop captures, which wait on capture queues), and an attach or a connect never `queue.sync`s
/// onto it (a capture's reattach doing that, while the poll's observer stopped that capture, deadlocked both).
final class SimulatorCatalogTests: XCTestCase {
    private let info = SimInfo(udid: "U", name: "iPhone", os: "iOS 27.0", state: .booted, w: 402, h: 874, pxW: 1206, pxH: 2622)

    func testObserversAreCalledOffTheCatalogQueue() {
        let catalog = SimulatorCatalog(developerDir: { nil })
        let i = info
        catalog.listOverride = { [i] }
        let called = expectation(description: "observed")
        called.assertForOverFulfill = false
        let label = LabelBox()
        catalog.observe { _ in
            label.set(String(cString: __dispatch_queue_get_label(nil)))
            called.fulfill()
        }
        catalog.setObserving(true)
        wait(for: [called], timeout: 5)
        XCTAssertNotEqual(label.get(), "rdev.sim.catalog", "an observer must never run ON the catalog queue")
    }

    func testAnAttachNeverWaitsOnABusyCatalogQueue() {
        let catalog = SimulatorCatalog(developerDir: { nil })
        catalog.listOverride = { Thread.sleep(forTimeInterval: 3); return [] }   // a WEDGED listing
        _ = catalog.list(deadline: 0.05)                                         // occupies the catalog queue
        let t0 = Date()
        let fb = catalog.attachFramebuffer("U", queue: DispatchQueue(label: "t"), surface: { _ in }, frame: {}, properties: {})
        XCTAssertNil(fb)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5, "attach waited on the wedged catalog queue")
        let t1 = Date()
        XCTAssertNil(catalog.connectHID("U"))
        XCTAssertLessThan(Date().timeIntervalSince(t1), 0.5, "connect waited on the wedged catalog queue")
    }
}

private final class LabelBox: @unchecked Sendable {
    private let lock = NSLock(); private var v = ""
    func set(_ s: String) { lock.withLock { v = s } }
    func get() -> String { lock.withLock { v } }
}
