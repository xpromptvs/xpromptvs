import Foundation

/// **WHAT A CLIENT SAYS AS IT JOINS** (2026-10-05; docs/sources-and-focus.md, "The offer carries the tab bar") — the
/// `app_hello` of its `client-confirm` (`E2EWire.ClientConfirm.appHello`), so it travels inside the client's §11
/// session, bounded by the wire: `{"grid":{"cols":N,"rows":M},"intent":"connect"}` —
///   - `grid`: its terminal area's grid as its own `resize` will report it once `control` opens. The host acts on it
///     only once the gate is open, and only as that `resize` would — the driver's, 1…500 each way
///     (`ChannelHub.applyJoinGrid`);
///   - `intent`: its JOIN INTENT (docs/sources-and-focus.md, "The join intent") — `connect` takes control at
///     admission, `reconnect` keeps its place. Said HERE since 2026-10-05 (asked for, "move it"), not in its relay
///     hello, so the relay can neither read nor forge it.
///
/// Anything else — absent, not JSON, a grid out of range, an intent this build does not know — is NO grid, NO intent,
/// never a refusal: the handshake owes the application nothing, and no intent claims nothing.
public struct JoinHello: Equatable, Sendable {
    public var grid: TermGridSize?
    public var intent: JoinIntent?
    public var fastData: Int?
    public init(grid: TermGridSize? = nil, intent: JoinIntent? = nil, fastData: Int? = nil) { self.grid = grid; self.intent = intent; self.fastData = fastData == 1 ? 1 : nil }

    /// The bounds `ChannelHub`'s `resize` takes, here too: a grid the driver could not report is no grid.
    public static let gridRange = 1...500

    public static func parse(_ bytes: [UInt8]) -> JoinHello {
        guard !bytes.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
        else { return JoinHello() }
        return JoinHello(grid: parseGrid(object["grid"]), intent: (object["intent"] as? String).flatMap(JoinIntent.init(rawValue:)), fastData: (object["fastData"] as? NSNumber).flatMap(exactInt))
    }

    /// `{cols, rows}` within `gridRange`, whole numbers — `claim-control` carries its grid the same way.
    static func parseGrid(_ value: Any?) -> TermGridSize? {
        guard let grid = value as? [String: Any],
              let cols = (grid["cols"] as? NSNumber).flatMap(exactInt), let rows = (grid["rows"] as? NSNumber).flatMap(exactInt),
              gridRange.contains(cols), gridRange.contains(rows)
        else { return nil }
        return TermGridSize(cols: cols, rows: rows)
    }

    /// A whole number, never a fraction or a Bool read as one.
    private static func exactInt(_ n: NSNumber) -> Int? {
        guard CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(),
              abs(n.doubleValue) < 1e9 else { return nil }
        return n.intValue
    }

    /// The bytes a client writes (the native client writes none; the tests write these).
    public func encoded() -> [UInt8] {
        var parts: [String] = []
        if let grid { parts.append(#""grid":{"cols":\#(grid.cols),"rows":\#(grid.rows)}"#) }
        if let intent { parts.append(#""intent":"\#(intent.rawValue)""#) }
        if fastData == 1 { parts.append(#""fastData":1"#) }
        return parts.isEmpty ? [] : Array("{\(parts.joined(separator: ","))}".utf8)
    }
}
