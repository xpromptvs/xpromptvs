// host/RdevCore/Sources/RdevCore/LatencyProbeStamp.swift

/// Cell geometry for the glass-to-glass timecode stamp — the other half of `LatencyTimecode`'s
/// host↔browser contract. Browser mirror: `web/src/lib/probe.ts`, which self-calibrates the cell
/// width from the frame and therefore survives WebRTC's rescaling; these are the host's native
/// dimensions.
///
/// Layout, corner-anchored at (0,0):
///   cell 0                  BLACK  (start finder + black reference)
///   cell 1                  WHITE  (start finder + white reference)
///   cells 2 ..< bits+2      data, MSB first
///   cell bits+2             WHITE  (end finder)
///   cell bits+3             BLACK  (end finder)
///
/// This enum lived in `SimFramebufferVideoSource` until `2d9666c` deleted that file with simulator
/// support, taking the host's ability to stamp anything with it. It belongs in RdevCore next to
/// `LatencyTimecode`: both halves of one wire contract, both pure, both tested.
public enum LatencyProbeStamp {
    public static let originX = 0
    public static let originY = 0
    public static let cellW = 16
    public static let cellH = 24
    public static let cellCount = LatencyTimecode.bitCount + 4

    public static var widthPx: Int { originX + cellCount * cellW }
    public static var heightPx: Int { originY + cellH }

    /// Whether a frame is large enough to carry the stamp. A frame that is not must be left
    /// UNSTAMPED rather than partially stamped — a truncated stamp decodes as a plausible-looking
    /// wrong timestamp, which is worse than no reading at all.
    public static func fits(width: Int, height: Int) -> Bool {
        width >= widthPx && height >= heightPx
    }

    /// White (`true`) or black (`false`) for cell `i`, or nil when `i` is out of range.
    public static func cellIsWhite(_ i: Int, bits: [Bool]) -> Bool? {
        switch i {
        case 0: return false
        case 1: return true
        case LatencyTimecode.bitCount + 2: return true
        case LatencyTimecode.bitCount + 3: return false
        case 2 ..< (LatencyTimecode.bitCount + 2):
            let b = i - 2
            return b < bits.count ? bits[b] : false
        default: return nil
        }
    }
}
