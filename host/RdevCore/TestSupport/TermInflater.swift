import Foundation
import zlib

/// The receiving end of one `TermDeflater` stream. TEST-ONLY — the host never inflates; the client's
/// end is fflate's `Inflate` (web/src/client/term-stream.ts). It lives in the `testonly` target
/// //host/RdevCore:RdevTermCorpus so it cannot ship in the product (Bazel refuses a non-testonly
/// dependency on it).
public final class TermInflater {
    public enum Failure: Error, Equatable { case corrupt(Int32) }
    private var stream = z_stream()

    public init() {
        let rc = inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        precondition(rc == Z_OK, "inflateInit2 failed: \(rc)")
    }

    deinit { inflateEnd(&stream) }

    public func decompress(_ input: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var src = input
        var failure: Int32? = nil
        src.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            repeat {
                chunk.withUnsafeMutableBufferPointer { o in
                    stream.next_out = o.baseAddress
                    stream.avail_out = uInt(o.count)
                    let rc = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    if rc != Z_OK && rc != Z_BUF_ERROR && rc != Z_STREAM_END { failure = rc }
                    out.append(contentsOf: o[0..<(o.count - Int(stream.avail_out))])
                }
            } while failure == nil && stream.avail_out == 0
            stream.next_in = nil
        }
        if let failure { throw Failure.corrupt(failure) }
        return out
    }
}
