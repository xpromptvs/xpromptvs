import Foundation
import RdevCore

/// The serializer's byte-stream corpus (protocol/fixtures/term-corpus, written by
/// scripts/gen_term_corpus.py) and what the emitter makes of each case. Shared by the fixture writer
/// (//tools/TermSnapshotFixtures) and the freshness test, so the two can never compute it differently.
///
/// TEST-ONLY: it lives in the `testonly` target //host/RdevCore:RdevTermCorpus, never in RdevCore,
/// so fixture-writing code cannot reach the product (Bazel refuses a non-testonly dependency on it).
public enum TermCorpus {
    public struct Case: Decodable, Equatable, Sendable {
        public let name: String
        public let cols: Int
        public let rows: Int
    }

    public static func cases(in dir: URL) throws -> [Case] {
        try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
    }

    public static func stream(_ c: Case, in dir: URL) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: dir.appendingPathComponent("\(c.name).bin")))
    }

    public static func snapshot(_ c: Case, stream: [UInt8]) -> TermSnapshot {
        let t = Terminal(cols: c.cols, rows: c.rows)
        _ = t.feed(stream)
        return t.snapshot()
    }

    public static func emitted(_ c: Case, stream: [UInt8]) -> [UInt8] {
        TermSnapshotEmitter.emit(snapshot(c, stream: stream))
    }

    /// A Swift-encoded frame sequence exercising every kind, chunking, two tabs, a context reset and a
    /// second wire (a wire start mid-stream: every context is gone), and what it decodes to — and a SCREEN snapshot
    /// whose late history arrives, chunked, between its tab's live output (docs/terminal.md, "Scrollback comes after
    /// the screen"), its full text listed under "<tab>#history". The TypeScript router decodes the same file
    /// (web/test/term-stream.test.ts).
    public static func wireFixture() -> (bin: Data, expected: Data) {
        let e = TermFixtureEncoder(maxMessageBytes: 512)
        let size = TermGridSize(cols: 80, rows: 24)
        var frames: [Data] = e.start()
        let big = (0..<1000).map { "row \($0) of the long output\r\n" }.joined()
        frames += e.snapshot(.pty(1), size: size, bytes: Array("hello\r\n".utf8))
        frames += e.output(.pty(1), Array("a\r\n".utf8))
        frames += e.output(.pty(1), Array(big.utf8))
        frames += e.snapshot(.tmux("$2"), size: TermGridSize(cols: 100, rows: 30), bytes: Array("tmux snapshot".utf8))
        frames += e.output(.pty(1), Array("b".utf8))
        frames += e.output(.tmux("$2"), Array(" + live".utf8))
        frames += e.snapshot(.pty(1), size: size, bytes: Array("second snapshot".utf8))
        frames += e.output(.pty(1), Array(" after".utf8))
        let history = (0..<300).map { "history line \($0)\r\n" }.joined() + "pty3 screen"
        frames += e.snapshot(.pty(3), size: size, bytes: Array("pty3 screen".utf8), historyFollows: true)
        frames += e.output(.pty(3), Array(" live1".utf8))
        frames += e.history(.pty(3), size: size, bytes: Array(history.utf8))
        frames += e.output(.pty(3), Array(" live2".utf8))
        frames += e.closed(.tmux("$2"))
        let e2 = TermFixtureEncoder(maxMessageBytes: 512, epoch: 2)
        frames += e2.start()
        frames += e2.snapshot(.pty(1), size: size, bytes: Array("second wire".utf8))
        var bin = Data()
        for f in frames {
            let n = UInt32(f.count)
            bin.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            bin.append(f)
        }
        let expected: [String: Any] = [
            "generations": ["pty:1": ["hello\r\na\r\n" + big + "b", "second snapshot after", "second wire"], "tmux:$2": ["tmux snapshot + live"],
                            "pty:3": ["pty3 screen live1 live2"], "pty:3#history": [history]],
            "closed": ["tmux:$2"],
        ]
        let json = try! JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys])
        return (bin, json)
    }
}
