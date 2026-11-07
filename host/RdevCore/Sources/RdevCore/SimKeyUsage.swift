import Foundation

/// USB HID keyboard usages (page 0x07) for an iOS simulator's DTUHID keyboard
/// (docs/superpowers/specs/2026-10-13-simulator-sources-design.md, "Measured"). A simulator takes keys as USB HID
/// usages, NOT as macOS virtual keycodes (`KeyInjection.macVirtualKeys`): the two numberings share nothing, and a
/// key sent in the wrong one types a different letter rather than failing.
///
/// THE TABLE IS READ TWICE: here, and in `protocol/fixtures/sim-key-usages.json`, written separately from the USB
/// HID Usage Tables 1.4 §10. `SimKeyUsageTests` asserts they agree.
public enum SimKeyUsage {
    public static let leftControl: UInt32 = 0xE0
    public static let leftShift: UInt32 = 0xE1
    public static let leftOption: UInt32 = 0xE2
    public static let leftCommand: UInt32 = 0xE3
    public static let v: UInt32 = 0x19

    /// The usage for a W3C `KeyboardEvent.code`, or nil for a code a simulator has no key for.
    public static func usage(forCode code: String) -> UInt32? { codes[code] }

    /// The usage, and whether ⇧ must be held, that types `ch` on a US layout; nil when no key does (é, emoji).
    public static func usage(forCharacter ch: Character) -> (usage: UInt32, shift: Bool)? { chars[ch] }

    /// Whether every character of `text` has a key, so it is TYPED rather than pasted. An empty string is not.
    public static func typeable(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { chars[$0] != nil }
    }

    static let codes: [String: UInt32] = {
        var t: [String: UInt32] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { t["Key\(c)"] = 0x04 + UInt32(i) }
        for n in 1...9 { t["Digit\(n)"] = 0x1E + UInt32(n - 1) }
        t["Digit0"] = 0x27
        for n in 1...12 { t["F\(n)"] = 0x3A + UInt32(n - 1) }
        for n in 1...9 { t["Numpad\(n)"] = 0x59 + UInt32(n - 1) }
        t["Numpad0"] = 0x62
        let named: [String: UInt32] = [
            "Enter": 0x28, "Escape": 0x29, "Backspace": 0x2A, "Tab": 0x2B, "Space": 0x2C, "Minus": 0x2D,
            "Equal": 0x2E, "BracketLeft": 0x2F, "BracketRight": 0x30, "Backslash": 0x31, "Semicolon": 0x33,
            "Quote": 0x34, "Backquote": 0x35, "Comma": 0x36, "Period": 0x37, "Slash": 0x38, "CapsLock": 0x39,
            "Insert": 0x49, "Home": 0x4A, "PageUp": 0x4B, "Delete": 0x4C, "End": 0x4D, "PageDown": 0x4E,
            "ArrowRight": 0x4F, "ArrowLeft": 0x50, "ArrowDown": 0x51, "ArrowUp": 0x52,
            "NumpadDivide": 0x54, "NumpadMultiply": 0x55, "NumpadSubtract": 0x56, "NumpadAdd": 0x57,
            "NumpadEnter": 0x58, "NumpadDecimal": 0x63, "IntlBackslash": 0x64, "NumpadEqual": 0x67,
            "ControlLeft": 0xE0, "ShiftLeft": 0xE1, "AltLeft": 0xE2, "MetaLeft": 0xE3,
            "ControlRight": 0xE4, "ShiftRight": 0xE5, "AltRight": 0xE6, "MetaRight": 0xE7,
        ]
        t.merge(named) { a, _ in a }
        return t
    }()

    static let chars: [Character: (usage: UInt32, shift: Bool)] = {
        var t: [Character: (usage: UInt32, shift: Bool)] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            t[c] = (0x04 + UInt32(i), false)
            t[Character(c.uppercased())] = (0x04 + UInt32(i), true)
        }
        for (i, c) in "1234567890".enumerated() { t[c] = (0x1E + UInt32(i), false) }
        for (i, c) in "!@#$%^&*()".enumerated() { t[c] = (0x1E + UInt32(i), true) }
        t["\n"] = (0x28, false); t["\t"] = (0x2B, false); t[" "] = (0x2C, false)
        let pairs: [(Character, Character, UInt32)] = [
            ("-", "_", 0x2D), ("=", "+", 0x2E), ("[", "{", 0x2F), ("]", "}", 0x30), ("\\", "|", 0x31),
            (";", ":", 0x33), ("'", "\"", 0x34), ("`", "~", 0x35), (",", "<", 0x36), (".", ">", 0x37),
            ("/", "?", 0x38),
        ]
        for (plain, shifted, usage) in pairs { t[plain] = (usage, false); t[shifted] = (usage, true) }
        return t
    }()
}
