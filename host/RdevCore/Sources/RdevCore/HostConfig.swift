import Foundation

/// Host startup configuration, translated from the environment by a FRONT-END.
///
/// The runtime takes this value rather than reading `ProcessInfo.environment` itself: the
/// `RDEV_*` surface is a test-harness concern, and the native app will never set any of it.
/// Keeping the translation here — pure, in RdevCore — is also the only way it gets tested,
/// since RdevHost has no test target.
public struct HostConfig: Equatable, Sendable {
    public var signalingBase: String
    public var useTestPattern: Bool
    /// Encode/send framerate. FIXED at 60 — per-source fps is a CLIENT pref (15/30/60 in the
    /// window titlebar). `RDEV_VIDEO_FPS` was removed 2026-07-30 because it defaulted to 30
    /// while every real launch passed 60, so its only effect was to make the default a lie.
    public var fps: Int
    public var scale: Double
    /// What a source actually streams at until a client changes it.
    public var bitrateBps: Int
    /// The highest a client may ASK for. Deliberately a different number from `bitrateBps`.
    public var bitrateCapBps: Int
    public var throttleFps: Int
    public var throttleBitrateBps: Int
    public var curtainSelfTest: Bool

    /// Hold the host's display awake while SHARING. On by default: a Mac whose display sleeps drops
    /// out of `CGGetActiveDisplayList`, which kills capture on every source, and five minutes later
    /// the session locks — a state no remote client can undo. `RDEV_KEEP_AWAKE=0` opts out.
    public var keepAwake: Bool

    /// Where saved pastes go (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §6). nil: the
    /// process's own `~/Library/Caches/<bundle id>/Pastes`; the APP passes its profile's. `RDEV_PASTE_DIR`
    /// overrides both — tests only.
    public var pasteDirectory: String? = nil

    public init(signalingBase: String, useTestPattern: Bool, fps: Int, scale: Double,
                bitrateBps: Int, bitrateCapBps: Int, throttleFps: Int,
                throttleBitrateBps: Int, curtainSelfTest: Bool, keepAwake: Bool) {
        self.signalingBase = signalingBase
        self.useTestPattern = useTestPattern
        self.fps = fps
        self.scale = scale
        self.bitrateBps = bitrateBps
        self.bitrateCapBps = bitrateCapBps
        self.throttleFps = throttleFps
        self.throttleBitrateBps = throttleBitrateBps
        self.curtainSelfTest = curtainSelfTest
        self.keepAwake = keepAwake
    }

    public static let defaultBitrateBps = 2_000_000
    public static let defaultBitrateCapBps = 20_000_000

    public static func from(environment env: [String: String]) -> HostConfig {
        let cap = Int(env["RDEV_VIDEO_BITRATE_CAP_BPS"] ?? "") ?? defaultBitrateCapBps
        // LOAD-BEARING: the fallback is `defaultBitrateBps`, NOT `cap`. See the test.
        let bitrate = min(Int(env["RDEV_VIDEO_BITRATE_BPS"] ?? "") ?? defaultBitrateBps, cap)
        var c = HostConfig(
            signalingBase: env["RDEV_SIGNALING"] ?? "http://localhost:8787",
            useTestPattern: env["RDEV_TEST_PATTERN"] == "1",
            fps: 60,
            scale: Double(env["RDEV_VIDEO_SCALE"] ?? "") ?? 1.0,
            bitrateBps: bitrate,
            bitrateCapBps: cap,
            throttleFps: Int(env["RDEV_THROTTLE_FPS"] ?? "") ?? 8,
            throttleBitrateBps: Int(env["RDEV_THROTTLE_BITRATE_BPS"] ?? "") ?? 400_000,
            curtainSelfTest: env["RDEV_CURTAIN_TEST"] == "1",
            keepAwake: env["RDEV_KEEP_AWAKE"] != "0")
        c.pasteDirectory = env["RDEV_PASTE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        return c
    }
}
