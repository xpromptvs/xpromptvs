import Foundation
import RdevTermCorpus
import RdevCore

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--measure" {
    try measure(CommandLine.arguments[2])
    exit(0)
}

guard CommandLine.arguments.count == 2 else {
    fatalError("usage: TermZstdFixtures /absolute/path/to/term-zstd-wire.json")
}
try TermZstdVectors.json().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

let encoder = try TermZstdEncoder()
_ = try encoder.flush(Data(0..<32))
print("Warmed terminal encoder: \(encoder.allocatedBytes) bytes")
