import Foundation
import Zstd

/// One ordered wire's compressor. The send stage serializes all access and flushes
/// only after selecting the next record. A flush preserves history; it never ends a frame.
public final class TermZstdEncoder {
    public enum Failure: Error, Equatable { case allocation, codec(String), outputBound }
    private let context: OpaquePointer

    public init() throws {
        guard let c = ZSTD_createCCtx() else { throw Failure.allocation }
        do {
            try Self.check(ZSTD_CCtx_setParameter(c, ZSTD_c_compressionLevel, 6))
            try Self.check(ZSTD_CCtx_setParameter(c, ZSTD_c_windowLog, 17))
            try Self.check(ZSTD_CCtx_setParameter(c, ZSTD_c_nbWorkers, 0))
        } catch {
            ZSTD_freeCCtx(c)
            throw error
        }
        context = c
    }

    deinit { ZSTD_freeCCtx(context) }
    public var allocatedBytes: Int { ZSTD_sizeof_CCtx(context) }

    public func flush(_ bytes: Data) throws -> Data {
        let capacity = ZSTD_compressBound(bytes.count) + 128
        var output = Data(count: capacity)
        let count = try bytes.withUnsafeBytes { input in
            try output.withUnsafeMutableBytes { out in
                var source = ZSTD_inBuffer(src: input.baseAddress, size: input.count, pos: 0)
                var target = ZSTD_outBuffer(dst: out.baseAddress, size: capacity, pos: 0)
                while true {
                    let remaining = ZSTD_compressStream2(context, &target, &source, ZSTD_e_flush)
                    try Self.check(remaining)
                    if remaining == 0 { return target.pos }
                    guard target.pos < target.size else { throw Failure.outputBound }
                }
            }
        }
        output.count = count
        return output
    }

    private static func check(_ code: Int) throws {
        if ZSTD_isError(code) != 0 { throw Failure.codec(String(cString: ZSTD_getErrorName(code))) }
    }
}
