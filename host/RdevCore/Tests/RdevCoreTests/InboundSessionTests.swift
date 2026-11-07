import XCTest
@testable import RdevCore

/// The session-state wire (docs/superpowers/specs/2026-09-29-host-session-state-design.md, §3): the
/// connection's hello and preference changes, the new window intents, and what is refused. Each
/// refusal is a message the host must DROP rather than half-apply.
final class InboundSessionTests: XCTestCase {
    private func parse(_ s: String) -> InboundMessage? { parseInbound(Data(s.utf8)) }

    func testClientHelloAndSetPrefsCarryTheWholePreferenceSet() {
        let full = ClientPrefs(fps: 30, scale: .fixed(0.5), bitrateBps: 4_000_000, codec: .av1,
                               pointerMode: .direct)
        let body = #""prefs":{"fps":30,"scale":0.5,"bitrateBps":4000000,"codec":"av1","pointerMode":"direct"}"#
        XCTAssertEqual(parse(#"{"t":"client-hello",\#(body)}"#), .clientHello(prefs: full, delivery: .rtp))
        XCTAssertEqual(parse(#"{"t":"set-prefs",\#(body)}"#), .setPrefs(full))
        XCTAssertEqual(parse(#"{"t":"client-hello","prefs":{}}"#), .clientHello(prefs: .default, delivery: .rtp),
                       "an empty set is every default")
    }

    /// The hello also states the CONNECTION's transport, so a window restored for a `?dc=1` connection
    /// comes back on the channel it asked for. ABSENT MEANS RTP AND AN UNKNOWN VALUE DEGRADES TO RTP —
    /// the `VideoDelivery` rule `subscribe` follows: a version skew costs the optimisation, never the hello.
    func testClientHelloCarriesTheConnectionsTransport() {
        XCTAssertEqual(parse(#"{"t":"client-hello","prefs":{}}"#), .clientHello(prefs: .default, delivery: .rtp))
        XCTAssertEqual(parse(#"{"t":"client-hello","prefs":{},"delivery":"dc"}"#),
                       .clientHello(prefs: .default, delivery: .dc))
        XCTAssertEqual(parse(#"{"t":"client-hello","prefs":{},"delivery":"quic"}"#),
                       .clientHello(prefs: .default, delivery: .rtp), "unknown degrades, never refuses")
        XCTAssertEqual(parse(#"{"t":"client-hello","prefs":{},"delivery":7}"#),
                       .clientHello(prefs: .default, delivery: .rtp))
    }

    /// Re-adds the driver's track for a window WITHOUT touching the session — the WebCodecs stall
    /// recovery, which under the state model must not close and reopen the window to get a fresh track.
    func testReattachSource() {
        XCTAssertEqual(parse(#"{"t":"reattach-source","source":"win:7"}"#), .reattachSource(source: "win:7"))
        XCTAssertNil(parse(#"{"t":"reattach-source"}"#))
        XCTAssertNil(parse(#"{"t":"reattach-source","source":""}"#))
        XCTAssertNil(parse(#"{"t":"reattach-source","source":7}"#), "a non-string source is malformed")
    }

    /// The OBJECT must be there — a hello without a preference set cannot say what the device wants —
    /// while each FIELD inside it is lenient (`ClientPrefsTests`).
    func testAMissingOrNonObjectPrefsIsMalformed() {
        XCTAssertNil(parse(#"{"t":"client-hello"}"#))
        XCTAssertNil(parse(#"{"t":"client-hello","prefs":"auto"}"#))
        XCTAssertNil(parse(#"{"t":"set-prefs","prefs":[]}"#))
        XCTAssertNil(parse(#"{"t":"set-prefs","prefs":null}"#))
        XCTAssertEqual(parse(#"{"t":"client-hello","prefs":{"fps":"x"}}"#),
                       .clientHello(prefs: .default, delivery: .rtp), "a bad field is absent, not a bad message")
    }

    func testMinimizeAndRestoreWindow() {
        XCTAssertEqual(parse(#"{"t":"minimize-window","source":"win:7"}"#), .minimizeWindow(source: "win:7"))
        XCTAssertEqual(parse(#"{"t":"restore-window","source":"dsp:1"}"#), .restoreWindow(source: "dsp:1"))
        XCTAssertNil(parse(#"{"t":"minimize-window"}"#))
        XCTAssertNil(parse(#"{"t":"restore-window","source":""}"#))
    }

    /// `land` (2026-10-02): the client says the person was AT the window it closes or parks — the only side
    /// that can tell (`SessionState.landing`). Absent is false; present, a boolean or the message is malformed.
    func testCloseAndMinimizeCarryLand() {
        XCTAssertEqual(parse(#"{"t":"unsubscribe","source":"win:7","land":true}"#), .unsubscribe(source: "win:7", land: true))
        XCTAssertEqual(parse(#"{"t":"unsubscribe","source":"win:7","land":false}"#), .unsubscribe(source: "win:7", land: false))
        XCTAssertEqual(parse(#"{"t":"unsubscribe","source":"win:7"}"#), .unsubscribe(source: "win:7", land: false))
        XCTAssertEqual(parse(#"{"t":"minimize-window","source":"win:7","land":true}"#), .minimizeWindow(source: "win:7", land: true))
        XCTAssertEqual(parse(#"{"t":"minimize-window","source":"win:7"}"#), .minimizeWindow(source: "win:7", land: false))
        XCTAssertNil(parse(#"{"t":"unsubscribe","source":"win:7","land":"yes"}"#))
        XCTAssertNil(parse(#"{"t":"minimize-window","source":"win:7","land":null}"#))
        XCTAssertEqual(parse(#"{"t":"restore-window","source":"win:7","land":"ignored"}"#), .restoreWindow(source: "win:7"),
                       "a restore lands nowhere: the field is not its")
    }

    func testSetWindowPosition() {
        XCTAssertEqual(parse(#"{"t":"set-window-position","source":"win:7","x":120.5,"y":-40}"#),
                       .setWindowPosition(source: "win:7", x: 120.5, y: -40))
        XCTAssertEqual(parse(#"{"t":"set-window-position","source":"win:7","x":100000,"y":-100000}"#),
                       .setWindowPosition(source: "win:7", x: 100_000, y: -100_000), "the bound itself")
    }

    /// A position the host cannot use is refused WHOLE — never clamped into a place nobody dragged to.
    func testAnUnusablePositionIsMalformed() {
        for body in [#""x":"1","y":2"#, #""x":1"#, #""x":100000.5,"y":0"#, #""x":0,"y":-1e300"#,
                     #""x":true,"y":0"#] {
            XCTAssertNil(parse(#"{"t":"set-window-position","source":"win:7",\#(body)}"#), body)
        }
        XCTAssertNil(parse(#"{"t":"set-window-position","x":1,"y":2}"#), "no source")
    }

    func testSetView() {
        XCTAssertEqual(parse(#"{"t":"set-view","surface":"windows"}"#),
                       .setView(surface: .windows, fullscreen: nil))
        XCTAssertEqual(parse(#"{"t":"set-view","fullscreen":"win:7"}"#),
                       .setView(surface: nil, fullscreen: .some("win:7")))
        XCTAssertEqual(parse(#"{"t":"set-view","fullscreen":null}"#),
                       .setView(surface: nil, fullscreen: .some(nil)), "null ENDS the mode; absent leaves it")
        XCTAssertEqual(parse(#"{"t":"set-view","surface":"terminal","fullscreen":null}"#),
                       .setView(surface: .terminal, fullscreen: .some(nil)))
    }

    func testAMalformedSetViewIsDropped() {
        XCTAssertNil(parse(#"{"t":"set-view"}"#), "asks for nothing")
        XCTAssertNil(parse(#"{"t":"set-view","surface":"both"}"#))
        XCTAssertNil(parse(#"{"t":"set-view","surface":null}"#))
        XCTAssertNil(parse(#"{"t":"set-view","fullscreen":""}"#))
        XCTAssertNil(parse(#"{"t":"set-view","fullscreen":3}"#))
    }

    /// GONE, not merely unused: tmux tabs are session state now, so a client has nothing to restore —
    /// and an unknown message is what a stale sender must get.
    func testRestoreTmuxIsNoLongerAMessage() {
        XCTAssertNil(parse(#"{"t":"restore-tmux","sessions":["$1"],"active":"$1"}"#))
    }

    // MARK: - the bar (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §2.1)

    func testMoveTab() {
        XCTAssertEqual(parse(#"{"t":"move-tab","tab":"pty:2","before":"win:4711"}"#),
                       .moveTab(tab: "pty:2", before: "win:4711"))
        XCTAssertEqual(parse(#"{"t":"move-tab","tab":"win:4711","before":null}"#),
                       .moveTab(tab: "win:4711", before: nil), "null is the END")
        XCTAssertEqual(parse(#"{"t":"move-tab","tab":"tmux:$3","before":"dsp:1"}"#),
                       .moveTab(tab: "tmux:$3", before: "dsp:1"))
    }

    /// `before` is REQUIRED — a key or null — and never the tab itself; `tab` must be a key. Anything else
    /// is malformed, not a move to somewhere guessed.
    func testAMalformedMoveTabIsDropped() {
        for body in [#""tab":"pty:2""#,                         // before absent
                     #""tab":"pty:2","before":"""#,             // empty
                     #""tab":"pty:2","before":3"#,              // not a string
                     #""tab":"pty:2","before":"pty:2""#,        // the tab itself
                     #""tab":"pty:2","before":"sim:ABC""#,      // not a key
                     #""tab":"pty:2","before":"pty:02""#,       // not canonical
                     #""before":null"#,                         // tab absent
                     #""tab":"","before":null"#,
                     #""tab":7,"before":null"#,
                     #""tab":"2","before":null"#,
                     #""tab":"terminal","before":null"#,
                     #""tab":"win:x","before":null"#,
                     #""tab":"sim:ABC","before":null"#] {
            XCTAssertNil(parse(#"{"t":"move-tab",\#(body)}"#), body)
        }
    }

    func testRenameTab() {
        XCTAssertEqual(parse(#"{"t":"rename-tab","tab":"tmux:$3","name":"build"}"#),
                       .renameTab(tab: "tmux:$3", name: "build"))
        XCTAssertEqual(parse(#"{"t":"rename-tab","tab":"pty:2","name":""}"#),
                       .renameTab(tab: "pty:2", name: ""), "empty CLEARS a pty: name")
        XCTAssertEqual(parse(#"{"t":"rename-tab","tab":"win:4711","name":""}"#),
                       .renameTab(tab: "win:4711", name: ""), "and a window's")
        XCTAssertEqual(parse(#"{"t":"rename-tab","tab":"dsp:1","name":"🎉 big screen"}"#),
                       .renameTab(tab: "dsp:1", name: "🎉 big screen"))
        let longest = String(repeating: "é", count: 128)
        XCTAssertEqual(parse(#"{"t":"rename-tab","tab":"pty:2","name":"\#(longest)"}"#),
                       .renameTab(tab: "pty:2", name: longest), "256 bytes: the bound itself")
    }

    /// `name` is REQUIRED and must be a valid name (`TabName`); a tmux session has no "no name", so an
    /// empty one for a tmux tab is malformed rather than a clear.
    func testAMalformedRenameTabIsDropped() {
        let tooLong = String(repeating: "é", count: 128) + "a"
        for body in [#""tab":"pty:2""#,                         // name absent
                     #""tab":"pty:2","name":null"#,
                     #""tab":"pty:2","name":3"#,
                     #""tab":"pty:2","name":"a\tb""#,           // a control character
                     #""tab":"pty:2","name":"a\u0085b""#,       // a C1 one
                     #""tab":"pty:2","name":"\#(tooLong)""#,    // 257 bytes
                     #""tab":"tmux:$3","name":"""#,             // tmux has no "no name"
                     #""name":"x""#,                            // tab absent
                     #""tab":"","name":"x""#,
                     #""tab":"pty:0","name":"x""#,
                     #""tab":"sim:ABC","name":"x""#] {
            XCTAssertNil(parse(#"{"t":"rename-tab",\#(body)}"#), body)
        }
    }
}
