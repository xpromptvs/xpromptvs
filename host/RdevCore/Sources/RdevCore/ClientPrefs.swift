import Foundation

/// The resolution preference. `auto` lets each window derive its own ceiling from the box it is drawn
/// in — the client's `autoScale`, reported per window as `set-source-prefs{scale}` — while a number
/// fixes every window at that fraction of its native size.
public enum ScalePref: Equatable, Sendable {
    case auto
    case fixed(Double)
}

/// How a touch drives a window: the finger IS the pointer (`direct`) or moves it like a trackpad. The
/// CLIENT's alone — the host parses it only so the preference set is one thing on the wire.
public enum PointerModePref: String, Equatable, Sendable {
    case direct, trackpad
}

/// A DEVICE's preferences (docs/superpowers/specs/2026-09-29-host-session-state-design.md, §2): NOT
/// session state and NOT per window. Saved on the device, sent in `client-hello` and `set-prefs`, and
/// applied by the host to EVERY window it streams to the driver that sent them — so a different device
/// taking over brings its own.
///
/// EVERY FIELD IS OPTIONAL AND ABSENT MEANS THE HOST'S DEFAULT. A device that never chose a frame rate
/// must get the host's, not a zero — and a host default that later changes must reach it.
public struct ClientPrefs: Equatable, Sendable {
    public var fps: Int?
    public var scale: ScalePref
    public var bitrateBps: Int?
    public var codec: CodecPref
    public var av1ReferenceRecovery: Bool
    public var pointerMode: PointerModePref?

    public init(fps: Int? = nil, scale: ScalePref = .auto, bitrateBps: Int? = nil,
                codec: CodecPref = .auto, pointerMode: PointerModePref? = nil, av1ReferenceRecovery: Bool = false) {
        self.fps = fps; self.scale = scale; self.bitrateBps = bitrateBps
        self.codec = codec; self.pointerMode = pointerMode
        self.av1ReferenceRecovery = av1ReferenceRecovery
    }

    /// Nothing chosen: the host's default everywhere.
    public static let `default` = ClientPrefs()

    /// The line past which a number is garbage rather than a wish. NOT clamps — `applyVideoPrefs` and
    /// the host's bitrate cap do those — but 1000 fps is no display's rate, and a bitrate past 10 Gbit/s
    /// would also overflow the `Int` it converts to (a trap, not a bad value).
    static let maxFps: Double = 1000
    static let maxBitrateBps: Double = 10_000_000_000

    /// LENIENT PER FIELD: a malformed field reads as ABSENT — the host's default — and the rest still
    /// apply. A preference is a wish, and one garbled field must not cost a device every other one. (The
    /// `prefs` OBJECT is still required: `parseInbound` drops a message without one.)
    public init(wire: [String: Any]) {
        self.init()
        // JSON numbers also bridge to Bool; only a JSON boolean may opt in.
        if let n = wire["av1ReferenceRecovery"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            av1ReferenceRecovery = n.boolValue
        }
        if let n = wireNumber(wire["fps"]), n >= 1, n <= Self.maxFps { fps = Int(n) }
        if let raw = wire["scale"] as? String {
            if raw == "auto" { scale = .auto }
        } else if let n = wireNumber(wire["scale"]), n > 0 {
            scale = .fixed(n)            // clamped to 0.05…1 where it is applied (`applyVideoPrefs`)
        }
        if let n = wireNumber(wire["bitrateBps"]), n >= 1, n <= Self.maxBitrateBps { bitrateBps = Int(n) }
        // An unrecognised codec is ABSENT (`auto`) — the rule `CodecPref(wire:)` exists for.
        if let raw = wire["codec"] as? String, let c = CodecPref(wire: raw) { codec = c }
        if let raw = wire["pointerMode"] as? String { pointerMode = PointerModePref(rawValue: raw) }
    }
}

/// A JSON number as a finite Double, or nil — and NEVER a JSON boolean. `JSONSerialization` hands a
/// boolean over as an NSNumber, so a plain `as? NSNumber` reads `true` as 1: a frame rate of one.
func wireNumber(_ raw: Any?) -> Double? {
    guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    return d.isFinite ? d : nil
}

/// The prefs a window streams at for a driver: `defaults` — the host's, computed per source by the
/// caller (a display's starting scale and a resolution-derived bitrate included) — overridden by the
/// driver's preferences.
///
/// SCALE: `.fixed(v)` is `v` for every window; `.auto` is the ceiling THIS window's client reported
/// (`autoScale`), and the default until it has. `crop` is the window's own and is carried through.
/// Every clamp is `applyVideoPrefs`' — the one place the bounds live — so this can never disagree with a
/// path that patches prefs directly.
public func resolvedVideoPrefs(defaults: VideoPrefs, client: ClientPrefs, autoScale: Double?,
                               crop: CropRect, bitrateCap: Int) -> VideoPrefs {
    let scale: Double?
    switch client.scale {
    case .fixed(let v): scale = v
    case .auto: scale = autoScale
    }
    return applyVideoPrefs(defaults, fps: client.fps, scale: scale, bitrateBps: client.bitrateBps,
                           codec: client.codec, crop: crop, bitrateCap: bitrateCap)
}
