import Foundation
import RdevCore

/// What the terminal produces for the driver, per tab and in order. TerminalManager emits these on the
/// tab's SERIAL PATH — a `pty:` tab's `serial` lock, a `tmux:` tab's control-client callback queue —
/// so a tab's snapshot sits at an exact position in its stream and its live bytes follow it.
public enum TermEmission: Sendable {
    case output(TermTabID, [UInt8])
    case snapshot(TermTabID, TermGridSize, [UInt8])
    /// A snapshot of the SCREEN alone — a new generation, exactly as `.snapshot` — whose `.history` follows.
    case screen(TermTabID, TermGridSize, [UInt8])
    /// The FULL snapshot taken at the same moment as the `.screen` before it (docs/terminal.md, "Scrollback comes
    /// after the screen"): sent in the pacer's history lane, behind what the person is waiting for.
    case history(TermTabID, TermGridSize, [UInt8])
    case closed(TermTabID)
}


/// One driver wire owns a shared compressor and a raw-record scheduler. The tab
/// registry controls query ownership; tab snapshots do not reset compression.
final class TermWire: @unchecked Sendable {
    static let frameBytes = 8 * 1024
    let epoch: UInt64
    private let lock = NSLock()
    private let pacer: SharedTermPacer
    private let messageCeiling: Int
    private var tabs: Set<TermTabID> = []
    private var retired = false

    init(epoch: UInt64, messageCeiling: Int, pacer: SharedTermPacer) {
        self.epoch = epoch; self.messageCeiling = messageCeiling; self.pacer = pacer
    }

    /// An unbuffered transport, used by standalone wire tests.
    convenience init(epoch: UInt64 = 1, messageCeiling: Int = TermWire.frameBytes,
                     maximumBytes: Int = 64 * 1024 * 1024,
                     deliver: @escaping @Sendable (Data) -> Void,
                     failed: @escaping @Sendable (SharedTermPacer.Failure) -> Void = { _ in }) {
        let p = SharedTermPacer(path: TermPath(), deps: .init(send: deliver,
            buffered: { 0 }, now: { DispatchTime.now().uptimeNanoseconds },
            schedule: TerminalManager.strictTimer, activeTab: { nil }),
            epoch: epoch, messageCeiling: messageCeiling, maximumBytes: maximumBytes, failed: failed)
        self.init(epoch: epoch, messageCeiling: messageCeiling, pacer: p)
    }

    func begin() { lock.lock(); defer { lock.unlock() }; if !retired { pacer.begin() } }

    /// The hub retires the old wire before publishing its replacement. This waits
    /// for an in-flight emission/drain, so no old message follows retirement.
    func retire() {
        lock.lock(); defer { lock.unlock() }
        retired = true; tabs.removeAll(); pacer.retire()
    }

    @discardableResult
    func emit(_ emission: TermEmission) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { return false }
        let tab: TermTabID
        let bytes: [UInt8]
        let size: TermGridSize?
        let kinds: (TermFrameKind, TermFrameKind)
        let lane: SharedTermPacer.Lane
        switch emission {
        case .output(let id, let b):
            guard tabs.contains(id), !b.isEmpty else { return false }
            tab = id; bytes = b; size = nil; kinds = (.output,.output); lane = .regular
        case .snapshot(let id, let grid, let b):
            tab = id; bytes = b; size = grid; kinds = (.snapshotChunk,.snapshotEnd); lane = .snapshot
        case .screen(let id, let grid, let b):
            tab = id; bytes = b; size = grid; kinds = (.screenChunk,.screenEnd); lane = .snapshot
        case .history(let id, let grid, let b):
            guard tabs.contains(id), !b.isEmpty else { return false }
            tab = id; bytes = b; size = grid; kinds = (.historyChunk,.historyEnd); lane = .history
        case .closed(let id):
            tab = id; bytes = []; size = nil; kinds = (.closed,.closed); lane = .closed
        }
        let name = tab.wire, idBytes = name.utf8.count
        let room = messageCeiling - 128 - 2 - idBytes - (size == nil ? 0 : 4)
        guard idBytes > 0, idBytes <= 255, room > 0 else { return false }
        let count = max(1, bytes.count / room + (bytes.count % room == 0 ? 0 : 1))
        let result = pacer.admit(tab: name, lane: lane, rawBytes: bytes.count + idBytes, recordCount: count) {
            TermRawBatch(tab: name, size: size, bytes: bytes, kinds: kinds, messageCeiling: messageCeiling)
        }
        guard result == .accepted else { return false }
        if lane == .snapshot { tabs.insert(tab) }
        if lane == .closed { tabs.remove(tab) }
        return true
    }
}

/// The 1 s hold on a hidden page's terminal pause (docs/terminal.md, "Hidden page"). The client sends
/// `terminal-pause` the moment it is hidden — iOS may suspend the page before any client-side timer
/// fires — and the pause APPLIES only if no `terminal-resume` arrives within `delay`. A resume after an
/// applied pause lifts it (every tab re-serialized); one inside the hold changes nothing. All state
/// lives on ONE serial queue, so a pause firing and a resume arriving cannot interleave.
///
/// Every pause and resume names its SENDER — the connection it came from — and is dropped ON THE QUEUE
/// unless that is the driver's connection (`owner`, read there, live). The hub checks the sender is the
/// driver on the message thread and then queues; a claim's `reset` landing between the two (final
/// review M3) would otherwise let the OLD driver's pause apply to the NEW driver, whose page is visible
/// and asked for nothing — and a rebuilt driver's dead connection could still pause its new one.
final class TerminalPauseGate: @unchecked Sendable {
    private let queue = DispatchQueue(label: "term.pause")
    private let delay: DispatchTimeInterval
    private let apply: () -> Void
    private let lift: () -> Void
    private let clear: () -> Void
    private var generation = 0
    private var paused = false
    /// The driver's connection now. Called on `queue`; it may take the hub's lock (nothing holding
    /// that lock ever waits on `queue`).
    private let owner: () -> AnyHashable?

    init(delay: DispatchTimeInterval = .milliseconds(1000), owner: @escaping () -> AnyHashable?,
         apply: @escaping () -> Void, lift: @escaping () -> Void, clear: @escaping () -> Void) {
        self.delay = delay; self.owner = owner; self.apply = apply; self.lift = lift; self.clear = clear
    }

    func pause(from sender: AnyHashable?) {
        queue.async {
            guard sender == self.owner() else { return }
            self.generation += 1
            let g = self.generation
            self.queue.asyncAfter(deadline: .now() + self.delay) {
                guard g == self.generation, !self.paused else { return }
                self.paused = true
                self.apply()
            }
        }
    }

    func resume(from sender: AnyHashable?) {
        queue.async {
            guard sender == self.owner() else { return }
            self.generation += 1
            guard self.paused else { return }
            self.paused = false
            self.lift()
        }
    }

    /// The driver changed, or its connection was rebuilt: what the old one asked for is void.
    /// SYNCHRONOUS, so the caller's snapshot of every tab for the new driver (or the new connection)
    /// runs after the pause is gone.
    func reset() {
        queue.sync { self.generation += 1; self.paused = false; self.clear() }
    }

    /// Tests: wait for everything queued so far.
    func sync() { queue.sync {} }
}
