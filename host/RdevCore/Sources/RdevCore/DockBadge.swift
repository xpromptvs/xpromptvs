import Foundation

/// A WINDOW TAB'S BELL (docs/window-capture-and-input.md, "A window's bell"). A streamed window's
/// APPLICATION never hears a BEL the client sees — what it shows the person, when it wants them, is its
/// DOCK ICON: a badge (Terminal.app's "Badge app icon" on a bell, a chat's unread count). The Dock's AX tree
/// carries each running application's badge as `AXStatusLabel`; a badge that RISES while the person is not
/// looking at one of its windows is that window's bell. A Dock BOUNCE (`requestUserAttention`) is in no AX
/// attribute and is not seen.
///
/// Pure: what counts as a rise, and which windows it rings. `DockBadgeWatch` (RdevHostKit) reads the Dock.
public enum DockBadge {
    /// The number a badge label carries — its ASCII digits, decoration ignored (`"..21"` → 21, `"99+"` → 99,
    /// `"1,234"` → 1234) — or nil when it has none, or more than nine (no count is that long; a label that
    /// is is not a count).
    public static func number(_ label: String) -> Int? {
        let digits = label.unicodeScalars.filter { $0 >= "0" && $0 <= "9" }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        return Int(String(String.UnicodeScalarView(digits)))
    }

    /// Whether a badge going from `old` to `new` is NEWS. A badge going away never is (the person read it
    /// somewhere); one appearing always is; two COUNTS ring only when the count grew (21 → 20 is a message
    /// read elsewhere); any other label rings when it changed. An empty or blank label is no badge.
    public static func rose(from old: String?, to new: String?) -> Bool {
        guard let new = label(new) else { return false }
        guard let old = label(old) else { return true }
        if let a = number(old), let b = number(new) { return b > a }
        return new != old
    }

    /// `l` trimmed, nil when blank — a blank label is no badge.
    public static func label(_ l: String?) -> String? {
        guard let t = l?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// What one application item's badge read as. `.unreadable` is NOT "no badge": an AX read that FAILED (the Dock
/// busy, the element gone mid-read, a timeout) says nothing about the badge, and recording it as none made the
/// next good read of the SAME label a rise (review F1, 2026-10-02).
public enum DockLabel: Sendable, Equatable {
    case badge(String)
    case none
    case unreadable
}

/// An application item of the Dock as the watch reads it.
public struct DockItemReading: Sendable, Equatable {
    /// The item's bundle, symlinks resolved — the baseline's key.
    public let path: String
    public let bundleID: String?
    public let label: DockLabel
    public init(path: String, bundleID: String?, label: DockLabel) {
        self.path = path; self.bundleID = bundleID; self.label = label
    }
}

/// One whole reading of the Dock: the Dock PROCESS it came from (a relaunch is a new one) and its application
/// items. A reading with NO items is not "every application quit" — the Dock lists Finder at the least — but a
/// Dock that could not be read (relaunching, its tree not built yet): it changes nothing.
public struct DockReading: Sendable, Equatable {
    public let dock: Int32
    public let items: [DockItemReading]
    public init(dock: Int32, items: [DockItemReading]) { self.dock = dock; self.items = items }
}

/// THE READINGS OF THE DOCK, remembered. Keyed by the application item's resolved bundle PATH.
///
/// NO BASELINE, NO NEWS: an application read for the FIRST time records its badge and rings nothing — a
/// badge already showing when the watch starts (or the application launches) is not something that just
/// happened. NOTHING UNREAD COUNTS (review F1): an unreadable label keeps the item's baseline, an EMPTY reading
/// changes nothing, and an item missing from ONE reading keeps its baseline too (its subrole or bundle read can
/// fail on its own) — only one missing from `forgetAfterMisses` readings in a row is forgotten (its application
/// quit), to start over at its first reading when it is back. A NEW DOCK (its pid changed — `killall Dock`, a
/// preferences tool restarting it) starts every baseline over and rings nothing for `settleReadings` readings:
/// a relaunched Dock can list its items a tick before it shows their badges, and each badge arriving then is
/// not news.
public struct DockBadgeBaseline: Sendable, Equatable {
    public static let forgetAfterMisses = 2
    public static let settleReadings = 3

    private var seen: [String: String?] = [:]
    private var missed: [String: Int] = [:]
    private var dock: Int32?
    private var settling = 0

    public init() {}

    /// Returns the keys whose badge ROSE (`DockBadge.rose`) since the last reading of them.
    public mutating func observe(_ reading: DockReading) -> Set<String> {
        guard !reading.items.isEmpty else { return [] }
        if let d = dock, d != reading.dock {
            seen = [:]; missed = [:]
            settling = Self.settleReadings
        }
        dock = reading.dock
        var rose = Set<String>()
        var present = Set<String>()
        for item in reading.items {
            present.insert(item.path)
            missed[item.path] = nil
            let label: String?
            switch item.label {
            case .unreadable: continue                                // the baseline stands
            case .none: label = nil
            case .badge(let b): label = DockBadge.label(b)
            }
            if settling == 0, let old = seen[item.path], DockBadge.rose(from: old, to: label) { rose.insert(item.path) }
            seen[item.path] = .some(label)
        }
        for key in Array(seen.keys) where !present.contains(key) {
            let n = (missed[key] ?? 0) + 1
            if n >= Self.forgetAfterMisses { seen[key] = nil; missed[key] = nil } else { missed[key] = n }
        }
        if settling > 0 { settling -= 1; return [] }
        return rose
    }

    /// Forget every baseline: the watch is starting (again), and what it reads first is the baseline.
    public mutating func reset() { self = DockBadgeBaseline() }
}

/// A window of the session and the application that owns it, as far as the host can name it.
public struct WindowOwnerApp: Sendable, Equatable {
    public let source: String
    public let path: String?
    public let bundleID: String?
    public init(source: String, path: String?, bundleID: String?) {
        self.source = source; self.path = path; self.bundleID = bundleID
    }
}

extension DockBadge {
    /// Which windows ring: for each Dock item whose badge `rose`, every window of `windows` its application
    /// owns — matched by bundle PATH, else, ONLY when no Dock item has the window's path, by bundle IDENTIFIER (a
    /// system application's path can differ between the Dock and the running application), in `windows`' order. One group per application, in
    /// the order of their first window; an application with no window in the session rings nothing.
    public static func ringing(windows: [WindowOwnerApp], items: [DockItemReading], rose: Set<String>) -> [[String]] {
        let risen = items.filter { rose.contains($0.path) }
        guard !risen.isEmpty else { return [] }
        var groups: [String: [String]] = [:]
        var order: [String] = []
        for w in windows {
            // The window's OWN bundle, when the Dock lists it — risen or not: then only it can ring this window.
            // The identifier is the fallback for a window whose path the Dock does not list at all (review F3,
            // 2026-10-02 — otherwise Xcode-beta's badge rang Xcode's windows, a dev build's an installed copy's).
            let item: DockItemReading?
            if let own = items.first(where: { $0.path == w.path }) {
                item = rose.contains(own.path) ? own : nil
            } else if let id = w.bundleID, !id.isEmpty {
                item = risen.first { $0.bundleID == id }
            } else {
                item = nil
            }
            guard let item else { continue }
            if groups[item.path] == nil { order.append(item.path) }
            groups[item.path, default: []].append(w.source)
        }
        return order.compactMap { groups[$0] }
    }
}

/// `{"t":"window-bell","sources":["win:<n>",…]}` — host → the DRIVER: the application owning these windows
/// raised its Dock badge (`DockBadge`). Every window of that application in the session, minimized ones
/// included; the client marks them unless the person is looking at one of them.
public func windowBellJSON(sources: [String]) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["t": "window-bell", "sources": sources])) ?? Data()
}
