import Foundation

/// THE PASTE/DROP WIRE, the host's half (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §3).
/// A DELIVERY is one paste or one drop: one target and 1–32 items, declared up front by `paste-begin`,
/// then each item's bytes in order (`paste-data`), then `paste-end`. Held to
/// `protocol/fixtures/paste-messages.json`, which the client's builders produce.
public enum PasteLimits {
    public static let chunkBytes = 16 * 1024
    /// 1 GiB a file and a delivery since 2026-10-02 (they were 50 and 100 MiB): a compressed folder is routinely
    /// more, and a big paste is now SENT after the client's warning. Written to disk piece by piece (`PasteStore`),
    /// so the cap bounds the disk, never memory.
    public static let fileMaxBytes = 1024 * 1024 * 1024
    public static let textMaxBytes = 4 * 1024 * 1024
    public static let totalMaxBytes = 1024 * 1024 * 1024
    public static let maxItems = 32
    public static let nameMaxBytes = 255
    public static let typeMaxBytes = 127
    /// A delivery with no piece for this long is abandoned (a suspended page, a dead link).
    public static let stallSeconds: Double = 30

    /// `.tooLarge` when a delivery breaks a cap the HOST enforces, whatever the client claimed. Shape
    /// errors are the parser's (malformed, dropped); an honest oversize gets an answer.
    public static func check(_ items: [PasteItem]) -> PasteError? {
        var total = 0
        for item in items {
            switch item {
            case .file(_, _, let size): if size > fileMaxBytes { return .tooLarge }
            case .text(let size): if size > textMaxBytes { return .tooLarge }
            }
            total += item.size
        }
        return total > totalMaxBytes ? .tooLarge : nil
    }
}

/// A point on a window's PICTURE, each coordinate 0…1 — normalized as a touch is.
public struct PastePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum PasteTarget: Equatable, Sendable {
    /// A terminal tab: the HOST types the saved paths into it.
    case terminal(TermTabID)
    /// A window (`win:`/`dsp:`): the Mac's clipboard and ⌘V — or, with `at`, a drop at that point.
    case window(source: String, at: PastePoint?)
}

public enum PasteItem: Equatable, Sendable {
    case file(name: String, type: String, size: Int)
    /// UTF-8 text for a WINDOW — never written to disk.
    case text(size: Int)
    public var size: Int {
        switch self { case .file(_, _, let s), .text(let s): return s }
    }
}

public struct PasteBegin: Equatable, Sendable {
    public let id: String
    public let to: PasteTarget
    public let items: [PasteItem]
    public init(id: String, to: PasteTarget, items: [PasteItem]) { self.id = id; self.to = to; self.items = items }
}

/// `paste-error`'s `reason`, exactly the spec's words.
public enum PasteError: String, CaseIterable, Sendable {
    case tooLarge = "too-large"
    case malformed
    case notDriver = "not-driver"
    case busy
    case noTarget = "no-target"
    case disk
    case failed
}

public enum PasteHow: String, Sendable { case paste, drop }

enum PasteWire {
    static func isValidID(_ s: String) -> Bool {
        (1...64).contains(s.utf8.count) && s.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D
        }
    }

    /// An integer field — a JSON number with no fraction. Never a Bool (NSNumber carries both).
    static func int(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.rounded() == d, abs(d) < 9.0e15 else { return nil }
        return Int(d)
    }

    static func unit(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return (0...1).contains(d) ? d : nil
    }

    /// nil = MALFORMED (dropped, as every malformed message is). An oversize delivery is NOT malformed:
    /// it parses, and `PasteLimits.check` answers it `too-large`.
    static func parseBegin(_ obj: [String: Any]) -> PasteBegin? {
        guard let id = obj["id"] as? String, isValidID(id),
              let to = obj["to"] as? [String: Any],
              let rawItems = obj["items"] as? [[String: Any]],
              (1...PasteLimits.maxItems).contains(rawItems.count) else { return nil }
        var items: [PasteItem] = []
        for raw in rawItems {
            guard let kind = raw["kind"] as? String, let size = int(raw["size"]), size > 0 else { return nil }
            switch kind {
            case "file":
                guard let name = raw["name"] as? String, name.utf8.count <= PasteLimits.nameMaxBytes,
                      let type = raw["type"] as? String, type.utf8.count <= PasteLimits.typeMaxBytes else { return nil }
                items.append(.file(name: name, type: type, size: size))
            case "text":
                items.append(.text(size: size))
            default:
                return nil
            }
        }
        let texts = items.filter { if case .text = $0 { return true } else { return false } }.count
        // A text is ALONE in its delivery: a window gets a string or files, never both.
        if texts > 0 && items.count != 1 { return nil }
        let target: PasteTarget
        if let term = to["term"] as? String, to["win"] == nil {
            // A terminal's TEXT never leaves the client, and a terminal has no drop point.
            guard TabKey.isTerminal(term), let tab = TermTabID(wire: term), texts == 0, obj["at"] == nil else { return nil }
            target = .terminal(tab)
        } else if let win = to["win"] as? String, to["term"] == nil {
            guard TabKey.isWindow(win) else { return nil }
            var at: PastePoint?
            if let raw = obj["at"] {
                guard let a = raw as? [String: Any], let x = unit(a["x"]), let y = unit(a["y"]) else { return nil }
                at = PastePoint(x: x, y: y)
            }
            target = .window(source: win, at: at)
        } else {
            return nil
        }
        return PasteBegin(id: id, to: target, items: items)
    }

    static func parseData(_ obj: [String: Any]) -> InboundMessage? {
        guard let id = obj["id"] as? String, isValidID(id),
              let item = int(obj["item"]), (0..<PasteLimits.maxItems).contains(item),
              let seq = int(obj["seq"]), seq >= 0,
              let b64 = obj["data"] as? String, let bytes = Data(base64Encoded: b64),
              !bytes.isEmpty, bytes.count <= PasteLimits.chunkBytes else { return nil }
        return .pasteData(id: id, item: item, seq: seq, bytes: bytes)
    }

    static func parseID(_ obj: [String: Any]) -> String? {
        guard let id = obj["id"] as? String, isValidID(id) else { return nil }
        return id
    }
}

/// The delivery is OPEN (2026-10-02): its `paste-begin` passed the busy and cap checks, and its pieces may come.
/// The client sends none until it has this and gives up after 5 s without it, so a Mac that ignores `paste-*`
/// costs no upload — an older Xpromptvs did, and the client's note sat at 94% until the 60 s reply timeout. A
/// refused begin gets its `paste-error` instead, never this.
public func pasteAcceptedJSON(id: String) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["t": "paste-accepted", "id": id])) ?? Data()
}

public func pasteDoneJSON(id: String, how: PasteHow) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["t": "paste-done", "id": id, "how": how.rawValue])) ?? Data()
}

public func pasteErrorJSON(id: String, reason: PasteError) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["t": "paste-error", "id": id, "reason": reason.rawValue])) ?? Data()
}
