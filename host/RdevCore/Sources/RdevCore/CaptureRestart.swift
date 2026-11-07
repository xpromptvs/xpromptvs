import Foundation

/// **A CAPTURE THAT DIES IS STARTED AGAIN** (2026-10-07: "if I press on a window to stream it before its preview loads in the
/// palette, sharing doesn't work"). `ScreenCaptureSource` logged a stream that stopped — "capture is dead and will not
/// resume" — and a `startCapture` that failed, and did nothing more: nothing listened to `onCaptureStopped`, so the
/// window stayed dark until it was opened again, with the subscription, the bind and the encoder all healthy. Two
/// captures on one application share its connection, and a sibling stopping while a stream starts kills it with
/// `-3805` (docs/sources-and-focus.md) — a palette's preview screenshots in flight are exactly such siblings.
///
/// The DECISION, pure: after a failure, how long to wait before starting again, or nil to give up. Backoff doubling
/// from `base`; at most `maxAttempts` in a row; a stream that ran `healthyAfter` before dying starts the count afresh;
/// never for a permission refusal (`-3801`, the user declined), which no retry changes.
public struct CaptureRestart: Equatable, Sendable {
    public static let base: Double = 0.25
    public static let maxAttempts = 6
    public static let healthyAfter: Double = 30
    /// `SCStreamError.userDeclined`.
    public static let permissionDenied = -3801

    public private(set) var attempts = 0

    public init() {}

    /// A failure: `code` (nil for one with none), and how long the stream had been running (nil when it never
    /// started). Returns the delay before the next start, or nil to stop trying.
    public mutating func next(code: Int?, ranFor: Double?) -> Double? {
        if let ranFor, ranFor >= Self.healthyAfter { attempts = 0 }
        guard code != Self.permissionDenied, attempts < Self.maxAttempts else { return nil }
        attempts += 1
        return Self.base * pow(2, Double(attempts - 1))
    }
}
