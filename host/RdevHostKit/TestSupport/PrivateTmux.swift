import Foundation
import RdevCore
import RdevHostKit

/// A PRIVATE tmux server, and a stream's snapshot as the PRODUCT reads it from one — for
/// `TmuxSnapshotAgreementTests` and `//tools/TmuxSnapshotFixtures`, which must produce the committed
/// fixtures (protocol/fixtures/tmux-snapshot/) by the SAME path the test checks them with.
///
/// `-L <socket>` (never `-S`: a path under a long temp directory overflows `sun_path`), and `-f /dev/null`
/// on EVERY command — it matters only to the one that starts the server, so none can read ~/.tmux.conf,
/// whatever the order. `stop()` kills the server and removes its socket file. A crash cannot run it; then
/// the server ends on its own: it keeps tmux's default `exit-empty on`, and every pane (the keeper's too)
/// exits within `paneLifetime`.
public final class PrivateTmux {
    public struct Failed: Error, CustomStringConvertible {
        public let description: String
        public init(_ what: String) { description = what }
    }

    /// Seconds a pane lives; the bound on a crashed run's leftover server.
    public static let paneLifetime = 120

    public let runner: TmuxRunner
    public let socket: String
    private var stopped = false

    /// nil when tmux is not installed. Throws when the server does not start; nothing below may then start
    /// one. The server is created with a `keeper` session and history as deep as the client's before any
    /// measured pane exists.
    public init?(socket: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        precondition(!socket.isEmpty && !socket.contains("/"), "a private server is named by -L, never a path")
        guard let r = TmuxRunner.locate(environment: environment.merging(["RDEV_TMUX_SOCKET": socket]) { $1 }) else { return nil }
        runner = r
        self.socket = socket
        let started = run(["new-session", "-d", "-s", "keeper", "sleep", "\(Self.paneLifetime)", ";",
                           "set-option", "-g", "history-limit", "\(TermSnapshot.historyCap)"])
        guard started.status == 0 else {
            stop()
            throw Failed("the private tmux server did not start (status \(started.status))")
        }
    }

    deinit { stop() }

    /// One command, `-f /dev/null` first, on the private socket (the runner's `-L`).
    @discardableResult
    public func run(_ args: [String]) -> (status: Int32, stdout: String) { runner.run(["-f", "/dev/null"] + args) }

    /// Kills the server and removes its socket file (tmux leaves it behind on `kill-server`). Idempotent.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        _ = run(["kill-server"])
        Self.removeSocket(socket)
    }

    /// The socket FILE a private server named `name` leaves behind.
    public static func removeSocket(_ name: String) {
        guard !name.isEmpty, !name.contains("/") else { return }
        let dir = ProcessInfo.processInfo.environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        try? FileManager.default.removeItem(atPath: "\(dir)/tmux-\(getuid())/\(name)")
    }

    /// What `capture` read: tmux's snapshot as the product builds it, and beside it the pane as tmux
    /// itself prints it — history and screen, attributes, and its cursor — read WITHOUT `TmuxSnapshot`,
    /// so a comparison of two of them does not share its mistakes.
    public struct Capture {
        public let snapshot: TermSnapshot
        public let rawPane: String
        /// The batch's server width options and version (the product reads the same replies).
        public let glyphs: TmuxGlyphOptions
        public let version: String
    }

    /// `bytes` into a fresh `cols × rows` pane (raw tty, `cat`), then `TmuxSnapshot` built from the
    /// product's batch over a control client.
    public func capture(_ bytes: [UInt8], cols: Int, rows: Int, name: String) throws -> Capture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rdev-tsa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("stream.bin")
        try Data(bytes).write(to: file)
        let channel = "rdev-tsa-done-\(UUID().uuidString)"
        let signal = ([runner.path] + runner.socketArgs + ["-f", "/dev/null", "wait-for", "-S", channel]).map { "'\($0)'" }.joined(separator: " ")
        let sid = run(["new-session", "-d", "-x", "\(cols)", "-y", "\(rows)", "-P", "-F", "#{session_id}",
                       "sh", "-c", "stty raw -echo; cat '\(file.path)'; \(signal); exec sleep \(Self.paneLifetime)"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sid.hasPrefix("$") else { throw Failed("\(name): new-session printed \(sid.debugDescription)") }
        defer { run(["kill-session", "-t", sid]) }
        guard run(["wait-for", channel]).status == 0 else { throw Failed("\(name): the pane did not finish its cat") }
        // `cat` has exited, but tmux reads the pane asynchronously: wait for two identical looks.
        var last = ""
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let look = run(["capture-pane", "-p", "-e", "-t", sid]).stdout
                + run(["display", "-p", "-t", sid, TmuxPaneState.format]).stdout
            if look == last { break }
            last = look
            Thread.sleep(forTimeInterval: 0.1)
        }
        let rawPane = run(["capture-pane", "-p", "-e", "-S", "-", "-E", "-", "-t", sid]).stdout
            + run(["display", "-p", "-t", sid, "#{cursor_x},#{cursor_y},#{history_size}"]).stdout

        guard let client = TmuxControlClient(runner: runner, session: sid, onEvent: { _ in }, onExit: {}) else {
            throw Failed("\(name): no control client")
        }
        defer { client.stop() }
        let done = DispatchSemaphore(value: 0)
        let box = RepliesBox()
        client.batch(TmuxSnapshot.commands(session: sid)) { box.replies = $0; done.signal() }
        guard done.wait(timeout: .now() + 10) == .success else { throw Failed("\(name): the snapshot batch went unanswered") }
        let replies = box.replies
        func lines(_ i: Int) -> [String]? { i < replies.count ? try? replies[i].get() : nil }
        guard let state = lines(0)?.first.flatMap(TmuxPaneState.parse) else { throw Failed("\(name): display") }
        guard let extra = lines(1)?.first.flatMap(TmuxSnapshot.Extra.parse) else { throw Failed("\(name): extra") }
        guard [state.width, state.height] == [cols, rows] else {
            throw Failed("\(name): the control client resized the pane to \(state.width)x\(state.height)")
        }
        guard lines(5).map(TmuxSnapshot.livePanes) != nil else { throw Failed("\(name): the pane list") }
        var tracker = TermModeTracker()
        tracker.feed(bytes)
        let glyphs = TmuxSnapshot.glyphOptions(variationSelectorAlwaysWide: lines(7), codepointWidths: lines(8))
        let snapshot = TmuxSnapshot.build(state: state, extra: extra, history: lines(2) ?? [], screen: lines(3) ?? [],
                                          savedNormal: state.modes.altScreen ? lines(4) : nil,
                                          focusReporting: tracker.modes.focusReporting, glyphs: glyphs)
        return Capture(snapshot: snapshot, rawPane: rawPane, glyphs: glyphs, version: lines(6)?.first ?? "")
    }
}

/// The batch completion writes, `capture` reads after the semaphore — ordered by it.
private final class RepliesBox: @unchecked Sendable { var replies: [Result<[String], TmuxCommandError>] = [] }

/// protocol/fixtures/tmux-snapshot/: for each glyph case of the serializer corpus, tmux's snapshot of
/// its stream, EMITTED (`<case>.emitted.bin`), and tmux's own cursor (`<case>.cursor.json`) —
/// what web/test/term-tmux-fidelity.test.ts replays into the client's tmux provider. Written by
/// `//tools/TmuxSnapshotFixtures`; `TmuxSnapshotAgreementTests.testATmuxTabCountsAsTmuxDoes` holds the
/// committed bytes to what this produces.
public enum TmuxSnapshotFixtures {
    /// The regenerate command every staleness message names.
    public static let regenerate = "bazelisk run //tools/TmuxSnapshotFixtures -- \"$PWD/protocol/fixtures\""

    /// The corpus cases a tmux tab counts as tmux does (TmuxSnapshotAgreementTests.tmuxModelOnly) plus
    /// `emoji-widths`, which both models agree on.
    public static let caseNames: Set<String> = ["emoji-split", "emoji-margin", "emoji-margin-skin-tone", "grapheme-joins", "emoji-widths"]

    public struct Case: Decodable {
        public let name: String
        public let cols: Int
        public let rows: Int
    }

    /// The cases, in manifest order, from `<fixtures>/term-corpus`.
    public static func cases(fixtures: URL) throws -> [Case] {
        let corpus = fixtures.appendingPathComponent("term-corpus")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: corpus.appendingPathComponent("manifest.json")))
            .filter { caseNames.contains($0.name) }
    }

    public struct Fixture {
        /// The original stream's capture (its snapshot, and the pane as tmux prints it).
        public let capture: PrivateTmux.Capture
        /// `<case>.emitted.bin`
        public let emitted: [UInt8]
        /// `<case>.cursor.json`
        public let cursor: Data
    }

    /// The case's stream into a fresh pane of `tmux`, snapshotted, emitted.
    public static func fixture(_ c: Case, fixtures: URL, tmux: PrivateTmux) throws -> Fixture {
        let bytes = [UInt8](try Data(contentsOf: fixtures.appendingPathComponent("term-corpus/\(c.name).bin")))
        let a = try tmux.capture(bytes, cols: c.cols, rows: c.rows, name: c.name)
        let cursor = Data("{\"x\":\(a.snapshot.cursor.x),\"y\":\(a.snapshot.cursor.y)}\n".utf8)
        return Fixture(capture: a, emitted: TermSnapshotEmitter.emit(a.snapshot), cursor: cursor)
    }
}
