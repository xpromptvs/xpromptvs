import Foundation

/// A NAME a person gives a tab — a `pty:` terminal's (`TabPool.setName`), a window's
/// (`SessionState.setName`), or a tmux session's through tmux (`rename-session`)
/// (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §2.3).
///
/// AT MOST 256 UTF-8 BYTES AND NO CONTROL CHARACTER (general category Cc: U+0000–U+001F,
/// U+007F–U+009F). BYTES, never characters: Swift counts grapheme clusters and JavaScript counts UTF-16
/// units, so a character limit would be two different limits, while both count a UTF-8 encoding the same
/// way. `protocol/fixtures/tab-names.json` holds the vectors BOTH languages assert. `""` is valid — it is
/// how a name is CLEARED — except for a tmux tab, whose session must have one (the parse refuses that).
///
/// The client trims surrounding whitespace before it sends; the host stores what passed, untrimmed.
public enum TabName {
    public static let maxBytes = 256

    public static func isValid(_ name: String) -> Bool {
        name.utf8.count <= maxBytes && !name.unicodeScalars.contains(where: isControl)
    }

    /// General category Cc, which is exactly these two ranges.
    static func isControl(_ s: Unicode.Scalar) -> Bool { s.value <= 0x1F || (0x7F...0x9F).contains(s.value) }
}

/// A tab's KEY in the session's bar (`SessionState.tabOrder`): a terminal tab id's wire form (`pty:<n>`,
/// `tmux:$<n>` — `TermTabID.wire`) or a window's source id (`win:<n>`, `dsp:<n>`). The PREFIX is the kind,
/// as everywhere else.
///
/// CANONICAL, and that is load-bearing: the host keeps keys as STRINGS and compares them as strings, so
/// `pty:01` or `win:+5` — which the id parsers would read as `pty:1` and `win:5` — would name a tab on one
/// path and miss it on another. Only the spelling the host itself writes is a key.
public enum TabKey {
    public static func isValid(_ key: String) -> Bool { isTerminal(key) || isWindow(key) || isAgent(key) }

    public static func isAgent(_ key: String) -> Bool {
        guard key.hasPrefix("agent:") else { return false }
        let id = key.dropFirst(6)
        return !id.isEmpty && id.utf8.count <= 128 && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// A canonical `TermTabID` wire form.
    public static func isTerminal(_ key: String) -> Bool { TermTabID(wire: key)?.wire == key }

    /// A canonical `win:`/`dsp:`/`sim:` source id. A simulator's udid is canonical as CoreSimulator writes it: an
    /// UPPERCASE UUID — any other spelling of the same device is not a key.
    public static func isWindow(_ key: String) -> Bool {
        switch parseSourceID(key) {
        case .window(let n): return sourceID(windowID: n) == key
        case .display(let n): return sourceID(displayID: n) == key
        case .sim(let u): return UUID(uuidString: u)?.uuidString == u && sourceID(simUDID: u) == key
        case .workspace(let uuid): return UUID(uuidString:uuid)?.uuidString==uuid
        case nil: return false
        }
    }
}
