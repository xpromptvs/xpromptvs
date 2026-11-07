import AppKit
import RdevCore
import ShellstormCore

@MainActor
final class NativeSimulatorInput {
    var send: (InboundMessage) -> Void
    private var press: CGPoint?
    private var option = false, shift = false
    private var last: [SimPoint] = []
    private var modifiers = Set<String>()
    private var scrollModel = NativeScrollGesture()
    private var scrollAnchor: CGPoint?
    private var scrollScale: CGFloat = 1
    var nativeScrollSupported = false
    private var scrollRouting = NativeScrollRouting()
    init(send: @escaping (InboundMessage) -> Void) { self.send = send }
    func release() {
        if let p = scrollAnchor { send(.scrollGesture(x: p.x,y: p.y,phase: .cancel,vx: 0,vy: 0,mods: .none)) }
        _ = scrollModel.cancel(); scrollAnchor = nil
        press = nil; last = []; modifiers.removeAll(); send(.winKeysRelease)
    }
    func text(_ value: String) { if !value.isEmpty { send(.simText(value)) } }
    func handle(_ e: NSEvent, in view: SimulatorMetalView) {
        switch e.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            let at = view.convert(e.locationInWindow, from: nil)
            guard let p = NativeSimulatorPointer.normalized(at, in: view.pictureRect, dragging: press != nil) else { return }
            if e.type == .leftMouseDown {
                press = p; option = e.modifierFlags.contains(.option); shift = e.modifierFlags.contains(.shift)
            }
            guard let press else { return }
            last = NativeSimulatorPointer.fingers(at: p, press: press, option: option, shift: shift).map { SimPoint(x: $0.x, y: $0.y) }
            send(.simTouch(phase: e.type == .leftMouseDown ? "down" : e.type == .leftMouseUp ? "up" : "move", points: last))
            if e.type == .leftMouseUp { self.press = nil; last = [] }
        case .scrollWheel:
            if NativeSourceScrollObserver.enabled,
               scrollRouting.usesNative(phase: scrollPhase(e), momentum: !e.momentumPhase.isEmpty,
                   precise: e.hasPreciseScrollingDeltas, supported: nativeScrollSupported) { nativeScroll(e, in: view); return }
            scroll(at: view.convert(e.locationInWindow, from: nil), in: view,
                   dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas, mods: mods(e))
        case .keyDown, .keyUp:
            if e.type == .keyDown, e.modifierFlags.contains(.command), e.keyCode == 9 {
                if let text = NSPasteboard.general.string(forType: .string) { send(.simText(text)) }
                return
            }
            guard let code = browserCode(forMacVirtualKey: e.keyCode) else { return }
            send(.winKey(down: e.type == .keyDown, code: code, key: e.characters ?? "", repeat: e.isARepeat, mods: mods(e)))
        case .flagsChanged:
            guard let code = browserCode(forMacVirtualKey: e.keyCode) else { return }
            let flag: NSEvent.ModifierFlags
            switch code {
            case "MetaLeft", "MetaRight": flag = .command
            case "ShiftLeft", "ShiftRight": flag = .shift
            case "AltLeft", "AltRight": flag = .option
            case "ControlLeft", "ControlRight": flag = .control
            case "CapsLock": flag = .capsLock
            default: return
            }
            let down = e.modifierFlags.contains(flag)
            if down { modifiers.insert(code) } else { modifiers.remove(code) }
            send(.winKey(down: down, code: code, key: "", repeat: false, mods: mods(e)))
        default: break
        }
    }
    private func nativeScroll(_ event: NSEvent, in view: SimulatorMetalView) {
        let at = view.convert(event.locationInWindow, from: nil)
        let current = NativeSimulatorPointer.normalized(at, in: view.pictureRect, dragging: false)
        let phase = scrollPhase(event)
        let outputs = scrollModel.handle(.init(time: event.timestamp,dx: event.scrollingDeltaX,dy: event.scrollingDeltaY,
            phase: phase,momentum: !event.momentumPhase.isEmpty,precise: event.hasPreciseScrollingDeltas))
        let modifiers = mods(event)
        if event.modifierFlags.contains(.control) {
            if let p = scrollAnchor { send(.scrollGesture(x:p.x,y:p.y,phase:.cancel,vx:0,vy:0,mods:modifiers)) }
            _ = scrollModel.cancel(); scrollAnchor = nil; return
        }
        for output in outputs {
            switch output {
            case .begin:
                scrollAnchor = current
                scrollScale = max(view.pictureRect.width / view.devicePointSize.width, 0.001)
                if let p = scrollAnchor { send(.scrollGesture(x:p.x,y:p.y,phase:.begin,vx:0,vy:0,mods:modifiers)) }
            case .scroll(let dx,let dy,let precise):
                let legacy = phase == .none || !event.hasPreciseScrollingDeltas
                guard let p = legacy ? current : scrollAnchor else { continue }
                let scale = precise ? (legacy ? max(view.pictureRect.width/view.devicePointSize.width,0.001) : scrollScale) : 1
                send(.scroll(x:p.x,y:p.y,dx:dx/scale,dy:dy/scale,unit:precise ? .pixel : .line,mods:modifiers))
            case .end(let vx,let vy):
                if let p = scrollAnchor { send(.scrollGesture(x:p.x,y:p.y,phase:.end,vx:vx/scrollScale,vy:vy/scrollScale,mods:modifiers)) }
                scrollAnchor = nil
            case .cancel:
                if let p = scrollAnchor { send(.scrollGesture(x:p.x,y:p.y,phase:.cancel,vx:0,vy:0,mods:modifiers)) }
                scrollAnchor = nil
            }
        }
    }
    private func scrollPhase(_ event: NSEvent) -> NativeScrollGesture.Phase {
        var phase: NativeScrollGesture.Phase = .none
        if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.mayBegin) { phase = .mayBegin }
        else if event.phase.contains(.changed) { phase = .changed }
        return phase
    }
    func scroll(at point: CGPoint, in view: SimulatorMetalView, dx: CGFloat, dy: CGFloat,
                precise: Bool, mods: InputModifiers = .none) {
        guard let p = NativeSimulatorPointer.normalized(point, in: view.pictureRect, dragging: false) else { return }
        // AppKit's signs are opposite DOM deltaX/Y; precise pixels map through the shown draw scale.
        let scale = precise ? max(view.pictureRect.width / view.devicePointSize.width, 0.001) : 1
        send(.scroll(x: p.x, y: p.y, dx: -dx / scale, dy: -dy / scale, unit: precise ? .pixel : .line, mods: mods))
    }
    private func mods(_ e: NSEvent) -> InputModifiers {
        var raw = 0
        if e.modifierFlags.contains(.shift) { raw |= InputModifiers.shiftBit }
        if e.modifierFlags.contains(.control) { raw |= InputModifiers.controlBit }
        if e.modifierFlags.contains(.option) { raw |= InputModifiers.optionBit }
        if e.modifierFlags.contains(.command) { raw |= InputModifiers.commandBit }
        if e.modifierFlags.contains(.capsLock) { raw |= InputModifiers.capsLockBit }
        return InputModifiers(raw: raw)
    }
}
