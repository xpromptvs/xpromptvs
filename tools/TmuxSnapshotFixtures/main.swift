import Foundation
import RdevCore
import RdevTmuxRig

// Usage: TmuxSnapshotFixtures <repo>/protocol/fixtures
// Without an argument, `bazelisk run` supplies BUILD_WORKSPACE_DIRECTORY.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("TmuxSnapshotFixtures: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
let root: URL = args.count > 1
    ? URL(fileURLWithPath: args[1])
    : URL(fileURLWithPath: ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] ?? ".")
        .appendingPathComponent("protocol/fixtures")
let out = root.appendingPathComponent("tmux-snapshot")
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("term-corpus/manifest.json").path) else {
    fail("\(root.path) is not protocol/fixtures (no term-corpus/manifest.json)")
}

// A PRIVATE server under a name nothing else uses, stopped (killed, socket file removed) on every way
// out this process controls — a signal included. A crash leaves it to exit on its own (PrivateTmux).
let socket = "rdev-tsf-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
let tmux: PrivateTmux
do {
    guard let t = try PrivateTmux(socket: socket) else { fail("tmux is not installed") }
    tmux = t
} catch {
    fail("\(error)")
}
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    s.setEventHandler { tmux.stop(); exit(128 + sig) }
    s.resume()
    signalSources.append(s)
}

func generate() throws -> Int {
    // The glyph model was measured on ONE tmux (protocol/fixtures/tmux-glyphs.json): fixtures from any
    // other would hold the client to a tmux the model does not describe.
    let version = tmux.run(["-V"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard version == "tmux \(TmuxGlyphs.measuredVersion)" else {
        throw PrivateTmux.Failed("\(version) is not the measured tmux \(TmuxGlyphs.measuredVersion) — re-run "
            + "scripts/measure_tmux_glyphs.py against it first (docs/testing-and-gates.md)")
    }
    let cases = try TmuxSnapshotFixtures.cases(fixtures: root)
    guard cases.count == TmuxSnapshotFixtures.caseNames.count else {
        throw PrivateTmux.Failed("the corpus has \(cases.count) of the \(TmuxSnapshotFixtures.caseNames.count) glyph cases")
    }
    var fixtures: [(TmuxSnapshotFixtures.Case, TmuxSnapshotFixtures.Fixture)] = []
    for c in cases { fixtures.append((c, try TmuxSnapshotFixtures.fixture(c, fixtures: root, tmux: tmux))) }
    // Every capture first, then the writes: a failure leaves the committed set whole.
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for old in try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
    where old.lastPathComponent.hasSuffix(".emitted.bin") || old.lastPathComponent.hasSuffix(".cursor.json") {
        try FileManager.default.removeItem(at: old)
    }
    for (c, f) in fixtures {
        try Data(f.emitted).write(to: out.appendingPathComponent("\(c.name).emitted.bin"))
        try f.cursor.write(to: out.appendingPathComponent("\(c.name).cursor.json"))
    }
    return fixtures.count
}

do {
    let written = try generate()
    tmux.stop()
    print("wrote \(written) tmux snapshot fixtures to \(out.path) (private tmux -L \(socket), stopped)")
} catch {
    tmux.stop()
    fail("\(error)")
}
