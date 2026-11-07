import XCTest
@testable import ShellstormCore

final class NativeSimulatorWindowsTests: XCTestCase {
    func testOpeningAtFullSizeIncludesChromeAndKeepsWindowOnScreen() {
        let screen = CGRect(x: 1920, y: 40, width: 1440, height: 1000)
        let result = NativeSimulatorGeometry.openingFrame(device: CGSize(width: 402, height: 874),
            header: 40, available: screen, previous: CGRect(x: 3300, y: 50, width: 300, height: 500))
        XCTAssertEqual(result.size, CGSize(width: 402, height: 914))
        XCTAssertTrue(screen.contains(result))
    }
    func testOpeningFitsOnlyWhenNecessaryAndNeverUpscales() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 700)
        let portrait = NativeSimulatorGeometry.openingFrame(device: CGSize(width: 400, height: 1000),
            header: 40, available: screen, previous: screen)
        XCTAssertEqual(portrait.height, 700)
        XCTAssertEqual(portrait.width, 264, accuracy: 0.001)
        let landscape = NativeSimulatorGeometry.openingFrame(device: CGSize(width: 1200, height: 600),
            header: 40, available: screen, previous: screen)
        XCTAssertEqual(landscape.size, CGSize(width: 800, height: 440))
        let small = NativeSimulatorGeometry.openingFrame(device: CGSize(width: 320, height: 480),
            header: 40, available: screen, previous: screen)
        XCTAssertEqual(small.size, CGSize(width: 320, height: 520))
    }
    private let a = NativeWindowState(source: "sim:a", title: "A", minimized: false)
    private let b = NativeWindowState(source: "sim:b", title: "B", minimized: true)
    private func snapshot(_ gen: UInt64, _ rev: UInt64, driving: Bool = true,
                          windows: [NativeWindowState], focused: String? = "sim:a", terminal: Bool = false) -> NativeWindowsSnapshot {
        NativeWindowsSnapshot(generation: gen, revision: rev, driving: driving, windows: windows,
                              focusedSource: focused, terminalActive: terminal)
    }
    func testDockActivationRaisesAllOpenSimulatorsButPreservesMinimizedAndTerminalFocus() {
        var model = NativeSimulatorWindowsModel()
        _ = model.apply(snapshot(1, 1, windows: [a, b], terminal: true))
        XCTAssertEqual(model.activation().update, [a])
        XCTAssertNil(model.activation().front, "raising simulators must not take keyboard focus from the terminal")
        _ = model.apply(snapshot(1, 2, windows: [a, b]))
        XCTAssertEqual(model.activation().front, a.source)
        _ = model.apply(snapshot(2, 3, driving: false, windows: [a, b]))
        XCTAssertEqual(model.activation().update, [], "Dock activation cannot reclaim remote simulators")
        XCTAssertNil(model.activation().front)
    }
    func testHandoffClosesAndRestoresOnlyCurrentMembership() {
        var model = NativeSimulatorWindowsModel()
        XCTAssertEqual(model.apply(snapshot(1, 1, windows: [a])).create, [a])
        XCTAssertEqual(model.apply(snapshot(2, 2, driving: false, windows: [a])).close, ["sim:a"])
        XCTAssertEqual(model.apply(snapshot(3, 3, windows: [b])).create, [b])
        XCTAssertEqual(model.apply(snapshot(1, 4, windows: [a])).create, [], "old main-queue work cannot resurrect A")
    }
    func testLateFrameCannotStealTerminalLandingAndRepeatedStateDoesNotFront() {
        var model = NativeSimulatorWindowsModel()
        let value = snapshot(1, 1, windows: [a], terminal: true)
        XCTAssertNil(model.apply(value).front)
        XCTAssertEqual(model.apply(value).create, [])
        XCTAssertNil(model.apply(snapshot(1, 2, windows: [a], terminal: true)).front)
    }
    func testMissedIntermediateHandoffStillReplacesOldGenerationWindows() {
        var model = NativeSimulatorWindowsModel()
        _ = model.apply(snapshot(1, 1, windows: [a]))
        let delta = model.apply(snapshot(3, 3, windows: [a]))
        XCTAssertEqual(delta.close, ["sim:a"])
        XCTAssertEqual(delta.create, [a])
    }
}
