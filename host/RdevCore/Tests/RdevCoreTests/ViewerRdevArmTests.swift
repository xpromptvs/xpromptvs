import XCTest
@testable import RdevCore

/// The pure decisions the viewer's rdev arm makes before, and while, it is connected.
///
/// Every one of these used to be a candidate for a line inside `tools/RdevViewer` — a module that
/// links `main.swift` and is therefore unreachable from any test binary. That is where this branch
/// has repeatedly shipped mechanisms that stayed green while deleted, so the rule for this task is
/// the same one Task 10's review set: if it is a DECISION, it lives here.
final class ViewerRdevArmTests: XCTestCase {

    // MARK: - the session URL

    func testSessionURLSwapsHTTPForWS() {
        XCTAssertEqual(
            RdevViewerSignaling.sessionURL(signaling: "http://127.0.0.1:8787", code: "rm5skaUZ")?
                .absoluteString,
            "ws://127.0.0.1:8787/session/rm5skaUZ")
    }

    func testSessionURLSwapsHTTPSForWSS() {
        XCTAssertEqual(
            RdevViewerSignaling.sessionURL(
                signaling: "https://rdev.example.workers.dev", code: "abc")?.absoluteString,
            "wss://rdev.example.workers.dev/session/abc")
    }

    /// THE MUTATION-CATCHER. A `replacingOccurrences(of: "http", with: "ws")` maps the SCHEME
    /// correctly and quietly mangles anything else that spells it — a host, a path, a port's
    /// neighbours. The scheme is a scheme, so it is replaced as one.
    func testSessionURLRewritesOnlyTheScheme() {
        XCTAssertEqual(
            RdevViewerSignaling.sessionURL(signaling: "http://http.example:8787", code: "abc")?
                .absoluteString,
            "ws://http.example:8787/session/abc")
    }

    /// A pasted origin routinely carries a trailing slash, and `…8787//session/abc` is a 404 the
    /// control plane answers with a plain "expected websocket upgrade" — which reads as a broken
    /// host rather than as a typed URL.
    func testSessionURLTolerantOfATrailingSlash() {
        XCTAssertEqual(
            RdevViewerSignaling.sessionURL(signaling: "http://127.0.0.1:8787/", code: "abc")?
                .absoluteString,
            "ws://127.0.0.1:8787/session/abc")
    }

    func testSessionURLAcceptsAnExplicitWebSocketScheme() {
        XCTAssertEqual(
            RdevViewerSignaling.sessionURL(signaling: "ws://127.0.0.1:8787", code: "abc")?
                .absoluteString,
            "ws://127.0.0.1:8787/session/abc")
        XCTAssertEqual(
            RdevViewerSignaling.sessionURL(signaling: "wss://x.example", code: "abc")?
                .absoluteString,
            "wss://x.example/session/abc")
    }

    func testSessionURLRejectsJunk() {
        XCTAssertNil(RdevViewerSignaling.sessionURL(signaling: "", code: "abc"))
        XCTAssertNil(RdevViewerSignaling.sessionURL(signaling: "127.0.0.1:8787", code: "abc"))
        XCTAssertNil(RdevViewerSignaling.sessionURL(signaling: "ftp://x.example", code: "abc"))
        XCTAssertNil(RdevViewerSignaling.sessionURL(signaling: "http://x.example", code: ""))
    }

    // MARK: - ICE servers

    /// LOAD-BEARING: `ice_servers_json` must be an ARRAY. The control plane's `welcome` carries a
    /// single TURN OBJECT (`{urls, username, credential, ttl}`), and handing that across
    /// unchanged makes `ParseIceServers` fail with "ice_servers_json must be an array" — which
    /// aborts `rdev_viewer_create` before any measurement, reporting a JSON shape rather than
    /// anything about TURN.
    func testIceServersWrapsTheWelcomeTurnInAnArray() throws {
        let turn = #"{"urls":["stun:stun.cloudflare.com:3478"],"username":"u","credential":"c","ttl":600}"#
        let json = RdevViewerSignaling.iceServersJSON(welcomeTurn: turn)
        let servers = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
            "ice_servers_json must be a JSON ARRAY of objects, got: \(json)")
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?["username"] as? String, "u")
        XCTAssertEqual(servers.first?["credential"] as? String, "c")
        XCTAssertEqual(servers.first?["urls"] as? [String], ["stun:stun.cloudflare.com:3478"])
    }

    /// `ttl` is the control plane's own bookkeeping. libwebrtc reads urls/username/credential and
    /// nothing else, so carrying it would put a number in the ICE configuration that means
    /// nothing there.
    func testIceServersDropsTTL() {
        let turn = #"{"urls":["turn:t.example:3478"],"username":"u","credential":"c","ttl":600}"#
        XCTAssertFalse(RdevViewerSignaling.iceServersJSON(welcomeTurn: turn).contains("ttl"))
    }

    /// A single string `urls` is legal in the WebRTC API and `ParseIceServers` accepts it, so it
    /// must survive rather than be dropped for not being an array.
    func testIceServersAcceptsAScalarUrls() {
        let turn = #"{"urls":"stun:stun.example:3478","username":"u","credential":"c"}"#
        let json = RdevViewerSignaling.iceServersJSON(welcomeTurn: turn)
        XCTAssertTrue(json.contains("stun:stun.example:3478"), json)
    }

    /// "" is the ABI's "no ICE servers", and it is the right answer for a TURN blob with no urls
    /// in it — an EMPTY ARRAY would be equally valid, but `[]` and `""` differ for nothing here
    /// while `[{}]` would be REFUSED ("ice server entry has no urls") and take the run down.
    func testIceServersIsEmptyForAnUnusableTurnBlob() {
        XCTAssertEqual(RdevViewerSignaling.iceServersJSON(welcomeTurn: "{}"), "")
        XCTAssertEqual(RdevViewerSignaling.iceServersJSON(welcomeTurn: "not json"), "")
        XCTAssertEqual(RdevViewerSignaling.iceServersJSON(welcomeTurn: #"{"urls":[]}"#), "")
    }

    // MARK: - the control channel, outbound
    //
    // Every one of these is asserted by ROUND-TRIPPING through `parseInbound` — the host's own
    // parser, the code that actually decides whether a message does anything. A test that
    // compared the built string against a hand-written literal would agree with itself while the
    // host ignored the message, which is precisely the failure the rdev arm cannot survive: an
    // unclaimed viewer receives zero frames and looks exactly like a dead transport.

    func testClaimControlRoundTripsThroughTheHostParser() {
        XCTAssertEqual(parseInbound(ViewerControl.claimControl.payload()), .claimControl(grid: nil))
    }

    func testListSourcesRoundTripsThroughTheHostParser() {
        XCTAssertEqual(parseInbound(ViewerControl.listSources.payload()), .listSources)
    }

    func testSubscribeRoundTripsThroughTheHostParser() {
        XCTAssertEqual(
            parseInbound(ViewerControl.subscribe(source: "win:42").payload()),
            .subscribe(source: "win:42", delivery: .rtp))
    }

    func testFocusSourceRoundTripsThroughTheHostParser() {
        XCTAssertEqual(
            parseInbound(ViewerControl.focusSource(source: "test").payload()),
            .focusSource(source: "test"))
    }

    /// The viewer's `--fps` / `--bitrate` are its DEVICE PREFERENCES now, stated in the `client-hello` the
    /// host waits for before it starts a driver's video. `parseInbound` returning each field present is
    /// what proves they travel as NUMBERS — a fps sent as the string "60" parses to absent and the host
    /// silently keeps its own.
    func testClientHelloCarriesTheViewersPreferencesAsNumbers() {
        XCTAssertEqual(
            parseInbound(ViewerControl.clientHello(fps: 60, bitrateBps: 8_000_000).payload()),
            .clientHello(prefs: ClientPrefs(fps: 60, bitrateBps: 8_000_000), delivery: .rtp))
    }

    /// An omitted preference must be ABSENT, not zero: absent is the host's default, while a 0 is a
    /// malformed field the host drops — the same outcome by accident rather than by intent.
    func testClientHelloOmitsUnsetFields() {
        let payload = ViewerControl.clientHello(fps: nil, bitrateBps: 4_000).payload()
        XCTAssertEqual(parseInbound(payload), .clientHello(prefs: ClientPrefs(bitrateBps: 4_000), delivery: .rtp))
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        XCTAssertEqual((object?["prefs"] as? [String: Any])?.keys.sorted(), ["bitrateBps"])
        // NO TRANSPORT: the viewer decodes RTP, which is what an absent `delivery` means.
        XCTAssertNil(object?["delivery"])
    }

    // MARK: - the control channel, inbound

    /// The failure policy's input. `active: false` is the difference between "measure this" and
    /// "fail now with the reason", because every mutation the viewer needs — subscribe,
    /// focus-source, set-source-prefs — is behind `isActiveClient` on the host, and a passive
    /// viewer therefore receives ZERO frames while every transport signal reads healthy.
    func testParsesControlState() {
        let state = ViewerControlState.parse(
            Data(#"{"t":"control-state","active":true,"clients":2}"#.utf8))
        XCTAssertEqual(state?.active, true)
        XCTAssertEqual(state?.clients, 2)
    }

    func testParsesInactiveControlState() {
        let state = ViewerControlState.parse(
            Data(#"{"t":"control-state","active":false,"clients":3}"#.utf8))
        XCTAssertEqual(state?.active, false)
        XCTAssertEqual(state?.clients, 3)
    }

    /// nil for any OTHER control message, so "no control-state has arrived yet" stays
    /// distinguishable from "the host said we are passive". The viewer must not fail a run on the
    /// first `term-list` it sees.
    func testControlStateIsNilForOtherMessages() {
        XCTAssertNil(ViewerControlState.parse(Data(#"{"t":"term-list","tabs":[]}"#.utf8)))
        XCTAssertNil(ViewerControlState.parse(Data(#"{"t":"view-set","subs":[]}"#.utf8)))
        XCTAssertNil(ViewerControlState.parse(Data("not json".utf8)))
    }

    /// `active` absent is not `active: false`. A message that failed to carry the field says
    /// nothing about who is driving, and turning that into "passive" would fail runs on a
    /// protocol addition.
    func testControlStateRequiresTheActiveField() {
        XCTAssertNil(ViewerControlState.parse(Data(#"{"t":"control-state","clients":1}"#.utf8)))
    }

    // MARK: - the host's echo of a source's prefs

    // THE FINDING these exist for: `set-source-prefs` is ACCEPTED and DROPPED on the headless
    // `RDEV_TEST_PATTERN=1` path — `ChannelHub` routes it to `simDelegate`, and there is no
    // `SimManager` there, so the message parses, passes the active-client gate, and reaches
    // nothing. A viewer that assumed its request applied would report a configuration nobody set.
    // `view-set` is the only thing the host ever says back about a source's prefs, so it is the
    // only thing that can confirm one.
    //
    // Built by the host's OWN `viewSetJSON`, not by a hand-written literal, for the same reason
    // the outbound messages round-trip through `parseInbound`: a literal agrees with itself while
    // the wire form drifts.

    func testReadsTheEffectivePrefsOutOfTheHostsViewSet() {
        let json = viewSetJSON(
            subs: [Subscription(source: "test",
                                prefs: VideoPrefs(fps: 30, scale: 1.0, bitrateBps: 2_000_000))],
            focused: "test")
        let echo = ViewerSourcePrefsEcho.parse(json, source: "test")
        XCTAssertEqual(echo?.fps, 30)
        XCTAssertEqual(echo?.bitrateBps, 2_000_000)
    }

    /// A `view-set` that does not mention OUR source confirms nothing about it. nil, never a
    /// zero-valued echo — "the host said nothing" and "the host said 0" are different claims, and
    /// only the first is what an unsubscribed or unacknowledged source produces.
    func testEchoIsNilWhenTheViewSetOmitsOurSource() {
        let json = viewSetJSON(
            subs: [Subscription(source: "win:42",
                                prefs: VideoPrefs(fps: 60, scale: 1.0, bitrateBps: 8_000_000))],
            focused: "win:42")
        XCTAssertNil(ViewerSourcePrefsEcho.parse(json, source: "test"))
        // An empty view set is the same reading, and is what a host that dropped the subscribe
        // would send.
        XCTAssertNil(ViewerSourcePrefsEcho.parse(
            viewSetJSON(subs: [], focused: nil), source: "test"))
    }

    /// Only `view-set`. The control channel carries `control-state`, `term-list`, `source-list`
    /// and `source-status` on the same stream, and a parser that keyed on a bare `fps` field
    /// would read one of those as a confirmation.
    ///
    /// THE THIRD CASE IS THE ONE THAT DEFENDS THE `t` GUARD, and it was added after a mutation
    /// run showed that deleting the guard broke nothing: today's other control messages have no
    /// `subs` array, so shape alone happens to be sufficient — which is a coincidence of the
    /// current protocol, not a property of it. A future message carrying `subs` would silently be
    /// read as a pref confirmation, which is the exact class of error this whole assertion exists
    /// to catch, arriving through its own reader.
    func testEchoIsNilForOtherControlMessages() {
        XCTAssertNil(ViewerSourcePrefsEcho.parse(
            Data(#"{"t":"control-state","active":true,"clients":1}"#.utf8), source: "test"))
        XCTAssertNil(ViewerSourcePrefsEcho.parse(Data("not json".utf8), source: "test"))
        XCTAssertNil(
            ViewerSourcePrefsEcho.parse(
                Data(#"{"t":"some-future-message","subs":[{"source":"test","fps":1}]}"#.utf8),
                source: "test"),
            "the message TYPE is what identifies a view-set, not the shape of its payload")
    }

    /// A field the host omits is UNCONFIRMED, not zero. The entry exists, so the source is in the
    /// view set; the value simply was not stated, and the assertion must be able to say that
    /// rather than compare a request against a fabricated 0.
    func testAnOmittedFieldIsNilRatherThanZero() {
        let echo = ViewerSourcePrefsEcho.parse(
            Data(#"{"t":"view-set","subs":[{"source":"test","fps":30}],"focused":"test"}"#.utf8),
            source: "test")
        XCTAssertEqual(echo?.fps, 30)
        XCTAssertNil(echo?.bitrateBps)
    }

    // MARK: - unhandled signaling types

    /// `web/src/lib/signaling.ts`'s `default: break` hid a permanently-unsatisfiable smoke step
    /// for months. The rule it learned — report an unhandled type, ONCE PER TYPE — is a decision
    /// about noise as much as about visibility: these arrive per peer-event, so a warning per
    /// MESSAGE would be the kind of output people filter out.
    func testUnhandledTypesWarnOncePerType() {
        var log = OnceLog()
        XCTAssertTrue(log.shouldReport("peer-resumed"))
        XCTAssertFalse(log.shouldReport("peer-resumed"))
        XCTAssertTrue(log.shouldReport("peer-suspended"))
        XCTAssertFalse(log.shouldReport("peer-suspended"))
        XCTAssertFalse(log.shouldReport("peer-resumed"))
    }

    // MARK: - the failure diagnostic

    /// Every reading a timed-out run has to carry, asserted INDIVIDUALLY. The whole point of the
    /// dump is that "no frames arrived" has half a dozen causes that are indistinguishable
    /// afterwards, so a field silently dropped from it costs a day nobody can reproduce.
    func testFailureDiagnosticCarriesEveryReading() {
        let text = ViewerWatchdog.failureDiagnostic(
            reason: "no frames for 10s", connectionState: 2,
            openChannels: ["control", "terminal"], negotiatedCodec: "AV1",
            controlState: ViewerControlState(active: false, clients: 2),
            statsJSON: #"{"state":"negotiated"}"#)
        XCTAssertTrue(text.contains("no frames for 10s"), text)
        XCTAssertTrue(text.contains("connectionState: 2"), text)
        XCTAssertTrue(text.contains("control,terminal"), text)
        XCTAssertTrue(text.contains("AV1"), text)
        XCTAssertTrue(text.contains("active=false"), text)
        XCTAssertTrue(text.contains("clients=2"), text)
        XCTAssertTrue(text.contains(#"{"state":"negotiated"}"#), text)
    }

    /// The absences must READ as absences. Empty strings and empty lists are the state the run
    /// is most likely to be in when the watchdog fires, and rendering them as blanks turns the
    /// most informative dump into the least.
    func testFailureDiagnosticNamesWhatIsMissing() {
        let text = ViewerWatchdog.failureDiagnostic(
            reason: "no frames", connectionState: -1, openChannels: [],
            negotiatedCodec: "", controlState: nil, statsJSON: "")
        XCTAssertTrue(text.contains("<none opened>"), text)
        XCTAssertTrue(text.contains("<none negotiated>"), text)
        XCTAssertTrue(text.contains("<no control-state received>"), text)
        XCTAssertTrue(text.contains("<unavailable>"), text)
    }

    /// The type name is recovered from the RAW text, because `RdevSignalIn.parse` returns nil for
    /// BOTH an unhandled type and malformed input — so the parse result alone cannot say which,
    /// and "unhandled `peer-resumed`" and "garbage on the socket" are very different reports.
    func testMessageTypeIsRecoverableFromRawText() {
        XCTAssertEqual(RdevSignalIn.messageType(#"{"t":"peer-resumed","peer":"x"}"#), "peer-resumed")
        XCTAssertNil(RdevSignalIn.messageType("{}"))
        XCTAssertNil(RdevSignalIn.messageType("not json"))
    }

    // MARK: - resolving --source-name against the host's own source-list

    private static func listPayload(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["t": "source-list", "sources": entries])
    }

    private static let motion: [String: Any] = [
        "id": "win:501", "kind": "window", "name": "llv \u{2014} Software Motion 1920x1080 @ 120 Hz",
        "inputCapable": true, "running": true, "w": 960, "h": 568,
    ]
    private static let finder: [String: Any] = [
        "id": "win:12", "kind": "window", "name": "Finder \u{2014} Downloads",
        "inputCapable": true, "running": true, "w": 800, "h": 600,
    ]

    func testSourceListParsesTheFieldsAnInstrumentNeeds() throws {
        let list = try XCTUnwrap(ViewerSourceList.parse(Self.listPayload([Self.motion, Self.finder])))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].id, "win:501")
        XCTAssertEqual(list[0].kind, "window")
        XCTAssertEqual(list[0].running, true)
        XCTAssertEqual(list[0].w, 960)
        XCTAssertEqual(list[0].h, 568)
    }

    /// Anything that is not a `source-list` returns nil, so the three control-channel parsers can
    /// each be offered every message without one claiming another's.
    func testSourceListIgnoresOtherMessages() {
        XCTAssertNil(ViewerSourceList.parse(Data(#"{"t":"view-set","subs":[]}"#.utf8)))
        XCTAssertNil(ViewerSourceList.parse(Data(#"{"t":"control-state","active":true}"#.utf8)))
        XCTAssertNil(ViewerSourceList.parse(Data("not json".utf8)))
    }

    /// A nameless entry is DROPPED, never defaulted to "": an empty name contains every
    /// substring, so defaulting would make it match whatever the operator typed.
    func testNamelessEntriesAreDroppedRatherThanMatchingEverything() throws {
        let list = try XCTUnwrap(ViewerSourceList.parse(Self.listPayload([
            ["id": "win:1", "kind": "window", "running": true],
            Self.motion,
        ])))
        XCTAssertEqual(list.map(\.id), ["win:501"])
    }

    func testResolveFindsTheOneMatch() {
        let list = ViewerSourceList.parse(Self.listPayload([Self.motion, Self.finder]))!
        guard case let .resolved(entry) = ViewerSourceList.resolve(name: "Software Motion", in: list)
        else { return XCTFail("expected a single match") }
        XCTAssertEqual(entry.id, "win:501")
    }

    func testResolveIsCaseInsensitive() {
        let list = ViewerSourceList.parse(Self.listPayload([Self.motion, Self.finder]))!
        guard case .resolved = ViewerSourceList.resolve(name: "software motion", in: list)
        else { return XCTFail("expected a match regardless of case") }
    }

    /// AMBIGUITY IS A FAILURE, not a first-wins. A silently-wrong window decodes perfectly, passes
    /// every assertion, and is invisible in every aggregate number the comparison produces.
    func testResolveRefusesToPickAmongSeveralMatches() {
        var second = Self.motion
        second["id"] = "win:502"
        let list = ViewerSourceList.parse(Self.listPayload([Self.motion, second, Self.finder]))!
        guard case let .failed(message) = ViewerSourceList.resolve(name: "Motion", in: list)
        else { return XCTFail("two matches must not resolve") }
        XCTAssertTrue(message.contains("win:501"), message)
        XCTAssertTrue(message.contains("win:502"), message)
        // The full listing too — a reader fixing this needs to see what else was on offer.
        XCTAssertTrue(message.contains("Finder"), message)
    }

    /// THE WHOLE LISTING IS THE DIAGNOSIS. "No match" is fixed by looking at the list the
    /// resolution used, and nothing else in the report contains it.
    func testResolveReportsEverySourceWhenNothingMatches() {
        let list = ViewerSourceList.parse(Self.listPayload([Self.motion, Self.finder]))!
        guard case let .failed(message) = ViewerSourceList.resolve(name: "Xcode", in: list)
        else { return XCTFail("no match must fail") }
        XCTAssertTrue(message.contains("matched NONE"), message)
        XCTAssertTrue(message.contains("win:501"), message)
        XCTAssertTrue(message.contains("win:12"), message)
        XCTAssertTrue(message.contains("960x568pt"), message)
    }

    /// An empty list is its own reading: the host answered and had nothing to offer, which points
    /// at Screen Recording or at a listing that hung, not at the substring.
    func testResolveSaysSoWhenTheHostListedNothing() {
        guard case let .failed(message) = ViewerSourceList.resolve(name: "Motion", in: [])
        else { return XCTFail("an empty list cannot resolve") }
        XCTAssertTrue(message.contains("NO sources at all"), message)
    }
}
