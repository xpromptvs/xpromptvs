import Foundation

public struct PasteFileInfo: Equatable, Sendable {
    public let name: String
    public let bytes: Int64
    public let modified: Date
    public init(name: String, bytes: Int64, modified: Date) { self.name = name; self.bytes = bytes; self.modified = modified }
}

/// WHICH saved pastes a sweep deletes (§6, decided with the user): everything older than 24 hours; then,
/// while the folder holds more than 2 GiB, the OLDEST — never `keep`, the file whose save ran this sweep.
/// 2 GiB is TWICE the largest delivery (`PasteLimits.totalMaxBytes`, 1 GiB since 2026-10-02): at 1 GiB, one
/// largest paste swept away every earlier one — a path typed but not yet sent to Claude, a drop Finder was
/// still copying.
public enum PasteSweep {
    public static let maxAge: TimeInterval = 24 * 3600
    public static let capBytes: Int64 = 2 << 30

    public static func victims(_ files: [PasteFileInfo], now: Date, keep: String?) -> [String] {
        var out: [String] = []
        var rest: [PasteFileInfo] = []
        for f in files {
            if f.name != keep && now.timeIntervalSince(f.modified) > maxAge { out.append(f.name) } else { rest.append(f) }
        }
        var total = rest.reduce(Int64(0)) { $0 + $1.bytes }
        for f in rest.sorted(by: { ($0.modified, $0.name) < ($1.modified, $1.name) }) where total > capBytes && f.name != keep {
            out.append(f.name)
            total -= f.bytes
        }
        return out
    }
}
