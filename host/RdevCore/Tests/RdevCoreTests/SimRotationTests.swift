import XCTest
@testable import RdevCore

final class SimRotationTests: XCTestCase {
    func testWireNames() {
        XCTAssertEqual(SimRotation(wire: "rot0"), .rot0)
        XCTAssertEqual(SimRotation(wire: "rot90"), .rot90)
        XCTAssertEqual(SimRotation(wire: "rot180"), .rot180)
        XCTAssertEqual(SimRotation(wire: "rot270"), .rot270)
        XCTAssertNil(SimRotation(wire: "landscapeLeft"))
        XCTAssertNil(SimRotation(wire: ""))
    }

    /// MEASURED (rot270, device landscapeLeft): the shown picture's top-left corner is the native frame's
    /// top-RIGHT, and moving right across the shown picture moves DOWN the native frame.
    func testRot270IsTheMeasuredMapping() {
        let r = SimRotation.rot270
        assertPoint(r.nativePoint(shownX: 0, shownY: 0), (1, 0))
        assertPoint(r.nativePoint(shownX: 1, shownY: 0), (1, 1))
        assertPoint(r.nativePoint(shownX: 0, shownY: 1), (0, 0))
        assertPoint(r.nativePoint(shownX: 0.4, shownY: 0.09), (0.91, 0.4))   // Safari's address field
    }

    func testRot0IsIdentity() {
        assertPoint(SimRotation.rot0.nativePoint(shownX: 0.25, shownY: 0.75), (0.25, 0.75))
    }

    func testEveryRotationRoundTrips() {
        for r in [SimRotation.rot0, .rot90, .rot180, .rot270] {
            for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.2, 0.7), (0.9, 0.1)] {
                let n = r.nativePoint(shownX: x, shownY: y)
                let back = r.shownPoint(nativeX: n.x, nativeY: n.y)
                assertPoint(back, (x, y), "\(r) round trip of (\(x), \(y))")
            }
        }
    }

    func testShownSizeSwapsOnlyForQuarterTurns() {
        XCTAssertTrue(SimRotation.rot0.shownSize(nativeW: 1206, nativeH: 2622) == (1206, 2622))
        XCTAssertTrue(SimRotation.rot90.shownSize(nativeW: 1206, nativeH: 2622) == (2622, 1206))
        XCTAssertTrue(SimRotation.rot180.shownSize(nativeW: 1206, nativeH: 2622) == (1206, 2622))
        XCTAssertTrue(SimRotation.rot270.shownSize(nativeW: 1206, nativeH: 2622) == (2622, 1206))
    }

    /// vImage counts COUNTER-clockwise quarter turns (kRotate90DegreesCounterClockwise == 1). rot270's native
    /// image is shown turned a quarter COUNTER-clockwise (its top-right corner becomes the shown top-left).
    func testVImageConstants() {
        XCTAssertEqual(SimRotation.rot0.vImageRotationConstant, 0)
        XCTAssertEqual(SimRotation.rot270.vImageRotationConstant, 1)
        XCTAssertEqual(SimRotation.rot180.vImageRotationConstant, 2)
        XCTAssertEqual(SimRotation.rot90.vImageRotationConstant, 3)
    }

    private func assertPoint(_ p: (x: Double, y: Double), _ e: (Double, Double), _ m: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, e.0, accuracy: 1e-9, m, file: file, line: line)
        XCTAssertEqual(p.y, e.1, accuracy: 1e-9, m, file: file, line: line)
    }
}
