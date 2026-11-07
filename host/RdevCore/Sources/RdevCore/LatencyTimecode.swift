// host/RdevCore/Sources/RdevCore/LatencyTimecode.swift

/// Shared host(encode)↔browser(decode) contract for the glass-to-glass latency probe.
/// A frame is stamped with the low 32 bits of a wall-clock epoch-millisecond value, drawn as
/// `bitCount` high-contrast black/white cells (MSB first) preceded by a white start-guard cell.
/// The browser samples the same cells, reconstructs the value, and computes
/// glass-to-glass = (nowLow32 − stampLow32) mod 2^32 ms. The 32-bit window wraps every ~49.7 days,
/// which is irrelevant for sub-second latency deltas.
public enum LatencyTimecode {
    public static let bitCount = 32

    /// MSB-first bits of `value`.
    public static func encode(_ value: UInt32) -> [Bool] {
        (0 ..< bitCount).map { i in
            let shift = UInt32(bitCount - 1 - i)
            return (value >> shift) & 1 == 1
        }
    }

    /// MSB-first bits → value. Short input zero-pads the low bits; extra bits are ignored.
    public static func decode(_ bits: [Bool]) -> UInt32 {
        var v: UInt32 = 0
        for i in 0 ..< bitCount {
            v <<= 1
            if i < bits.count && bits[i] { v |= 1 }
        }
        return v
    }
}
