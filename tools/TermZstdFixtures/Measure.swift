import Foundation
import Darwin
import Zstd

// Test-only level comparison. Input is the actual scheduled raw record order captured by an E2E probe.
func measure(_ path: String) throws {
    let encoded = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let records = encoded.map { Data(base64Encoded: $0)! }
    for level: Int32 in [3, 6] {
        let c = ZSTD_createCCtx()!
        defer { ZSTD_freeCCtx(c) }
        for (parameter, value) in [(ZSTD_c_compressionLevel, level), (ZSTD_c_windowLog, Int32(17)), (ZSTD_c_nbWorkers, Int32(0))] {
            precondition(ZSTD_isError(ZSTD_CCtx_setParameter(c, parameter, value)) == 0)
        }
        var samples: [Double] = [], wireBytes = 0, rawBytes = 0
        let cpu = clock()
        for (i, raw) in ([Data(0..<32)] + records).enumerated() {
            var out = Data(count: ZSTD_compressBound(raw.count) + 128)
            let started = DispatchTime.now().uptimeNanoseconds
            let count = raw.withUnsafeBytes { input in out.withUnsafeMutableBytes { output in
                var source = ZSTD_inBuffer(src: input.baseAddress, size: input.count, pos: 0)
                var target = ZSTD_outBuffer(dst: output.baseAddress, size: output.count, pos: 0)
                while true {
                    let n = ZSTD_compressStream2(c, &target, &source, ZSTD_e_flush)
                    precondition(ZSTD_isError(n) == 0)
                    if n == 0 { return target.pos }
                    precondition(target.pos < target.size)
                }
            } }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
            wireBytes += count + (i == 0 ? 13 : 25); rawBytes += raw.count
        }
        let cpuMs = Double(clock() - cpu) / Double(CLOCKS_PER_SEC) * 1000
        samples.sort()
        let result: [String: Any] = ["level": level, "records": records.count, "rawBytes": rawBytes,
            "wireBytes": wireBytes, "cpuMs": cpuMs, "flushP95Ms": samples[Int(Double(samples.count - 1) * 0.95)],
            "contextBytes": ZSTD_sizeof_CCtx(c)]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
