import AppKit
import XCTest
@testable import RdevHostKit

final class CursorWatcherTests: XCTestCase {
    func testHighDensityExportFillsTheBitmapAtThreeTimesResolution() throws {
        let image = NSImage(size: NSSize(width: 10, height: 16), flipped: false) { rect in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: rect.width / 2, height: rect.height).fill()
            return true
        }
        for scale in [1, 3] {
            let png = try XCTUnwrap(CursorWatcher.png(image, scale: scale))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
            XCTAssertEqual(bitmap.pixelsWide, 10 * scale)
            XCTAssertEqual(bitmap.pixelsHigh, 16 * scale)
            // Verify the drawing scales exactly once, preserving its transparent half.
            let left = try XCTUnwrap(bitmap.colorAt(x: 2 * scale, y: 15 * scale))
            let right = try XCTUnwrap(bitmap.colorAt(x: 8 * scale, y: 15 * scale))
            XCTAssertGreaterThan(left.alphaComponent, 0.99)
            XCTAssertLessThan(right.alphaComponent, 0.01)
        }
    }
}
