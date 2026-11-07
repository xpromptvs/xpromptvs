import Foundation
import RdevCore

/// The caller validates its captured route while holding the ownership lock around ONLY `post`.
/// AX, HID connection and clipboard work must happen before entering this boundary.
public typealias InputPostFence = (_ post: () -> Void) -> Bool

/// Queue-local context, retained explicitly by delayed work. Nested input dispatch stays on the
/// injector's existing queue; ordinary callers still enqueue, preserving legacy event ordering.
final class ScopedInputExecution {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<Bool>()
    private var depth = 0
    private(set) var fence: InputPostFence?

    init(queue: DispatchQueue) { self.queue = queue; queue.setSpecific(key: key, value: true) }
    var executing: Bool { DispatchQueue.getSpecific(key: key) == true && depth > 0 }
    func run(fence: InputPostFence?, _ work: () -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let previous = self.fence
        self.fence = fence; depth += 1
        defer { depth -= 1; self.fence = previous }
        work()
    }
    func enqueue(_ work: @escaping () -> Void) {
        if executing { work() } else { queue.async(execute: work) }
    }
    func capture(_ work: @escaping () -> Void) -> () -> Void {
        let captured = fence
        return { self.run(fence: captured, work) }
    }
    @discardableResult func post(_ work: () -> Void) -> Bool {
        if let fence { return fence(work) }
        work(); return true
    }
    var current: Bool { post {} }
}

extension InputInjector {
    /// Called inside the injector's serial queue, under its captured post context.
    func dispatchScoped(_ event: SourceInputEvent) {
        switch event {
        case .touch(let x, let y, let phase, let button, _): inject(touchNormalizedX: x, y: y, phase: phase, button: button)
        case .hover(let x, let y): move(normalizedX: x, normalizedY: y)
        case .scroll(let x, let y, let dx, let dy, let unit, let mods):
            scroll(normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy, unit: unit, mods: mods)
        case .scrollFling(let x, let y, let vx, let vy, let mods):
            scrollFling(normalizedX: x, normalizedY: y, velocityX: vx, velocityY: vy, mods: mods)
        case .scrollGesture(let x, let y, let phase, let vx, let vy, let mods):
            scrollGesture(normalizedX: x, normalizedY: y, phase: phase, velocityX: vx, velocityY: vy, mods: mods)
        case .winKey(let down, let code, let key, let repeated, let mods):
            self.key(down: down, code: code, key: key, repeat: repeated, mods: mods)
        case .winKeysRelease: releaseKeys()
        case .simTouch(let phase, let points): simTouch(phase: phase, points: points)
        case .simText(let text): simText(text)
        }
    }
}

/// A view of an already connected sink. Every actual HID operation rechecks the captured lease,
/// including operations after a blocking connect and each character of a text commit.
final class ScopedSimHIDSink: SimHIDSink {
    let raw: SimHIDSink
    let fence: InputPostFence
    let didKey: (UInt32, Bool) -> Void
    let didTouch: (SimTouchEvent) -> Void
    let didAttemptTouch: () -> Void
    init(raw: SimHIDSink, fence: @escaping InputPostFence, didAttemptTouch: @escaping () -> Void, didTouch: @escaping (SimTouchEvent) -> Void,
         didKey: @escaping (UInt32, Bool) -> Void) {
        self.raw = raw; self.fence = fence; self.didKey = didKey; self.didTouch = didTouch; self.didAttemptTouch = didAttemptTouch
    }
    var invalidated: Bool { raw.invalidated }
    func touch(_ event: SimTouchEvent) {
        didAttemptTouch()
        if fence({ raw.touch(event) }) { didTouch(event) }
    }
    func key(_ usage: UInt32, down: Bool) {
        if fence({ raw.key(usage, down: down) }) { didKey(usage, down) }
    }
    func button(_ button: SimButton, down: Bool) { _ = fence { raw.button(button, down: down) } }
}
