import Foundation

/// The live-tunable video stream settings: capture frame-rate cap, capture scale (fraction of native
/// resolution), and encoder target bitrate. One shared instance per host — the stream is global to the
/// single active client. Sendable value type; the host holds the authoritative copy in SimManager.
public struct VideoPrefs: Equatable, Sendable {
    public var fps: Int
    public var scale: Double
    public var bitrateBps: Int
    /// What the client ASKED for. The negotiated result lives on the SourceStream, not here — this
    /// struct is the request, and conflating the two is how the UI would lose a pin.
    public var codec: CodecPref
    /// The sub-rectangle the single active client can actually see. Everything outside it is filled
    /// with `Checkerboard` at encode time, so the bitrate goes where the viewer is looking.
    ///
    /// DEFAULTS TO `.full`, which is what keeps every client that has never heard of this field on
    /// exactly today's behaviour.
    public var crop: CropRect
    public init(fps: Int, scale: Double, bitrateBps: Int, codec: CodecPref = .auto,
                crop: CropRect = .full) {
        self.fps = fps; self.scale = scale; self.bitrateBps = bitrateBps
        self.codec = codec; self.crop = crop
    }
}

/// Merge an optional patch onto `current`, clamped to safe bounds. Pure. Nil fields pass through
/// unchanged. Clamps: scale∈[0.05,1.0] (matches the capture source's own clamp), bitrate∈[1,cap]
/// (the 1 floor just guards ≤0), fps≥1. `bitrateCap` is the host's hard ceiling — the most a client may ASK for (20 Mbps by default),
/// which is NOT the same as the 2 Mbps a source starts at. See main.swift.
public func applyVideoPrefs(_ current: VideoPrefs,
                            fps: Int?, scale: Double?, bitrateBps: Int?,
                            codec: CodecPref? = nil,
                            crop: CropRect? = nil,
                            bitrateCap: Int) -> VideoPrefs {
    var out = current
    if let fps { out.fps = max(1, fps) }
    if let scale { out.scale = min(max(scale, 0.05), 1.0) }
    if let bitrateBps { out.bitrateBps = min(max(bitrateBps, 1), bitrateCap) }
    if let codec { out.codec = codec }   // no clamp: CodecPref cannot hold an invalid value
    // NO CLAMP HERE EITHER. The rect is resolved against a frame at encode time, where
    // `CropRect.pixels` clamps, rounds outward and answers "no mask" for anything degenerate —
    // clamping twice, in two places, is how the two would come to disagree.
    if let crop { out.crop = crop }
    return out
}

/// The rate an UNFOCUSED source runs at: focus governs video rate (focused = full prefs). Lowers fps
/// and bitrate toward the throttle floor but NEVER above the source's full prefs; scale is preserved
/// (throttling drops frame-rate/bitrate, not resolution — so a focus flip needs no pixel-pool recreate).
public func throttledPrefs(_ full: VideoPrefs, throttleFps: Int, throttleBitrateBps: Int) -> VideoPrefs {
    VideoPrefs(fps: min(full.fps, throttleFps),
               scale: full.scale,
               bitrateBps: min(full.bitrateBps, throttleBitrateBps),
               codec: full.codec,   // throttling changes RATE, never codec — a focus flip must not renegotiate
               // GEOMETRY IS NOT RATE, the same rule `scale` follows. An unfocused source that lost
               // its crop would spend its REDUCED budget on the nine tenths nobody is looking at.
               crop: full.crop)
}

/// The rate a HIDDEN source runs at. 1 rather than 0 because `ScreenCaptureSource.setFpsCap` clamps
/// with `max(fps, 1)` and `cfg.minimumFrameInterval` is `1/fps` — 1 fps is the floor the capture path
/// can express. Reaching true zero would mean stopping capture, and `ScreenCaptureSource.stop()`
/// latches `stopped = true` permanently, so resuming would need a fresh source and a fresh encoder.
public let hiddenFps = 1

/// The rate a source should actually run at, composing every reason to turn it down.
///
/// PRECEDENCE: hidden beats unfocused beats focused. A hidden tab is not being looked at whatever
/// the focus says.
///
/// RATE ONLY — `scale` and `codec` pass through untouched, exactly as `throttledPrefs` does. A tab
/// switch must not renegotiate, and must not undo the resolution the client's Auto mode settled on.
///
/// HIDDEN CUTS BITRATE AS WELL AS fps. The encoder is CBR: left at the full bitrate while fed 1 fps
/// it may spend the entire per-second budget on a single frame, which is real encoding work for a
/// picture nobody receives. `min`, never assignment, so a client asking for less than the throttle
/// floor keeps its lower number.
public func effectiveVideoPrefs(full: VideoPrefs, focused: Bool, hidden: Bool,
                                throttleFps: Int, throttleBitrateBps: Int) -> VideoPrefs {
    if hidden {
        return VideoPrefs(fps: hiddenFps,
                          scale: full.scale,
                          bitrateBps: min(full.bitrateBps, throttleBitrateBps),
                          codec: full.codec,
                          // GEOMETRY, like `scale` beside it. This branch builds its OWN VideoPrefs
                          // rather than delegating, so an omission here would silently repaint the
                          // mask and hand the encoder the whole window back on every tab switch.
                          crop: full.crop)
    }
    return focused ? full
                   : throttledPrefs(full, throttleFps: throttleFps, throttleBitrateBps: throttleBitrateBps)
}

/// The scale a DISPLAY subscribe starts at when the client asked for none.
///
/// WHY NOT 1.0. A 5K display at scale 1.0 captures 5120x2880, which `EncodeDimensions.fit` then clamps
/// to libaom's 3840x2160 ceiling — so the opening second of every subscribe pays a large vImage
/// downscale to throw away information the encoder was never going to keep. Measured on a 16" MBP:
/// scale 1.0 gave `[encode] dsp:1 AV1 3340x2160` from a 3456x2234 panel, i.e. the clamp fired on the
/// very first frame. The client's Auto resolution supersedes this within about a second; this only
/// stops that first moment being wasteful.
///
/// THIS IS A STARTING DEFAULT, NOT A CAPTURE-SIDE CAP. The 3840x2160 bound belongs to the libaom
/// backend, and the capture source does not know the negotiated codec — it is built before
/// `codec-resolved` settles. Enforcing a backend-specific limit at a backend-agnostic layer would
/// announce a downscale a VideoToolbox session never required, which is the same reasoning that keeps
/// `EncodeDimensions.fit` scoped to the libaom path.
///
/// An unreadable size (0 or negative) returns 1.0 rather than guessing: `EncodeDimensions.fit` still
/// clamps downstream, so the failure mode is wasteful, not broken.
public func displayDefaultScale(pixelW: Int, pixelH: Int) -> Double {
    guard pixelW > 0, pixelH > 0 else { return 1.0 }
    return min(1.0, 3840.0 / Double(pixelW), 2160.0 / Double(pixelH))
}

/// Bits per pixel per frame the resolution-derived starting bitrate aims for.
///
/// CALIBRATED, NOT CHOSEN. It is the rate the flat 2 Mbit/s default already delivered to a source of
/// about a megapixel at 60fps — 1200x800x60 x 0.035 = 2.02 Mbit/s. Anchoring it there is what makes
/// this a fix for the STARVED sources rather than a re-tuning of every source: a mid-size window
/// lands where it already was, and only much larger ones move.
///
/// IT IS NOT A MEASURED OPTIMUM. Nobody has run a quality sweep against it; it is the value that
/// preserves today's behaviour at the reference size. `RDEV_VIDEO_BITS_PER_PIXEL` overrides it so
/// tuning needs no rebuild.
public let defaultBitsPerPixel: Double = 0.035

/// The starting bitrate for a source of this many pixels at this frame rate.
///
/// WHY THIS EXISTS. The default bitrate was a flat 2 Mbit/s regardless of pixel count, so a full
/// desktop and a small window drew on the same budget. Measured against a 3456x2234 panel that is
/// ~0.0002 bits per pixel — roughly a fourteenth of what a 600x400 window gets from the same
/// default. The encoder cannot afford steady-state detail at that rate, so a scene change spends the
/// entire budget in one enormous frame (observed: 347 KB, 290 packets), and that frame is precisely
/// the one whose packets age past the retransmission window before a NACK can repair them — which
/// the responder then escalates to a keyframe. The keyframe storm and the picture quality are the
/// same problem seen twice.
///
/// FLOORED, SO NOTHING REGRESSES. `floorBps` is the bitrate the source would have had anyway, so
/// this can only ever raise a budget. Capped at the host's own ceiling, because a derived default
/// that exceeded it would be silently clamped by `applyVideoPrefs` a moment later.
///
/// A STARTING DEFAULT, NOT A CAP — the same contract as `displayDefaultScale`. An explicit client
/// `bitrateBps` still wins, because `applyVideoPrefs` patches over this.
///
/// An unreadable size or frame rate (0 or negative on any axis) returns the floor rather than
/// guessing, which is exactly the behaviour that shipped.
public func resolutionBitrateBps(pixelW: Int, pixelH: Int, fps: Int,
                                 floorBps: Int, capBps: Int,
                                 bitsPerPixel: Double = defaultBitsPerPixel) -> Int {
    guard pixelW > 0, pixelH > 0, fps > 0, bitsPerPixel > 0 else { return floorBps }
    let derived = Double(pixelW) * Double(pixelH) * Double(fps) * bitsPerPixel
    // Saturate before converting: a 16K-by-1000fps argument would overflow Int on the way in.
    guard derived.isFinite else { return capBps }
    return min(capBps, max(floorBps, Int(derived.rounded())))
}
