import XCTest
import RdevCore
@testable import RdevHostKit

/// FINAL REVIEW I7. Simulators are listed FIRST and a simulator's thumbnail is a `simctl` subprocess, so in lock-step
/// batches every window tile waited behind them — and behind a wedged CoreSimulatorService, forever. Windows and
/// displays go first, in their own lane; simulators run beside them.
final class SourceThumbnailerOrderTests: XCTestCase {
    func testWindowsAndDisplaysAreThumbnailedApartFromSimulators() {
        let sources = makeSources(
            sims: [SimInfo(udid: "U1", name: "iPhone", os: "iOS 27.0", state: .booted, w: 402, h: 874, pxW: 1206, pxH: 2622)],
            displays: [DisplayInfo(id: 1, name: "Built-in")],
            windows: [WindowInfo(id: 7, app: "Safari", title: "T")])
        XCTAssertEqual(sources.first?.kind, "sim", "the listing puts simulators first — the order this test guards against")
        let lanes = SourceThumbnailer.lanes(sources)
        XCTAssertEqual(lanes.mac.map(\.id), ["dsp:1", "win:7"])
        XCTAssertEqual(lanes.simulators.map(\.id), ["sim:U1"])
    }
}
