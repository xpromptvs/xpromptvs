import Foundation

/// Why the host is holding its display awake. A SET OF REASONS — not a boolean, and not a refcount.
///
/// Two independent holders exist and they must not clobber each other:
///
/// - `.sharing`, so an unattended Mac never idles into sleep-then-lock. That state is unrecoverable
///   remotely: `loginwindow` discards synthetic `CGEvent`s from an Aqua-session app, so no client can
///   type the password (measured — a click and three keystrokes left the field empty while the
///   captured clock kept advancing).
/// - `.curtain`, which is meaningless over a sleeping display: `setGammaBlack` iterates the ACTIVE
///   display list, so a curtain raised over a dark screen blacks nothing while still suppressing
///   local input.
///
/// `RDEV_KEEP_AWAKE=0` suppresses only the SHARING reason. Raising the curtain always wakes, because
/// a curtain over a dark display is the defect this exists to remove, not a preference.
///
/// A SET RATHER THAN A REFCOUNT so a double-add cannot pin the display awake forever — the failure
/// mode of `CGDisplayHideCursor`, which the curtain already has to hand-balance for exactly that
/// reason.
public struct DisplayAwakeReasons: Equatable, Sendable {
    public enum Reason: String, CaseIterable, Sendable { case sharing, curtain }

    private var held: Set<Reason> = []
    public init() {}

    public mutating func add(_ r: Reason) { held.insert(r) }
    public mutating func remove(_ r: Reason) { held.remove(r) }
    public var isHeld: Bool { !held.isEmpty }
    /// Sorted so a log line is stable run to run.
    public var reasons: [String] { held.map(\.rawValue).sorted() }
}
