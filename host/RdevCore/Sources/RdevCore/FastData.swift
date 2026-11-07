import Foundation

/// Application framing; no socket, encryption or media dependencies.
public enum FastData {
    public enum Kind: UInt8, Sendable { case data = 1, ack = 2, probe = 3, probeReply = 4 }
    public struct Record: Equatable, Sendable {
        public let kind: Kind
        public let generation: Data
        public let stream: UInt8
        public let value: UInt64
        public let bytes: Data
        public init(kind: Kind, generation: Data, stream: UInt8, value: UInt64, bytes: Data = Data()) {
            self.kind = kind; self.generation = generation; self.stream = stream; self.value = value; self.bytes = bytes
        }
    }
    public enum Invalid: Error { case record }
    public static let recordMax = 8192
    public static func encode(_ r: Record) throws -> Data {
        guard r.generation.count == 16, r.stream <= 2,
              r.kind == .data ? (1...recordMax).contains(r.bytes.count) : r.bytes.isEmpty else { throw Invalid.record }
        var out = Data([1, r.kind.rawValue]); out.append(r.generation); out.append(r.stream)
        for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: r.value >> shift)) }
        if r.kind == .data { out.append(UInt8(r.bytes.count >> 8)); out.append(UInt8(truncatingIfNeeded: r.bytes.count)); out.append(r.bytes) }
        return out
    }
    public static func decode(_ data: Data) -> Record? {
        // Normalize Data slice indices before indexing untrusted bytes.
        let b = [UInt8](data)
        guard b.count >= 27, b[0] == 1, let kind = Kind(rawValue: b[1]), b[18] <= 2 else { return nil }
        if kind == .data {
            guard b.count >= 30 else { return nil }
            let n = Int(b[27]) << 8 | Int(b[28])
            guard (1...recordMax).contains(n), b.count == 29 + n else { return nil }
        } else if b.count != 27 { return nil }
        let value = b[19..<27].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Record(kind: kind, generation: Data(b[2..<18]), stream: b[18], value: value, bytes: kind == .data ? Data(b[29...]) : Data())
    }
}
