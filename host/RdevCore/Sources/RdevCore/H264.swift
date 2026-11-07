import Foundation

/// Pure H.264 bitstream helpers. VideoToolbox emits length-prefixed AVCC; pion's RTP
/// payloader wants start-code-delimited Annex-B. Kept in RdevCore so it is unit-testable.
public enum H264 {
    public static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Convert an AVCC buffer (each NAL prefixed by an `nalLengthSize`-byte big-endian length)
    /// to Annex-B (each NAL prefixed by a 4-byte start code). Returns `[]` on malformed input.
    public static func avccToAnnexB(_ avcc: [UInt8], nalLengthSize: Int) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        let n = avcc.count
        while i + nalLengthSize <= n {
            var len = 0
            for _ in 0 ..< nalLengthSize { len = (len << 8) | Int(avcc[i]); i += 1 }
            guard len > 0, i + len <= n else { return [] }
            out.append(contentsOf: startCode)
            out.append(contentsOf: avcc[i ..< i + len])
            i += len
        }
        return i == n ? out : []
    }

    /// Concatenate parameter sets (SPS, PPS, …), each prefixed by a start code.
    public static func annexBParameterSets(_ sets: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for s in sets { out.append(contentsOf: startCode); out.append(contentsOf: s) }
        return out
    }
}
