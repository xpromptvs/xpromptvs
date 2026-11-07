import XCTest
@testable import ShellstormCore

final class SimulatorRenderScheduleTests: XCTestCase {
    func testBusyRendererKeepsOnlyTheNewestFrame() {
        var schedule = SimulatorRenderSchedule()
        XCTAssertTrue(schedule.offer(sequence: 1))
        for n in 2...100 { XCTAssertFalse(schedule.offer(sequence: UInt64(n))) }
        XCTAssertEqual(schedule.completed(), 100)
        XCTAssertNil(schedule.completed())
        XCTAssertTrue(schedule.offer(sequence: 101))
    }
    func testHiddenAndStoppedRenderersDoNotSubmit() {
        var schedule = SimulatorRenderSchedule()
        schedule.setVisible(false)
        XCTAssertFalse(schedule.offer(sequence: 1))
        XCTAssertNil(schedule.completed())
        schedule.setVisible(true)
        XCTAssertTrue(schedule.offer(sequence: 1), "redraw the static frame when exposed")
        schedule.stop()
        XCTAssertFalse(schedule.offer(sequence: 2))
        XCTAssertNil(schedule.completed())
    }
    func testHidingDiscardsPendingWorkButKeepsAnInFlightSubmissionBounded() {
        var schedule = SimulatorRenderSchedule()
        XCTAssertTrue(schedule.offer(sequence: 1))
        XCTAssertFalse(schedule.offer(sequence: 2))
        schedule.setVisible(false)
        schedule.setVisible(true)
        XCTAssertFalse(schedule.offer(sequence: 3))
        XCTAssertEqual(schedule.completed(), 3)
        XCTAssertNil(schedule.completed())
    }
}
