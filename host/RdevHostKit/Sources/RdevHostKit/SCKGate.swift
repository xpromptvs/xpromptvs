import Foundation

/// **A PREVIEW SCREENSHOT AND A CAPTURE START NEVER OVERLAP** (2026-10-07: "if I press on a window to stream it before its
/// preview loads in the palette, sharing doesn't work"). Two ScreenCaptureKit captures on one application share its
/// connection, and one STOPPING while another STARTS kills the starting one with `-3805` (docs/sources-and-focus.md —
/// measured on a codec switch). A palette's previews are a batch of one-shot screenshots, each a capture that starts and
/// stops; a window picked before they finish started its stream among them.
///
/// Two kinds share the gate: any number of `still`s (`SourceThumbnailer`) together, or any number of `start`s
/// (`ScreenCaptureSource`) together — never one of each. FIFO across kinds: once a waiter of the other kind is queued,
/// newcomers of the running kind queue behind it, so a long preview batch cannot starve a pick, nor a pick the previews.
public actor SCKGate {
    public enum Kind: Sendable { case still, start }

    public static let shared = SCKGate()

    private var running: Kind?
    private var holders = 0
    private var queue: [(kind: Kind, resume: CheckedContinuation<Void, Never>)] = []

    public init() {}

    /// Run `body` holding the gate as `kind`.
    public func run<T: Sendable>(_ kind: Kind, _ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(kind)
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    /// Hold the gate as `kind` until `leave()` — for a caller whose result is not `Sendable` (an `SCStream`).
    public func enter(_ kind: Kind) async { await acquire(kind) }
    public func leave() { release() }

    private func acquire(_ kind: Kind) async {
        if queue.isEmpty, running == nil || running == kind {
            running = kind
            holders += 1
            return
        }
        await withCheckedContinuation { queue.append((kind, $0)) }
    }

    private func release() {
        holders -= 1
        guard holders == 0 else { return }
        running = nil
        // Admit the head of the queue and every waiter of its kind right behind it.
        guard let head = queue.first else { return }
        running = head.kind
        while let next = queue.first, next.kind == head.kind {
            queue.removeFirst()
            holders += 1
            next.resume.resume()
        }
    }

    /// Tests: who holds the gate now.
    public var state: (kind: Kind?, holders: Int, waiting: Int) { (running, holders, queue.count) }
}
