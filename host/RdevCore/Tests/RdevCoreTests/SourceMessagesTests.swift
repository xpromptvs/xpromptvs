import XCTest
@testable import RdevCore

final class SourceMessagesTests: XCTestCase {

    private func parse(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    func testSourceListShape() {
        let sources = [
            Source(id: "sim:ABC", kind: "sim", name: "iPhone 17e", inputCapable: true, running: true),
            Source(id: "win:42", kind: "window", name: "Safari", inputCapable: false, running: true),
        ]
        let obj = parse(sourceListJSON(sources: sources))
        XCTAssertEqual(obj["t"] as? String, "source-list")
        let arr = obj["sources"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 2)
        XCTAssertEqual(arr?[0]["id"] as? String, "sim:ABC")
        XCTAssertEqual(arr?[0]["kind"] as? String, "sim")
        XCTAssertEqual(arr?[0]["name"] as? String, "iPhone 17e")
        XCTAssertEqual(arr?[0]["inputCapable"] as? Bool, true)
        XCTAssertEqual(arr?[0]["running"] as? Bool, true)
        XCTAssertEqual(arr?[1]["id"] as? String, "win:42")
        XCTAssertEqual(arr?[1]["kind"] as? String, "window")
        XCTAssertEqual(arr?[1]["inputCapable"] as? Bool, false)
    }

    // MARK: - activeDelivery / dcIndex

    private var oneSub: [Subscription] {
        [Subscription(source: "win:1", prefs: VideoPrefs(fps: 60, scale: 1.0, bitrateBps: 2_000_000))]
    }

    // ABSENT MEANS UNKNOWN, never "rtp" — the same rule as activeCodec. A client must be able to tell
    // "not resolved yet" from "resolved, and it is rtp", or a session still negotiating looks like
    // one that refused.
    func testViewSetOmitsActiveDeliveryUntilItIsKnown() {
        let subs = parse(viewSetJSON(subs: oneSub, focused: nil))["subs"] as? [[String: Any]]
        XCTAssertNil(subs?[0]["activeDelivery"])
        XCTAssertNil(subs?[0]["dcIndex"])
    }

    func testViewSetReportsTheDeliveryTheHostApplied() {
        let obj = parse(viewSetJSON(subs: oneSub, focused: nil,
                                    activeDelivery: ["win:1": .dc], dcIndices: ["win:1": 3]))
        let subs = obj["subs"] as? [[String: Any]]
        XCTAssertEqual(subs?[0]["activeDelivery"] as? String, "dc")
        XCTAssertEqual(subs?[0]["dcIndex"] as? Int, 3)
    }

    // An index is meaningless without the channel, and emitting a stale one would let a client bind
    // symbols to a source that is not being delivered over it.
    func testViewSetOmitsDcIndexWhenDeliveryIsRTP() {
        let obj = parse(viewSetJSON(subs: oneSub, focused: nil,
                                    activeDelivery: ["win:1": .rtp], dcIndices: ["win:1": 3]))
        let subs = obj["subs"] as? [[String: Any]]
        XCTAssertEqual(subs?[0]["activeDelivery"] as? String, "rtp")
        XCTAssertNil(subs?[0]["dcIndex"])
    }

    // Index 0 is a VALID index. Emitting it only when non-zero would strand the first routed source,
    // whose symbols the client would then never bind — the same off-by-one the ABI's packed return
    // guards against on the other side of the boundary.
    func testViewSetEmitsIndexZero() {
        let obj = parse(viewSetJSON(subs: oneSub, focused: nil,
                                    activeDelivery: ["win:1": .dc], dcIndices: ["win:1": 0]))
        let subs = obj["subs"] as? [[String: Any]]
        XCTAssertEqual(subs?[0]["dcIndex"] as? Int, 0)
    }

    func testViewSetShape() {
        let subs = [Subscription(source: "sim:ABC", prefs: VideoPrefs(fps: 60, scale: 0.5, bitrateBps: 2_000_000))]
        let obj = parse(viewSetJSON(subs: subs, focused: "sim:ABC"))
        XCTAssertEqual(obj["t"] as? String, "view-set")
        XCTAssertEqual(obj["focused"] as? String, "sim:ABC")
        let arr = obj["subs"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 1)
        XCTAssertEqual(arr?[0]["source"] as? String, "sim:ABC")
        XCTAssertEqual(arr?[0]["fps"] as? Int, 60)
        XCTAssertEqual(arr?[0]["scale"] as? Double, 0.5)
        XCTAssertEqual(arr?[0]["bitrateBps"] as? Int, 2_000_000)
    }

    /// ABSENT MEANS UNKNOWN, NOT DEGRADED. The client must be able to tell "the answer has not
    /// settled the recovery stack yet" from "the receiver declined FlexFEC" — the same rule
    /// `activeCodec` follows, and the reason both are omitted rather than defaulted.
    func testViewSetOmitsActiveRecoveryUntilItResolves() {
        let subs = [Subscription(source: "win:1",
                                 prefs: VideoPrefs(fps: 60, scale: 1.0, bitrateBps: 2_000_000))]
        let unresolved = parse(viewSetJSON(subs: subs, focused: "win:1"))
        XCTAssertNil(unresolved["activeRecovery"])

        let empty = parse(viewSetJSON(subs: subs, focused: "win:1", activeRecovery: ""))
        XCTAssertNil(empty["activeRecovery"], "an empty stack is unresolved, not a value")

        for stack in ["nack-rtx-flexfec", "nack-rtx"] {
            let resolved = parse(viewSetJSON(subs: subs, focused: "win:1", activeRecovery: stack))
            XCTAssertEqual(resolved["activeRecovery"] as? String, stack)
        }
    }

    func testViewSetNullFocused() {
        let obj = parse(viewSetJSON(subs: [], focused: nil))
        XCTAssertEqual(obj["t"] as? String, "view-set")
        XCTAssertTrue(obj["focused"] is NSNull)
        XCTAssertEqual((obj["subs"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - makeSources

    func testMakeSourcesMapsSimsThenWindows() {
        let sims = [
            SimInfo(udid: "U1", name: "iPhone 17e", os: "iOS 26.0", state: .booted, w: 375, h: 812, pxW: 1125, pxH: 2436),
            SimInfo(udid: "U2", name: "iPad", os: "iOS 26.0", state: .shutdown, w: 820, h: 1180, pxW: 1640, pxH: 2360),
        ]
        let windows = [WindowInfo(id: 7, app: "Safari", title: "GitHub")]
        let sources = makeSources(sims: sims, windows: windows)

        XCTAssertEqual(sources.count, 3)
        // sims first, in order
        XCTAssertEqual(sources[0], Source(id: "sim:U1", kind: "sim", name: "iPhone 17e (iOS 26.0)", inputCapable: true,
                                          running: true, w: 375, h: 812, simState: .booted))
        XCTAssertEqual(sources[1].id, "sim:U2")
        XCTAssertEqual(sources[1].running, false)   // shutdown → not running
        XCTAssertEqual(sources[1].inputCapable, true)
        // window last, now input-capable (click/drag/scroll injection via CGEvent)
        XCTAssertEqual(sources[2], Source(id: "win:7", kind: "window",
                                          name: "Safari - GitHub", inputCapable: true, running: true))
    }

    func testMakeSourcesEmpty() {
        XCTAssertEqual(makeSources(sims: [], windows: []).count, 0)
    }

    func testMakeSourcesMarksMinimizedWindowNotRunning() {
        let sources = makeSources(sims: [], windows: [
            WindowInfo(id: 7, app: "Safari", title: "GitHub"),                 // on-screen (default)
            WindowInfo(id: 9, app: "Notes", title: "Ideas", minimized: true),  // minimized
        ])
        XCTAssertEqual(sources[0].running, true)   // on-screen window → running
        XCTAssertEqual(sources[1].running, false)  // minimized window → not running
        XCTAssertEqual(sources[1].id, "win:9")
    }

    // MARK: - size metadata

    func testSourceListIncludesSizeWhenKnownAndOmitsItOtherwise() {
        let obj = parse(sourceListJSON(sources: [
            Source(id: "win:7", kind: "window", name: "Safari - GitHub", inputCapable: true, running: true, w: 892, h: 655),
            Source(id: "sim:U1", kind: "sim", name: "iPhone", inputCapable: true, running: true),
        ]))
        let arr = obj["sources"] as! [[String: Any]]
        XCTAssertEqual(arr[0]["w"] as? Int, 892)
        XCTAssertEqual(arr[0]["h"] as? Int, 655)
        XCTAssertNil(arr[1]["w"])       // unknown size → field absent, never 0
        XCTAssertNil(arr[1]["h"])
    }

    func testSourceStatusCarriesOptionalSize() {
        let obj = parse(sourceStatusJSON(statuses: [
            SourceStatus(id: "win:7", live: true, w: 900, h: 600),
            SourceStatus(id: "win:9", live: false),
        ]))
        let arr = obj["statuses"] as! [[String: Any]]
        XCTAssertEqual(arr[0]["w"] as? Int, 900)
        XCTAssertEqual(arr[0]["h"] as? Int, 600)
        XCTAssertEqual(arr[1]["live"] as? Bool, false)
        XCTAssertNil(arr[1]["w"])       // liveness-only push carries no size
    }

    func testSourceStatusCarriesOptionalNativePixelSize() {
        let obj = parse(sourceStatusJSON(statuses: [
            SourceStatus(id: "win:7", live: true, w: 900, h: 600, pxW: 1800, pxH: 1200),
            SourceStatus(id: "win:9", live: true, w: 900, h: 600),
            SourceStatus(id: "win:11", live: false),
        ]))
        let arr = obj["statuses"] as! [[String: Any]]
        XCTAssertEqual(arr[0]["pxW"] as? Int, 1800)
        XCTAssertEqual(arr[0]["pxH"] as? Int, 1200)
        // The liveness monitor reads CGWindowList and has NO backing scale, so its pushes carry points
        // only. Absent must mean "unknown" — a client that cleared on absence would lose the native size
        // on every minimize/restore.
        XCTAssertNil(arr[1]["pxW"])
        XCTAssertNil(arr[1]["pxH"])
        XCTAssertNil(arr[2]["pxW"])
    }

    func testMakeSourcesCarriesEverySourcesSize() {
        let sources = makeSources(
            sims: [SimInfo(udid: "U1", name: "iPhone", os: "iOS 26.0", state: .booted, w: 402, h: 874, pxW: 1206, pxH: 2622)],
            windows: [WindowInfo(id: 7, app: "Safari", title: "GitHub", w: 892, h: 655)])
        XCTAssertEqual(sources[0].w, 402)           // a simulator's portrait points
        XCTAssertEqual(sources[1].w, 892)           // window
        XCTAssertEqual(sources[1].h, 655)
    }

    // MARK: - source-status

    func testSourceStatusShape() {
        let obj = parse(sourceStatusJSON(statuses: [
            SourceStatus(id: "win:12345", live: false),
            SourceStatus(id: "win:7", live: true),
        ]))
        XCTAssertEqual(obj["t"] as? String, "source-status")
        let arr = obj["statuses"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 2)
        XCTAssertEqual(arr?[0]["id"] as? String, "win:12345")
        XCTAssertEqual(arr?[0]["live"] as? Bool, false)
        XCTAssertEqual(arr?[1]["id"] as? String, "win:7")
        XCTAssertEqual(arr?[1]["live"] as? Bool, true)
    }

    func testSourceStatusEmpty() {
        let obj = parse(sourceStatusJSON(statuses: []))
        XCTAssertEqual(obj["t"] as? String, "source-status")
        XCTAssertEqual((obj["statuses"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - source-thumb

    func testSourceThumbShape() {
        let obj = parse(sourceThumbJSON(id: "win:7", w: 320, h: 200, jpegBase64: "QUJD"))
        XCTAssertEqual(obj["t"] as? String, "source-thumb")
        XCTAssertEqual(obj["id"] as? String, "win:7")
        XCTAssertEqual(obj["w"] as? Int, 320)
        XCTAssertEqual(obj["h"] as? Int, 200)
        XCTAssertEqual(obj["fmt"] as? String, "jpeg")
        XCTAssertEqual(obj["data"] as? String, "QUJD")
        XCTAssertNil(obj["unavailable"])
    }

    func testSourceThumbUnavailableShape() {
        let obj = parse(sourceThumbUnavailableJSON(id: "sim:U2"))
        XCTAssertEqual(obj["t"] as? String, "source-thumb")
        XCTAssertEqual(obj["id"] as? String, "sim:U2")
        XCTAssertEqual(obj["unavailable"] as? Bool, true)
        XCTAssertNil(obj["data"])
    }

    // MARK: - cursor

    func testHighResolutionCursorKeepsPointDimensionsAndHotspot() {
        let obj = parse(cursorJSON(pngBase64: "one", w: 16, h: 24, hotspotX: 2, hotspotY: 3, png3xBase64: "three"))
        XCTAssertEqual(obj["data"] as? String, "one")
        XCTAssertEqual(obj["data3x"] as? String, "three")
        XCTAssertEqual(obj["w"] as? Int, 16)
        XCTAssertEqual(obj["h"] as? Int, 24)
        XCTAssertEqual(obj["hotspotX"] as? Int, 2)
        XCTAssertEqual(obj["hotspotY"] as? Int, 3)
    }

    func testCursorShape() {
        let obj = parse(cursorJSON(pngBase64: "QUJD", w: 9, h: 18, hotspotX: 4, hotspotY: 9))
        XCTAssertEqual(obj["t"] as? String, "cursor")
        XCTAssertEqual(obj["fmt"] as? String, "png")
        XCTAssertEqual(obj["data"] as? String, "QUJD")
        XCTAssertEqual(obj["w"] as? Int, 9)
        XCTAssertEqual(obj["h"] as? Int, 18)
        XCTAssertEqual(obj["hotspotX"] as? Int, 4)
        XCTAssertEqual(obj["hotspotY"] as? Int, 9)
    }
}

extension SourceMessagesTests {
    func testViewSetCarriesRequestedAndActiveCodec() throws {
        let subs = [Subscription(source: "win:1",
                                 prefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000, codec: .av1))]
        let data = viewSetJSON(subs: subs, focused: "win:1", activeCodecs: ["win:1": .h265])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try XCTUnwrap((obj["subs"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["codec"] as? String, "av1", "the REQUEST")
        XCTAssertEqual(entry["activeCodec"] as? String, "h265", "what the answer settled on")
    }

    // Absent until the answer resolves — the client must tell "not yet known" from "known and equal".
    func testViewSetOmitsActiveCodecWhenUnresolved() throws {
        let subs = [Subscription(source: "win:1",
                                 prefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000))]
        let data = viewSetJSON(subs: subs, focused: nil, activeCodecs: [:])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try XCTUnwrap((obj["subs"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["codec"] as? String, "auto")
        XCTAssertNil(entry["activeCodec"])
    }

    // The field is TOP-LEVEL, beside `focused`, never per-subscription: a session-wide value
    // duplicated per source is a value that can disagree with itself.
    func testViewSetCarriesTheRecoveryOverrideAtTopLevel() throws {
        let data = viewSetJSON(subs: [], focused: nil, recoveryOverrideBp: 3000)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["recoveryOverrideBp"] as? Int, 3000)
        XCTAssertTrue(try XCTUnwrap(obj["subs"] as? [[String: Any]]).isEmpty)
    }

    func testViewSetOmitsTheRecoveryOverrideWhenAuto() throws {
        let data = viewSetJSON(subs: [], focused: nil, recoveryOverrideBp: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["recoveryOverrideBp"],
                     "Auto is the ABSENCE of the field, so an old client reads it as Auto")
    }

    // MARK: - displays

    func testSingleDisplayIsNamedExactlyDesktop() {
        let sources = makeSources(displays: [DisplayInfo(id: 1, name: "Built-in Retina Display", w: 1728, h: 1117)],
                                  windows: [])
        XCTAssertEqual(sources.count, 1)
        // EXACTLY "Desktop" — qualifying a sole display with its model name is noise that says nothing.
        XCTAssertEqual(sources[0], Source(id: "dsp:1", kind: "display", name: "Desktop",
                                          inputCapable: true, running: true, w: 1728, h: 1117))
    }

    func testMultipleDisplaysAreQualifiedByName() {
        let sources = makeSources(displays: [
            DisplayInfo(id: 1, name: "Built-in Retina Display", w: 1728, h: 1117),
            DisplayInfo(id: 2, name: "LG UltraFine", w: 2560, h: 1440),
        ], windows: [])
        XCTAssertEqual(sources[0].name, "Desktop \u{2014} Built-in Retina Display")
        XCTAssertEqual(sources[1].name, "Desktop \u{2014} LG UltraFine")
        XCTAssertEqual(sources[1].id, "dsp:2")
    }

    func testDisplaysSortBeforeWindows() {
        let sources = makeSources(displays: [DisplayInfo(id: 1, name: "Built-in", w: 1728, h: 1117)],
                                  windows: [WindowInfo(id: 7, app: "Safari", title: "GitHub")])
        // The Desktop is the marquee entry in the palette, not something you scroll past 26 windows for.
        XCTAssertEqual(sources[0].kind, "display")
        XCTAssertEqual(sources[1].kind, "window")
    }

    func testDisplaysAreAlwaysRunningAndInputCapable() {
        let sources = makeSources(displays: [DisplayInfo(id: 1, name: "Built-in", w: nil, h: nil)], windows: [])
        // A listed display is attached; disappearance is expressed by absence + a source-status
        // live:false, so `running` has no second state to carry.
        XCTAssertTrue(sources[0].running)
        XCTAssertTrue(sources[0].inputCapable)
        XCTAssertNil(sources[0].w)
    }

    // MARK: - curtain

    func testViewSetCarriesCurtainStateTopLevel() {
        let up = parse(viewSetJSON(subs: [], focused: nil, curtainUp: true))
        XCTAssertEqual(up["curtainUp"] as? Bool, true)
        let down = parse(viewSetJSON(subs: [], focused: nil, curtainUp: false))
        XCTAssertEqual(down["curtainUp"] as? Bool, false)
    }

    func testViewSetOmitsCurtainWhenUnknown() {
        // ABSENT MEANS UNKNOWN, never "down" — the same rule activeRecovery and activeCodec follow.
        // A host that predates this field must read as "no opinion", not as an assertion.
        XCTAssertNil(parse(viewSetJSON(subs: [], focused: nil))["curtainUp"])
    }

    // MARK: - host display availability

    func testDisplayAvailabilityDerivation() {
        // An ACTIVE display is the only thing that makes capture possible.
        XCTAssertEqual(DisplayAvailability.from(activeCount: 1, onlineCount: 1), .ok)
        XCTAssertEqual(DisplayAvailability.from(activeCount: 2, onlineCount: 2), .ok)

        // Asleep: macOS keeps it ONLINE but drops it from the ACTIVE list. This is the incident.
        XCTAssertEqual(DisplayAvailability.from(activeCount: 0, onlineCount: 1), .asleep)

        // Nothing attached at all — a different condition with a different remedy (a dummy HDMI plug).
        XCTAssertEqual(DisplayAvailability.from(activeCount: 0, onlineCount: 0), .noDisplay)
    }

    func testDisplayAvailabilityWireValues() {
        // "none" on the wire, `noDisplay` in Swift: a case named `none` collides with Optional.none.
        XCTAssertEqual(DisplayAvailability.ok.rawValue, "ok")
        XCTAssertEqual(DisplayAvailability.asleep.rawValue, "asleep")
        XCTAssertEqual(DisplayAvailability.noDisplay.rawValue, "none")
    }

    func testHostDisplayStatusKeepsLockedUnknown() {
        // nil is NOT false: "we could not read the session dictionary" must stay tellable from "unlocked".
        XCTAssertNil(HostDisplayStatus(availability: .ok, locked: nil).locked)
        XCTAssertEqual(HostDisplayStatus(availability: .ok, locked: false).locked, false)
        XCTAssertEqual(HostDisplayStatus(availability: .ok, locked: true).locked, true)
    }

    func testSourceListCarriesDisplayStatus() {
        let obj = parse(sourceListJSON(
            sources: [Source(id: "win:7", kind: "window", name: "Safari", inputCapable: true, running: true)],
            display: HostDisplayStatus(availability: .asleep, locked: true)))
        let d = obj["display"] as? [String: Any]
        XCTAssertEqual(d?["availability"] as? String, "asleep")
        XCTAssertEqual(d?["locked"] as? Bool, true)
    }

    func testSourceListOmitsDisplayWhenUnknown() {
        // Absent means UNKNOWN. An older host that never sets it must not be read as "ok".
        let obj = parse(sourceListJSON(sources: []))
        XCTAssertNil(obj["display"])
    }

    func testSourceListOmitsLockedWhenUnknown() {
        let obj = parse(sourceListJSON(sources: [], display: HostDisplayStatus(availability: .ok, locked: nil)))
        let d = obj["display"] as? [String: Any]
        XCTAssertEqual(d?["availability"] as? String, "ok")
        XCTAssertNil(d?["locked"])
    }

    // MARK: - display-awake reasons

    func testDisplayAwakeReasonsHoldWhileAnyReasonLives() {
        var r = DisplayAwakeReasons()
        XCTAssertFalse(r.isHeld)
        r.add(.sharing)
        XCTAssertTrue(r.isHeld)
        r.add(.curtain)
        r.remove(.sharing)
        // The CURTAIN still needs the display awake once sharing's reason is gone.
        XCTAssertTrue(r.isHeld)
        r.remove(.curtain)
        XCTAssertFalse(r.isHeld)
    }

    func testDisplayAwakeReasonsAreIdempotent() {
        var r = DisplayAwakeReasons()
        r.add(.curtain); r.add(.curtain)
        r.remove(.curtain)
        // A SET, not a refcount: one remove must clear one reason completely, or a double-raise
        // would leave the display pinned awake forever.
        XCTAssertFalse(r.isHeld)
        XCTAssertEqual(r.reasons, [])
    }
}
