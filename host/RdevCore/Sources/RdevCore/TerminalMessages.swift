import Foundation

/// `{"t":"term-list","tabs":[{id,n,title,name?,agent?},…],"activeId": <id|null>}` — ids are `TermTabID` wire strings — the terminal tab bar payload.
/// `n` is the tab's creation ordinal (the "Terminal N" fallback label); `activeId` is the one tab
/// currently streamed to the driver. `name` — a `pty:` tab's user name — is PRESENT ONLY WHEN SET, never
/// `null` or `""`: the client's label is `name ?? title ?? "Terminal N"`. The ORDER of `tabs` is the
/// pool's, which follows the bar's (`TabPool.arrange`); the bar itself is `view-set`'s `tabOrder`. `agent` —
/// `"working"` or `"idle"` — is PRESENT ONLY WHILE an agent runs in the tab's foreground (`AgentActivity`).
/// `{"t":"term-screen","id":<tab>,"cols":N,"rows":M,"data":<base64>}` — THE ACTIVE TAB'S SCREEN, carried by a
/// fresh offer (`ChannelHub.offerScreen`; docs/sources-and-focus.md, "The offer carries the tab bar"): the emitter's
/// bytes for a FRESH instance at that grid with NO scrollback, as ONE raw-DEFLATE stream flushed once (what fflate's
/// `Inflate` reads, as on the terminal channel), base64 in the JSON. A picture: the client paints it, inert, until the
/// terminal channel's own snapshot of that tab.
public func termScreenJSON(id: TermTabID, size: TermGridSize, bytes: [UInt8]) -> Data {
    let packed = Data(TermDeflater().compress(bytes)).base64EncodedString()
    let obj: [String: Any] = ["t": "term-screen", "id": id.wire, "cols": size.cols, "rows": size.rows, "data": packed]
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

public func termListJSON(tabs: [TabDescriptor], activeId: TermTabID?) -> Data {
    let arr: [[String: Any]] = tabs.map {
        var o: [String: Any] = ["id": $0.id.wire, "n": $0.ordinal, "title": $0.title]
        if let name = $0.name { o["name"] = name }
        if let agent = $0.agent { o["agent"] = agent.rawValue }
        if let kind = $0.agentKind { o["agentKind"] = kind }
        return o
    }
    var obj: [String: Any] = ["t": "term-list", "tabs": arr]
    obj["activeId"] = activeId?.wire as Any? ?? NSNull()
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

/// `{"t":"term-bell","term":"<tab id>"}` — host → the DRIVER: `term` rang its bell in output that REACHED NO
/// client context (a hidden page's pause, a resume's gap, a new wire before the tab's snapshot), so the
/// client's xterm.js never rang it (docs/terminal.md, "The bell"). At most ONE per tab per such stretch.
public func termBellJSON(term: TermTabID) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["t": "term-bell", "term": term.wire])) ?? Data()
}
