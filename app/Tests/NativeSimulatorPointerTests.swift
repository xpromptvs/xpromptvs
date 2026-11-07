import Foundation
import XCTest
@testable import ShellstormCore
final class NativeSimulatorPointerTests: XCTestCase {
    func testLetterboxingAndOutOfBoundsDrag() {
        let rect = CGRect(x: 50, y: 0, width: 100, height: 200)
        XCTAssertNil(NativeSimulatorPointer.normalized(CGPoint(x: 20, y: 50), in: rect, dragging: false))
        XCTAssertEqual(NativeSimulatorPointer.normalized(CGPoint(x: 100, y: 50), in: rect, dragging: false), CGPoint(x: 0.5, y: 0.25))
        XCTAssertEqual(NativeSimulatorPointer.normalized(CGPoint(x: 300, y: -30), in: rect, dragging: true), CGPoint(x: 1, y: 0))
    }
    func testOptionMirrorsAndOptionShiftKeepsTheInitialOffset() {
        let press = CGPoint(x: 0.2, y: 0.3), move = CGPoint(x: 0.3, y: 0.4)
        XCTAssertEqual(NativeSimulatorPointer.fingers(at: move, press: press, option: true, shift: false), [move, CGPoint(x: 0.7, y: 0.6)])
        let parallel = NativeSimulatorPointer.fingers(at: move, press: press, option: true, shift: true)
        XCTAssertEqual(parallel[1].x, 0.9, accuracy: 0.00001)
        XCTAssertEqual(parallel[1].y, 0.8, accuracy: 0.00001)
    }
}
