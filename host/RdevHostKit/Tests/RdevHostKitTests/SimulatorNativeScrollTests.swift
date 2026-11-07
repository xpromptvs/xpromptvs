import XCTest
import RdevCore
@testable import RdevHostKit

final class SimulatorNativeScrollTests: XCTestCase {
    final class Sink: SimScrollHIDSink {
        var invalidated = false
        var events: [SimScrollTouchEvent] = []
        func touch(_ event: SimScrollTouchEvent) { events.append(event) }
    }
    private func injector(_ sink: Sink, display: SimDisplayState = SimDisplayState()) -> SimulatorInputInjector {
        SimulatorInputInjector(udid: "probe", connect: { nil }, connectScroll: { sink }, display: display,
            control: SimulatorControl(run: { _, _, _ in (0, Data()) }), nativePointW: 400, nativePointH: 800)
    }
    func testReleaseIsPromptAndDoesNotWaitForLegacyWheelTimer() {
        let sink = Sink(), inj = injector(sink)
        inj.scrollGesture(normalizedX: 0.5, normalizedY: 0.5, phase: .begin, velocityX: 0, velocityY: 0, mods: .none)
        inj.scroll(normalizedX: 0.5, normalizedY: 0.5, deltaX: 0, deltaY: 40, unit: .pixel, mods: .none)
        inj.scrollGesture(normalizedX: 0.5, normalizedY: 0.5, phase: .end, velocityX: 0, velocityY: 1000, mods: .none)
        inj.drainForTests()
        XCTAssertEqual(sink.events, [.contact(SimPoint(x: 0.5,y: 0.5)),.contact(SimPoint(x: 0.5,y: 0.45)),.end(SimPoint(x: 0.5,y: 0.45))])
    }
    func testPausedReleaseAndFocusDrainCancelWithoutAThrow() {
        let sink = Sink(), inj = injector(sink)
        for _ in 0..<2 {
            inj.scrollGesture(normalizedX: 0.5, normalizedY: 0.5, phase: .begin, velocityX: 0, velocityY: 0, mods: .none)
            inj.scroll(normalizedX: 0.5, normalizedY: 0.5, deltaX: 0, deltaY: 40, unit: .pixel, mods: .none)
        }
        inj.releaseKeys(); inj.drainForTests()
        XCTAssertEqual(sink.events.filter { if case .cancel = $0 { return true }; return false }.count,2)
        XCTAssertFalse(sink.events.contains { if case .end = $0 { return true }; return false })
    }
    func testRejectedPostCannotCreateOrReleaseATouchAndDrainOnlyCancelsWhatPosted() {
        let sink = Sink(), inj = injector(sink)
        var allowed = true
        let fence: InputPostFence = { post in guard allowed else { return false }; post(); return true }
        inj.submitScoped(.scrollGesture(x: 0.5,y: 0.5,phase: .begin,vx: 0,vy: 0,mods: .none),postFence: fence)
        inj.drainForTests(); allowed = false
        inj.submitScoped(.scrollGesture(x: 0.5,y: 0.5,phase: .end,vx: 0,vy: 1000,mods: .none),postFence: fence)
        inj.drainForFocusChange {}; inj.drainForTests()
        XCTAssertEqual(sink.events,[.contact(SimPoint(x: 0.5,y: 0.5)),.cancel(SimPoint(x: 0.5,y: 0.5))])
    }
    func testAStaleNativeBeginCannotBecomeALegacyWheelGesture() {
        let sink = Sink()
        var now = 0, legacyConnects = 0
        let inj = SimulatorInputInjector(udid:"probe",connect:{legacyConnects += 1;return nil},connectScroll:{now = 501;return sink},
            display:SimDisplayState(),control:SimulatorControl(run:{_,_,_ in (0,Data())}),nativePointW:400,nativePointH:800,nowMs:{now})
        inj.scrollGesture(normalizedX:0.5,normalizedY:0.5,phase:.begin,velocityX:0,velocityY:0,mods:.none)
        inj.drainForTests()
        inj.scroll(normalizedX:0.5,normalizedY:0.5,deltaX:0,deltaY:40,unit:.pixel,mods:.none)
        inj.scrollGesture(normalizedX:0.5,normalizedY:0.5,phase:.end,velocityX:0,velocityY:1000,mods:.none)
        inj.drainForTests()
        XCTAssertEqual(legacyConnects,0)
        XCTAssertTrue(sink.events.isEmpty)
    }
}
