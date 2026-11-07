import CoreVideo
import RdevWorkspacePacking

/// One coded frame carries all three planes; no separately timed hit-map messages.
enum WorkspacePacking {
    static func pack(color: CVPixelBuffer, hit: CVPixelBuffer) -> CVPixelBuffer? {
        #if arch(arm64)
        return RdevWorkspacePackVectorized(color, hit)
        #else
        return RdevWorkspacePackWithHit(color, hit)
        #endif
    }
}
