import Foundation

/// A parsed source id — a simulator udid, a window CGWindowID, or a display CGDirectDisplayID. The
/// wire form is a kind-prefixed string ("sim:<udid>" / "win:<cgWindowID>" / "dsp:<displayID>"); the
/// host maps this to its `SourceTarget`.
///
/// THE PREFIX IS LOAD-BEARING, not decoration: CGWindowID and CGDirectDisplayID are both UInt32 and
/// draw from different namespaces, so the same number is a valid id of either kind. Nothing but the
/// prefix separates them.
public enum ParsedSourceID: Equatable, Sendable {
    case sim(String)
    case window(Int)
    case display(Int)
    case workspace(String)
}

/// Build the wire id for a simulator udid.
public func sourceID(simUDID udid: String) -> String { "sim:\(udid)" }

/// Build the wire id for a window CGWindowID (as Int).
public func sourceID(windowID id: Int) -> String { "win:\(id)" }

/// Build the wire id for a display's CGDirectDisplayID (as Int).
public func sourceID(displayID id: Int) -> String { "dsp:\(id)" }

/// Parse a wire source id. Returns nil for an unknown prefix, an empty udid, or a non-integer window
/// or display id.
public func parseSourceID(_ id: String) -> ParsedSourceID? {
    if id.hasPrefix("apps:") {
        let uuid=String(id.dropFirst(5))
        guard UUID(uuidString:uuid)?.uuidString==uuid else{return nil}
        return .workspace(uuid)
    }
    if id.hasPrefix("sim:") {
        let u = String(id.dropFirst(4))
        return u.isEmpty ? nil : .sim(u)
    }
    if id.hasPrefix("win:") {
        guard let n = Int(id.dropFirst(4)) else { return nil }
        return .window(n)
    }
    if id.hasPrefix("dsp:") {
        guard let n = Int(id.dropFirst(4)) else { return nil }
        return .display(n)
    }
    return nil
}
