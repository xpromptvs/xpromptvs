import Foundation

/// Only input can travel inside a source lease. In particular this is not an arbitrary nested
/// InboundMessage: terminal/control/privilege messages and recursively scoped envelopes are refused.
public enum SourceInputEvent: Equatable {
    case touch(x: Double, y: Double, phase: String, button: MouseButton, ts: Int?)
    case hover(x: Double, y: Double)
    case scroll(x: Double, y: Double, dx: Double, dy: Double, unit: ScrollUnit, mods: InputModifiers)
    case scrollFling(x: Double, y: Double, vx: Double, vy: Double, mods: InputModifiers)
    case scrollGesture(x: Double, y: Double, phase: ScrollGesturePhase, vx: Double, vy: Double, mods: InputModifiers)
    case winKey(down: Bool, code: String, key: String, repeat: Bool, mods: InputModifiers)
    case winKeysRelease
    case simTouch(phase: String, points: [SimPoint])
    case simText(String)

    private static let wireTypes: Set<String> = ["touch", "hover", "scroll", "scroll-fling", "scroll-gesture", "win-key", "win-keys-release", "sim-touch", "sim-text"]
    private static let phases: Set<String> = ["down", "move", "up"]
    private static let maxMotion = 1_000_000.0
    private static func coordinate(_ value: Double) -> Double? { value.isFinite ? min(max(value, 0), 1) : nil }
    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue.isFinite ? value.doubleValue : nil
    }
    private static func velocity(_ value: Double) -> Double { value.isFinite && abs(value) <= maxMotion ? value : 0 }

    public static func parse(_ raw: [String: Any]) -> SourceInputEvent? {
        guard let type = raw["t"] as? String, wireTypes.contains(type) else { return nil }
        var object = raw
        if ["touch", "hover", "scroll", "scroll-fling"].contains(type) {
            guard let x = number(raw["x"]), let y = number(raw["y"]) else { return nil }
            object["x"] = x; object["y"] = y
        }
        if type == "scroll" {
            for field in ["dx", "dy"] where raw[field] != nil {
                guard let value = number(raw[field]), abs(value) <= maxMotion else { return nil }
            }
        }
        if type == "scroll-fling" {
            // Zero is STOP. Preserve the legacy rule: a malformed velocity cannot leave a glide running.
            object["vx"] = velocity(number(raw["vx"]) ?? 0)
            object["vy"] = velocity(number(raw["vy"]) ?? 0)
        }
        if type == "sim-touch", let points = raw["points"] as? [[String: Any]] {
            guard points.allSatisfy({ number($0["x"]) != nil && number($0["y"]) != nil }) else { return nil }
        }
        guard let message = parseInboundObject(object) else { return nil }
        return SourceInputEvent(message)
    }

    public init?(_ message: InboundMessage) {
        switch message {
        case .touch(let x, let y, let phase, let button, let ts):
            guard let x = Self.coordinate(x), let y = Self.coordinate(y), Self.phases.contains(phase) else { return nil }
            self = .touch(x: x, y: y, phase: phase, button: button, ts: ts)
        case .hover(let x, let y):
            guard let x = Self.coordinate(x), let y = Self.coordinate(y) else { return nil }
            self = .hover(x: x, y: y)
        case .scroll(let x, let y, let dx, let dy, let unit, let mods):
            guard let x = Self.coordinate(x), let y = Self.coordinate(y), dx.isFinite, dy.isFinite,
                  abs(dx) <= Self.maxMotion, abs(dy) <= Self.maxMotion else { return nil }
            self = .scroll(x: x, y: y, dx: dx, dy: dy, unit: unit, mods: mods)
        case .scrollFling(let x, let y, let vx, let vy, let mods):
            guard let x = Self.coordinate(x), let y = Self.coordinate(y) else { return nil }
            self = .scrollFling(x: x, y: y, vx: Self.velocity(vx), vy: Self.velocity(vy), mods: mods)
        case .scrollGesture(let x, let y, let phase, let vx, let vy, let mods):
            guard let x = Self.coordinate(x), let y = Self.coordinate(y), vx.isFinite, vy.isFinite,
                  abs(vx) <= Self.maxMotion, abs(vy) <= Self.maxMotion else { return nil }
            self = .scrollGesture(x: x, y: y, phase: phase, vx: vx, vy: vy, mods: mods)
        case .winKey(let down, let code, let key, let repeated, let mods):
            guard !code.isEmpty, code.utf8.count <= 64, key.utf8.count <= 4096 else { return nil }
            self = .winKey(down: down, code: code, key: key, repeat: repeated, mods: mods)
        case .winKeysRelease: self = .winKeysRelease
        case .simTouch(let phase, let points):
            guard Self.phases.contains(phase), (1...2).contains(points.count),
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            self = .simTouch(phase: phase, points: points.map { SimPoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) })
        case .simText(let text):
            guard !text.isEmpty, text.utf8.count <= 4096 else { return nil }
            self = .simText(text)
        default: return nil
        }
    }

    public var message: InboundMessage {
        switch self {
        case .touch(let x, let y, let phase, let button, let ts): return .touch(x: x, y: y, phase: phase, button: button, ts: ts)
        case .hover(let x, let y): return .hover(x: x, y: y)
        case .scroll(let x, let y, let dx, let dy, let unit, let mods): return .scroll(x: x, y: y, dx: dx, dy: dy, unit: unit, mods: mods)
        case .scrollFling(let x, let y, let vx, let vy, let mods): return .scrollFling(x: x, y: y, vx: vx, vy: vy, mods: mods)
        case .scrollGesture(let x, let y, let phase, let vx, let vy, let mods): return .scrollGesture(x: x, y: y, phase: phase, vx: vx, vy: vy, mods: mods)
        case .winKey(let down, let code, let key, let repeated, let mods): return .winKey(down: down, code: code, key: key, repeat: repeated, mods: mods)
        case .winKeysRelease: return .winKeysRelease
        case .simTouch(let phase, let points): return .simTouch(phase: phase, points: points)
        case .simText(let text): return .simText(text)
        }
    }
}

/// Negotiation, activation and input are separate commands so accepting a focus request never
/// implicitly accepts input. A lease is issued only after the host has committed the injector.
public enum SourceInputCommand: Equatable {
    case capabilities
    case focus(source: String?, request: String)
    case input(source: String, lease: String, event: SourceInputEvent)

    static func parse(_ object: [String: Any]) -> SourceInputCommand? {
        func token(_ field: String, max: Int) -> String? {
            guard let value = object[field] as? String, !value.isEmpty, value.utf8.count <= max else { return nil }
            return value
        }
        switch object["t"] as? String {
        case "source-input-capabilities":
            guard let version = object["v"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else { return nil }
            return .capabilities
        case "source-focus":
            guard let request = token("request", max: 64) else { return nil }
            if object["source"] is NSNull { return .focus(source: nil, request: request) }
            guard let source = token("source", max: 256) else { return nil }
            return .focus(source: source, request: request)
        case "source-input":
            guard let source = token("source", max: 256), let lease = token("lease", max: 128),
                  let raw = object["event"] as? [String: Any], let event = SourceInputEvent.parse(raw) else { return nil }
            return .input(source: source, lease: lease, event: event)
        default: return nil
        }
    }
}
