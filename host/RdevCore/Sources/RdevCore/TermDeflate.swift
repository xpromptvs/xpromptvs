import Foundation
import zlib

/// One raw-DEFLATE stream (RFC 1951, no zlib header — what fflate's `Inflate` reads), flushed with
/// `Z_SYNC_FLUSH` after every message: the receiver can decode each message the moment it arrives
/// (≈5 bytes of flush marker, no latency), and later messages still compress against everything
/// earlier in the tab. System zlib, not Apple's Compression framework, because the latter has no
/// sync flush. NOT thread-safe.
public final class TermDeflater {
    private var stream = z_stream()

    public init() {
        let rc = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                               zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        precondition(rc == Z_OK, "deflateInit2 failed: \(rc)")
    }

    deinit { deflateEnd(&stream) }

    public func compress(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var src = input
        src.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            repeat {
                chunk.withUnsafeMutableBufferPointer { o in
                    stream.next_out = o.baseAddress
                    stream.avail_out = uInt(o.count)
                    let rc = zlib.deflate(&stream, Z_SYNC_FLUSH)
                    precondition(rc == Z_OK || rc == Z_BUF_ERROR, "deflate failed: \(rc)")
                    out.append(contentsOf: o[0..<(o.count - Int(stream.avail_out))])
                }
            } while stream.avail_out == 0
            stream.next_in = nil
        }
        return out
    }
}
