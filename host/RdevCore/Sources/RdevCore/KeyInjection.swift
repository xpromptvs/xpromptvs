import CoreGraphics
import Foundation

/// THE ONE PLACE A BROWSER KEY BECOMES A MAC KEY.
///
/// The browser reports two things about a keystroke and rdev needs both: `code` is the PHYSICAL key
/// ("KeyA" is wherever `A` sits on a US keyboard) and `key` is the CHARACTER the client's own layout
/// produced. `code` becomes the macOS virtual keycode, which is what makes ⌘C a real Command-C; `key`
/// becomes a unicode override, which is what makes a layout mismatch type what the user saw.
///
/// The table is keyed on the W3C `code` names, which do NOT match the mac constants: `Enter` (not
/// Return), `Backquote` (not Grave), `Backspace` for the key above Return and `Delete` for forward
/// delete. Getting one wrong types a plausible WRONG character, which is why the table is tested by
/// name rather than by round trip.
private let macVirtualKeys: [String: UInt16] = [
    "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5, "KeyZ": 6, "KeyX": 7,
    "KeyC": 8, "KeyV": 9, "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16,
    "KeyT": 17, "KeyO": 31, "KeyU": 32, "KeyI": 34, "KeyP": 35, "KeyL": 37, "KeyJ": 38, "KeyK": 40,
    "KeyN": 45, "KeyM": 46,

    "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit6": 22, "Digit5": 23,
    "Digit9": 25, "Digit7": 26, "Digit8": 28, "Digit0": 29,

    "Equal": 24, "Minus": 27, "BracketRight": 30, "BracketLeft": 33, "Quote": 39, "Semicolon": 41,
    "Backslash": 42, "Comma": 43, "Slash": 44, "Period": 47, "Backquote": 50,

    "Enter": 36, "Tab": 48, "Space": 49, "Backspace": 51, "Escape": 53,

    "MetaLeft": 55, "MetaRight": 54, "ShiftLeft": 56, "CapsLock": 57, "AltLeft": 58,
    "ControlLeft": 59, "ShiftRight": 60, "AltRight": 61, "ControlRight": 62,

    "NumpadDecimal": 65, "NumpadMultiply": 67, "NumpadAdd": 69, "NumpadClear": 71,
    "NumpadDivide": 75, "NumpadEnter": 76, "NumpadSubtract": 78, "NumpadEqual": 81,
    "Numpad0": 82, "Numpad1": 83, "Numpad2": 84, "Numpad3": 85, "Numpad4": 86, "Numpad5": 87,
    "Numpad6": 88, "Numpad7": 89, "Numpad8": 91, "Numpad9": 92,

    "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100,
    "F9": 101, "F10": 109, "F11": 103, "F12": 111, "F13": 105, "F14": 107, "F15": 113,
    "F16": 106, "F17": 64, "F18": 79, "F19": 80, "F20": 90,

    "Insert": 114, "Home": 115, "PageUp": 116, "Delete": 117, "End": 119, "PageDown": 121,
    "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
]

private let modifierCodes: Set<String> = [
    "MetaLeft", "MetaRight", "ShiftLeft", "ShiftRight", "AltLeft", "AltRight",
    "ControlLeft", "ControlRight", "CapsLock",
]

public func macVirtualKey(forCode code: String) -> UInt16? { macVirtualKeys[code] }
private let browserCodes = Dictionary(uniqueKeysWithValues: macVirtualKeys.map { ($0.value, $0.key) })
public func browserCode(forMacVirtualKey key: UInt16) -> String? { browserCodes[key] }

public func isModifierCode(_ code: String) -> Bool { modifierCodes.contains(code) }

public enum KeyAction: Equatable, Sendable {
    /// A modifier key. Posted as `.flagsChanged`, NOT as a keyDown: apps that react to a bare ⌥ or ⇧
    /// (a cursor change, a constrain-drag) watch flagsChanged, and a keyDown on keycode 58 is not the
    /// same event to them.
    case flagsChanged(keyCode: UInt16, flags: CGEventFlags)
    /// An ordinary key. `unicode` non-nil means override the character the host's layout would have
    /// produced with the one the client actually typed.
    case key(keyCode: UInt16, flags: CGEventFlags, unicode: String?, autorepeat: Bool)
    case drop(reason: String)
}

/// Decide what to post for one browser key event. Pure: no window, no permission, no state.
///
/// THE UNICODE OVERRIDE RULE: override when the client produced a single-scalar character AND the
/// event carries neither ⌘ nor ⌃. Shift and Option are excluded from that test on purpose — they are
/// HOW the client produced the character (`A`, `≈`), not a chord to preserve. With ⌘ or ⌃ present the
/// event must stay keycode-only, or the app sees a modified character instead of the Command-C it
/// dispatches on.
public func planKeyInjection(down: Bool, code: String, key: String,
                             repeat isRepeat: Bool, mods: InputModifiers) -> KeyAction {
    let flags = mods.cgFlags

    if isModifierCode(code) {
        guard let kc = macVirtualKey(forCode: code) else { return .drop(reason: "unknown modifier \(code)") }
        return .flagsChanged(keyCode: kc, flags: flags)
    }

    // A dead key produces no character of its own — the composed one arrives on the NEXT keydown.
    // Injecting the literal name would type the word "Dead".
    guard key != "Dead" else { return .drop(reason: "dead key") }

    // `key` is a CHARACTER only when it is one scalar long; otherwise it is a name ("ArrowUp", "F5").
    let printable = key.unicodeScalars.count == 1 && !mods.command && !mods.control
    let unicode: String? = printable ? key : nil

    if let kc = macVirtualKey(forCode: code) {
        return .key(keyCode: kc, flags: flags, unicode: unicode, autorepeat: isRepeat)
    }
    // An unmapped physical key that still produced a character types it, on the one keycode every
    // layout has. Cost, documented: an app reading raw keycodes sees `a`.
    guard let unicode else { return .drop(reason: "unmapped code \(code)") }
    return .key(keyCode: 0, flags: flags, unicode: unicode, autorepeat: isRepeat)
}

/// The non-modifier keys the host currently believes are pressed.
///
/// It exists for one reason: **macOS does not deliver a keyup while Command is held**, so the
/// browser never sends one either. After a single ⌘C the host would hold `c` down forever, and
/// every subsequent keystroke would reach the app as a chord. The caller releases Command by
/// draining this ledger — see `WindowInputInjector.releaseKeys()`.
///
/// The same drain covers the case the CLIENT structurally cannot report: ⌘W kills the browser tab
/// mid-chord, so the ⌘-down was forwarded and the ⌘-up never will be.
public struct HeldKeys: Equatable, Sendable {
    private var keys: Set<UInt16> = []

    public init() {}

    public var count: Int { keys.count }

    public mutating func down(_ keyCode: UInt16) { keys.insert(keyCode) }
    public mutating func up(_ keyCode: UInt16) { keys.remove(keyCode) }

    /// Every held key, once, and forgets them — so a second call emits nothing rather than posting a
    /// keyUp for a key nothing is holding.
    public mutating func releaseAll() -> [UInt16] {
        let all = Array(keys)
        keys.removeAll()
        return all
    }
}
