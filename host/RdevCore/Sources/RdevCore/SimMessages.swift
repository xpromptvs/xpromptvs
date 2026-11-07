import Foundation

/// A simulator's lifecycle state on the wire (`source-list`'s and `source-status`'s `simState`). Absent means "not a
/// simulator". CoreSimulator's own numbering (SimDevice.state) is 0 creating · 1 shutdown · 2 booting · 3 booted ·
/// 4 shutting down; a device still being CREATED is not listed at all.
public enum SimState: String, Equatable, Sendable {
    case booted, booting, shutdown, shuttingDown = "shutting-down"

    public init?(coreSimulator raw: Int) {
        switch raw {
        case 1: self = .shutdown
        case 2: self = .booting
        case 3: self = .booted
        case 4: self = .shuttingDown
        default: return nil
        }
    }
}

/// One available simulator, as `SimulatorCatalog` lists it. `w`/`h` are its PORTRAIT size in points and
/// `pxW`/`pxH` in native pixels (the framebuffer's), both from its device type.
public struct SimInfo: Equatable, Sendable {
    public let udid: String
    public let name: String
    /// The runtime's name, e.g. "iOS 27.0".
    public let os: String
    public let state: SimState
    public let w: Int, h: Int, pxW: Int, pxH: Int
    public init(udid: String, name: String, os: String, state: SimState, w: Int, h: Int, pxW: Int, pxH: Int) {
        self.udid = udid; self.name = name; self.os = os; self.state = state
        self.w = w; self.h = h; self.pxW = pxW; self.pxH = pxH
    }
}

/// What `xcrun devicectl device info displays --device <udid> -j -` says of a simulator's PRIMARY display: its
/// interface rotation, its native size in pixels, and its points-to-pixels scale. Read on every
/// `propertiesChangedCallback` — which fires for an APP's rotation as well as the device's (spec, "Measured").
public struct SimDisplayInfo: Equatable, Sendable {
    public let rotation: SimRotation
    public let nativeW: Int, nativeH: Int
    public let pointScale: Double
    public init(rotation: SimRotation, nativeW: Int, nativeH: Int, pointScale: Double) {
        self.rotation = rotation; self.nativeW = nativeW; self.nativeH = nativeH; self.pointScale = pointScale
    }

    public static func parse(devicectlJSON data: Data) -> SimDisplayInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let displays = result["displays"] as? [[String: Any]], !displays.isEmpty else { return nil }
        let d = displays.first { $0["primary"] as? Bool == true } ?? displays[0]
        guard let wire = d["currentOrientation"] as? String, let rotation = SimRotation(wire: wire),
              let size = d["nativeSize"] as? [NSNumber], size.count == 2,
              let scale = (d["pointScale"] as? NSNumber)?.doubleValue, scale > 0 else { return nil }
        return SimDisplayInfo(rotation: rotation, nativeW: size[0].intValue, nativeH: size[1].intValue, pointScale: scale)
    }
}

/// A driver's intent on a simulator (`sim-action`, docs/superpowers/specs/2026-10-13-simulator-sources-design.md).
public enum SimAction: String, Equatable, Sendable {
    case home, keyboard, appSwitcher = "app-switcher", lock, siri, volumeUp = "volume-up", volumeDown = "volume-down"
    case shake, rotateLeft = "rotate-left", rotateRight = "rotate-right", boot, shutdown
}

/// A capturable window (ScreenCaptureKit) as advertised to the client. `minimized` windows are listed so a
/// driver can discover + wake them; they map to `Source(running: false)` (the only listed-but-not-running
/// window case, so the client reads window-kind + !running as "minimized").
public struct WindowInfo: Equatable, Sendable {
    public let id: Int
    public let app: String
    public let title: String
    public let minimized: Bool
    /// The window's size in POINTS (not pixels), when known. Drives the client's actual-size rendering.
    public let w: Int?
    public let h: Int?
    public init(id: Int, app: String, title: String, minimized: Bool = false, w: Int? = nil, h: Int? = nil) {
        self.id = id; self.app = app; self.title = title; self.minimized = minimized
        self.w = w; self.h = h
    }
}

/// One attached display, for the unified source list. `id` is a `CGDirectDisplayID` widened to Int (the
/// same widening `WindowInfo` applies to CGWindowID). `name` is `NSScreen.localizedName` and is used ONLY
/// when more than one display is attached — see `makeSources`.
public struct DisplayInfo: Equatable, Sendable {
    public let id: Int
    public let name: String
    /// Size in POINTS, when known — the same units `WindowInfo` carries, so the client's actual-size
    /// rendering and Auto-resolution arithmetic are identical for both kinds.
    public let w: Int?
    public let h: Int?
    public init(id: Int, name: String, w: Int? = nil, h: Int? = nil) {
        self.id = id; self.name = name; self.w = w; self.h = h
    }
}

private func jsonData(_ obj: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

/// `{"t":"sim-status","udid":…,"phase":…[,"message":…]}` — swap progress / errors.
/// phase ∈ {"booting","attaching","streaming","error"}.
public func simStatusJSON(udid: String, phase: String, message: String?) -> Data {
    var obj: [String: Any] = ["t": "sim-status", "udid": udid, "phase": phase]
    if let message { obj["message"] = message }
    return jsonData(obj)
}
