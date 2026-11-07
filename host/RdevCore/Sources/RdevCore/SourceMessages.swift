import Foundation

/// One capturable source — a simulator or a window — advertised to the client's source picker. `id` is a
/// kind-prefixed unique id: "sim:<udid>" or "win:<cgWindowID>"; `kind` ∈ {"sim","window"}. Both are
/// inputCapable: sims via touch injection, windows via `CGEvent` mouse/scroll injection.
public struct Source: Equatable, Sendable {
    public let id: String
    public let kind: String
    public let name: String
    public let inputCapable: Bool
    public let running: Bool
    /// Size in POINTS when known (a window's, a display's, a simulator's portrait size). Optional on the wire —
    /// absent means "unknown", never zero.
    public let w: Int?
    public let h: Int?
    /// A simulator's lifecycle state; nil for every other kind (docs/superpowers/specs/2026-10-13-simulator-sources-design.md).
    public let simState: SimState?
    public init(id: String, kind: String, name: String, inputCapable: Bool, running: Bool,
                w: Int? = nil, h: Int? = nil, simState: SimState? = nil) {
        self.id = id; self.kind = kind; self.name = name
        self.inputCapable = inputCapable; self.running = running
        self.w = w; self.h = h; self.simState = simState
    }
}

/// One active subscription in the view set: a source id plus its per-stream video prefs.
public struct Subscription: Equatable, Sendable {
    public let source: String   // a Source.id
    public var prefs: VideoPrefs
    public init(source: String, prefs: VideoPrefs) { self.source = source; self.prefs = prefs }
}

/// One source's runtime liveness — whether it currently produces frames. A window is live when it is on an
/// active Space's screen (not minimized, not on another Space, not closed). Sims are never reported here
/// (a simulator's status carries its `simState`).
public struct SourceStatus: Equatable, Sendable {
    public let id: String       // a Source.id, e.g. "win:12345"
    public let live: Bool
    /// Current size in POINTS, when this push carries one. The liveness monitor omits it; the capture
    /// source's size poll includes it. Absent means "unchanged/unknown" — the client must not clear.
    public let w: Int?
    public let h: Int?
    /// Current size in NATIVE PIXELS (`points × the host display's backing scale`), when this push carries
    /// one. Only the capture source knows the backing scale, so liveness-only pushes omit it — and, as
    /// with `w`/`h`, absent means UNKNOWN, never "cleared". The client caps the resolution it requests at
    /// what it can actually paint (Auto resolution mode) and needs the native size to express that as a
    /// fraction the host will reproduce exactly.
    public let pxW: Int?
    public let pxH: Int?
    /// A simulator's lifecycle state, so a window that shows nothing can say why ("Shut down", "Booting…"). nil for
    /// every other kind.
    public let simState: SimState?
    public init(id: String, live: Bool, w: Int? = nil, h: Int? = nil, pxW: Int? = nil, pxH: Int? = nil,
                simState: SimState? = nil) {
        self.id = id; self.live = live; self.w = w; self.h = h; self.pxW = pxW; self.pxH = pxH
        self.simState = simState
    }
}

/// What the host can currently capture, derived from the display counts alone.
///
/// A SLEEPING DISPLAY IS ONLINE BUT NOT ACTIVE. `CGGetActiveDisplayList` returns empty and so does
/// `SCShareableContent.displays` — so there is no `dsp:` source, no thumbnail and no frame on any
/// source. Windows keep ENUMERATING throughout (that path needs no scanout), which is what makes the
/// palette look merely incomplete rather than broken, and is why this once ran for twelve hours on a
/// deployed host with every counter reading healthy.
public enum DisplayAvailability: String, Equatable, Sendable {
    case ok
    case asleep
    /// No display attached at all. DELIBERATELY NOT SPELLED `none`: an enum case named `none`
    /// collides with `Optional.none` at every use site involving an optional of this type. The wire
    /// value is still "none".
    case noDisplay = "none"

    public static func from(activeCount: Int, onlineCount: Int) -> DisplayAvailability {
        if activeCount > 0 { return .ok }
        return onlineCount > 0 ? .asleep : .noDisplay
    }
}

/// Availability plus whether the session is locked. The two are INDEPENDENT: a Mac can be awake and
/// locked, which still streams windows perfectly while discarding every injected event.
public struct HostDisplayStatus: Equatable, Sendable {
    public let availability: DisplayAvailability
    /// nil means we could not read it — never coerce that to `false`.
    public let locked: Bool?
    public init(availability: DisplayAvailability, locked: Bool?) {
        self.availability = availability
        self.locked = locked
    }
}

private func jsonData(_ obj: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

/// `{"t":"source-list","sources":[{id,kind,name,inputCapable,running},…],"display":{availability,locked?}}`
/// — the picker payload.
///
/// `display` explains the LIST: a host with no active display returns no `dsp:` source and no
/// thumbnails, and the client must be able to say WHY rather than render an empty grid. Omitted when
/// unknown, so an older host stays readable and "unknown" never collapses into "ok".
public func sourceListJSON(sources: [Source], display: HostDisplayStatus? = nil) -> Data {
    let arr: [[String: Any]] = sources.map {
        var o: [String: Any] = ["id": $0.id, "kind": $0.kind, "name": $0.name,
                                "inputCapable": $0.inputCapable, "running": $0.running]
        if let w = $0.w, let h = $0.h { o["w"] = w; o["h"] = h }
        if let st = $0.simState { o["simState"] = st.rawValue }
        return o
    }
    var out: [String: Any] = ["t": "source-list", "sources": arr]
    if let display {
        var d: [String: Any] = ["availability": display.availability.rawValue]
        if let locked = display.locked { d["locked"] = locked }
        out["display"] = d
    }
    return jsonData(out)
}

/// `{"t":"source-status","statuses":[{id,live},…]}` — per-window runtime liveness, distinct from the
/// session-wide `sim-status`. Broadcast on change + pushed as a baseline on control-open / claim.
/// CONVENTION: a source absent from `statuses` is treated as LIVE by the client (sims never appear here).
public func sourceStatusJSON(statuses: [SourceStatus]) -> Data {
    let arr: [[String: Any]] = statuses.map {
        var o: [String: Any] = ["id": $0.id, "live": $0.live]
        if let w = $0.w, let h = $0.h { o["w"] = w; o["h"] = h }
        if let pxW = $0.pxW, let pxH = $0.pxH { o["pxW"] = pxW; o["pxH"] = pxH }
        if let st = $0.simState { o["simState"] = st.rawValue }
        return o
    }
    return jsonData(["t": "source-status", "statuses": arr])
}

/// `{"t":"cursor","fmt":"png","data":"<base64>","w":…,"h":…,"hotspotX":…,"hotspotY":…}` — the shape the host
/// app is currently showing, in POINTS, sent only when it CHANGES. The client renders it as a CSS cursor on
/// its own pointer, so no cursor POSITION is ever sent.
public func cursorJSON(pngBase64: String, w: Int, h: Int, hotspotX: Int, hotspotY: Int, png3xBase64: String? = nil) -> Data {
    var obj: [String: Any] = ["t": "cursor", "fmt": "png", "data": pngBase64,
              "w": w, "h": h, "hotspotX": hotspotX, "hotspotY": hotspotY]
    if let png3xBase64 { obj["data3x"] = png3xBase64 }
    return jsonData(obj)
}

/// `{"t":"source-thumb","id":…,"w":…,"h":…,"fmt":"jpeg","data":"<base64>"}` — one captured source snapshot
/// for the picker gallery. One message per source; a source with no capturable pixels uses
/// `sourceThumbUnavailableJSON` instead. Named apart from the terminal's snapshots.
public func sourceThumbJSON(id: String, w: Int, h: Int, jpegBase64: String) -> Data {
    jsonData(["t": "source-thumb", "id": id, "w": w, "h": h, "fmt": "jpeg", "data": jpegBase64])
}

/// `{"t":"source-thumb","id":…,"unavailable":true}` — a source with no capturable pixels (minimized /
/// off-screen window, shut-down sim, or a capture error). Terminates the tile's loading state so it never
/// spins forever.
public func sourceThumbUnavailableJSON(id: String) -> Data {
    jsonData(["t": "source-thumb", "id": id, "unavailable": true])
}

/// One subscription's audio state, as the HOST sees it.
///
/// TWO FALSE STATES THAT MUST NOT BE CONFLATED: `sending: false, owner: nil` is MUTED (the client
/// asked for silence), and `sending: false, owner: "win:1"` is YIELDED (another window carries this
/// application's audio). They sound identical and the client renders them differently — one is a
/// setting the user chose, the other is a fact about the host they did not.
public struct AudioSubState: Equatable, Sendable {
    public let sending: Bool
    /// Non-nil ⇒ this source yielded, and this is the id that carries its audio.
    public let owner: String?
    public init(sending: Bool, owner: String?) { self.sending = sending; self.owner = owner }
}

/// `{"t":"view-set","subs":[{source,scale,fps,bitrateBps},…],"focused": <id|null>,"windows":[{source,
/// minimized,x?,y?,name?},…],"tabOrder":[key,…],"view":{…},"version":N}` — broadcast on change + on claim.
///
/// TWO THINGS IN ONE MESSAGE, and they answer different questions. `windows` / `view` / `version` (+ `focused`)
/// are the SESSION STATE's windows-and-view half — what every client renders (docs/superpowers/specs/
/// 2026-09-29-host-session-state-design.md, §3); `subs` is the LIVE echo of the windows being streamed —
/// each one's effective prefs and what the host actually did with it (codec, delivery, audio).
/// `activeCodecs` maps source id -> the codec its track's answer settled on. A source missing from it
/// has not resolved yet, and its entry omits `activeCodec` entirely — the client must be able to tell
/// "not yet known" from "known and equal to the request".
public func viewSetJSON(subs: [Subscription], focused: String?,
                        state: SessionState = SessionState(),
                        activeCodecs: [String: NegotiatedCodec] = [:],
                        activeDelivery: [String: VideoDelivery] = [:],
                        dcIndices: [String: Int] = [:],
                        audioState: [String: AudioSubState] = [:],
                        recoveryOverrideBp: Int? = nil,
                        activeRecovery: String? = nil,
                        playoutDelayMinMs: Int? = nil,
                        playoutDelayMaxMs: Int? = nil,
                        curtainUp: Bool? = nil) -> Data {
    let arr: [[String: Any]] = subs.map {
        var e: [String: Any] = ["source": $0.source, "scale": $0.prefs.scale, "fps": $0.prefs.fps,
                                "bitrateBps": $0.prefs.bitrateBps, "codec": $0.prefs.codec.wireName]
        if case .workspace?=parseSourceID($0.source),let data=try? JSONEncoder().encode(WorkspaceFormat.v1),let format=try? JSONSerialization.jsonObject(with:data) {e["presentation"]=format}
        if let a = activeCodecs[$0.source] { e["activeCodec"] = a.wireName }
        // PER SUBSCRIPTION, AND READ FROM WHAT THE HOST DID — never echoed from the request. The
        // `activeCodec` rule, for the `activeCodec` reason: a client that asked for the DataChannel
        // and got RTP must be able to SEE it rather than infer it, because a correct fallback that
        // is indistinguishable from a bug is a bug. ABSENT MEANS UNKNOWN, never "rtp".
        if let d = activeDelivery[$0.source] {
            e["activeDelivery"] = d.rawValue
            // The index is meaningless without the channel, so it rides only with `dc` — a stale one
            // would let a client bind symbols to a source not delivered over it. Index 0 is VALID and
            // is emitted: skipping it would strand the first routed source.
            if d == .dc, let index = dcIndices[$0.source] { e["dcIndex"] = index }
        }
        // ABSENT MEANS UNKNOWN, never "off" — the activeCodec/activeDelivery/activeRecovery rule.
        // A host that has not decided, and a host that predates the field, must read the same.
        if let audio = audioState[$0.source] {
            e["audio"] = audio.sending
            // Only ever emitted for a source that YIELDED. A carrier mapped to itself would be
            // saying it yielded to itself, which the client would render as its own name.
            if let owner = audio.owner { e["audioOwner"] = owner }
        }
        return e
    }
    var obj: [String: Any] = ["t": "view-set", "subs": arr]
    obj["focused"] = focused as Any? ?? NSNull()
    // THE WHOLE STATE, EVERY TIME — never a diff. A client that missed one is repaired by the next, and a
    // reconnecting or new client needs nothing else to render the session.
    obj["windows"] = state.windows.map { w -> [String: Any] in
        var e: [String: Any] = ["source": w.source, "minimized": w.minimized]
        // TOGETHER OR NEITHER: a window never dragged cascades, and half a place is no place.
        if let p = w.position { e["x"] = p.x; e["y"] = p.y }
        // PRESENT ONLY WHEN SET, never null or "": an unnamed window's label is its source's own name.
        if let name = w.name { e["name"] = name }
        return e
    }
    // The BAR's order — terminal and window keys interleaved — WHOLE, like the rest of the state
    // (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §2.2).
    obj["agents"] = state.agents.map { a -> [String: Any] in
        var row: [String: Any] = ["id": a.id, "title": a.title, "cwd": a.cwd]
        if let name = a.name { row["name"] = name }
        if let status = a.status { row["status"] = status }
        if !a.activeFlags.isEmpty { row["activeFlags"] = a.activeFlags }
        return row
    }
    obj["selectedAgent"] = state.selectedAgent as Any? ?? NSNull()
    obj["tabOrder"] = state.tabOrder
    obj["view"] = ["surface": state.view.surface.rawValue,
                   "fullscreen": state.view.fullscreen as Any? ?? NSNull()] as [String: Any]
    obj["version"] = NSNumber(value: state.version)
    // TOP-LEVEL, NEVER PER-SUBSCRIPTION. The value is session-wide, and duplicating it per source
    // would let a client render two different numbers for one setting. Omitted entirely when Auto,
    // so absence and adaptive control are the same thing on the wire — which is also what makes an
    // older client read a session under adaptive control correctly rather than as a forced zero.
    if let bp = recoveryOverrideBp { obj["recoveryOverrideBp"] = bp }
    // TOP-LEVEL FOR THE SAME REASON, and ABSENT UNTIL THE ANSWER RESOLVES IT — absence means
    // UNKNOWN, never "degraded", exactly as `activeCodec` works. Recovery is per CONNECTION rather
    // than per source, and it is reported at all because FlexFEC-versus-not stopped being a detail
    // the moment a receiver could decline it: FEC repairs in band with no round trip, which is the
    // only mechanism that helps where RTX is age-refused before a NACK can arrive.
    if let recovery = activeRecovery, !recovery.isEmpty { obj["activeRecovery"] = recovery }
    // TOP-LEVEL AND ABSENT-MEANS-AUTO, the same two rules as the recovery override above, and for the
    // same reasons: the floor is one value per session, and an older client reading a session under
    // adaptive control must see Auto rather than a forced zero.
    if let minMs = playoutDelayMinMs { obj["playoutDelayMinMs"] = minMs }
    // Absent means the configured ceiling; present is the explicit ceiling the client asked for.
    if let maxMs = playoutDelayMaxMs { obj["playoutDelayMaxMs"] = maxMs }
    // TOP-LEVEL AND ABSENT-MEANS-UNKNOWN, the same two rules activeRecovery follows. The curtain is one
    // HOST-wide fact; duplicating it per subscription would let a client render two answers for one
    // setting. A host that predates the field must read as "no opinion", never as "down".
    if let curtainUp { obj["curtainUp"] = curtainUp }
    return jsonData(obj)
}

/// Map the host's display + window catalogs into the unified `Source` list for the picker.
///
/// ORDER IS DELIBERATE: displays first, then windows. The Desktop is the marquee entry and must not sit
/// below a couple of dozen window rows.
///
/// `sims` and `displays` both default to `[]` so existing call sites keep compiling — simulator support
/// was removed on 2026-07-31 but the parameter is kept because the `sim:` wire form is deliberately
/// still parsed.
public func makeSources(sims: [SimInfo] = [],
                        displays: [DisplayInfo] = [],
                        windows: [WindowInfo]) -> [Source] {
    let simSources = sims.map {
        Source(id: sourceID(simUDID: $0.udid), kind: "sim", name: "\($0.name) (\($0.os))",
               inputCapable: true, running: $0.state == .booted, w: $0.w, h: $0.h, simState: $0.state)
    }
    // NAMING IS CONDITIONAL ON COUNT. "Desktop — Built-in Retina Display" on a single-screen laptop
    // qualifies a thing that needs no qualifying; the model name earns its place only once there is a
    // second display to tell it apart from.
    let many = displays.count > 1
    let displaySources = displays.map {
        Source(id: sourceID(displayID: $0.id), kind: "display",
               name: many ? "Desktop \u{2014} \($0.name)" : "Desktop",
               // A LISTED DISPLAY IS ATTACHED. Disappearance rides absence from the next source-list
               // plus a source-status `live:false`, so `running` has no second state to carry.
               inputCapable: true, running: true,
               w: $0.w, h: $0.h)
    }
    let winSources = windows.map {
        Source(id: sourceID(windowID: $0.id), kind: "window",
               name: "\($0.app) - \($0.title)", inputCapable: true, running: !$0.minimized,
               w: $0.w, h: $0.h)
    }
    return simSources + displaySources + winSources
}
