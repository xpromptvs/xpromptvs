import Foundation

/// Which transport carries a source's encoded video.
///
/// ABSENT MEANS `.rtp` AND AN UNRECOGNISED VALUE DEGRADES TO `.rtp`, never a refusal — the same rule
/// `codec_pref` follows across the ABI. A version skew must cost the optimisation, not the source: a
/// client from the future asking for a transport this host has never heard of must still get its
/// window, over the path that has always worked.
public enum VideoDelivery: String, Sendable {
    case rtp
    case dc
}

/// Unpack `pion_peer_set_video_delivery`'s return value: `(dcIndex << 1) | isDC`, or negative for an
/// unknown handle.
///
/// SEPARATED FROM THE CALL SO IT CAN BE TESTED. Bit-packing across an FFI boundary is exactly the
/// kind of thing that misreports silently — an off-by-one in the shift yields a plausible index and
/// therefore the wrong source's symbols, which presents as a decoder bug rather than as a routing
/// one. Note that index 0 encodes as 1, so a `> 1` guard would turn the first routed source into RTP.
public func decodeVideoDeliveryResult(_ encoded: Int32) -> (delivery: VideoDelivery, dcIndex: Int?) {
    guard encoded > 0, encoded & 1 == 1 else { return (.rtp, nil) }
    return (.dc, Int(encoded >> 1))
}

public enum InboundMessage: Equatable {
    case agent(AgentCommand)
    case sourceInput(SourceInputCommand)
    /// Terminal bytes from the driver, ADDRESSED to the tab the client believed it was typing into.
    ///
    /// The id is not routing — the host still writes only to its own active tab. It is a claim the
    /// host CHECKS: if the client named a different tab, the two disagree about what the user was
    /// looking at, and the bytes are dropped rather than delivered somewhere unseen.
    case key(String, term: TermTabID)
    /// A device-query REPLY from the client's xterm.js instance for `term` — the tab whose bytes asked,
    /// shown or not. Never typing (that is `key`). Routed by `TerminalInput.shouldDeliverReply`.
    case termReply(String, term: TermTabID)
    case touch(x: Double, y: Double, phase: String, button: MouseButton, ts: Int?)
    /// Bare pointer hover over the focused source (normalized 0..1). Distinct from `touch` BY DESIGN: the
    /// sim injector treats every touch "move" as a held-finger report, so a hover sent as a touch would read
    /// as a stuck drag. Only window sources act on it.
    case hover(x: Double, y: Double)
    case requestThumbs
    /// A receiver-side diagnostic line, rendered by the client and printed verbatim by the host.
    /// UNGATED like `list-sources` and `request-thumbs` — it reports, it does not mutate.
    case receiverReport(line: String)
    /// Take control. `grid`: the claimer's terminal grid, as its own `resize` will report it — the host applies it
    /// BEFORE the new driver's wire snapshots every tab, so that first snapshot is at the claimer's size, not the
    /// previous driver's (docs/terminal.md, "A claim says its grid"). Absent or out of range: none.
    case claimControl(grid: TermGridSize?)
    case resize(cols: Int, rows: Int)
    /// `term-mode` `raw`: the client decodes the terminal WIRE — bind one for it (a driver) or build a
    /// fresh one (a client that could not decode its stream). The ONLY terminal mode: the legacy
    /// cell-frame mode is gone, so any other `mode` is malformed.
    case termWire
    /// The driver's page was hidden (`terminal-pause`) / is visible again (`terminal-resume`). The host
    /// holds a pause for 1 s (TerminalPauseGate) and re-serializes every tab on a resume after it.
    case terminalPause
    case terminalResume
    /// The client's xterm.js palette as it REPORTS it (`term-palette`, sent on control open and on a
    /// theme change). The driver's is what the host answers a tmux tab's colour queries from when their
    /// bytes reach no client (docs/terminal.md, "tmux answers device queries itself"). UNGATED: a
    /// passive client's is kept for when it becomes the driver.
    case termPalette(TermPalette)
    case listTerminals
    case openTerminal
    /// Reopen the tab the driver closed last (⌘⇧T): its tmux session re-attached, or a shell in its
    /// directory (`SavedTerminalTab`). Driver-gated.
    case reopenTerminal
    case closeTerminal(id: TermTabID)
    case switchTerminal(id: TermTabID)
    /// Ask for the host's tmux sessions. UNGATED like `list-terminals` — it reads, it does not mutate.
    case listTmux
    /// Open (or select) a tab for an existing tmux session. Driver-gated.
    case openTmux(session: String)
    /// Create a tmux session and open it. Driver-gated.
    case newTmux
    /// End a tmux session. Driver-gated; the client confirms first.
    case killTmux(session: String)
    case appsCapabilities(Bool)
    case appsList
    case appsAdd(String)
    case appsRemove(String)
    case appsRestoreAll
    case listSources
    /// Open a window — or un-minimize and focus it if the session already holds it. Driver-gated. Its
    /// video settings are NOT here: they are the device's (`clientHello` / `setPrefs`).
    case subscribe(source: String, delivery: VideoDelivery)
    /// The FIRST control message a connection finishes with (the last of its control-open batch, after
    /// the connection's own settings): the device's preferences, and the host's cue that this connection
    /// has stated everything it starts with — the host starts a driver's video only after it. UNGATED:
    /// it describes the connection, not the session, and a passive client's apply once it drives.
    /// `delivery` is the CONNECTION's transport for the windows the host restores to it — absent or
    /// unknown is `.rtp`, the rule `subscribe` follows — so a `?dc=1` page's windows come back on the
    /// channel it asked for rather than on RTP.
    case av1Reference(AV1ReferenceMessage)
    case clientHello(prefs: ClientPrefs, delivery: VideoDelivery, av1ReferenceAck: Int? = nil)
    /// The device's preferences changed mid-session: the WHOLE set, never a patch. UNGATED like the hello.
    case setPrefs(ClientPrefs)
    /// Park a window as its tab: it stays in the session state with no capture. Driver-gated. `land`: the
    /// person was AT the window (the client's to tell — `SessionState.landing`), so they land on the bar's
    /// previous tab; absent is false.
    case minimizeWindow(source: String, land: Bool = false)
    /// Bring a parked window back and focus it. Driver-gated.
    case restoreWindow(source: String)
    /// Where the driver left a window on the desktop (floating) layout — sent at the END of a drag, in the
    /// client's stage CSS px, validated here (`WindowPosition.isValid`). Driver-gated.
    case setWindowPosition(source: String, x: Double, y: Double)
    /// Which surface a pinned layout shows and which window is in full-screen mode. Each field optional:
    /// `nil` leaves it alone; for `fullscreen`, `.some(nil)` ends the mode. Driver-gated.
    case setView(surface: SessionSurface?, fullscreen: String??)
    /// Move a tab of the session's BAR — terminal or window, by KEY (`TabKey`) — to just before `before`,
    /// or to the end when it is nil (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md,
    /// §2.1). Driver-gated; permitted to a window-less client (it arranges the bar, not the Mac's windows).
    case moveTab(tab: String, before: String?)
    /// Name a tab: a `pty:` terminal's or a window's user name (`""` clears it), or a `tmux:` tab's SESSION
    /// name (renamed through tmux; never empty). Driver-gated; permitted to a window-less client.
    case renameTab(tab: String, name: String)
    /// A PASTE or a DROP from the driver (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §3):
    /// declared whole, then its items' bytes in order, then `paste-end`.
    case pasteBegin(PasteBegin)
    case pasteData(id: String, item: Int, seq: Int, bytes: Data)
    case pasteEnd(id: String)
    case pasteCancel(id: String)
    /// The image a path printed in a terminal tab names, to show on the client (`FileFetch`). Driver-gated, as
    /// the terminal is; permitted to a window-less client.
    case fileGet(FileGet)
    /// Re-add THIS driver's track for a streamed window — the WebCodecs stall recovery. NOT a session
    /// change (no state change, no version bump): under the state model its old unsubscribe+subscribe
    /// would close the window and reopen it. Driver-gated.
    case reattachSource(source: String)
    /// Close a window: it leaves the session. `land` as for `minimizeWindow`.
    case unsubscribe(source: String, land: Bool = false)
    /// The client's decoder needs an IDR for this source.
    ///
    /// RESTORED 2026-08-27. It existed for the WebCodecs receive path, and was deleted in 03bee96
    /// once that path was retired. It is needed again for exactly the same reason: a client that
    /// consumes the encoded frames via `RTCRtpScriptTransform` starves the browser's own decoder, so
    /// the browser never sends a PLI again and decoder-driven recovery becomes the client's job.
    /// `<video>` clients never send this — their browser still PLIs for them.
    ///
    /// The host already answers it correctly: `KeyframeDebounce` is 500ms PER SOURCE and a suppressed
    /// request is DEFERRED, never dropped — measured over 20s under 1% loss as the difference between
    /// 21 frames (dead at 1s) and 1131 frames (healthy).
    case requestKeyframe(source: String)
    /// The per-window values the client DERIVES: the Auto resolution ceiling (`scale`, while the device's
    /// scale preference is `auto`) and the crop. fps, bitrate and codec are the device's (`setPrefs`).
    case setSourcePrefs(source: String, scale: Double?, crop: CropRect?)
    /// Client asks the host to resize the REAL window behind this source (POINTS). Best-effort: the app may
    /// clamp or refuse; the authoritative answer is the `source-status` size the size poll pushes back.
    case setSourceSize(source: String, w: Int, h: Int)
    /// Force the session's FEC overhead, in basis points of media, or `nil` for adaptive control.
    /// SESSION-SCOPED, unlike every other pref here — FEC is one controller and one budget per
    /// connection, so this deliberately does not name a source.
    case setRecovery(overrideBp: Int?)
    /// Playout-delay FLOOR in milliseconds, session-wide; nil is Auto. Auto behaves as 0 today and is
    /// carried on the wire so an adaptive mode can start meaning something without a protocol change.
    /// `maxMs` nil is "the host's configured ceiling, raised to the floor" — the only form until
    /// 2026-09-04. A number is an explicit ceiling; `minMs == maxMs` is a fixed WINDOW from capture,
    /// the setting a Chromium receiver on a clean path measures best on (`PlayoutDelayControl.swift`).
    case setPlayoutDelay(minMs: Int?, maxMs: Int?)
    /// The client's tab went to the background (or came back). SESSION-SCOPED like `setRecovery`:
    /// it names no source, because visibility is a property of the CLIENT, not of any one window.
    /// Start or stop sending this source's audio to THIS client. Drops the encoder's sink and
    /// stops the wire; the track stays NEGOTIATED, so there is no renegotiation, no new SSRC and
    /// no IDR — the hidden-tab pause's mechanism.
    case setSourceAudio(source: String, enabled: Bool)
    case setVisibility(hidden: Bool)
    case focusSource(source: String)
    /// A wheel/trackpad scroll over the focused source. `unit` is what the BROWSER reported, not a
    /// normalized value — a notched wheel stays lines and posts `.line` units, a trackpad stays
    /// pixels and posts continuous `.pixel` units with a synthesized phase. Absent means line
    /// (see `ScrollUnit.init(wire:)`). `mods` is the wheel event's own modifier snapshot, which is
    /// what makes ⌥-scroll and ⌘-scroll-to-zoom work even when the modifier was held before the
    /// window ever took keyboard focus.
    case scroll(x: Double, y: Double, dx: Double, dy: Double, unit: ScrollUnit, mods: InputModifiers)
    /// A TOUCH client's two-finger flick has ended: run the glide on the HOST. `vx`/`vy` are host
    /// points per SECOND in the same sign convention as `scroll`'s deltas, and a ZERO velocity means
    /// STOP — which is what a finger landing back on a gliding view sends.
    ///
    /// ONLY A TOUCHSCREEN SENDS THIS. A Mac trackpad's momentum is synthesized by macOS into the
    /// browser and arrives here as ordinary `scroll` deltas, so a second source would double-scroll
    /// it; the client's wheel path deliberately sends no fling at all. See `ScrollMomentum` for why
    /// the host owns the curve rather than the client streaming it a frame at a time.
    case scrollFling(x: Double, y: Double, vx: Double, vy: Double, mods: InputModifiers)
    case scrollGesture(x: Double, y: Double, phase: ScrollGesturePhase, vx: Double, vy: Double, mods: InputModifiers)
    /// One key transition for the focused WINDOW source. Deliberately NOT `key`, which is the
    /// terminal's (bytes → PTY) and carries no physical identity at all.
    ///
    /// `code` is the PHYSICAL key (W3C `KeyboardEvent.code`) and becomes the mac virtual keycode;
    /// `key` is the CHARACTER the client's layout produced and becomes a unicode override for
    /// printable keys with no ⌘/⌃. See `planKeyInjection`.
    case winKey(down: Bool, code: String, key: String, repeat: Bool, mods: InputModifiers)
    /// Release everything the host believes is held. Sent by the client on blur, window blur, tab
    /// hide and pagehide — every transition after which the browser stops delivering keyups.
    case winKeysRelease
    /// Raise or lower the host's screen curtain. DRIVER-GATED. Distinct from the menu-bar item and
    /// SIGUSR1/SIGUSR2, which remain — this is the REMOTE route, and full-display capture is what makes
    /// it worth having: gamma blackout is applied at SCANOUT, after SCK captures, so the remote view
    /// stays perfect while the physical screen goes black and local input dies.
    case curtain(on: Bool)
    /// A SIMULATOR window's pass-through touch: one or two contacts, 0…1 on the picture AS SHOWN, clamped onto it.
    /// Its own message, not `touch`: DTUHID carries both contacts in ONE event, and `touch` carries window semantics
    /// (a mouse button, a deferred press) a simulator has none of. Routed to the focused source like `touch`.
    case simTouch(phase: String, points: [SimPoint])
    /// What a soft keyboard inserted into a SIMULATOR window, whole — a `win-key` cannot carry é or an emoji (its
    /// `code` is empty, and empty is refused).
    case simText(String)
    /// A driver's intent on a simulator, which names its source: a button, shake, a rotation, boot, shutdown.
    case simAction(source: String, action: SimAction)
}

/// Parse a raw (already-unwrapped) JSON payload into an InboundMessage.
/// Returns nil for unknown `t` values, missing discriminator, or non-JSON input.
public func parseInbound(_ data: Data) -> InboundMessage? {
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return parseInboundObject(obj)
}

/// Shared canonical field decoding; scoped source input admits its explicit type allowlist first.
func parseInboundObject(_ obj: [String: Any]) -> InboundMessage? {
    guard let t = obj["t"] as? String else { return nil }
    switch t {
    case "source-input-capabilities", "source-focus", "source-input":
        return SourceInputCommand.parse(obj).map { .sourceInput($0) }
    case "av1-ref-bound", "av1-ref-ack", "av1-ref-reset":
        return AV1ReferenceMessage.decode(obj).map(InboundMessage.av1Reference)
    case "key":
        // `term` MUST be present, and defaulting it would be worse than dropping the message. Keystrokes
        // travel on `input` while `switch-terminal` travels on `control` — two independent streams, of one
        // lane or (the SCTP baseline) two channels — so the host cannot infer from arrival order which tab
        // the user was typing into. The field is what closes that gap, and a default of "whatever is active"
        // is exactly the behaviour it exists to remove. An unaddressed keystroke is therefore MALFORMED, and
        // so is one naming a tab in the retired numeric form (`TermTabID`).
        guard let s = obj["data"] as? String,
              let raw = obj["term"] as? String, let term = TermTabID(wire: raw) else { return nil }
        return .key(s, term: term)
    case "term-reply":
        // Addressed like `key`, and for the same reason malformed without its tab: a reply's tab is the
        // one fact it carries that a keystroke's does not have to be trusted for.
        guard let s = obj["data"] as? String,
              let raw = obj["term"] as? String, let term = TermTabID(wire: raw) else { return nil }
        return .termReply(s, term: term)
    case "touch":
        let x = (obj["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (obj["y"] as? NSNumber)?.doubleValue ?? 0
        let phase = obj["phase"] as? String ?? ""
        let ts = (obj["ts"] as? NSNumber)?.intValue
        return .touch(x: x, y: y, phase: phase,
                      button: MouseButton(wire: obj["button"] as? String), ts: ts)
    case "hover":
        guard let x = (obj["x"] as? NSNumber)?.doubleValue,
              let y = (obj["y"] as? NSNumber)?.doubleValue else { return nil }
        return .hover(x: x, y: y)
    case "request-thumbs":
        return .requestThumbs
    case "rx-stats":
        guard let raw = obj["line"] as? String, let line = ReceiverReport.sanitize(raw) else { return nil }
        return .receiverReport(line: line)
    case "scroll":
        let x = (obj["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (obj["y"] as? NSNumber)?.doubleValue ?? 0
        let dx = (obj["dx"] as? NSNumber)?.doubleValue ?? 0
        let dy = (obj["dy"] as? NSNumber)?.doubleValue ?? 0
        return .scroll(x: x, y: y, dx: dx, dy: dy,
                       unit: ScrollUnit(wire: obj["unit"] as? String),
                       mods: InputModifiers(raw: (obj["mods"] as? NSNumber)?.intValue ?? 0))
    case "scroll-gesture":
        guard let rawPhase = obj["phase"] as? String, let phase = ScrollGesturePhase(rawValue: rawPhase) else { return nil }
        func finite(_ field: String, default fallback: Double? = nil) -> Double? {
            guard let raw = obj[field] else { return fallback }
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, abs(value.doubleValue) <= 1_000_000 else { return nil }
            return value.doubleValue
        }
        guard let x = finite("x"), let y = finite("y"), let vx = finite("vx", default: 0), let vy = finite("vy", default: 0) else { return nil }
        return .scrollGesture(x: min(max(x, 0), 1), y: min(max(y, 0), 1), phase: phase,
                              vx: vx, vy: vy, mods: InputModifiers(raw: (obj["mods"] as? NSNumber)?.intValue ?? 0))
    case "scroll-fling":
        // Velocities DEFAULT TO ZERO rather than refusing the message: zero is the stop, so a
        // garbled fling stops a glide instead of leaving one running that nothing can now reach.
        return .scrollFling(x: (obj["x"] as? NSNumber)?.doubleValue ?? 0,
                            y: (obj["y"] as? NSNumber)?.doubleValue ?? 0,
                            vx: (obj["vx"] as? NSNumber)?.doubleValue ?? 0,
                            vy: (obj["vy"] as? NSNumber)?.doubleValue ?? 0,
                            mods: InputModifiers(raw: (obj["mods"] as? NSNumber)?.intValue ?? 0))
    case "win-key":
        // `down` MUST be present. Defaulting it would turn every keystroke into a keyUp for a key
        // that was never pressed.
        guard let down = obj["down"] as? Bool,
              let code = obj["code"] as? String, !code.isEmpty else { return nil }
        return .winKey(down: down, code: code,
                       key: obj["key"] as? String ?? "",
                       repeat: obj["repeat"] as? Bool ?? false,
                       mods: InputModifiers(raw: (obj["mods"] as? NSNumber)?.intValue ?? 0))
    case "win-keys-release":
        return .winKeysRelease
    case "claim-control":
        return .claimControl(grid: JoinHello.parseGrid(obj))
    case "resize":
        guard let c = (obj["cols"] as? NSNumber)?.intValue,
              let r = (obj["rows"] as? NSNumber)?.intValue else { return nil }
        return .resize(cols: c, rows: r)
    case "term-mode":
        guard obj["mode"] as? String == "raw" else { return nil }
        return .termWire
    case "terminal-pause":
        return .terminalPause
    case "terminal-resume":
        return .terminalResume
    case "term-palette":
        return TermPalette(wire: obj).map { .termPalette($0) }
    case "agent-request":
        return AgentCommand.parse(obj).map { .agent($0) }
    case "list-terminals":
        return .listTerminals
    case "open-terminal":
        return .openTerminal
    case "reopen-terminal":
        return .reopenTerminal
    case "close-terminal":
        guard let raw = obj["id"] as? String, let id = TermTabID(wire: raw) else { return nil }
        return .closeTerminal(id: id)
    case "switch-terminal":
        guard let raw = obj["id"] as? String, let id = TermTabID(wire: raw) else { return nil }
        return .switchTerminal(id: id)
    case "list-tmux":
        return .listTmux
    case "new-tmux":
        return .newTmux
    case "open-tmux", "kill-tmux":
        // Validated HERE: a session id is interpolated into tmux `-t` targets.
        guard let s = obj["session"] as? String, TmuxList.isSessionId(s) else { return nil }
        return t == "open-tmux" ? .openTmux(session: s) : .killTmux(session: s)
    case "apps-capabilities": return .appsCapabilities(obj["packedV1"] as? Bool ?? false)
    case "apps-list": return .appsList
    case "apps-restore-all": return .appsRestoreAll
    case "apps-add", "apps-remove":
        guard let app=obj["app"] as? String,!app.isEmpty,app.utf8.count<=256 else{return nil}
        return t=="apps-add" ? .appsAdd(app) : .appsRemove(app)
    case "list-sources":
        return .listSources
    case "subscribe":
        // fps/scale/bitrate NO LONGER RIDE A SUBSCRIBE — they are the device's preferences
        // (`client-hello`/`set-prefs`), applied to every window. A stale sender's copies are IGNORED,
        // not refused: the window still opens.
        guard let source = obj["source"] as? String, !source.isEmpty else { return nil }
        return .subscribe(source: source,
                          delivery: VideoDelivery(rawValue: (obj["delivery"] as? String) ?? "") ?? .rtp)
    case "client-hello", "set-prefs":
        // THE `prefs` OBJECT IS REQUIRED — a hello without one cannot say what the device wants — while
        // every field inside it is lenient (`ClientPrefs(wire:)`): a bad field is the host's default.
        guard let prefs = obj["prefs"] as? [String: Any] else { return nil }
        guard t == "client-hello" else { return .setPrefs(ClientPrefs(wire: prefs)) }
        // The connection's transport: ABSENT MEANS RTP AND AN UNKNOWN VALUE DEGRADES TO RTP — the
        // `subscribe` rule. A version skew must cost the optimisation, never the hello the host's video
        // waits for.
        return .clientHello(prefs: ClientPrefs(wire: prefs),
                            delivery: VideoDelivery(rawValue: (obj["delivery"] as? String) ?? "") ?? .rtp,
                            av1ReferenceAck: AV1ReferenceMessage.capability(obj["av1ReferenceAck"]))
    case "reattach-source":
        guard let source = obj["source"] as? String, !source.isEmpty else { return nil }
        return .reattachSource(source: source)
    case "minimize-window", "restore-window":
        guard let source = obj["source"] as? String, !source.isEmpty else { return nil }
        guard t == "minimize-window" else { return .restoreWindow(source: source) }
        guard let land = landFlag(obj) else { return nil }
        return .minimizeWindow(source: source, land: land)
    case "set-window-position":
        // REFUSED WHOLE, never clamped: a clamped position is a place nobody dragged the window to.
        guard let source = obj["source"] as? String, !source.isEmpty,
              let x = wireNumber(obj["x"]), let y = wireNumber(obj["y"]),
              WindowPosition.isValid(x: x, y: y) else { return nil }
        return .setWindowPosition(source: source, x: x, y: y)
    case "set-view":
        // ABSENT LEAVES A FIELD ALONE; a PRESENT field must be valid or the message is malformed — a
        // `surface` of null or a `fullscreen` of "" is a sender bug, not a request. `fullscreen: null` is
        // the one present-and-null that means something: END the mode.
        var surface: SessionSurface? = nil
        if let raw = obj["surface"] {
            guard let s = raw as? String, let parsed = SessionSurface(rawValue: s) else { return nil }
            surface = parsed
        }
        var fullscreen: String?? = nil
        if let raw = obj["fullscreen"] {
            if raw is NSNull { fullscreen = .some(nil) }
            else if let s = raw as? String, !s.isEmpty { fullscreen = .some(s) }
            else { return nil }
        }
        guard surface != nil || fullscreen != nil else { return nil }   // asks for nothing
        return .setView(surface: surface, fullscreen: fullscreen)
    case "move-tab":
        // `before` IS REQUIRED: a key, or null for the END. Absent, "", a non-key or the tab itself is a
        // sender bug, never a move to somewhere guessed. A key, never an index — a client's bar can be a
        // subset of the session's (a window-less one shows no windows).
        guard let tab = obj["tab"] as? String, TabKey.isValid(tab), let raw = obj["before"] else { return nil }
        if raw is NSNull { return .moveTab(tab: tab, before: nil) }
        guard let before = raw as? String, TabKey.isValid(before), before != tab else { return nil }
        return .moveTab(tab: tab, before: before)
    case "rename-tab":
        // `name` IS REQUIRED and must be a name (`TabName`). "" CLEARS a pty:/window name; a tmux session
        // has no "no name" (tmux would even take one), so "" for a tmux tab is malformed, not a clear.
        guard let tab = obj["tab"] as? String, TabKey.isValid(tab),
              let name = obj["name"] as? String, TabName.isValid(name) else { return nil }
        if name.isEmpty, TermTabID(wire: tab)?.tmuxSession != nil { return nil }
        return .renameTab(tab: tab, name: name)
    case "paste-begin": return PasteWire.parseBegin(obj).map { .pasteBegin($0) }
    case "paste-data": return PasteWire.parseData(obj)
    case "paste-end": return PasteWire.parseID(obj).map { .pasteEnd(id: $0) }
    case "paste-cancel": return PasteWire.parseID(obj).map { .pasteCancel(id: $0) }
    case "file-get": return FileFetch.parse(obj).map { .fileGet($0) }
    case "set-recovery":
        // The key must be PRESENT. Absent is a malformed message; present-and-null is Auto, which is
        // a different setting from a forced 0% (no FEC at all).
        guard obj.keys.contains("overrideBp") else { return nil }
        if obj["overrideBp"] is NSNull { return .setRecovery(overrideBp: nil) }
        guard let bp = obj["overrideBp"] as? NSNumber else { return nil }
        return .setRecovery(overrideBp: clampRecoveryOverrideBp(bp.intValue))
    case "set-playout-delay":
        // PRESENT-AND-NULL IS AUTO; absent is malformed. Same rule as set-recovery, and the same
        // reason: Auto and a forced 0 are different settings, and today they merely behave alike.
        guard obj.keys.contains("minMs") else { return nil }
        // ABSENT OR NULL `maxMs` IS THE CONFIGURED CEILING — an older client never sends it. A number
        // is clamped like the floor; a ceiling below the floor is a contradiction and reads as malformed.
        var maxMs: Int? = nil
        if let rawMax = obj["maxMs"], !(rawMax is NSNull) {
            guard let n = rawMax as? NSNumber else { return nil }
            maxMs = clampPlayoutDelayMinMs(n.intValue)
        }
        if obj["minMs"] is NSNull {
            guard maxMs == nil else { return nil }   // a ceiling with no floor names no window
            return .setPlayoutDelay(minMs: nil, maxMs: nil)
        }
        guard let ms = obj["minMs"] as? NSNumber else { return nil }
        let minMs = clampPlayoutDelayMinMs(ms.intValue)
        if let maxMs, let minMs, maxMs < minMs { return nil }
        return .setPlayoutDelay(minMs: minMs, maxMs: maxMs)
    case "unsubscribe":
        guard let source = obj["source"] as? String, !source.isEmpty, let land = landFlag(obj) else { return nil }
        return .unsubscribe(source: source, land: land)
    case "request-keyframe":
        guard let source = obj["source"] as? String, !source.isEmpty else { return nil }
        return .requestKeyframe(source: source)
    case "set-source-prefs":
        // NARROWED to what the client DERIVES per window: the Auto resolution ceiling (`scale`, while the
        // device's scale preference is `auto`) and the crop. fps, bitrate and codec are the device's
        // (`set-prefs`); a stale sender's copies are ignored.
        guard let source = obj["source"] as? String, !source.isEmpty else { return nil }
        return .setSourcePrefs(source: source, scale: wireNumber(obj["scale"]), crop: parseCrop(obj["crop"]))
    case "set-visibility":
        // `as? Bool` also accepts JSON 1/0 through NSNumber bridging, which is harmless here — both
        // spellings mean the same thing. A MISSING flag is rejected rather than defaulted.
        guard let hidden = obj["hidden"] as? Bool else { return nil }
        return .setVisibility(hidden: hidden)
    case "set-source-audio":
        // A MISSING FLAG IS REJECTED, NOT DEFAULTED — the `curtain` and `set-visibility` rule.
        // `as? Bool` also accepts JSON 1/0 through NSNumber bridging, which is harmless: both
        // spellings mean the same thing.
        guard let source = obj["source"] as? String, !source.isEmpty,
              let enabled = obj["enabled"] as? Bool else { return nil }
        return .setSourceAudio(source: source, enabled: enabled)
    case "focus-source":
        guard let source = obj["source"] as? String, !source.isEmpty else { return nil }
        return .focusSource(source: source)
    case "set-source-size":
        guard let source = obj["source"] as? String, !source.isEmpty,
              let w = (obj["w"] as? NSNumber)?.intValue, let h = (obj["h"] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        return .setSourceSize(source: source, w: w, h: h)
    case "curtain":
        // `as? Bool` also accepts JSON 1/0 through NSNumber bridging. A MISSING flag is REJECTED, not
        // defaulted — defaulting would let a malformed message black someone's screen.
        guard let on = obj["on"] as? Bool else { return nil }
        return .curtain(on: on)
    case "sim-touch":
        guard let phase = obj["phase"] as? String, ["down", "move", "up"].contains(phase),
              let raw = obj["points"] as? [[String: Any]], (1...2).contains(raw.count) else { return nil }
        var points: [SimPoint] = []
        for p in raw {
            guard let x = (p["x"] as? NSNumber)?.doubleValue, let y = (p["y"] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite else { return nil }
            points.append(SimPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)))
        }
        return .simTouch(phase: phase, points: points)
    case "sim-text":
        // Capped like a paste's text is not: this is TYPING, and 4 KB is a long dictation.
        guard let text = obj["text"] as? String, !text.isEmpty, text.utf8.count <= 4096 else { return nil }
        return .simText(text)
    case "sim-action":
        guard let source = obj["source"] as? String, case .sim? = parseSourceID(source),
              let raw = obj["action"] as? String, let action = SimAction(rawValue: raw) else { return nil }
        return .simAction(source: source, action: action)
    default:
        return nil
    }
}

/// A close's or a park's `land` (the person was AT the window, `SessionState.landing`): ABSENT is false;
/// PRESENT must be a boolean, or the message is malformed — a sender bug, not a request (`set-view`'s rule).
/// `as? Bool` also accepts JSON 1/0 through NSNumber bridging, which is harmless here, as for `hidden`.
private func landFlag(_ obj: [String: Any]) -> Bool? {
    guard let raw = obj["land"] else { return false }
    return raw as? Bool
}

/// A crop rect from the wire, or nil for "no patch".
///
/// ALL FOUR FIELDS OR NOTHING. A partial rect is a bug at the sender, and filling the gaps with
/// defaults would silently move the viewer's window — the same reason a codec typo yields nil rather
/// than resetting the pin to auto.
private func parseCrop(_ raw: Any?) -> CropRect? {
    guard let o = raw as? [String: Any],
          let x = (o["x"] as? NSNumber)?.doubleValue,
          let y = (o["y"] as? NSNumber)?.doubleValue,
          let w = (o["w"] as? NSNumber)?.doubleValue,
          let h = (o["h"] as? NSNumber)?.doubleValue else { return nil }
    return CropRect(x: x, y: y, w: w, h: h)
}
