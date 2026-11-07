import Foundation

public struct TermGridSize: Equatable, Sendable {
    public let cols: Int
    public let rows: Int
    public init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
}

/// The raw record inside a compressed RZT1 DATA message (docs/terminal.md, "The terminal channel").
public enum TermFrameKind: UInt8, Sendable {
    /// Live bytes for the tab.
    case output = 0
    /// A first or middle chunk of a snapshot. A snapshot kind that arrives while the tab is not
    /// mid-snapshot STARTS one: on the client, a fresh instance; the wire codec context stays shared.
    case snapshotChunk = 1
    /// The last (or only) chunk of a snapshot.
    case snapshotEnd = 2
    /// The tab is gone.
    case closed = 3
    /// Reserved legacy kind. RZT1 rejects it inside DATA; START is an outer message.
    case wireStart = 4
    /// THE LATE HISTORY (docs/terminal.md, "Scrollback comes after the screen"): the FULL snapshot of a tab, taken at
    /// the same moment as the screen-only snapshot that began its current generation, inside the shared zstd wire
    /// context, for the client to rebuild the tab with its scrollback.
    case historyChunk = 5
    case historyEnd = 6
    /// A snapshot of the SCREEN alone, whose history follows as `historyChunk`/`historyEnd`: otherwise exactly a
    /// `snapshotChunk`/`snapshotEnd` (a new tab generation).
    case screenChunk = 7
    case screenEnd = 8
}

/// Raw `[kind][tabIdLen][tabId]([u16 cols][u16 rows])[payload]`.
/// Grid is present for snapshot/screen/history kinds. RZT1 compresses the entire record.
public struct TermFrame: Equatable, Sendable {
    public var kind: TermFrameKind
    public var tab: String
    public var size: TermGridSize?
    public var payload: [UInt8]

    public init(kind: TermFrameKind, tab: String, size: TermGridSize?, payload: [UInt8]) {
        self.kind = kind; self.tab = tab; self.size = size; self.payload = payload
    }

    /// The wire start: `[0x04][0x00]`.
    public static let wireStart = TermFrame(kind: .wireStart, tab: "", size: nil, payload: [])

    static func carriesSize(_ k: TermFrameKind) -> Bool { k != .output && k != .closed && k != .wireStart }

    public static func headerSize(tab: String, kind: TermFrameKind) -> Int {
        2 + tab.utf8.count + (carriesSize(kind) ? 4 : 0)
    }

    public func encoded() -> Data {
        if kind == .wireStart { return Data([kind.rawValue, 0]) }
        let id = Array(tab.utf8)
        precondition(!id.isEmpty && id.count <= 255, "a tab id is 1…255 bytes")
        var out = Data([kind.rawValue, UInt8(id.count)])
        out.append(contentsOf: id)
        if Self.carriesSize(kind) {
            let s = size ?? TermGridSize(cols: 0, rows: 0)
            // u16be: CLAMP to the wire's range rather than wrap mod 65536 — a wrapped 65536 silently
            // becomes 0 on the wire with no signal anywhere that truncation happened.
            let cols = min(max(s.cols, 0), 65535), rows = min(max(s.rows, 0), 65535)
            out.append(contentsOf: [UInt8(cols >> 8 & 0xFF), UInt8(cols & 0xFF), UInt8(rows >> 8 & 0xFF), UInt8(rows & 0xFF)])
        }
        out.append(contentsOf: payload)
        return out
    }

    public static func decode(_ d: Data) -> TermFrame? {
        let b = [UInt8](d)
        guard b.count >= 2, let kind = TermFrameKind(rawValue: b[0]) else { return nil }
        let n = Int(b[1])
        if kind == .wireStart { return n == 0 && b.count == 2 ? .wireStart : nil }
        guard n > 0, b.count >= 2 + n else { return nil }
        let tab = String(decoding: b[2..<(2 + n)], as: UTF8.self)
        var i = 2 + n
        var size: TermGridSize? = nil
        if carriesSize(kind) {
            guard b.count >= i + 4 else { return nil }
            size = TermGridSize(cols: Int(b[i]) << 8 | Int(b[i + 1]), rows: Int(b[i + 2]) << 8 | Int(b[i + 3]))
            i += 4
        }
        return TermFrame(kind: kind, tab: tab, size: size, payload: Array(b[i...]))
    }
}
