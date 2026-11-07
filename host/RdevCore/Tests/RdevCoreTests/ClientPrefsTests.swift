import XCTest
@testable import RdevCore

/// A device's preferences arrive as JSON from a client and become every streamed window's prefs, so both
/// halves are pinned: what `init(wire:)` reads (leniently, per field) and what `resolvedVideoPrefs` makes
/// of it (the host's defaults, overridden, clamped exactly as `applyVideoPrefs` clamps).
final class ClientPrefsTests: XCTestCase {

    private func prefs(_ json: String) -> ClientPrefs {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return ClientPrefs(wire: obj)
    }

    // MARK: - init(wire:)

    func testNothingChosenIsTheHostDefaultEverywhere() {
        XCTAssertEqual(ClientPrefs.default,
                       ClientPrefs(fps: nil, scale: .auto, bitrateBps: nil, codec: .auto, pointerMode: nil))
        XCTAssertEqual(prefs("{}"), .default)
    }

    func testReferenceRecoveryRequiresAnExplicitBooleanOptIn() {
        XCTAssertNotEqual(prefs(#"{"av1ReferenceRecovery":true}"#), .default)
        for json in [#"{}"#, #"{"av1ReferenceRecovery":false}"#, #"{"av1ReferenceRecovery":1}"#,
                     #"{"av1ReferenceRecovery":"true"}"#, #"{"av1ReferenceRecovery":null}"#] {
            XCTAssertEqual(prefs(json), .default, json)
        }
    }

    func testEveryFieldParses() {
        XCTAssertEqual(
            prefs(#"{"fps":30,"scale":0.5,"bitrateBps":4000000,"codec":"h265","pointerMode":"trackpad"}"#),
            ClientPrefs(fps: 30, scale: .fixed(0.5), bitrateBps: 4_000_000, codec: .h265, pointerMode: .trackpad))
        XCTAssertEqual(prefs(#"{"scale":"auto"}"#).scale, .auto)
        XCTAssertEqual(prefs(#"{"pointerMode":"direct"}"#).pointerMode, .direct)
    }

    /// LENIENT PER FIELD: a malformed field reads as ABSENT — the host's default — and the rest still apply.
    func testAMalformedFieldIsAbsent() {
        XCTAssertEqual(prefs(#"{"fps":"60","scale":"huge","bitrateBps":-5,"codec":"vp9","pointerMode":"mouse"}"#),
                       .default)
        XCTAssertNil(prefs(#"{"fps":0}"#).fps)
        XCTAssertNil(prefs(#"{"fps":-30}"#).fps)
        XCTAssertNil(prefs(#"{"fps":1001}"#).fps, "past any display's rate: garbage, not a wish")
        XCTAssertEqual(prefs(#"{"fps":1000}"#).fps, 1000)
        XCTAssertNil(prefs(#"{"fps":true}"#).fps, "a JSON boolean is not a number, though NSNumber says it is")
        XCTAssertNil(prefs(#"{"bitrateBps":0}"#).bitrateBps)
        XCTAssertNil(prefs(#"{"bitrateBps":1e300}"#).bitrateBps, "ignored — never a trap converting to Int")
        XCTAssertEqual(prefs(#"{"scale":0}"#).scale, .auto)
        XCTAssertEqual(prefs(#"{"scale":-0.5}"#).scale, .auto)
        XCTAssertEqual(prefs(#"{"scale":false}"#).scale, .auto)
    }

    func testOneBadFieldLeavesItsNeighboursAlone() {
        XCTAssertEqual(prefs(#"{"fps":"x","bitrateBps":3000000,"codec":"av1"}"#),
                       ClientPrefs(bitrateBps: 3_000_000, codec: .av1))
    }

    // MARK: - resolvedVideoPrefs

    private let defaults = VideoPrefs(fps: 60, scale: 1.0, bitrateBps: 2_000_000)
    private let cap = 20_000_000

    private func resolve(_ client: ClientPrefs, autoScale: Double? = nil, crop: CropRect = .full,
                         defaults d: VideoPrefs? = nil) -> VideoPrefs {
        resolvedVideoPrefs(defaults: d ?? defaults, client: client, autoScale: autoScale, crop: crop,
                           bitrateCap: cap)
    }

    func testNoPreferencesIsTheHostDefault() {
        XCTAssertEqual(resolve(.default), defaults)
    }

    func testAFixedScaleWinsOverTheWindowsAutoCeiling() {
        XCTAssertEqual(resolve(ClientPrefs(scale: .fixed(0.5)), autoScale: 0.8).scale, 0.5)
    }

    /// `.auto` is the ceiling THIS window's client reported, and the host's default until it has.
    func testAutoUsesTheWindowsCeilingOnceReportedElseTheDefault() {
        let d = VideoPrefs(fps: 60, scale: 0.7, bitrateBps: 2_000_000)
        XCTAssertEqual(resolve(.default, autoScale: 0.4, defaults: d).scale, 0.4)
        XCTAssertEqual(resolve(.default, autoScale: nil, defaults: d).scale, 0.7)
    }

    /// Every clamp is `applyVideoPrefs`' — the one place the bounds live.
    func testClampsAreApplyVideoPrefs() {
        let big = resolve(ClientPrefs(fps: 1000, scale: .fixed(5), bitrateBps: 50_000_000))
        XCTAssertEqual(big.fps, 1000)
        XCTAssertEqual(big.scale, 1.0)
        XCTAssertEqual(big.bitrateBps, cap)
        XCTAssertEqual(resolve(ClientPrefs(scale: .fixed(0.001))).scale, 0.05)
    }

    func testCodecAndCropCarryThrough() {
        let crop = CropRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
        XCTAssertEqual(resolve(ClientPrefs(fps: 30, bitrateBps: 3_000_000, codec: .h264), crop: crop),
                       VideoPrefs(fps: 30, scale: 1.0, bitrateBps: 3_000_000, codec: .h264, crop: crop))
    }
}
