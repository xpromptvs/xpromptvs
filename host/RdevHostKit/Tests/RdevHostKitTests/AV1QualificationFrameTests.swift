import XCTest
import CoreVideo
@testable import RdevHostKit

final class AV1QualificationFrameTests: XCTestCase {
    func testCapturedBGRARoundTripsWithoutChangingPixelsOrStride() throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 73, 48, kCVPixelFormatType_32BGRA, nil, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<48 { for x in 0..<(73 * 4) { bytes[y * stride + x] = UInt8((x + y * 3) % 256) } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let fixture = try AV1QualificationFrame.capture(buffer)
        let data = try JSONEncoder().encode(fixture)
        let decoded = try JSONDecoder().decode(AV1QualificationFrame.self, from: data).pixelBuffer()
        XCTAssertEqual(CVPixelBufferGetWidth(decoded), 73)
        XCTAssertEqual(CVPixelBufferGetHeight(decoded), 48)
        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly) }
        let output = CVPixelBufferGetBaseAddress(decoded)!.assumingMemoryBound(to: UInt8.self)
        let outputStride = CVPixelBufferGetBytesPerRow(decoded)
        for y in 0..<48 { for x in 0..<(73 * 4) { XCTAssertEqual(output[y * outputStride + x], UInt8((x + y * 3) % 256)) } }
    }
    func testRecorderWaitsForArmAndStopsAtItsBoundedFrameCount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AV1QualificationRecorder(directory: directory, limit: 2)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        try recorder.record(frame, source: "owned", pts: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("0000.json").path))
        try Data().write(to: directory.appendingPathComponent("capture"))
        for pts in 2...4 { try recorder.record(frame, source: "owned", pts: Int64(pts)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("0001.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("0002.json").path))
    }
    func testMalformedDimensionsAndTruncatedPixelsAreRefused() throws {
        for json in [
            "{\"width\":8193,\"height\":1,\"stride\":32772,\"compressed\":false,\"pixels\":\"\"}",
            "{\"width\":10,\"height\":10,\"stride\":40,\"compressed\":true,\"pixels\":\"AA==\"}",
            "{\"width\":10,\"height\":10,\"stride\":39,\"compressed\":false,\"pixels\":\"\"}",
        ] {
            let fixture = try JSONDecoder().decode(AV1QualificationFrame.self, from: Data(json.utf8))
            XCTAssertThrowsError(try fixture.pixelBuffer())
        }
    }
}
