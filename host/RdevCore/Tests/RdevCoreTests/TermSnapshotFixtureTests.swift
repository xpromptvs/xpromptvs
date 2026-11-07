import XCTest
@testable import RdevCore
import RdevTermCorpus

/// The committed emitter output (protocol/fixtures/term-snapshot/*.emitted.bin) is what the xterm.js
/// differential check replays. A Swift change that alters the emitter or the capture without
/// regenerating them would leave that check measuring the OLD code — this test refuses that.
/// Regenerate: bazelisk run //tools/TermSnapshotFixtures -- "$PWD/protocol/fixtures"
final class TermSnapshotFixtureTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures")
    private var corpus: URL { Self.fixtures.appendingPathComponent("term-corpus") }

    /// The exact count scripts/gen_term_corpus.py writes: a manifest that lost cases is not "fewer
    /// cases passed", it is coverage that silently went away. Update it with the generator.
    func testTheCorpusIsComplete() throws {
        XCTAssertEqual(try TermCorpus.cases(in: corpus).count, 34)
    }

    func testEmittedFixturesAreFresh() throws {
        for c in try TermCorpus.cases(in: corpus) {
            let want = TermCorpus.emitted(c, stream: try TermCorpus.stream(c, in: corpus))
            let url = Self.fixtures.appendingPathComponent("term-snapshot/\(c.name).emitted.bin")
            let have = [UInt8]((try? Data(contentsOf: url)) ?? Data())
            XCTAssertEqual(have, want, "\(c.name).emitted.bin is stale — run: bazelisk run //tools/TermSnapshotFixtures -- \"$PWD/protocol/fixtures\"")
        }
    }

    /// The Swift half of the fidelity property, over the whole corpus.
    func testEveryCorpusCaseRoundTripsThroughSwiftTerm() throws {
        for c in try TermCorpus.cases(in: corpus) {
            let a = TermCorpus.snapshot(c, stream: try TermCorpus.stream(c, in: corpus))
            let t = Terminal(cols: c.cols, rows: c.rows)
            _ = t.feed(TermSnapshotEmitter.emit(a))
            var b = t.snapshot(); b.title = a.title
            XCTAssertEqual(b, a, "\(c.name) did not round-trip through SwiftTerm")
        }
    }
}
