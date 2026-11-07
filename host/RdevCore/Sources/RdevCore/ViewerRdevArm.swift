import Foundation

/// The rdev arm's pure signaling decisions: where the WebSocket goes, and what the ABI is handed
/// for ICE servers.
///
/// Both were one-liners in the viewer's run loop until they were not: the first has a scheme
/// rewrite that a plain string replacement gets subtly wrong, and the second has a SHAPE mismatch
/// that fails the run before it starts. Neither is reachable from a test where it was.
public enum RdevViewerSignaling {

    /// `http://127.0.0.1:8787` + a session code -> `ws://127.0.0.1:8787/session/<code>`.
    ///
    /// The client the viewer is replacing derives this the same way (`web/src/lib/
    /// signaling-base.ts`: the page origin with `http` swapped for `ws`), so this is the same
    /// wire, not a second convention. `ws`/`wss` are accepted verbatim for an operator who types
    /// what they mean.
    ///
    /// The scheme is replaced AS A SCHEME. A `replacingOccurrences(of: "http", with: "ws")` gets
    /// the common cases right and mangles a host, path or query that happens to spell it — the
    /// class of bug that survives every test written against `localhost`.
    public static func sessionURL(signaling: String, code: String) -> URL? {
        guard !code.isEmpty else { return nil }
        var components = URLComponents(
            string: signaling.trimmingCharacters(in: .whitespacesAndNewlines))
        guard components != nil, let scheme = components?.scheme?.lowercased(),
              components?.host?.isEmpty == false else { return nil }
        switch scheme {
        case "http", "ws": components?.scheme = "ws"
        case "https", "wss": components?.scheme = "wss"
        default: return nil
        }
        // Whatever path the origin carried is REPLACED, not appended to: the control plane serves
        // sessions at exactly `/session/<code>`, and a pasted origin routinely ends in a slash —
        // `//session/<code>` is a 404 answered with "expected websocket upgrade", which reads as
        // a broken host rather than as a typed URL.
        components?.path = "/session/\(code)"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    /// The control plane's `welcome.turn` — ONE object — as the ARRAY `ice_servers_json` requires.
    ///
    /// LOAD-BEARING, and the failure is at the wrong end of the run: handing the object across
    /// unchanged makes `ParseIceServers` return "ice_servers_json must be an array", which fails
    /// `rdev_viewer_create` before a single frame, reporting a JSON shape rather than anything
    /// about TURN. `web/src/client/main.ts` does the identical wrap
    /// (`iceServers: [{ urls: t.urls, ... }]`).
    ///
    /// Returns "" — the ABI's "no ICE servers" — for a blob with no usable urls, rather than
    /// `[{}]`, which `ParseIceServers` REFUSES ("ice server entry has no urls") and which would
    /// therefore take the run down over an absent TURN service instead of proceeding on host and
    /// server-reflexive candidates.
    public static func iceServersJSON(welcomeTurn: String) -> String {
        guard let data = welcomeTurn.data(using: .utf8),
              let turn = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        var server: [String: Any] = [:]
        // urls may be a string or an array of them; both are legal in the WebRTC API and both are
        // accepted by ParseIceServers, so both survive.
        if let list = turn["urls"] as? [String], !list.isEmpty {
            server["urls"] = list
        } else if let single = turn["urls"] as? String, !single.isEmpty {
            server["urls"] = single
        } else {
            return ""
        }
        // Only what libwebrtc reads. `ttl` is the control plane's own bookkeeping and would be a
        // number in the ICE configuration that means nothing there.
        if let username = turn["username"] as? String { server["username"] = username }
        if let credential = turn["credential"] as? String { server["credential"] = credential }
        guard let out = try? JSONSerialization.data(
            withJSONObject: [server], options: [.sortedKeys]),
            let text = String(data: out, encoding: .utf8) else { return "" }
        return text
    }
}

/// The control-channel messages the viewer SENDS, as the host's own parser reads them.
///
/// rdev has always had `parseInbound` (host side) and a TypeScript builder (client side) and
/// nothing in between; a native client needs the builder in Swift. Kept beside `parseInbound` so
/// the tests can round-trip build -> parse, which is what proves the wire form is one the host
/// acts on rather than one it silently ignores.
public enum ViewerControl: Equatable, Sendable {
    case claimControl
    case listSources
    /// The viewer's preferences — the ONLY place `--fps` / `--bitrate` reach the host now, and the message
    /// the host waits for before it starts a driver's video. Absent fields are the host's defaults.
    case clientHello(fps: Int?, bitrateBps: Int?)
    case subscribe(source: String)
    case focusSource(source: String)

    /// The RAW payload, before the codec envelope. `wrapMessage` is the caller's job — it belongs
    /// to the channel, not to the message.
    public func payload() -> Data {
        var object: [String: Any]
        switch self {
        case .claimControl:
            object = ["t": "claim-control"]
        case .listSources:
            object = ["t": "list-sources"]
        case let .subscribe(source):
            object = ["t": "subscribe", "source": source]
        case let .focusSource(source):
            object = ["t": "focus-source", "source": source]
        case let .clientHello(fps, bitrateBps):
            // ABSENT, not zero, for an unset field: absent is the host's default, while a 0 is a
            // malformed field the host drops — the same outcome by accident rather than by intent.
            var prefs: [String: Any] = [:]
            if let fps { prefs["fps"] = fps }
            if let bitrateBps { prefs["bitrateBps"] = bitrateBps }
            object = ["t": "client-hello", "prefs": prefs]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
    }
}

/// `{"t":"control-state","active":…,"clients":…}` — the host telling one client whether it is the
/// driver.
///
/// This is the rdev arm's most important inbound message and the reason it is parsed at all:
/// `subscribe` and `focus-source` are both behind `isActiveClient` on the host,
/// so a viewer that connected without claiming receives zero frames while ICE reads connected and
/// every data channel reads open. Failing the run with that reason is the only way to tell it
/// apart from a dead transport inside a watchdog interval.
public struct ViewerControlState: Equatable, Sendable {
    public let active: Bool
    public let clients: Int

    public init(active: Bool, clients: Int) {
        self.active = active
        self.clients = clients
    }

    /// nil for anything that is not a `control-state`, INCLUDING a `control-state` with no
    /// `active` field. "No control-state has arrived yet" and "the host says we are passive" are
    /// different readings, and defaulting a missing field to `false` would collapse them — which
    /// would fail runs on a protocol addition rather than on a real demotion.
    public static func parse(_ payload: Data) -> ViewerControlState? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["t"] as? String == "control-state",
              let active = object["active"] as? Bool else { return nil }
        return ViewerControlState(
            active: active, clients: (object["clients"] as? NSNumber)?.intValue ?? 0)
    }
}

/// The host's echo of ONE source's video prefs, read out of `view-set`.
///
/// WHY THIS EXISTS. The `client-hello`'s preferences are a REQUEST, and the host answers them with
/// silence: the message is parsed, stored as this connection's preferences — and on the
/// headless `RDEV_TEST_PATTERN=1` path there is no `SimManager`, so `simDelegate` is nil and it
/// reaches nothing at all. Nothing in the transport, the stats or the host log distinguishes that
/// from a request that applied; the first rdev-arm smoke asked for exactly rdev's own default
/// bitrate, so both readings agreed with every observable.
///
/// `view-set` is the ONLY thing the host says back about a source's prefs. So it is the only
/// thing that can turn "asked" into "confirmed", and a viewer that cannot find its source in one
/// must report the request as unconfirmed rather than as configuration.
///
/// Each field is INDEPENDENTLY optional: nil means the host did not state it, never 0. The
/// difference matters because the consumer compares against a requested value, and a fabricated
/// zero would read as a disagreement the host never expressed.
public struct ViewerSourcePrefsEcho: Equatable, Sendable {
    public let fps: Int?
    public let bitrateBps: Int?

    public init(fps: Int?, bitrateBps: Int?) {
        self.fps = fps
        self.bitrateBps = bitrateBps
    }

    /// nil unless `payload` is a `view-set` carrying an entry for `source`. Both halves of that
    /// are load-bearing: keying on the fields alone would read a `source-status` or a
    /// `source-list` as a confirmation, and an entry for a DIFFERENT source says nothing about
    /// ours (a multi-source view set is the norm on a real host).
    public static func parse(_ payload: Data, source: String) -> ViewerSourcePrefsEcho? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["t"] as? String == "view-set",
              let subs = object["subs"] as? [[String: Any]],
              let entry = subs.first(where: { $0["source"] as? String == source })
        else { return nil }
        return ViewerSourcePrefsEcho(
            fps: (entry["fps"] as? NSNumber)?.intValue,
            bitrateBps: (entry["bitrateBps"] as? NSNumber)?.intValue)
    }
}

/// One entry of the host's `source-list`, reduced to what an instrument needs to CHOOSE a source
/// and to say afterwards which one it chose.
///
/// Deliberately NOT `RdevCore.Source`. That type is the host's own model, built by `makeSources`
/// from live window enumeration; this is a parse of a wire message that a *different process*
/// sent, and the two must be free to drift — a field the host stops sending has to read as
/// "absent" here rather than as a decode failure that takes a run down.
public struct ViewerSourceListing: Equatable, Sendable {
    public let id: String
    public let kind: String
    public let name: String
    public let running: Bool
    /// Size in POINTS when the host stated one (windows do; sims do not). nil is "not stated".
    public let w: Int?
    public let h: Int?

    public init(id: String, kind: String, name: String, running: Bool,
                w: Int? = nil, h: Int? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.running = running
        self.w = w; self.h = h
    }

    /// One row of the listing a failure prints. Fixed order, every field the operator needs to
    /// pick a different substring: id, kind, running, size, name.
    public var describedRow: String {
        let size = (w != nil && h != nil) ? " \(w!)x\(h!)pt" : ""
        return "\(id)  [\(kind)\(running ? "" : ", not running")]\(size)  \(name)"
    }
}

/// Resolving `--source-name` against the host's own `source-list`.
///
/// WHY MATCH ON A NAME AT ALL, when this repo's own rule (`tools/WinTapTarget`) is that a target
/// PRINTS ITS OWN WINDOW ID so a harness never has to. Because that pattern is unavailable for
/// the one target this instrument needs: `llv presentation-motion` prints no window id.
/// (It lives under `host/streaming-engine/Sources/llv/`, which gate G1 froze per-file when this
/// was written. **G1 released `Sources/` and `PionBridge/` on 2026-08-17**, so adding an id
/// print there is now permitted work — it simply has not been done, and doing it would not
/// change the reasoning below about WHOSE name is matched.)
///
/// What makes a name match acceptable here is WHOSE name it is: the string matched against is the
/// one **rdev itself reports** in `source-list`, so a mismatch is diagnosable from exactly the
/// list the resolution used — which is why `Failure` carries the whole listing rather than a
/// count. It is not a match against a title read from somewhere else and hoped to agree.
public enum ViewerSourceList {

    /// nil for anything that is not a `source-list`. An entry missing `id`/`name` is DROPPED
    /// rather than defaulted: a nameless entry can never be the one an operator meant, and
    /// substituting "" for it would make it match every substring.
    public static func parse(_ payload: Data) -> [ViewerSourceListing]? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["t"] as? String == "source-list",
              let sources = object["sources"] as? [[String: Any]] else { return nil }
        return sources.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let name = entry["name"] as? String else { return nil }
            return ViewerSourceListing(
                id: id, kind: entry["kind"] as? String ?? "",
                name: name, running: entry["running"] as? Bool ?? false,
                w: (entry["w"] as? NSNumber)?.intValue, h: (entry["h"] as? NSNumber)?.intValue)
        }
    }

    public enum Resolution: Equatable {
        case resolved(ViewerSourceListing)
        /// The run cannot proceed, and the message is the whole diagnosis — including every
        /// source the host offered, because "no match" and "three matches" are both fixed by
        /// looking at that list and nothing else in the report contains it.
        case failed(String)
    }

    /// The single entry whose `name` contains `substring`, case-insensitively.
    ///
    /// FAILS LOUDLY ON ZERO **AND** ON MORE THAN ONE. Picking the first of several matches is the
    /// failure this whole resolution exists to prevent: a silently-wrong window decodes perfectly,
    /// passes every assertion, and is invisible in every aggregate number the parity comparison
    /// produces. Case-insensitive because the operator types a human name and both failure modes
    /// are loud — an ambiguity introduced by ignoring case cannot pass silently either.
    public static func resolve(
        name substring: String, in sources: [ViewerSourceListing]
    ) -> Resolution {
        let listing = sources.isEmpty
            ? "    <the host listed NO sources at all>"
            : sources.map { "    " + $0.describedRow }.joined(separator: "\n")
        guard !substring.isEmpty else {
            return .failed("--source-name was empty; it must be a substring of a source name")
        }
        let matches = sources.filter {
            $0.name.range(of: substring, options: [.caseInsensitive]) != nil
        }
        switch matches.count {
        case 1: return .resolved(matches[0])
        case 0:
            return .failed("""
            --source-name \"\(substring)\" matched NONE of the \(sources.count) sources the host \
            listed:
            \(listing)
            """)
        default:
            return .failed("""
            --source-name \"\(substring)\" matched \(matches.count) sources, and an instrument may \
            not pick one of them:
            \(matches.map { "    " + $0.describedRow }.joined(separator: "\n"))
              …out of the \(sources.count) the host listed:
            \(listing)
            """)
        }
    }
}

/// "Have I already said this?" — one line of state behind a name, so the once-per-type rule is
/// testable rather than an `if !warned.contains(…)` buried in a receive loop.
public struct OnceLog: Equatable, Sendable {
    private var seen: Set<String> = []

    public init() {}

    /// True the FIRST time `key` is offered, false forever after.
    public mutating func shouldReport(_ key: String) -> Bool {
        seen.insert(key).inserted
    }
}

public extension RdevSignalIn {
    /// The `t` of a raw signaling message, WITHOUT interpreting it.
    ///
    /// `parse` returns nil for an unhandled type AND for malformed input, so its result cannot
    /// distinguish "the control plane sent `peer-resumed`, which this client does not handle"
    /// from "there is garbage on the socket". Those want different reports, and reporting neither
    /// is how `signaling.ts`'s `default: break` hid a permanently-unsatisfiable smoke step.
    static func messageType(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["t"] as? String
    }
}
