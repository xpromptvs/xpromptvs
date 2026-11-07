import CoreGraphics

/// The modifier snapshot every browser-originated input message carries (`scroll`, `win-key`).
///
/// It is a SNAPSHOT off the originating DOM event, not accumulated state, which is what makes it
/// self-correcting: a modifier held down BEFORE the window took keyboard focus produced no keydown
/// for the host to see, but it is still present on the wheel/key event that follows.
///
/// Unknown bits are DROPPED rather than passed through. A newer client adding a sixth modifier must
/// degrade to "that modifier is absent", never to an arbitrary `CGEventFlags` bit on every event the
/// host posts — the same rule `CodecPref` follows for an unrecognised codec string.
public struct InputModifiers: Equatable, Sendable {
    public static let shiftBit = 1
    public static let controlBit = 2
    public static let optionBit = 4
    public static let commandBit = 8
    public static let capsLockBit = 16
    private static let knownBits = shiftBit | controlBit | optionBit | commandBit | capsLockBit

    public static let none = InputModifiers(raw: 0)

    public let raw: Int
    public init(raw: Int) { self.raw = raw & Self.knownBits }

    public var shift: Bool    { raw & Self.shiftBit != 0 }
    public var control: Bool  { raw & Self.controlBit != 0 }
    public var option: Bool   { raw & Self.optionBit != 0 }
    public var command: Bool  { raw & Self.commandBit != 0 }
    public var capsLock: Bool { raw & Self.capsLockBit != 0 }

    public var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if shift    { f.insert(.maskShift) }
        if control  { f.insert(.maskControl) }
        if option   { f.insert(.maskAlternate) }
        if command  { f.insert(.maskCommand) }
        if capsLock { f.insert(.maskAlphaShift) }
        return f
    }
}
