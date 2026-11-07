import XCTest
@testable import RdevCore

final class AudioMessagesTests: XCTestCase {
    private func decode(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }
    private func subs(_ d: Data) -> [[String: Any]] {
        decode(d)["subs"] as? [[String: Any]] ?? []
    }
    private let prefs = VideoPrefs(fps: 60, scale: 1.0, bitrateBps: 2_000_000, codec: .auto)

    /// ABSENT MEANS UNKNOWN. A host with no opinion about a source's audio must emit NEITHER key,
    /// so an older client and a not-yet-decided host read identically — the rule activeCodec,
    /// activeDelivery and activeRecovery all follow.
    func testNoAudioStateEmitsNeitherKey() {
        let d = viewSetJSON(subs: [Subscription(source: "win:1", prefs: prefs)], focused: "win:1")
        XCTAssertNil(subs(d)[0]["audio"])
        XCTAssertNil(subs(d)[0]["audioOwner"])
    }

    /// A carrier that is sending says so, and carries NO owner — `audioOwner` means "somebody else
    /// has it", so emitting it here would say the source yielded to itself.
    func testCarrierEmitsAudioTrueAndNoOwner() {
        let d = viewSetJSON(subs: [Subscription(source: "win:1", prefs: prefs)], focused: "win:1",
                            audioState: ["win:1": AudioSubState(sending: true, owner: nil)])
        XCTAssertEqual(subs(d)[0]["audio"] as? Bool, true)
        XCTAssertNil(subs(d)[0]["audioOwner"])
    }

    /// A source that yielded names the owner. This is what lets the client render "audio from
    /// <window>" instead of a silent window indistinguishable from a broken one.
    func testYieldedSourceNamesItsOwner() {
        let d = viewSetJSON(subs: [Subscription(source: "win:2", prefs: prefs)], focused: "win:2",
                            audioState: ["win:2": AudioSubState(sending: false, owner: "win:1")])
        XCTAssertEqual(subs(d)[0]["audio"] as? Bool, false)
        XCTAssertEqual(subs(d)[0]["audioOwner"] as? String, "win:1")
    }

    /// MUTED IS `audio:false` WITH NO OWNER, and that is what distinguishes it from yielding. The
    /// two look the same on the speaker and must not look the same on the wire.
    func testMutedCarrierHasNoOwner() {
        let d = viewSetJSON(subs: [Subscription(source: "win:1", prefs: prefs)], focused: "win:1",
                            audioState: ["win:1": AudioSubState(sending: false, owner: nil)])
        XCTAssertEqual(subs(d)[0]["audio"] as? Bool, false)
        XCTAssertNil(subs(d)[0]["audioOwner"])
    }

    func testParseSetSourceAudioEnabled() {
        let d = Data(#"{"t":"set-source-audio","source":"win:1","enabled":true}"#.utf8)
        XCTAssertEqual(parseInbound(d), .setSourceAudio(source: "win:1", enabled: true))
    }

    func testParseSetSourceAudioDisabled() {
        let d = Data(#"{"t":"set-source-audio","source":"win:1","enabled":false}"#.utf8)
        XCTAssertEqual(parseInbound(d), .setSourceAudio(source: "win:1", enabled: false))
    }

    /// A MISSING FLAG IS REJECTED, NOT DEFAULTED — the `curtain` and `set-visibility` rule. A
    /// default would let a malformed message silence a window that asked for nothing.
    func testMissingEnabledIsRejected() {
        XCTAssertNil(parseInbound(Data(#"{"t":"set-source-audio","source":"win:1"}"#.utf8)))
    }

    func testEmptySourceIsRejected() {
        XCTAssertNil(parseInbound(Data(#"{"t":"set-source-audio","source":"","enabled":true}"#.utf8)))
    }
}
