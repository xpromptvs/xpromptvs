import XCTest
@testable import RdevCore

final class EnvelopeTests: XCTestCase {
    func testRoundTripCompressesLarge() {
        let big = Data(repeating: 0x20, count: 2000)
        let wrapped = wrapMessage(big)
        XCTAssertEqual(wrapped.first, Codec.deflate.rawValue)
        XCTAssertLessThan(wrapped.count, big.count + 1)
        XCTAssertEqual(try XCTUnwrap(unwrapMessage(wrapped)), big)
    }

    func testTinyPayloadStaysRaw() {
        let tiny = Data([1, 2, 3, 4])
        let wrapped = wrapMessage(tiny)
        XCTAssertEqual(wrapped.first, Codec.none.rawValue)
        XCTAssertEqual(try XCTUnwrap(unwrapMessage(wrapped)), tiny)
    }

    func testDeflateInflateIdentity() {
        let payload = Data((0..<5000).map { UInt8($0 % 13) })
        XCTAssertEqual(rawInflate(rawDeflate(payload)), payload)
    }

    func testDecodesEnvelopeNoneGolden() throws {
        // envelope-none.bin = [0x00] + a 10-byte payload (codec none, byte-portable). The payload was a
        // cursor frame of the retired cell-frame terminal; to the envelope it is opaque bytes.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/envelope-none.bin")
        let golden = try Data(contentsOf: url)
        XCTAssertEqual(golden.first, Codec.none.rawValue)
        XCTAssertEqual(golden.count, 11)
        let inner = try XCTUnwrap(unwrapMessage(golden))
        XCTAssertEqual(inner, golden.dropFirst())
    }
}
