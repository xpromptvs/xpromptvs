import Foundation

/// RZT1 is deliberately incompatible with the old per-tab terminal wire.
public enum TermWireMessage: Equatable, Sendable {
    case start(epoch: UInt64, compressed: Data)
    case data(epoch: UInt64, sequence: UInt64, rawLength: UInt32, compressed: Data)
    public enum Failure: Error { case malformed }
    public static let maximumBytes = 60 * 1024

    public func encoded() -> Data {
        var out = Data([82, 90, 84, 49])
        switch self {
        case let .start(epoch, compressed):
            out.append(0); Self.append(epoch, to: &out); out.append(compressed)
        case let .data(epoch, sequence, rawLength, compressed):
            out.append(1); Self.append(epoch, to: &out); Self.append(sequence, to: &out)
            Self.append(rawLength, to: &out); out.append(compressed)
        }
        return out
    }

    public static func decode(_ bytes: Data) throws -> TermWireMessage {
        guard bytes.count >= 14, bytes.count <= maximumBytes else { throw Failure.malformed }
        let b = [UInt8](bytes)
        guard b[0..<4].elementsEqual([82,90,84,49]), b[4] <= 1 else { throw Failure.malformed }
        let epoch = read(b, at: 5, count: 8)
        guard epoch != 0 else { throw Failure.malformed }
        if b[4] == 0 { return .start(epoch: epoch, compressed: Data(b[13...])) }
        guard b.count > 25 else { throw Failure.malformed }
        let sequence = read(b, at: 13, count: 8)
        let size = read(b, at: 21, count: 4)
        guard size >= 2, size <= UInt64(maximumBytes - 128) else { throw Failure.malformed }
        return .data(epoch: epoch, sequence: sequence, rawLength: UInt32(size), compressed: Data(b[25...]))
    }

    private static func append<T: FixedWidthInteger>(_ n: T, to data: inout Data) {
        var value = n.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    private static func read(_ b: [UInt8], at start: Int, count: Int) -> UInt64 {
        b[start..<(start + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
