import Foundation
import Zstd

/// Test-only native receiver for byte-exact host codec and pacing checks.
public final class TermZstdInflater {
    public enum Failure: Error { case allocation, invalid, outputBound }
    private let context: OpaquePointer
    public init() throws {
        guard let c = ZSTD_createDCtx() else { throw Failure.allocation }
        guard ZSTD_isError(ZSTD_DCtx_setParameter(c, ZSTD_d_windowLogMax, 17)) == 0 else {
            ZSTD_freeDCtx(c); throw Failure.invalid
        }
        context = c
    }
    deinit { ZSTD_freeDCtx(context) }
    public func push(_ bytes: Data, maximumOutput: Int) throws -> Data {
        guard maximumOutput >= 0, maximumOutput < Int.max else { throw Failure.outputBound }
        let capacity = maximumOutput + 1
        var output = Data(count: capacity)
        let count = try bytes.withUnsafeBytes { input in
            try output.withUnsafeMutableBytes { out in
                var source = ZSTD_inBuffer(src: input.baseAddress, size: input.count, pos: 0)
                var target = ZSTD_outBuffer(dst: out.baseAddress, size: capacity, pos: 0)
                repeat {
                    let before = source.pos
                    let result = ZSTD_decompressStream(context, &target, &source)
                    guard ZSTD_isError(result) == 0, result != 0 else { throw Failure.invalid }
                    guard target.pos <= maximumOutput else { throw Failure.outputBound }
                    guard source.pos != before || source.pos == source.size else { throw Failure.invalid }
                } while source.pos < source.size
                return target.pos
            }
        }
        output.count = count
        return output
    }
}
