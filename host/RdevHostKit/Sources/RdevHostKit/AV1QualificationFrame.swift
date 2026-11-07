import Compression
import CoreVideo
import Foundation

/// Lossless BGRA fixtures for the owned-window qualification instrument. No
/// rendered/encoded copy becomes the input of the quality comparison.
struct AV1QualificationFrame: Codable {
    let width: Int, height: Int, stride: Int
    let compressed: Bool
    let pixels: Data
    enum Failure: Error { case invalidFrame, invalidPixels }

    private var byteCount: Int? {
        guard (1...8192).contains(width), (1...8192).contains(height),
              stride >= width * 4, stride <= width * 4 + 4096,
              stride * height <= 96 * 1024 * 1024 else { return nil }
        return stride * height
    }
    static func capture(_ buffer: CVPixelBuffer) throws -> Self {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw Failure.invalidFrame }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0, w <= 8192, h <= 8192, row >= w * 4, row <= w * 4 + 4096,
              row * h <= 96 * 1024 * 1024, let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.invalidFrame }
        // Pixel-buffer row padding is not image data and need not be initialized.
        // Store only the owned window's pixels, in a deterministic tight stride.
        var raw = Data(count: w * 4 * h)
        raw.withUnsafeMutableBytes { destination in
            for y in 0..<h { memcpy(destination.baseAddress!.advanced(by: y * w * 4), base.advanced(by: y * row), w * 4) }
        }
        var output = Data(count: raw.count + raw.count / 128 + 1024)
        let capacity = output.count
        let count = output.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZ4)
            }
        }
        let compressed = count > 0 && count < raw.count
        if compressed { output.count = count }
        return Self(width: w, height: h, stride: w * 4, compressed: compressed, pixels: compressed ? output : raw)
    }
    func pixelBuffer() throws -> CVPixelBuffer {
        guard let size = byteCount else { throw Failure.invalidFrame }
        var raw: Data
        if compressed {
            guard !pixels.isEmpty, pixels.count <= size else { throw Failure.invalidPixels }
            raw = Data(count: size)
            let count = raw.withUnsafeMutableBytes { destination in
                pixels.withUnsafeBytes { source in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                                              source.bindMemory(to: UInt8.self).baseAddress!, pixels.count, nil, COMPRESSION_LZ4)
                }
            }
            guard count == size else { throw Failure.invalidPixels }
        } else {
            guard pixels.count == size else { throw Failure.invalidPixels }
            raw = pixels
        }
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess,
              let result, CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw Failure.invalidFrame }
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        guard let destination = CVPixelBufferGetBaseAddress(result) else { throw Failure.invalidFrame }
        let destinationStride = CVPixelBufferGetBytesPerRow(result)
        raw.withUnsafeBytes { source in
            for row in 0..<height {
                memcpy(destination.advanced(by: row * destinationStride), source.baseAddress!.advanced(by: row * stride), width * 4)
            }
        }
        return result
    }
}

/// Instrument only, serialized by the adapter's encode lock. Capture IO is never
/// enabled during timing/CPU measurement; the resulting fixtures are replayed.
final class AV1QualificationRecorder {
    private let directory: URL
    private let limit: Int
    private var entries: [[String: Any]] = []
    private var bytes = 0
    private var failed = false
    init(directory: URL, limit: Int = 180) { self.directory = directory; self.limit = max(1, min(240, limit)) }
    static func configured() -> AV1QualificationRecorder? {
        let env = ProcessInfo.processInfo.environment
        guard env["RDEV_INSTRUMENTS"] == "1", let path = env["RDEV_AV1_QUALIFICATION_CAPTURE"], !path.isEmpty else { return nil }
        return AV1QualificationRecorder(directory: URL(fileURLWithPath: path))
    }
    func record(_ buffer: CVPixelBuffer, source: String, pts: Int64) throws {
        guard !failed, entries.count < limit,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("capture").path) else { return }
        let frame = try AV1QualificationFrame.capture(buffer)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(frame)
        guard bytes + data.count <= 1024 * 1024 * 1024 else { throw AV1QualificationFrame.Failure.invalidFrame }
        let name = String(format: "%04d.json", entries.count)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        bytes += data.count
        entries.append(["file": name, "ptsNs": String(pts), "width": frame.width, "height": frame.height])
        if entries.count == limit {
            let manifest: [String: Any] = ["source": source, "frames": entries, "bytes": bytes, "format": "lossless-bgra-lz4-json"]
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: directory.appendingPathComponent("complete.json"), options: .atomic)
        }
    }
    func stop(error: Error) {
        failed = true
        try? Data(String(describing: error).utf8).write(to: directory.appendingPathComponent("error.txt"), options: .atomic)
    }
}
