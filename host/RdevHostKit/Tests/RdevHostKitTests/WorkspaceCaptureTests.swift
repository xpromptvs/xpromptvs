import XCTest
import CoreVideo
import CoreGraphics
@testable import RdevHostKit

final class WorkspaceCaptureTests: XCTestCase {
    func testParkedApplicationCaptureIgnoresLegacyOptInWithoutCreatingWorkspace() {
        let savedFlag = ProcessInfo.processInfo.environment["RDEV_APPS_EXPERIMENTAL"]
        let savedJournal = ProcessInfo.processInfo.environment["RDEV_APPS_JOURNAL_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("RDEV_APPS_EXPERIMENTAL", "1", 1)
        setenv("RDEV_APPS_JOURNAL_DIR", root.path, 1)
        defer {
            if let savedFlag { setenv("RDEV_APPS_EXPERIMENTAL", savedFlag, 1) } else { unsetenv("RDEV_APPS_EXPERIMENTAL") }
            if let savedJournal { setenv("RDEV_APPS_JOURNAL_DIR", savedJournal, 1) } else { unsetenv("RDEV_APPS_JOURNAL_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        let coordinator = AppWorkspaceCoordinator()
        let done = expectation(description: "parked Apps request refused")
        coordinator.request("list", app: nil) { state in
            XCTAssertEqual(state.availability, "disabled")
            XCTAssertTrue(state.applications.isEmpty)
            XCTAssertTrue(state.members.isEmpty)
            XCTAssertNil(state.source)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "disabled mode must not construct the native adapter or journal")
    }

    func testBackgroundRolesAndOwnerFamiliesCannotEnterWorkspace() {
        let display = CGRect(x: 2000, y: 0, width: 1280, height: 800)
        let small = CGRect(x: 2100, y: 100, width: 300, height: 200)
        func excluded(_ bundle: String, _ layer: Int, _ frame: CGRect) -> Bool {
            WorkspaceBackgroundPolicy.excludes(bundleID: bundle, layer: layer, frame: frame, display: display)
        }
        let topBand = CGRect(x: display.minX, y: display.minY, width: display.width, height: 67)
        XCTAssertTrue(excluded("com.apple.WindowManager", -2147483624, display))
        XCTAssertTrue(excluded("", -2147483626, display))
        XCTAssertTrue(excluded("", -2147483602, topBand))
        XCTAssertFalse(excluded("org.example.app", -10, display))
        XCTAssertFalse(excluded("org.example.app", -10, topBand))
        XCTAssertFalse(excluded("org.example.app", -2147483624, small))
        XCTAssertFalse(excluded("org.example.app", 101, topBand))
        XCTAssertFalse(excluded("org.example.app", 24, topBand))
        XCTAssertTrue(excluded("com.apple.wallpaper.agent", 0, display))
        XCTAssertTrue(excluded("com.apple.wallpaper.dynamic", -1, small))
        XCTAssertTrue(excluded("com.apple.dock", 0, small))
        XCTAssertTrue(excluded("unknown.owner", Int(CGWindowLevelForKey(.desktopWindow)), display))
        XCTAssertTrue(excluded("com.apple.finder", Int(CGWindowLevelForKey(.desktopIconWindow)), small))
        XCTAssertTrue(excluded("com.apple.finder", -1, display))
        XCTAssertFalse(excluded("com.apple.finder", 0, display))
        XCTAssertFalse(excluded("com.apple.finder", -1, small))
        XCTAssertFalse(excluded("org.example.app", -1, display))
        XCTAssertFalse(excluded("org.example.app", Int(CGWindowLevelForKey(.popUpMenuWindow)), small))
        XCTAssertFalse(excluded("org.example.app", Int(CGWindowLevelForKey(.mainMenuWindow)), display))
    }

    func testExpiryClearsFrameWithoutReplacingCaptureAndRejectsLatePTS() {
        var store = CompositionFrameStore<String>()
        let generation = store.begin(42)
        XCTAssertTrue(store.receive("old", id: 42, generation: generation, timestamp: 10))
        XCTAssertTrue(store.discard(42, generation: generation, before: 30))
        XCTAssertNil(store.frames[42])
        XCTAssertFalse(store.receive("late", id: 42, generation: generation, timestamp: 20))
        XCTAssertTrue(store.receive("fresh", id: 42, generation: generation, timestamp: 40))
        XCTAssertEqual(store.frames[42], "fresh")
        store.retire(42)
        _ = store.begin(42)
        XCTAssertFalse(store.receive("retired", id: 42, generation: generation, timestamp: 50))
    }

    func testLateExpiryDoesNotEraseNewerAdmittedFrameOrLowerItsTimestamp() {
        var store = CompositionFrameStore<String>()
        let generation = store.begin(42)
        XCTAssertTrue(store.receive("fresh", id: 42, generation: generation, timestamp: 40))
        XCTAssertFalse(store.discard(42, generation: generation, before: 30))
        XCTAssertEqual(store.frames[42], "fresh")
        XCTAssertFalse(store.receive("stale completion", id: 42, generation: generation, timestamp: 31))
        XCTAssertEqual(store.frames[42], "fresh")
    }

    private final class Sink: VideoFrameSink {
        func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64) {}
    }

    @MainActor func testBaseFailureRestartsAndPermissionDenialPreservesOriginalError() async {
        let restarted = expectation(description: "same source restarts its base")
        var starts = 0
        let source = WorkspaceCaptureSource(displayID: 0, captureStart: {
            starts += 1
            if starts == 2 { restarted.fulfill() }
        })
        source.start(into: Sink())
        source.recoverAfterBaseFailure(NSError(domain: "NativeSCK", code: -3805))
        XCTAssertFalse(source.inputReady)
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(starts, 2)
        var failure: NSError?
        source.onError = { failure = $0 as NSError }
        source.recoverAfterBaseFailure(NSError(domain: "NativeSCK", code: -3801))
        XCTAssertEqual(failure?.domain, "NativeSCK")
        XCTAssertEqual(failure?.code, -3801)
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(starts, 2, "permission refusal must not schedule another capture")
        source.stop()
    }

    @MainActor func testSuccessfulNativeStartWithoutAFirstComposedFrameRestarts() async {
        let restarted = expectation(description: "silent successful start retried")
        var starts = 0
        let source = WorkspaceCaptureSource(displayID: 0, captureStart: {
            starts += 1
            if starts == 2 { restarted.fulfill() }
        })
        source.start(into: Sink())
        source.checkFirstFrameDeadline(now: ProcessInfo.processInfo.systemUptime + 2)
        XCTAssertEqual(starts, 1)
        source.checkFirstFrameDeadline(now: ProcessInfo.processInfo.systemUptime + 3.1)
        XCTAssertFalse(source.inputReady)
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(starts, 2)
        source.stop()
        source.checkFirstFrameDeadline(now: ProcessInfo.processInfo.systemUptime + 10)
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(starts, 2, "stopped capture never restarts through an old deadline")
    }

    @MainActor func testExplicitStopCancelsPendingBaseRetryAndReleasesItsSink() async {
        var starts = 0
        let source = WorkspaceCaptureSource(displayID: 0, captureStart: { starts += 1 })
        var sink: Sink? = Sink()
        weak var retained = sink
        source.start(into: sink!)
        sink = nil
        source.recoverAfterBaseFailure(NSError(domain: "NativeSCK", code: -3805))
        XCTAssertNotNil(retained, "the pending retry owns the overlay/encoder sink")
        source.stop()
        XCTAssertNil(retained, "explicit stop releases the pending retry sink")
        XCTAssertFalse(source.inputReady)
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(starts, 1, "a cancelled generation cannot resurrect capture")
    }

    @MainActor func testNewStartSupersedesPendingBaseRetry() async {
        var starts = 0
        let source = WorkspaceCaptureSource(displayID: 0, captureStart: { starts += 1 })
        source.start(into: Sink())
        source.recoverAfterBaseFailure(NSError(domain: "NativeSCK", code: -3805))
        source.start(into: Sink())
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(starts, 2, "old retry must not start a third capture over the replacement")
        source.stop()
    }

    func testRejectedGeometryLeaseExpiresEvenWithoutAnotherCaptureCallback() {
        var lease = ResizeRejectionLease(timeout: 0.100)
        XCTAssertFalse(lease.observe(accepted: false, now: 10))
        XCTAssertFalse(lease.takeExpiry(now: 10.099))
        XCTAssertTrue(lease.takeExpiry(now: 10.101))
        XCTAssertFalse(lease.observe(accepted: true, now: 10.102))
        XCTAssertFalse(lease.takeExpiry(now: 11))
    }

    func testValidationMailboxKeepsOnlyNewestWaitingSample() {
        var mailbox = LatestValidationMailbox<Int>()
        XCTAssertEqual(mailbox.submit(1), 1)
        XCTAssertNil(mailbox.submit(2))
        XCTAssertNil(mailbox.submit(3))
        XCTAssertEqual(mailbox.complete(), 3)
        XCTAssertNil(mailbox.complete())
        XCTAssertFalse(mailbox.active)
    }

    func testPackingPreservesPremultipliedColorAndCarriesMaskInSameFrame() throws {
        let width = 17, height = 8 // Exercises NEON and scalar tail together.
        var source: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &source), kCVReturnSuccess)
        let color = try XCTUnwrap(source)
        CVPixelBufferLockBaseAddress(color, [])
        let data = try XCTUnwrap(CVPixelBufferGetBaseAddress(color)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(color)
        for y in 0..<height { for x in 0..<width {
            let p = data + y * stride + x * 4
            p[0] = 20; p[1] = 40; p[2] = 64; p[3] = 128
        }}
        CVPixelBufferUnlockBaseAddress(color, [])
        let hit = try XCTUnwrap(WorkspaceHitMask.make(width: width, height: height, regions: [CGRect(x: 2, y: 1, width: 5, height: 3)]))
        let packed = try XCTUnwrap(WorkspacePacking.pack(color: color, hit: hit))
        XCTAssertEqual(CVPixelBufferGetWidth(packed), width * 3)
        XCTAssertEqual(CVPixelBufferGetHeight(packed), height)
        CVPixelBufferLockBaseAddress(packed, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(packed, .readOnly) }
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(packed)).assumingMemoryBound(to: UInt8.self)
        let packedStride = CVPixelBufferGetBytesPerRow(packed)
        for y in 0..<height { for x in 0..<width {
            let p = pixels + y * packedStride + x * 4
            XCTAssertEqual(Array(UnsafeBufferPointer(start: p, count: 4)), [20, 40, 64, 255])
            XCTAssertEqual(Array(UnsafeBufferPointer(start: p + width * 4, count: 4)), [128, 128, 128, 255])
            let expected: UInt8 = (2..<7).contains(x) && (1..<4).contains(y) ? 255 : 0
            XCTAssertEqual(p[width * 8], expected)
        }}
    }

    func testInputRefusesUntilCaptureHasAdmittedAMask() {
        let source = WorkspaceCaptureSource(displayID: 0)
        XCTAssertFalse(source.hitAt(normalizedX: 0.5, y: 0.5))
        XCTAssertFalse(source.hitAt(normalizedX: .nan, y: 0))
        XCTAssertFalse(source.hitAt(normalizedX: 1, y: 0))
    }
}
