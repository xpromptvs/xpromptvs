import Foundation
import CoreVideo
import RdevCore

/// A debug-only stage between a capture source and its encoder: copies each frame into a buffer we
/// OWN, draws the enabled overlays onto it, and forwards.
///
/// WHY A COPY, and not drawing in place into the capture buffer — two independent reasons, either
/// sufficient:
///
///  1. ScreenCaptureKit owns and RECYCLES its buffers (queueDepth 5, and it exposes dirty rects,
///     which implies it re-renders only changed regions into recycled surfaces). A rectangle drawn
///     into one would persist in the static areas of a later frame that reuses it. On a cosmetic
///     overlay that is a smear; on a LATENCY INSTRUMENT it is a lie, and it would present as the
///     measurement rather than as a bug.
///  2. Restore-after-encode does not work. VTEncoder hands the buffer to VideoToolbox, which
///     encodes ASYNCHRONOUSLY and keeps reading after the call returns. AV1Encoder happens to
///     convert to I420 synchronously, so the same code would be safe on AV1 and broken on
///     H.264/H.265 — a codec-dependent correctness bug, which is worse than an obvious one.
///
/// The copy costs roughly 0.1 ms at 816x538 and 2 ms at full retina. It is MEASURED and reported as
/// the `overlay` stage rather than assumed negligible; the timecode is stamped AFTER it, so it
/// falls outside the interval the probe reports; and the rectangle is a differential instrument, so
/// a delay applied equally to the marker and to the app's captured response cancels out.
///
/// THREADING: `encode` is called only from its capture source's own serial queue —
/// `ScreenCaptureSource.sampleQueue` or `TestPatternSource`'s timer queue — so `pool`/`poolW`/
/// `poolH` are confined to that queue and need no lock. That confinement is what justifies
/// `@unchecked Sendable`.
final class FrameOverlaySink: VideoFrameSink, @unchecked Sendable {
    static let cursorEnabled = ProcessInfo.processInfo.environment["RDEV_CURSOR_OVERLAY"] == "1"
    static let probeEnabled = ProcessInfo.processInfo.environment["RDEV_LATENCY_PROBE"] == "1"
    /// Whether to PAINT the timecode. Separate from `probeEnabled` so the stage timings can stay on
    /// while the stamp is suppressed — which is what `tools/LatencyTarget` needs: it paints its own
    /// timecode at the same corner-anchored (0,0), so leaving the host's on means the two overwrite
    /// each other and the browser decodes garbage. That presents as implausible latency numbers, not
    /// as a visible collision, so it is worth an explicit switch.
    static let stampEnabled = probeEnabled
        && ProcessInfo.processInfo.environment["RDEV_LATENCY_STAMP"] != "0"
    /// A REFERENCE MOTION that is regular BY CONSTRUCTION, drawn into every captured frame.
    ///
    /// WHY. Every timing number rdev has describes DELIVERY — `[capture] interval` is when the host
    /// received a frame, and the RTP timestamp is deliberately arrival time rather than the sample's
    /// own presentation time. None of them describe when the PIXELS were composed. So a source app
    /// rendering at 120Hz and sampled at 60 can advance 2 or 3 refreshes of content between frames
    /// while delivery stays perfectly even at 16.7ms, and nothing in the pipeline would show it.
    ///
    /// This bar's position is a pure function of the host's monotonic clock at the moment the frame
    /// is drawn, so it is smooth by definition. On screen that separates the two:
    ///
    ///   bar smooth, app content juddery  -> the capture SAMPLING of that app is uneven (or the app is)
    ///   bar juddery too                  -> the pipeline: encode, transport, pacing or presentation
    ///
    /// It cannot be faked by the pacer: rdev's own scheduling moves the whole frame, bar included.
    static let motionEnabled = ProcessInfo.processInfo.environment["RDEV_MOTION_OVERLAY"] == "1"
    static var anyEnabled: Bool { cursorEnabled || probeEnabled || motionEnabled }

    /// Seconds for the bar to cross the frame. Slow enough to follow with the eye across the whole
    /// sweep — a faster bar makes a single mistimed frame obvious but is harder to judge as SMOOTH,
    /// and smoothness is the question.
    private static let motionPeriodS = 3.0

    /// Wrap `encoder` when any overlay is enabled; otherwise return the encoder ITSELF, so the
    /// production path has no wrapper, no branch in the frame path and no allocation.
    ///
    /// `sourceID` nil means a source with no focus concept (the headless test pattern) — it always
    /// draws. A non-nil id draws only while that source is focused.
    ///
    /// LOAD-BEARING: the CALLER must retain the returned value when its capture source holds the
    /// sink WEAKLY. `TestPatternSource.sink` is `weak`, so a decorator referenced only by the source
    /// deallocates immediately and the pattern then emits into nothing — a frozen client, not a
    /// crash. `ScreenCaptureSource` holds its sink strongly and needs no help.
    static func install(on encoder: VideoEncoding, sourceID: String?) -> VideoFrameSink {
        anyEnabled ? FrameOverlaySink(wrapping: encoder, sourceID: sourceID) : encoder
    }

    private let encoder: VideoEncoding
    private let sourceID: String?
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0

    private init(wrapping encoder: VideoEncoding, sourceID: String?) {
        self.encoder = encoder
        self.sourceID = sourceID
    }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let dst = copy(pixelBuffer) else {
            encoder.encode(pixelBuffer, ptsNs: ptsNs)   // pass-through: never drop a frame for a debug feature
            return
        }
        draw(into: dst)
        LatencyStages.shared.record(.overlay, source: sourceID ?? "test",
                                    ms: Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000)
        encoder.encode(dst, ptsNs: ptsNs)
    }

    /// Copy into a pooled BGRA buffer we own.
    ///
    /// LOAD-BEARING: the pool is recreated on ANY dimension change. A stale pool keeps vending the
    /// OLD size, so the emitted buffer never changes dimensions, `VTEncoder.recreateSession` never
    /// fires, and a smaller frame lands in a corner over stale pixels while a larger one overflows
    /// and freezes the stream with no recovery. Same condition AV1Encoder uses for its conversion
    /// buffer, for the same reason.
    private func copy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        guard w > 0, h > 0 else { return nil }
        if pool == nil || w != poolW || h != poolH {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var p: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p) == kCVReturnSuccess,
                  p != nil else {
                pool = nil; poolW = 0; poolH = 0
                return nil
            }
            pool = p; poolW = w; poolH = h
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let dst = out else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(src), let d = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let sStride = CVPixelBufferGetBytesPerRow(src), dStride = CVPixelBufferGetBytesPerRow(dst)
        if sStride == dStride {
            memcpy(d, s, sStride * h)
        } else {
            let rowBytes = min(sStride, dStride)
            for y in 0 ..< h { memcpy(d + y * dStride, s + y * sStride, rowBytes) }
        }
        return dst
    }

    private func draw(into pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)

        if FrameOverlaySink.cursorEnabled,
           let m = CursorOverlayState.shared.marker(forSource: sourceID),
           let r = CursorMarker.rect(normX: m.x, normY: m.y, width: w, height: h) {
            let c = CursorMarker.colorBGRA(pressed: m.pressed)
            for y in r.y0 ..< r.y1 {
                let row = y * stride
                for x in r.x0 ..< r.x1 {
                    let o = row + x * 4
                    base[o] = c.b; base[o + 1] = c.g; base[o + 2] = c.r; base[o + 3] = 255
                }
            }
        }

        // A REFERENCE MOTION, before the stamp so the stamp still wins the corner. Position comes from
        // the MONOTONIC clock (systemUptime), not the wall clock: a wall-clock step would move the bar
        // and read as pipeline judder that never happened.
        if FrameOverlaySink.motionEnabled, w > 64, h > 8 {
            let barW = max(8, w / 48)
            let travel = w - barW
            if travel > 0 {
                let phase = ProcessInfo.processInfo.systemUptime
                    .truncatingRemainder(dividingBy: FrameOverlaySink.motionPeriodS)
                    / FrameOverlaySink.motionPeriodS
                let x0 = Int(phase * Double(travel))
                // A band rather than the full height, so it cannot hide the content being judged.
                let y0 = h / 2 - max(4, h / 12), y1 = h / 2 + max(4, h / 12)
                for y in max(0, y0) ..< min(h, y1) {
                    let row = y * stride
                    for x in x0 ..< min(w, x0 + barW) {
                        let o = row + x * 4
                        // Opaque white: maximum luma contrast, so 4:2:0 chroma subsampling cannot
                        // soften the edge the eye is tracking.
                        base[o] = 255; base[o + 1] = 255; base[o + 2] = 255; base[o + 3] = 255
                    }
                }
            }
        }

        // LAST, unconditionally after the cursor rectangle. The stamp is corner-anchored at (0,0)
        // and 576x24 px; a marker near the top-left would otherwise overwrite cells, and the client
        // would decode a plausible-looking WRONG timestamp rather than show a visible drawing bug.
        //
        // Stamped AFTER the copy on purpose: the copy is this instrument's own cost, and the probe
        // must not charge the pipeline for it.
        if FrameOverlaySink.stampEnabled, LatencyProbeStamp.fits(width: w, height: h) {
            let epochMs = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000))
            let bits = LatencyTimecode.encode(epochMs)
            for i in 0 ..< LatencyProbeStamp.cellCount {
                guard let white = LatencyProbeStamp.cellIsWhite(i, bits: bits) else { continue }
                let v: UInt8 = white ? 255 : 0
                let x0 = LatencyProbeStamp.originX + i * LatencyProbeStamp.cellW
                for y in LatencyProbeStamp.originY ..< (LatencyProbeStamp.originY + LatencyProbeStamp.cellH) {
                    let row = y * stride
                    for x in x0 ..< (x0 + LatencyProbeStamp.cellW) {
                        let o = row + x * 4
                        base[o] = v; base[o + 1] = v; base[o + 2] = v; base[o + 3] = 255
                    }
                }
            }
        }
    }
}
