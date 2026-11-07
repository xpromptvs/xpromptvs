import Foundation

public struct ByteWriter {
    public private(set) var data = Data()
    public init() {}
    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
    public mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
}

public struct ByteReader {
    private let b: [UInt8]
    private var i = 0
    public init(_ data: Data) { b = [UInt8](data) }
    public init(_ bytes: [UInt8]) { b = bytes }
    public var remaining: Int { b.count - i }
    public mutating func u8() -> UInt8 { defer { i += 1 }; return b[i] }
    public mutating func u16() -> UInt16 { let v = UInt16(b[i]) | (UInt16(b[i + 1]) << 8); i += 2; return v }
    public mutating func u32() -> UInt32 {
        let v = UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
        i += 4; return v
    }
    public mutating func take(_ n: Int) -> [UInt8] { defer { i += n }; return Array(b[i..<i + n]) }
}
