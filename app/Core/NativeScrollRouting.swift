import Foundation

/// Latch the route for one physical contact and its OS momentum tail. A capability that arrives during a legacy
/// gesture must wait for the next contact, or half the scroll disappears between WebKit/AppKit and the host.
public struct NativeScrollRouting {
    private var native: Bool?
    public init() {}
    public mutating func usesNative(phase: NativeScrollGesture.Phase, momentum: Bool, precise: Bool, supported: Bool) -> Bool {
        guard precise else { return false }
        if phase == .began || phase == .mayBegin || (phase == .changed && native == nil) { native = supported }
        if phase == .none && !momentum { return false }
        return native ?? false
    }
}
