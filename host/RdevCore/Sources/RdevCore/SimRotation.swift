import Foundation

/// A simulator display's INTERFACE rotation, as `xcrun devicectl device info displays` names it
/// (`currentOrientation`: "rot0" … "rot270").
///
/// THE FRAMEBUFFER NEVER ROTATES (docs/superpowers/specs/2026-10-13-simulator-sources-design.md, "Measured" —
/// Rotation): the IOSurface stays native (portrait) and the content is drawn sideways in it, and the digitizer takes
/// NATIVE-frame points. So the host turns the picture before encoding it and turns every touch back — both through
/// this one type, so they cannot disagree.
public enum SimRotation: Int, Equatable, Sendable, CustomStringConvertible {
    case rot0 = 0, rot90 = 90, rot180 = 180, rot270 = 270

    public init?(wire: String) {
        switch wire {
        case "rot0": self = .rot0
        case "rot90": self = .rot90
        case "rot180": self = .rot180
        case "rot270": self = .rot270
        default: return nil
        }
    }

    public var description: String { "rot\(rawValue)" }

    /// Whether the shown picture's width is the native height.
    public var swapsAxes: Bool { self == .rot90 || self == .rot270 }

    public func shownSize(nativeW: Int, nativeH: Int) -> (w: Int, h: Int) {
        swapsAxes ? (nativeH, nativeW) : (nativeW, nativeH)
    }

    /// A point normalised to the SHOWN picture → the native-frame point the digitizer takes. rot270 is MEASURED;
    /// rot90 is its mirror and rot180 the half turn.
    public func nativePoint(shownX x: Double, shownY y: Double) -> (x: Double, y: Double) {
        switch self {
        case .rot0: return (x, y)
        case .rot270: return (1 - y, x)
        case .rot90: return (y, 1 - x)
        case .rot180: return (1 - x, 1 - y)
        }
    }

    /// The inverse of `nativePoint`.
    public func shownPoint(nativeX x: Double, nativeY y: Double) -> (x: Double, y: Double) {
        switch self {
        case .rot0: return (x, y)
        case .rot270: return (y, 1 - x)
        case .rot90: return (1 - y, x)
        case .rot180: return (1 - x, 1 - y)
        }
    }

    /// `vImageRotate90_ARGB8888`'s `rotationConstant` that turns the NATIVE image into the SHOWN one. vImage counts
    /// counter-clockwise quarter turns.
    public var vImageRotationConstant: UInt8 {
        switch self {
        case .rot0: return 0
        case .rot270: return 1
        case .rot180: return 2
        case .rot90: return 3
        }
    }
}
