import Foundation

/// A simulator's hardware buttons, as the DTUHID `IndigoButtonEvent`'s HID Consumer-page usages (page 0x0C).
/// `home` (0x40, Menu) was MEASURED going home from Settings (docs/superpowers/specs/2026-10-13-simulator-sources-design.md,
/// "Measured" — Buttons); the rest are idb's `SimulatorHIDButtonIdentity` values (MIT, facebook/idb).
public enum SimButton: Sendable {
    case home, keyboard, lock, siri, volumeUp, volumeDown

    public var page: UInt16 { 0x0C }
    public var usage: UInt16 {
        switch self {
        case .keyboard: return 0xB8    // Consumer Eject: toggles the guest software keyboard.
        case .home: return 0x40         // Menu
        case .lock: return 0x30         // Power
        case .siri: return 0xCF         // Voice Command
        case .volumeUp: return 0xE9     // Volume Increment
        case .volumeDown: return 0xEA   // Volume Decrement
        }
    }
}
