import Compression
import Foundation

public enum Codec: UInt8, Sendable { case none = 0, deflate = 1, lzfse = 2, zstd = 3 }

private func transform(_ input: Data, _ op: compression_stream_operation) -> Data {
    if input.isEmpty { return Data() }
    let bufSize = 64 * 1024
    let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { dst.deallocate() }
    var stream = compression_stream(dst_ptr: dst, dst_size: bufSize, src_ptr: dst, src_size: 0, state: nil)
    guard compression_stream_init(&stream, op, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return Data() }
    defer { compression_stream_destroy(&stream) }
    var output = Data()
    let src = [UInt8](input)
    return src.withUnsafeBufferPointer { srcBuf -> Data in
        stream.src_ptr = srcBuf.baseAddress!
        stream.src_size = srcBuf.count
        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
        while true {
            stream.dst_ptr = dst
            stream.dst_size = bufSize
            let status = compression_stream_process(&stream, flags)
            output.append(dst, count: bufSize - stream.dst_size)
            if status == COMPRESSION_STATUS_END { return output }
            if status != COMPRESSION_STATUS_OK { return Data() }
        }
    }
}

public func rawDeflate(_ input: Data) -> Data { transform(input, COMPRESSION_STREAM_ENCODE) }
public func rawInflate(_ input: Data) -> Data { transform(input, COMPRESSION_STREAM_DECODE) }

/// Wrap a payload with a 1-byte codec prefix, compressing only when it strictly saves space.
public func wrapMessage(_ payload: Data, codec: Codec = .deflate) -> Data {
    if codec == .deflate {
        let compressed = rawDeflate(payload)
        if !compressed.isEmpty && compressed.count < payload.count {
            var out = Data([Codec.deflate.rawValue]); out.append(compressed); return out
        }
    }
    var out = Data([Codec.none.rawValue]); out.append(payload); return out
}

public func unwrapMessage(_ bytes: Data) -> Data? {
    guard let codecByte = bytes.first else { return Data() }
    let body = bytes.dropFirst()
    guard let codec = Codec(rawValue: codecByte) else { return nil }
    switch codec {
    case .none: return Data(body)
    case .deflate: return rawInflate(Data(body))
    default: return nil
    }
}
