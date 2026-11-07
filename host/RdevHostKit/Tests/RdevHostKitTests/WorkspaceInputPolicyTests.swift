import CoreGraphics
import RdevCore
@testable import RdevHostKit
import XCTest

final class WorkspaceInputPolicyTests: XCTestCase {
    let bounds = CGRect(x: -1280, y: 100, width: 1280, height: 800)
    func testUnknownOwnAndBackgroundNeverFallThroughToLowerWindow() {
        let good = WorkspaceInputWindow(id: 1, ownerPID: 40, identityKnown: true, bundleID: "org.example.Editor", layer: 0, frame: CGRect(x: -1280, y: 100, width: 800, height: 600))
        let point = CGPoint(x: -1200, y: 200)
        XCTAssertTrue(WorkspaceInputPolicy.allows(point: point, bounds: bounds, windows: [good], ownPID: 99))
        for bad in [
            WorkspaceInputWindow(id: 2, ownerPID: 99, identityKnown: true, bundleID: "host", layer: 0, frame: good.frame),
            WorkspaceInputWindow(id: 2, ownerPID: nil, identityKnown: false, bundleID: nil, layer: 0, frame: good.frame),
            WorkspaceInputWindow(id: 2, ownerPID: 50, identityKnown: true, bundleID: "com.apple.dock", layer: 20, frame: good.frame),
            WorkspaceInputWindow(id: 2, ownerPID: 50, identityKnown: true, bundleID: "com.apple.wallpaper.agent", layer: -1, frame: good.frame)
        ] {
            XCTAssertFalse(WorkspaceInputPolicy.allows(point: point, bounds: bounds, windows: [bad, good], ownPID: 99))
        }
        XCTAssertFalse(WorkspaceInputPolicy.allows(point: CGPoint(x: 1, y: 200), bounds: bounds, windows: [good], ownPID: 99))
        XCTAssertFalse(WorkspaceInputPolicy.allows(point: CGPoint(x: CGFloat.nan, y: 200), bounds: bounds, windows: [good], ownPID: 99))
    }
    func testGestureRequiresAdmittedDownAndNativeSafetyThroughout() {
        var gate = WorkspaceInputGesture()
        XCTAssertFalse(gate.admit(phase: "down", button: .left, mask: false, native: true))
        XCTAssertFalse(gate.admit(phase: "up", button: .left, mask: true, native: true))
        XCTAssertTrue(gate.admit(phase: "down", button: .left, mask: true, native: true))
        XCTAssertTrue(gate.admit(phase: "move", button: .left, mask: false, native: true))
        XCTAssertFalse(gate.admit(phase: "move", button: .left, mask: true, native: false))
        XCTAssertTrue(gate.admit(phase: "up", button: .left, mask: false, native: true))
        XCTAssertFalse(gate.admit(phase: "up", button: .left, mask: true, native: true))
        XCTAssertTrue(gate.admit(phase: "down", button: .right, mask: true, native: true))
        gate.reset()
        XCTAssertFalse(gate.admit(phase: "up", button: .right, mask: true, native: true))
    }
    func testAdmittedButUnpostedDownOwesNoCancellationUp() {
        var gate = WorkspaceInputGesture()
        XCTAssertTrue(gate.admit(phase: "down", button: .left, mask: true, native: true))
        XCTAssertNil(gate.postedButton, "lease may revoke after admission but before the native post")
        gate.reset()
        XCTAssertTrue(gate.admit(phase: "down", button: .right, mask: true, native: true))
        gate.didPost(phase: "down", button: .right)
        XCTAssertEqual(gate.postedButton, .right)
        XCTAssertTrue(gate.admit(phase: "up", button: .right, mask: false, native: true))
        XCTAssertEqual(gate.postedButton, .right, "a failed native up still owes cancellation")
        gate.didPost(phase: "up", button: .right)
        XCTAssertNil(gate.postedButton)
    }
    func testCaptureReadinessPausesLeaseWithoutRevivingOldGesture() {
        let lease = WorkspaceInputLease()
        var ready = true
        var gesture = WorkspaceInputGesture()
        XCTAssertTrue(gesture.admit(phase: "down", button: .left, mask: true, native: true))
        XCTAssertTrue(lease.perform(whileReady: { ready }) { gesture.didPost(phase: "down", button: .left) })
        ready = false
        XCTAssertFalse(lease.perform(whileReady: { ready }) { XCTFail("unready capture posted a latched drag") })
        var safeUps = 0
        if gesture.takeCancellationButton() != nil { safeUps += 1 }
        if gesture.takeCancellationButton() != nil { safeUps += 1 }
        XCTAssertEqual(safeUps, 1, "capture loss owes exactly one matching up at a revalidated safe target")
        ready = true
        XCTAssertFalse(gesture.admit(phase: "move", button: .left, mask: true, native: true))
        XCTAssertTrue(gesture.admit(phase: "down", button: .left, mask: true, native: true))
        XCTAssertTrue(lease.perform(whileReady: { ready }) { }, "fresh capture can reuse this injector")
        lease.invalidate()
        XCTAssertFalse(lease.perform(whileReady: { ready }) { XCTFail("readiness cannot undo capability revocation") })
    }
    func testCancellationOnlyReleasesActuallyPostedDownAtSafeTarget() {
        var gesture = WorkspaceInputGesture()
        var ups = 0
        func cancel(nativeSafe: Bool) {
            if gesture.takeCancellationButton() != nil, nativeSafe { ups += 1 }
        }
        XCTAssertTrue(gesture.admit(phase: "down", button: .left, mask: true, native: true))
        cancel(nativeSafe: true)
        XCTAssertEqual(ups, 0)
        XCTAssertTrue(gesture.admit(phase: "down", button: .left, mask: true, native: true))
        gesture.didPost(phase: "down", button: .left)
        cancel(nativeSafe: true)
        cancel(nativeSafe: true)
        XCTAssertEqual(ups, 1)
        XCTAssertTrue(gesture.admit(phase: "down", button: .left, mask: true, native: true))
        gesture.didPost(phase: "down", button: .left)
        cancel(nativeSafe: false)
        XCTAssertEqual(ups, 1, "never release into a protected or changed native owner")
    }
    func testQueuedOldGestureCannotPostAfterSynchronousInvalidation() {
        let lease = WorkspaceInputLease()
        let queue = DispatchQueue(label: "workspace.test.input")
        let releaseQueue = DispatchSemaphore(value: 0)
        let done = expectation(description: "queued event examined")
        XCTAssertTrue(lease.perform { }) // accepted down
        queue.async {
            releaseQueue.wait()
            XCTAssertFalse(lease.perform { XCTFail("stale queued drag posted") })
            done.fulfill()
        }
        lease.invalidate()
        releaseQueue.signal()
        wait(for: [done], timeout: 2)
        XCTAssertFalse(lease.perform { XCTFail("new press on retired injector posted") })
        XCTAssertTrue(WorkspaceInputLease().perform { }, "a fresh capture has its own admission lifetime")
    }
    func testActualAXHitDisambiguatesNoninteractiveDockRectangle() {
        let app = WorkspaceInputWindow(id: 1, ownerPID: 40, identityKnown: true, bundleID: "org.example.Editor", layer: 0, frame: bounds)
        let dock = WorkspaceInputWindow(id: 2, ownerPID: 50, identityKnown: true, bundleID: "com.apple.dock", layer: 20, frame: bounds)
        let point = CGPoint(x: -1200, y: 200)
        XCTAssertTrue(WorkspaceInputPolicy.allowsAXHit(point: point, bounds: bounds, hitPID: 40, windowID: 1, windows: [dock, app], ownPID: 99))
        for (pid, window): (Int32?, UInt32?) in [(99, 1), (nil, 1), (40, nil), (50, 2), (41, 1), (40, 999)] {
            XCTAssertFalse(WorkspaceInputPolicy.allowsAXHit(point: point, bounds: bounds, hitPID: pid, windowID: window, windows: [app, dock], ownPID: 99), "unknown, protected, mismatched and windowless AX targets fail closed")
        }
        let unknown = WorkspaceInputWindow(id: 1, ownerPID: 40, identityKnown: false, bundleID: nil, layer: 0, frame: bounds)
        XCTAssertFalse(WorkspaceInputPolicy.allowsAXHit(point: point, bounds: bounds, hitPID: 40, windowID: 1, windows: [unknown], ownPID: 99))
    }
    func testWindowlessMenuRequiresNativeAncestryGeometryAndWorkspaceFocus() {
        let point = CGPoint(x: -1200, y: 110)
        let frame = CGRect(x: -1250, y: 100, width: 120, height: 30)
        let owner = WorkspaceInputWindow(id: 0, ownerPID: 40, identityKnown: true, bundleID: "editor", layer: 0, frame: frame)
        for role in ["AXMenuBarItem", "AXMenuItem"] {
            XCTAssertTrue(WorkspaceInputPolicy.allowsMenuHit(point: point, bounds: bounds, role: role, frame: frame, owner: owner, ownPID: 99, verifiedMenuAncestry: true, focusedWorkspace: true))
        }
        for (role, ancestry, focus, rect) in [("AXButton", true, true, frame), ("AXMenuItem", false, true, frame), ("AXMenuItem", true, false, frame), ("AXMenuItem", true, true, CGRect.zero), ("AXMenuItem", true, true, CGRect(x: -1300, y: 100, width: 120, height: 30))] {
            XCTAssertFalse(WorkspaceInputPolicy.allowsMenuHit(point: point, bounds: bounds, role: role, frame: rect, owner: owner, ownPID: 99, verifiedMenuAncestry: ancestry, focusedWorkspace: focus))
        }
        for blocked in [WorkspaceInputWindow(id: 0, ownerPID: 99, identityKnown: true, bundleID: "host", layer: 0, frame: frame), WorkspaceInputWindow(id: 0, ownerPID: 50, identityKnown: true, bundleID: "com.apple.dock", layer: 0, frame: frame), WorkspaceInputWindow(id: 0, ownerPID: 40, identityKnown: false, bundleID: "editor", layer: 0, frame: frame)] {
            XCTAssertFalse(WorkspaceInputPolicy.allowsMenuHit(point: point, bounds: bounds, role: "AXMenuItem", frame: frame, owner: blocked, ownPID: 99, verifiedMenuAncestry: true, focusedWorkspace: true))
        }
    }
    func testFocusedWindowMustBeEntirelyInsideWorkspace() {
        XCTAssertTrue(WorkspaceInputPolicy.keyboardFrame(CGRect(x: -1200, y: 130, width: 400, height: 300), in: bounds))
        XCTAssertFalse(WorkspaceInputPolicy.keyboardFrame(CGRect(x: -1300, y: 130, width: 400, height: 300), in: bounds))
        XCTAssertFalse(WorkspaceInputPolicy.keyboardFrame(.null, in: bounds))
    }
}
