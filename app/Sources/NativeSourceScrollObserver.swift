import AppKit
import ShellstormCore
import WebKit

/// Observe, never consume: WebKit retains normal scrolling for controls inside the source document.
/// That document suppresses only its remote-picture DOM sender after host capability negotiation.
@MainActor
final class NativeSourceScrollObserver {
    static var enabled: Bool {
        #if RDEV_DEV_BUILD
        return ProcessInfo.processInfo.environment["RDEV_NATIVE_SCROLL"] != "0"
        #else
        return true
        #endif
    }
    private weak var view: WKWebView?
    private var monitor: Any?
    private var model = NativeScrollGesture()
    private var sequence: UInt64 = 0, incarnation: UInt64 = 0, gesture: UInt64 = 0
    private var last: [String: Any]?
    private let emit: ([String: Any]) -> Void

    init(view: WKWebView, emit: @escaping ([String: Any]) -> Void) {
        self.view = view; self.emit = emit
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event); return event
        }
    }
    func handle(_ event: NSEvent) {
        guard let view, event.window === view.window, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let at = view.convert(event.locationInWindow, from: nil)
        capture(event, at: at)
    }
    // Separated from window routing so isolated checks can characterize actual NSEvent phase
    // extraction/bridge delivery without claiming CGEvent-created events are physical hardware.
    func capture(_ event: NSEvent, at: NSPoint) {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        guard gesture != 0 || view.bounds.contains(at) else { return }
        var phase: NativeScrollGesture.Phase = .none
        if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.mayBegin) { phase = .mayBegin }
        else if event.phase.contains(.changed) { phase = .changed }
        let outputs = model.handle(.init(time: event.timestamp, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
            phase: phase, momentum: !event.momentumPhase.isEmpty, precise: event.hasPreciseScrollingDeltas))
        let y = view.isFlipped ? at.y : view.bounds.height - at.y
        var mods = 0
        for (flag, bit) in [(NSEvent.ModifierFlags.shift, 1), (.control, 2), (.option, 4), (.command, 8), (.capsLock, 16)] {
            if event.modifierFlags.contains(flag) { mods |= bit }
        }
        last = ["x": at.x / view.bounds.width, "y": y / view.bounds.height,
                "width": view.bounds.width, "height": view.bounds.height, "mods": mods]
        for output in outputs { deliver(output, legacy: phase == .none || !event.hasPreciseScrollingDeltas) }
    }
    private func deliver(_ output: NativeScrollGesture.Output, legacy: Bool = false) {
        guard var value = last else { return }
        let event: [String: Any]
        var id = gesture
        switch output {
        case .begin:
            incarnation += 1; gesture = incarnation; id = gesture; event = ["kind": "begin"]
        case .scroll(let dx, let dy, let precise):
            if legacy { id = 0 }
            event = ["kind": "scroll", "dx": dx, "dy": dy, "precise": precise]
        case .end(let vx, let vy): event = ["kind": "end", "vx": vx, "vy": vy]; gesture = 0
        case .cancel: event = ["kind": "cancel"]; gesture = 0
        }
        sequence += 1; value["sequence"] = sequence; value["gesture"] = id; value["events"] = [event]
        emit(value)
    }
    func cancel() { for output in model.cancel() { deliver(output) } }
    func invalidate() {
        cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
