import XCTest
import CoreGraphics
@testable import RdevCore

final class TouchMappingTests: XCTestCase {
    private let dev = CGSize(width: 390, height: 844)

    func testDeviceCenter() {
        let p = deviceTouchPoint(normalizedX: 0.5, normalizedY: 0.5, deviceSize: dev)
        XCTAssertEqual(p.x, 195, accuracy: 0.001)
        XCTAssertEqual(p.y, 422, accuracy: 0.001)
    }
    func testDeviceTopLeft() {
        let p = deviceTouchPoint(normalizedX: 0, normalizedY: 0, deviceSize: dev)
        XCTAssertEqual(p.x, 0, accuracy: 0.001); XCTAssertEqual(p.y, 0, accuracy: 0.001)
    }
    func testDeviceBottomRight() {
        let p = deviceTouchPoint(normalizedX: 1, normalizedY: 1, deviceSize: dev)
        XCTAssertEqual(p.x, 390, accuracy: 0.001); XCTAssertEqual(p.y, 844, accuracy: 0.001)
    }
    func testDeviceClampsOutOfRange() {
        let p = deviceTouchPoint(normalizedX: -0.2, normalizedY: 1.3, deviceSize: dev)
        XCTAssertEqual(p.x, 0, accuracy: 0.001); XCTAssertEqual(p.y, 844, accuracy: 0.001)
    }
    func testDeviceMonotonicMatchesClickContract() {
        let a = deviceTouchPoint(normalizedX: 0.5, normalizedY: 0.35, deviceSize: dev)
        let b = deviceTouchPoint(normalizedX: 0.5, normalizedY: 0.65, deviceSize: dev)
        XCTAssertGreaterThan(b.y, a.y)
        let c = deviceTouchPoint(normalizedX: 0.3, normalizedY: 0.5, deviceSize: dev)
        let d = deviceTouchPoint(normalizedX: 0.7, normalizedY: 0.5, deviceSize: dev)
        XCTAssertGreaterThan(d.x, c.x)
    }

    // MARK: - windowInputPoint (normalized over a window's global bounds → global point)

    private let winBounds = CGRect(x: 100, y: 200, width: 800, height: 600)

    func testWindowCenter() {
        let p = windowInputPoint(normalizedX: 0.5, normalizedY: 0.5, bounds: winBounds)
        XCTAssertEqual(p.x, 500, accuracy: 0.001)   // 100 + 0.5*800
        XCTAssertEqual(p.y, 500, accuracy: 0.001)   // 200 + 0.5*600
    }
    func testWindowTopLeftIsOrigin() {
        let p = windowInputPoint(normalizedX: 0, normalizedY: 0, bounds: winBounds)
        XCTAssertEqual(p.x, 100, accuracy: 0.001); XCTAssertEqual(p.y, 200, accuracy: 0.001)
    }
    func testWindowBottomRight() {
        let p = windowInputPoint(normalizedX: 1, normalizedY: 1, bounds: winBounds)
        XCTAssertEqual(p.x, 900, accuracy: 0.001); XCTAssertEqual(p.y, 800, accuracy: 0.001)
    }
    func testWindowClampsOutOfRange() {
        let p = windowInputPoint(normalizedX: -0.5, normalizedY: 2.0, bounds: winBounds)
        XCTAssertEqual(p.x, 100, accuracy: 0.001)   // clamped to origin
        XCTAssertEqual(p.y, 800, accuracy: 0.001)   // clamped to bottom
    }
    // Single-axis corners: catch an axis swap that center/full-clamp tests could miss.
    func testWindowTopRight() {
        let p = windowInputPoint(normalizedX: 1, normalizedY: 0, bounds: winBounds)
        XCTAssertEqual(p.x, 900, accuracy: 0.001); XCTAssertEqual(p.y, 200, accuracy: 0.001)
    }
    func testWindowBottomLeft() {
        let p = windowInputPoint(normalizedX: 0, normalizedY: 1, bounds: winBounds)
        XCTAssertEqual(p.x, 100, accuracy: 0.001); XCTAssertEqual(p.y, 800, accuracy: 0.001)
    }

    // MARK: - onScreenPosition

    /// Screen space here is TOP-LEFT origin (kCGWindowBounds / kAXPosition), matching the call site.
    private let screen = CGRect(x: 0, y: 25, width: 1728, height: 1067)   // 1728x1117 minus menu bar

    func testFullyOnScreenWindowIsNotMoved() {
        let win = CGRect(x: 300, y: 200, width: 740, height: 677)
        XCTAssertNil(onScreenPosition(window: win, visible: screen))
    }

    func testWindowOffTheLeftEdgeIsPulledBack() {
        let win = CGRect(x: -220, y: 360, width: 740, height: 677)
        XCTAssertEqual(onScreenPosition(window: win, visible: screen), CGPoint(x: 0, y: 360))
    }

    func testWindowOffTheBottomRightIsPulledBack() {
        let win = CGRect(x: 1500, y: 900, width: 740, height: 677)
        // right edge -> 1728-740 = 988; bottom edge -> (25+1067)-677 = 415
        XCTAssertEqual(onScreenPosition(window: win, visible: screen), CGPoint(x: 988, y: 415))
    }

    func testWindowUnderTheMenuBarIsPushedDown() {
        let win = CGRect(x: 100, y: 0, width: 400, height: 300)
        XCTAssertEqual(onScreenPosition(window: win, visible: screen), CGPoint(x: 100, y: 25))
    }

    func testWindowBiggerThanTheScreenPinsToTheTopLeft() {
        let win = CGRect(x: -50, y: -50, width: 2000, height: 1400)
        XCTAssertEqual(onScreenPosition(window: win, visible: screen), CGPoint(x: 0, y: 25))
    }

    // MARK: - display rects (global, top-left origin)

    func testMapsIntoTheMainDisplayRect() {
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertEqual(windowInputPoint(normalizedX: 0.0, normalizedY: 0.0, bounds: main), CGPoint(x: 0, y: 0))
        XCTAssertEqual(windowInputPoint(normalizedX: 1.0, normalizedY: 1.0, bounds: main), CGPoint(x: 1728, y: 1117))
        XCTAssertEqual(windowInputPoint(normalizedX: 0.5, normalizedY: 0.5, bounds: main), CGPoint(x: 864, y: 558.5))
    }

    /// A SECOND DISPLAY TO THE RIGHT. Its rect has a non-zero x origin in the global space, so a
    /// mapping that forgot to add the origin would land every click on the MAIN display — and would
    /// look perfectly correct on a single-display machine, which is where this gets developed.
    func testMapsIntoASecondDisplayToTheRight() {
        let right = CGRect(x: 1728, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(windowInputPoint(normalizedX: 0.0, normalizedY: 0.0, bounds: right), CGPoint(x: 1728, y: 0))
        XCTAssertEqual(windowInputPoint(normalizedX: 1.0, normalizedY: 1.0, bounds: right), CGPoint(x: 4288, y: 1440))
    }

    /// A SECOND DISPLAY TO THE LEFT has a NEGATIVE origin. `CGDisplayBounds` reports this and it is
    /// legal; a clamp that assumed non-negative coordinates would pin every click to x=0.
    func testMapsIntoADisplayWithANegativeOrigin() {
        let left = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
        XCTAssertEqual(windowInputPoint(normalizedX: 0.0, normalizedY: 0.0, bounds: left), CGPoint(x: -2560, y: -300))
        XCTAssertEqual(windowInputPoint(normalizedX: 1.0, normalizedY: 0.0, bounds: left), CGPoint(x: 0, y: -300))
    }
}
