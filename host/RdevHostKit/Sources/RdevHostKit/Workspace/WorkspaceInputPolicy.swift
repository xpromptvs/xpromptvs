import Foundation
import CoreGraphics
import RdevCore

/// A process-local ownership epoch changes even across A→B→A or same-ID reconnection.
/// The immutable binding is checked again at each native post, after any blocked AX work.
struct WorkspaceInputOwnership: Sendable {
    let epoch: UInt64?
    let current: @Sendable () -> UInt64?
    var isCurrent: Bool { epoch != nil && current() == epoch }
}

/// Native z-order snapshot. Unknown ownership is a blocker, never a reason to try the window below.
struct WorkspaceInputWindow: Sendable {
    let id: UInt32
    let ownerPID: Int32?
    let identityKnown: Bool
    let bundleID: String?
    let layer: Int?
    let frame: CGRect
}

enum WorkspaceInputPolicy {
    static func ownerAllowed(_ window: WorkspaceInputWindow, ownPID: Int32) -> Bool {
        guard let pid = window.ownerPID, pid > 0, pid != ownPID, window.identityKnown,
              let layer = window.layer, layer >= 0 else { return false }
        return !["com.apple.dock", "com.apple.wallpaper.agent"].contains(window.bundleID?.lowercased() ?? "")
    }
    static func allows(point: CGPoint, bounds: CGRect, windows: [WorkspaceInputWindow], ownPID: Int32) -> Bool {
        guard point.x.isFinite, point.y.isFinite, bounds.width > 0, bounds.height > 0,
              bounds.contains(point), let top = windows.first(where: { $0.frame.contains(point) }) else { return false }
        return ownerAllowed(top, ownPID: ownPID)
    }
    static func allowsAXHit(point: CGPoint, bounds: CGRect, hitPID: Int32?, windowID: UInt32?,
                            windows: [WorkspaceInputWindow], ownPID: Int32) -> Bool {
        guard point.x.isFinite, point.y.isFinite, bounds.contains(point),
              let hitPID, let windowID, windowID != 0,
              let window = windows.first(where: { $0.id == windowID }),
              window.ownerPID == hitPID, window.frame.contains(point) else { return false }
        return ownerAllowed(window, ownPID: ownPID)
    }
    static func allowsMenuHit(point: CGPoint, bounds: CGRect, role: String, frame: CGRect,
                              owner: WorkspaceInputWindow, ownPID: Int32,
                              verifiedMenuAncestry: Bool, focusedWorkspace: Bool) -> Bool {
        guard ["AXMenuBarItem", "AXMenuItem"].contains(role), verifiedMenuAncestry, focusedWorkspace,
              point.x.isFinite, point.y.isFinite, keyboardFrame(frame, in: bounds),
              frame.contains(point) else { return false }
        return ownerAllowed(owner, ownPID: ownPID)
    }
    static func keyboardFrame(_ frame: CGRect, in bounds: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0 &&
            bounds.width > 0 && bounds.height > 0 && bounds.contains(frame)
    }
}

/// The browser's ownership decision is independently enforced at the host. Only an admitted down
/// starts a gesture. Its continuation may cross a transparent gap, but never a prohibited native target.
struct WorkspaceInputGesture {
    private(set) var button: MouseButton?
    private(set) var postedButton: MouseButton?
    mutating func reset() { button = nil; postedButton = nil }
    mutating func takeCancellationButton() -> MouseButton? {
        let posted = postedButton
        reset()
        return posted
    }
    mutating func didPost(phase: String, button: MouseButton) {
        if phase == "down" { postedButton = button }
        if phase == "up" { postedButton = nil }
    }
    mutating func admit(phase: String, button incoming: MouseButton, mask: Bool, native: Bool) -> Bool {
        if phase == "down" {
            guard button == nil, mask, native else { return false }
            button = incoming; return true
        }
        guard button == incoming else { return false }
        if phase == "up" { button = nil }
        return native
    }
}

/// Revocation is synchronous with the post boundary, not a queued message behind old drags.
/// Once invalidate returns, no ordinary event queued for this capture lifetime can post.
final class WorkspaceInputLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func invalidate() { lock.lock(); active = false; lock.unlock() }
    @discardableResult func perform(whileReady ready: () -> Bool = { true }, _ post: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, ready() else { return false }
        post(); return true
    }
}
