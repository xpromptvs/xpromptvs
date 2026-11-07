import Foundation

/// Chooses an SVT-AV1 preset from the frame size and a per-frame ENCODE-LATENCY budget.
///
/// WHY LATENCY AND NOT THROUGHPUT: every preset hits the CBR target, so a lower preset number buys
/// quality at the same bitrate rather than a smaller stream — and the cost it charges is milliseconds
/// added to EVERY frame. Picking "the slowest preset that still sustains 60 fps" would land on preset 4
/// at 640×400, which is 3× the encode latency of preset 9 for identical framerate. On a project whose
/// goal is lowest-possible latency (and where AV1 already costs ~8 ms more client-side jitter buffer
/// than hardware H.265), the budget is the thing to hold, and quality is what we spend the slack on.
///
/// The machine's speed is NOT hardcoded — see `machineFactor`. Only the SHAPE (how presets compare to
/// each other, and how cost grows with frame size) is baked in, which is far more portable across
/// machines than absolute timings.
public enum AV1Preset {
    /// Cost of each preset relative to preset 11, averaged over 640×400 / 976×454 / 1400×950 / 2644×1230
    /// on screen-like content. Ratios, not timings: a slower machine scales all of them together, which
    /// is exactly what `machineFactor` re-derives at runtime.
    ///
    /// 5 and 12 are ABSENT because both are DOMINATED: preset 5 measured no cheaper than preset 4
    /// (occasionally dearer — the curve is not monotonic there) while being lower quality, and preset 12
    /// measured the same cost as 11 while being lower quality. A dominated rung can only ever be the
    /// wrong answer, so the ladder does not offer it.
    public static let relativeCost: [(preset: Int, cost: Double)] = [
        (4, 3.18), (6, 2.02), (7, 1.88), (8, 1.74), (9, 1.22), (10, 1.07), (11, 1.00),
    ]

    /// Reference cost of a frame at preset 11, in milliseconds, as an AFFINE function of megapixels:
    /// `fixedMs + perMegapixelMs × MP`.
    ///
    /// LOAD-BEARING that this is affine and not a simple ms-per-megapixel rate. Cost per PIXEL is far
    /// from constant — preset 11 measured 6.60 ms/MP at 640×400 but 2.54 ms/MP at 2644×1230, because a
    /// large fixed per-frame overhead dominates small frames. A linear model fitted at one size
    /// underestimates a small frame by ~40%, which would hand it a preset it cannot afford. Fitted over
    /// 640×400 / 976×454 / 1400×950 / 2644×1230 (reproduces all four within ~3%).
    public static let fixedMs = 1.127
    public static let perMegapixelMs = 2.198

    /// What one frame of `pixels` costs at preset 11 on the reference machine, in milliseconds.
    public static func referenceFrameMs(pixels: Int) -> Double {
        fixedMs + perMegapixelMs * (Double(pixels) / 1_000_000.0)
    }

    /// How much dearer a frame is here than on the machine the table was fitted on. 1.0 = the reference
    /// (an 18-core Apple Silicon box); 2.0 = twice the cost. `AV1Encoder` derives it from real frame
    /// timings, which is what makes the ladder correct on hardware it has never seen.
    ///
    /// It absorbs CONTENT DIFFICULTY as well as machine speed, and that is deliberate — but it is why a
    /// first pick can miss. The table is fitted on synthetic screen-like content; measured live against
    /// video playback, the same preset cost ~1.6× the prediction (preset 6 predicted 5.0 ms, measured
    /// 8.2 ms), because natural content carries far more residual than flat UI does. The factor persists
    /// across recreates, so only the FIRST resolution pays for that; by the next one it has converged.
    public static let referenceMachineFactor = 1.0

    /// Predicted milliseconds to encode one frame of `pixels` at `preset` on a machine of this factor.
    public static func predictedMs(preset: Int, pixels: Int, machineFactor: Double) -> Double {
        let cost = relativeCost.first(where: { $0.preset == preset })?.cost ?? 1.0
        return machineFactor * cost * referenceFrameMs(pixels: pixels)
    }

    /// Re-derive the machine factor from one real observation: `measuredMs` for a frame of `pixels`
    /// encoded at `preset`. Returns nil for a degenerate input rather than poisoning the estimate.
    public static func machineFactor(measuredMs: Double, pixels: Int, preset: Int) -> Double? {
        guard measuredMs > 0, pixels > 0 else { return nil }
        let cost = relativeCost.first(where: { $0.preset == preset })?.cost ?? 1.0
        let ref = cost * referenceFrameMs(pixels: pixels)
        guard ref > 0 else { return nil }
        return measuredMs / ref
    }

    /// The LOWEST (best quality) preset predicted to encode a `pixels` frame within `budgetMs`.
    ///
    /// When nothing fits — a big window on a slow machine — this returns the FASTEST rung rather than
    /// failing: exceeding the budget is a quality/latency regression, but refusing to pick would be no
    /// video at all. `AV1Encoder` still logs the overshoot so it is visible rather than silent.
    public static func choose(pixels: Int, budgetMs: Double, machineFactor: Double) -> Int {
        let rungs = relativeCost.sorted { $0.preset < $1.preset }   // best quality first
        for r in rungs where predictedMs(preset: r.preset, pixels: pixels, machineFactor: machineFactor) <= budgetMs {
            return r.preset
        }
        return rungs.last?.preset ?? 11
    }
}
