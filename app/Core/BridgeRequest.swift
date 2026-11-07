import Foundation

public struct Motion: Equatable, Sendable {
    public let debug: Bool, slow: Bool
    public init(debug: Bool, slow: Bool) { self.debug = debug; self.slow = slow }
}

public struct BridgeError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One `postMessage({op, args})` from a page, parsed. Bounded (op ≤ 64 chars, ≤ 8 args) because
/// the page is the thing on the other side of this boundary.
public struct BridgeRequest {
    public let op: String
    private let args: [Any]

    public init?(body: Any) {
        guard let d = body as? [String: Any], let op = d["op"] as? String,
              (1...64).contains(op.count) else { return nil }
        let args = d["args"] as? [Any] ?? []
        guard args.count <= 8 else { return nil }
        self.op = op; self.args = args
    }

    public var count: Int { args.count }
    public func object(_ i: Int) -> [String: Any]? { i < args.count ? args[i] as? [String: Any] : nil }

    /// Present AND a string — a number is not a string.
    public func string(_ i: Int) -> String? { i < args.count ? args[i] as? String : nil }

    /// Present AND an array of strings, at most 32 of them (a delivery's items) each at most 4096 UTF-16 units —
    /// the paths a paste prepares, the urls it discards. Anything else is nil, never a partial list.
    public func strings(_ i: Int) -> [String]? {
        guard i < args.count, let a = args[i] as? [Any], a.count <= 32 else { return nil }
        let out = a.compactMap { $0 as? String }
        guard out.count == a.count, out.allSatisfy({ $0.utf16.count <= 4096 }) else { return nil }
        return out
    }

    /// Present AND a whole JS NUMBER inside `range` — a count. Never a Bool (WebKit hands `true` over as an
    /// NSNumber too), a string, a fraction, NaN, or a number outside the range.
    public func int(_ i: Int, in range: ClosedRange<Int>) -> Int? {
        guard i < args.count, let n = args[i] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d.rounded() == d, d >= Double(range.lowerBound), d <= Double(range.upperBound) else { return nil }
        return Int(d)
    }

    /// Present AND a JS `null` — which WebKit hands over as `NSNull`, distinct from absent.
    public func isNull(_ i: Int) -> Bool { i < args.count && args[i] is NSNull }

    /// A pairing string, bounded as the Electron handler bounded it: JS `slice(0, 4096)`, which
    /// counts UTF-16 CODE UNITS — not Swift Characters, one of which can be many units.
    public func pairing(_ i: Int) -> String? { string(i).map { Self.prefixUTF16($0, 4096) } }

    /// At most `max` UTF-16 code units. Where JS `slice` would split a surrogate pair and keep a
    /// LONE high surrogate (which a Swift String cannot hold, and `encodeURIComponent` would throw
    /// on), the half pair is dropped instead of becoming U+FFFD.
    static func prefixUTF16(_ s: String, _ max: Int) -> String {
        let units = s.utf16
        guard units.count > max else { return s }
        var end = units.index(units.startIndex, offsetBy: max)
        if UTF16.isTrailSurrogate(units[end]) { end = units.index(before: end) }
        return String(s[..<end])
    }

    /// Only a literal JS `true` — `=== true`, as every Electron handler checked.
    public func bool(_ i: Int) -> Bool { i < args.count && Self.isTrue(args[i]) }

    public func motion(_ i: Int) -> Motion? {
        guard i < args.count, let o = args[i] as? [String: Any] else { return nil }
        return Motion(debug: Self.isTrue(o["debug"] as Any), slow: Self.isTrue(o["slow"] as Any))
    }

    static func isTrue(_ v: Any) -> Bool {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue
    }
}

/// The client window's URL — the retired Electron `windows.ts`'s `openClient`, byte for byte.
public enum ClientURL {
    public static func make(pairing: String?, motion: Motion?) -> String {
        url(route: [], pairing: pairing, motion: motion)
    }

    /// "This Mac": a window-less session over the bridge socket to this app's own host (`main.ts`'s
    /// `?local=1` route). No pairing — the bridge is the authentication.
    public static func local(motion: Motion?) -> String { url(route: ["local=1"], pairing: nil, motion: motion) }

    private static func url(route: [String], pairing: String?, motion: Motion?) -> String {
        var prefs = route
        if let m = motion {
            if m.debug { prefs.append("debug=1") }
            if m.debug && m.slow { prefs.append("motionSlow=1") }
        }
        var url = "app://client/index.html" + (prefs.isEmpty ? "" : "?" + prefs.joined(separator: "&"))
        if let pairing, !pairing.isEmpty { url += "#pairing=" + encodeURIComponent(pairing) }
        return url
    }

    /// JavaScript's `encodeURIComponent`: everything but A-Z a-z 0-9 - _ . ! ~ * ' ( ).
    public static func encodeURIComponent(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
