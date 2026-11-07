import XCTest
@testable import RdevCore

/// `view-set` is the windows-and-view half of the session state on the wire (the spec's §3). The client
/// renders from it, so its whole shape is pinned — including an EMPTY session, which must still say what
/// it is rather than omit the fields a client would then have to guess at.
final class ViewSetStateJSONTests: XCTestCase {

    private func parse(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    func testAnEmptySessionStillStatesItsWholeShape() {
        let obj = parse(viewSetJSON(subs: [], focused: nil))
        XCTAssertEqual((obj["windows"] as? [Any])?.count, 0)
        let view = obj["view"] as? [String: Any]
        XCTAssertEqual(view?["surface"] as? String, "terminal")
        XCTAssertTrue(view?["fullscreen"] is NSNull)
        XCTAssertEqual(obj["version"] as? Int, 0)
    }

    func testCarriesEveryWindowWithItsMinimizedFlagAndPosition() {
        var s = SessionState()
        s.open("win:1"); s.open("dsp:2"); s.open("win:3")
        s.minimize("dsp:2")
        s.setPosition("win:1", x: 120.5, y: -40)
        s.setView(surface: .windows, fullscreen: .some("win:3"))
        let obj = parse(viewSetJSON(subs: [], focused: s.focused, state: s))
        let windows = obj["windows"] as? [[String: Any]]
        XCTAssertEqual(windows?.map { $0["source"] as? String }, ["win:1", "dsp:2", "win:3"])
        XCTAssertEqual(windows?.map { $0["minimized"] as? Bool }, [false, true, false])
        XCTAssertEqual(windows?[0]["x"] as? Double, 120.5)
        XCTAssertEqual(windows?[0]["y"] as? Double, -40)
        // TOGETHER OR NEITHER: an unpositioned window carries no half of a place.
        XCTAssertNil(windows?[1]["x"])
        XCTAssertNil(windows?[1]["y"])
        let view = obj["view"] as? [String: Any]
        XCTAssertEqual(view?["surface"] as? String, "windows")
        XCTAssertEqual(view?["fullscreen"] as? String, "win:3")
        XCTAssertEqual(obj["version"] as? Int, Int(s.version))
        XCTAssertEqual(obj["focused"] as? String, "win:3")
    }

    /// `subs` stays the LIVE per-window echo beside the state: they answer different questions — what the
    /// session holds, and what is being streamed and how.
    func testSubsStayTheLiveEchoBesideTheState() {
        var s = SessionState()
        s.open("win:1"); s.open("win:2"); s.minimize("win:2")
        let subs = [Subscription(source: "win:1",
                                 prefs: VideoPrefs(fps: 30, scale: 0.5, bitrateBps: 3_000_000))]
        let obj = parse(viewSetJSON(subs: subs, focused: s.focused, state: s))
        let echo = obj["subs"] as? [[String: Any]]
        XCTAssertEqual(echo?.map { $0["source"] as? String }, ["win:1"])
        XCTAssertEqual(echo?[0]["fps"] as? Int, 30)
        XCTAssertEqual((obj["windows"] as? [[String: Any]])?.count, 2)
    }

    // MARK: - the bar (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §2.2)

    /// The WHOLE order, top-level, every time — terminal keys and window keys interleaved as the bar
    /// shows them — and an empty session states an empty one rather than omitting it.
    func testCarriesTheWholeTabOrder() {
        XCTAssertEqual(parse(viewSetJSON(subs: [], focused: nil))["tabOrder"] as? [String], [],
                       "present and empty, never absent")
        var s = SessionState()
        s.syncTerminals(["pty:1", "tmux:$3"])
        s.open("win:7")
        s.moveTab("win:7", before: "tmux:$3")
        XCTAssertEqual(parse(viewSetJSON(subs: [], focused: s.focused, state: s))["tabOrder"] as? [String],
                       ["pty:1", "win:7", "tmux:$3"])
    }

    /// A window's `name` is PRESENT ONLY WHEN SET — absent, never `null` or `""`, so the client's label is
    /// the source's own name.
    func testAWindowCarriesItsNameOnlyWhenSet() {
        var s = SessionState()
        s.open("win:1"); s.open("win:2")
        s.setName("win:1", "mail")
        let windows = parse(viewSetJSON(subs: [], focused: s.focused, state: s))["windows"] as? [[String: Any]]
        XCTAssertEqual(windows?[0]["name"] as? String, "mail")
        XCTAssertFalse(windows?[1].keys.contains("name") ?? true)
    }
}
