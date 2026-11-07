import Foundation
import RdevCore

/// Captured before joining the serialized AX lane, validated again at commit and final native post.
/// An owner-less plan preserves the existing local/test focus path without inventing an admission.
struct SourceFocusRoutePlan {
    let epoch: UInt64?
    let ticket: SourceInputRoute.Ticket?
}

struct SourceFocusRequest {
    let connection: ObjectIdentifier
    let epoch: UInt64
    let source: String?
    let request: String
}
