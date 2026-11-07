import Foundation

/// **A BRIDGE SOCKET'S OUTBOUND QUEUE** (docs/desktop-app.md, "The bridge socket") — pure, so its ORDER
/// is tested:
/// - Frames leave in the order `append` was CALLED, from any thread, followed by at most one close.
/// - A flush takes everything queued at once.
/// - A caller schedules a flush only when `append` or `close` says none is pending, so the page gets
///   one `evaluateJavaScript` per main-thread turn, not one per frame.
///
/// `MessageSocket.send` must never reorder: the per-tab DEFLATE stream and "a WIRE START first" depend
/// on the order `TermWire` sent in.
public final class FrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var scheduled = false
    /// `close()` was called: nothing more is queued, and the close follows what is.
    private var closeQueued = false
    /// A drain has handed the close out — it goes to the page ONCE.
    private var closeTaken = false
    /// The page is gone: nothing is queued or handed out.
    private var discarded = false

    public init() {}

    /// Queue one frame. TRUE when the caller must schedule a flush. Dropped after `close` or `discard`.
    public func append(_ frame: Data) -> Bool {
        lock.withLock {
            guard !closeQueued, !discarded else { return false }
            frames.append(frame)
            return schedule()
        }
    }

    /// Queue the close BEHIND every frame already queued. TRUE when the caller must schedule a flush;
    /// false the second time, and after `discard`.
    public func close() -> Bool {
        lock.withLock {
            guard !closeQueued, !discarded else { return false }
            closeQueued = true
            return schedule()
        }
    }

    /// The page is gone: drop what is queued, the close included, and accept nothing more.
    public func discard() {
        lock.withLock {
            discarded = true
            frames.removeAll()
            closeTaken = true
        }
    }

    /// Everything queued, in order, and whether the close follows it. The next `append` schedules again.
    public func drain() -> (frames: [Data], close: Bool) {
        lock.withLock {
            scheduled = false
            let out = frames
            frames.removeAll()
            let close = closeQueued && !closeTaken
            if close { closeTaken = true }
            return (out, close)
        }
    }

    /// Under `lock`.
    private func schedule() -> Bool {
        if scheduled { return false }
        scheduled = true
        return true
    }
}
