import Foundation
import RdevCore

public enum TmuxCommandError: Error, Equatable {
    /// tmux answered `%error`; the lines are its message.
    case failed([String])
    /// The control client is gone (tmux exited, was killed, or a command timed out).
    case dead
}

/// One `tmux -C attach -t <session>` process — tmux's control mode over plain pipes.
///
/// Commands are written to stdin, and their replies come back as `%begin…%end|%error` blocks IN
/// ORDER, so replies are matched FIFO to commands. Only blocks flagged as ours (flags 1) are matched;
/// the initial attach's block has flags 0.
///
/// Threading: the read loop runs on `readQueue`; `onEvent`, `onExit` and every completion run on
/// `callbackQueue` (serial), never on the caller's thread and never under the caller's lock. A command
/// that gets no reply within its timeout KILLS the process — a hung tmux must not wedge the terminal —
/// and every pending and later command then fails `.dead`.
public final class TmuxControlClient: @unchecked Sendable {
    private let proc: Process
    private let stdin: FileHandle
    private let lock = NSLock()
    /// Serialises register-and-write (see `batch`). Never taken by the read side.
    private let writeLock = NSLock()
    private var pending: [(id: Int, completion: (Result<[String], TmuxCommandError>) -> Void)] = []
    private var nextId = 0
    private var alive = true
    private var killedByTimeout = false
    private let readQueue = DispatchQueue(label: "tmux.read")
    private let callbackQueue = DispatchQueue(label: "tmux.callback")
    private let onEvent: (TmuxEvent) -> Void
    private let onExit: () -> Void
    private let clipboardChanged: ((String) -> Void)?
    /// Marks `callbackQueue` with the client INSTANCE it belongs to.
    private static let queueKey = DispatchSpecificKey<UUID>()
    /// This client's identity (tests: which client's queue an emission ran on).
    let instance = UUID()

    public init?(runner: TmuxRunner, session: String,
                 onEvent: @escaping (TmuxEvent) -> Void, onExit: @escaping () -> Void,
                 clipboardChanged: ((String) -> Void)? = nil) {
        guard TmuxList.isSessionId(session) else { return nil }
        self.onEvent = onEvent
        self.onExit = onExit
        self.clipboardChanged = clipboardChanged
        callbackQueue.setSpecific(key: Self.queueKey, value: instance)
        proc = runner.process(["-C", "attach", "-t", session])
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        stdin = inPipe.fileHandleForWriting
        proc.terminationHandler = { [weak self] _ in self?.died() }
        do { try proc.run() } catch { return nil }
        let reader = outPipe.fileHandleForReading
        readQueue.async { [weak self] in
            var parser = TmuxControlParser()
            Self.readChunks(from: reader) { d in
                // Merged per read: a redraw is one message, not one per line.
                let events = TmuxEvent.coalesced(parser.feed([UInt8](d)))
                guard let self else { return false }
                self.dispatch(events)
                return true
            }
        }
    }

    /// Reads `reader` until EOF (or until `chunk` returns false), each read in its OWN autorelease pool.
    /// The read loop is one GCD block that never returns while the client lives, and GCD drains a
    /// queue's pool only when a block ends — while `availableData` hands back an AUTORELEASED NSData.
    /// Without the pool every chunk tmux ever sent stayed alive until the client exited: measured
    /// 2026-10-13, the app at 46 GB with no client connected — 19,062 NSConcreteData of 16 KB after nine
    /// minutes of six tmux tabs running agents, ~30–40 MB a minute; replaced clients gave it back.
    static func readChunks(from reader: FileHandle, _ chunk: (Data) -> Bool) {
        while true {
            let more: Bool = autoreleasepool {
                let d = reader.availableData
                return !d.isEmpty && chunk(d)
            }
            if !more { return }
        }
    }

    public func command(_ cmd: String, timeout: TimeInterval = 5,
                        completion: @escaping (Result<[String], TmuxCommandError>) -> Void) {
        batch([cmd], timeout: timeout) { completion($0[0]) }
    }

    /// Several commands in ONE write: tmux runs lines it reads together in one pass, so nothing a pane
    /// prints lands between them (an attach's cursor and screen agree). One result per command, in
    /// order, delivered together once the last has answered.
    ///
    /// Registering and writing happen under `writeLock` as ONE step. Commands come from several threads
    /// (the peer dispatcher, this client's own callback queue), and replies are matched FIFO: a caller
    /// that registered first but wrote second would receive the other caller's reply. The lock also
    /// keeps two large writes (over PIPE_BUF) from interleaving inside a line. `dispatch` takes only
    /// `lock`, never `writeLock`, so a write blocked on a full pipe cannot stop replies being read.
    public func batch(_ cmds: [String], timeout: TimeInterval = 5,
                      completion: @escaping ([Result<[String], TmuxCommandError>]) -> Void) {
        guard !cmds.isEmpty else { callbackQueue.async { completion([]) }; return }
        let collector = BatchCollector(count: cmds.count, completion: completion)
        writeLock.lock()
        lock.lock()
        guard alive else {
            lock.unlock(); writeLock.unlock()
            callbackQueue.async { collector.fail() }
            return
        }
        let first = nextId
        for i in cmds.indices { pending.append((first + i, { collector.set(i, $0) })) }
        nextId += cmds.count
        lock.unlock()
        let line = cmds.map { $0 + "\n" }.joined()
        // The throwing form: a closed pipe becomes an error here instead of an exception.
        do { try stdin.write(contentsOf: Data(line.utf8)) } catch { proc.terminate() }
        writeLock.unlock()
        let last = first + cmds.count - 1
        callbackQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stillPending = self.pending.contains { $0.id == last }; self.lock.unlock()
            if stillPending {
                print("[tmux] no reply in \(timeout)s, killing the control client: \(cmds.first ?? "")")
                self.lock.lock(); self.killedByTimeout = true; self.lock.unlock()
                self.proc.terminate()
            }
        }
    }

    /// A command's timeout killed this client (as opposed to tmux exiting, or `stop`). Set BEFORE the
    /// kill, so every `.dead` it causes reads it true.
    public var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return killedByTimeout }

    /// Runs `work` on the callback queue — AFTER every event and reply already dispatched to it, and
    /// before any dispatched later — and waits for it. Inline when already on THIS client's queue. The
    /// caller must hold no lock a callback takes (every callback may take the owner's lock).
    public func onCallbackQueue(_ work: () -> Void) {
        if Self.currentCallbackQueueInstance == instance { work(); return }
        callbackQueue.sync(execute: work)
    }

    /// Like `onCallbackQueue`, without waiting — for a caller that may itself be on ANOTHER client's
    /// callback queue (two queues each waiting on the other would deadlock).
    public func asyncOnCallbackQueue(_ work: @escaping @Sendable () -> Void) {
        callbackQueue.async(execute: work)
    }

    /// The client INSTANCE whose callback queue the caller is running on, or nil (tests: the probe that
    /// every emission for a tmux tab is made in order with ITS OWN client's control stream — a replaced
    /// client of the same session does not count).
    static var currentCallbackQueueInstance: UUID? { DispatchQueue.getSpecific(key: queueKey) }

    /// Detach. Closing stdin makes tmux end the control client cleanly — the SESSION keeps running.
    /// SIGTERM after a second is the fallback.
    public func stop() {
        try? stdin.close()
        let p = proc
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } }
    }

    private func dispatch(_ events: [TmuxEvent]) {
        for e in events {
            // Capture recipient identity when the notification is READ, before a blocked callback queue
            // can carry an old copy into a new ownership generation. This callback must only enqueue IO.
            if case .pasteBufferChanged(let name) = e, let clipboardChanged { clipboardChanged(name); continue }
            if case .reply(let ok, let fromUs, let lines) = e {
                guard fromUs else { continue }
                lock.lock()
                let first = pending.isEmpty ? nil : pending.removeFirst()
                lock.unlock()
                if let first { callbackQueue.async { first.completion(ok ? .success(lines) : .failure(.failed(lines))) } }
            } else {
                callbackQueue.async { [onEvent] in onEvent(e) }
            }
        }
    }

    private func died() {
        lock.lock()
        guard alive else { lock.unlock(); return }
        alive = false
        let drained = pending
        pending = []
        lock.unlock()
        callbackQueue.async { [onExit] in
            for p in drained { p.completion(.failure(.dead)) }
            onExit()
        }
    }
}

/// Collects one batch's results; calls back once, when the last arrives. Every call is on the client's
/// serial callback queue, so it needs no lock of its own.
private final class BatchCollector: @unchecked Sendable {
    private var results: [Result<[String], TmuxCommandError>?]
    private var remaining: Int
    private let completion: ([Result<[String], TmuxCommandError>]) -> Void

    init(count: Int, completion: @escaping ([Result<[String], TmuxCommandError>]) -> Void) {
        results = Array(repeating: nil, count: count); remaining = count; self.completion = completion
    }

    func set(_ i: Int, _ r: Result<[String], TmuxCommandError>) {
        guard results[i] == nil else { return }
        results[i] = r
        remaining -= 1
        if remaining == 0 { completion(results.map { $0! }) }
    }

    func fail() { for i in results.indices { set(i, .failure(.dead)) } }
}
