import Foundation
import RdevTermCorpus

// Usage: TermSnapshotFixtures <repo>/protocol/fixtures
// Without an argument, `bazelisk run` supplies BUILD_WORKSPACE_DIRECTORY.
let args = CommandLine.arguments
let root: URL = args.count > 1
    ? URL(fileURLWithPath: args[1])
    : URL(fileURLWithPath: ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] ?? ".")
        .appendingPathComponent("protocol/fixtures")
let corpus = root.appendingPathComponent("term-corpus")
let out = root.appendingPathComponent("term-snapshot")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for old in try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil) where old.pathExtension == "bin" {
    try FileManager.default.removeItem(at: old)
}
var written = 0
for c in try TermCorpus.cases(in: corpus) {
    let bytes = TermCorpus.emitted(c, stream: try TermCorpus.stream(c, in: corpus))
    try Data(bytes).write(to: out.appendingPathComponent("\(c.name).emitted.bin"))
    written += 1
}
print("wrote \(written) emitted fixtures to \(out.path)")

let wire = TermCorpus.wireFixture()
try wire.bin.write(to: root.appendingPathComponent("term-wire.bin"))
try wire.expected.write(to: root.appendingPathComponent("term-wire.json"))
print("wrote term-wire.bin (\(wire.bin.count) bytes) and term-wire.json")

try TermWidthTable.json().write(to: root.appendingPathComponent("term-widths.json"))
print("wrote term-widths.json")
