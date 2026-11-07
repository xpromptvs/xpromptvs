import Foundation
import RdevCore

/// One live subscribed source: its OWN encoder (built LAZILY once the track's codec is negotiated — see
/// `SimManager.ensureEncoder`, driven by the bridge's `codec-resolved` callback — NOT at subscribe, since the
/// codec isn't known until the answer settles), plus the capture source + injector filled in AFTER the sim
/// boots. Replaces Milestone A's single `SourceBinding` + shared encoder with a per-source stream so N
/// sources encode independently at their own rate.
///
/// THREAD-SAFETY CONTRACT (LOAD-BEARING): this type has NO lock of its own. Every mutable field
/// (`encoder`, `source`, `injector`, `fullPrefs`, `started`) is read/written ONLY while holding
/// `SimManager.lock`. Methods on the encoder/source (`start`/`stop`/`setScale`/`setFpsCap`/`setFps`/`setBitrate`)
/// are thread-safe on their own, but SimManager must snapshot the ref under the lock and CALL it OUTSIDE the lock
/// (never hold `SimManager.lock` across a source/encoder call — same discipline as Milestone A's swap).
final class SourceStream {
    let sourceID: String
    var nativeEpoch: UInt64? // fixed before installation; nil for streamed presentation
    var workspaceEpoch: UInt64? // fixed before installation; retired on every driver generation
    let target: SourceTarget
    var encoder: VideoEncoding?        // nil until codec-resolved builds it; guarded by SimManager.lock
    /// This source's Opus encoder. Built at SUBSCRIBE, unlike `encoder` — audio needs no
    /// codec-resolved round trip because Opus is the only audio codec rdev registers. Guarded by
    /// SimManager.lock.
    var audioEncoder: (any AudioEncoding)?
    /// The pid of the application that owns this source, or nil for a display source (which owns
    /// EVERY application's audio). Feeds AudioOwnership.elect. Guarded by SimManager.lock.
    var ownerPID: Int32?
    var source: StreamVideoSource?     // nil until the sim boots + capture attaches; guarded by SimManager.lock
    var injector: InputInjector?       // nil for a window source / until boot; guarded by SimManager.lock
    var fullPrefs: VideoPrefs          // resolved: the driver's preferences over `baseDefaults`, this window's Auto ceiling + crop; guarded by SimManager.lock
    var started = false                // capture has been start(into:)'d into the encoder; guarded by SimManager.lock
    /// The codec this source's track NEGOTIATED, once an answer settled. Distinct from
    /// `fullPrefs.codec`, which is what the client ASKED for — a pin can go unmet, and `view-set`
    /// reports both so the UI can say so. nil until the first codec-resolved. Guarded by SimManager.lock.
    var activeCodec: NegotiatedCodec?
    /// The source's NATIVE pixel size (the fixed coded panels for Apps), known at subscribe. Feeds the derived bitrate
    /// below; nil for a source whose size was unreadable. Guarded by SimManager.lock.
    var nativePixels: (w: Int, h: Int)?
    /// What this stream's prefs resolve FROM before the driver's preferences apply: the host's
    /// defaults, or for a DISPLAY its panel-derived scale and bitrate (`SimManager.makeStream`). Set
    /// once, at creation. Guarded by SimManager.lock.
    var baseDefaults: VideoPrefs

    /// Who owns this stream's audio, for the election. Under `SimManager.lock`, like every field here.
    var audioOwner: AudioOwner {
        if case .simulator = target { return .silent }
        return ownerPID.map { AudioOwner.application(pid: $0) } ?? .everything
    }

    init(sourceID: String, target: SourceTarget, fullPrefs: VideoPrefs) {
        self.sourceID = sourceID
        self.target = target
        self.fullPrefs = fullPrefs
        self.baseDefaults = fullPrefs
    }

    /// Stop the capture (frees the capture/encode CPU). The encoder deallocs with the stream once its sinks
    /// are removed. Idempotent-ish: safe to call with a nil source (pre-attach unsubscribe).
    ///
    /// The injector needs no teardown: `WindowInputInjector` holds no connection or stream, only a serial
    /// queue and a pid. (`SimHIDInjector` did — it owned an AsyncStream feeding a live HID connection, and
    /// was stopped here. It went with simulator support on 2026-07-31.)
    func stop() {
        source?.stop()
    }
}
