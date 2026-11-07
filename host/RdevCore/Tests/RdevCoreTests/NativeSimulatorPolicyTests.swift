import XCTest
@testable import RdevCore

final class NativeSimulatorPolicyTests: XCTestCase {
    private let sim = "sim:9B45C574-451C-475D-8498-66BD68AEE17D"

    func testOnlySimulatorSourcesCanBeOpenedOrChanged() {
        for source in [sim, "win:1", "dsp:1", "sim:invalid", "sim:"] {
            let allowed = source == sim
            XCTAssertEqual(NativeSimulatorPolicy.permits(.subscribe(source: source, delivery: .rtp), focusedSource: nil), allowed)
            XCTAssertEqual(NativeSimulatorPolicy.permits(.unsubscribe(source: source), focusedSource: nil), allowed)
            XCTAssertEqual(NativeSimulatorPolicy.permits(.focusSource(source: source), focusedSource: nil), allowed)
            XCTAssertEqual(NativeSimulatorPolicy.permits(.restoreWindow(source: source), focusedSource: nil), allowed)
        }
    }

    func testNativePresentationCannotAcknowledgeRemoteVideo() throws {
        let message = try XCTUnwrap(parseInbound(Data(#"{"t":"av1-ref-bound","source":"win:1","epoch":"e","trackId":"track"}"#.utf8)))
        XCTAssertFalse(NativeSimulatorPolicy.permits(message, focusedSource: sim))
    }

    func testInputRequiresAFocusedSimulator() {
        for focus in [nil, "win:1", "dsp:1", sim] {
            XCTAssertEqual(NativeSimulatorPolicy.permits(.simText("hello"), focusedSource: focus), focus == sim)
            XCTAssertEqual(NativeSimulatorPolicy.permits(.simTouch(phase: "down", points: [SimPoint(x: 0.5, y: 0.5)]), focusedSource: focus), focus == sim)
        }
    }

    func testNativePresentationDoesNotPermitMachineOrNetworkControls() {
        for message: InboundMessage in [.curtain(on: true), .setVisibility(hidden: true), .setRecovery(overrideBp: 500), .setPlayoutDelay(minMs: 0, maxMs: 500), .setSourcePrefs(source: sim, scale: 0.5, crop: nil)] {
            XCTAssertFalse(NativeSimulatorPolicy.permits(message, focusedSource: sim))
        }
        XCTAssertTrue(NativeSimulatorPolicy.permits(.listSources, focusedSource: nil))
        XCTAssertTrue(NativeSimulatorPolicy.permits(.openTerminal, focusedSource: nil))
        XCTAssertTrue(NativeSimulatorPolicy.permits(.claimControl(grid: nil), focusedSource: nil))
    }

    func testFullscreenCannotTargetAMacWindow() {
        XCTAssertFalse(NativeSimulatorPolicy.permits(.setView(surface: .windows, fullscreen: .some("win:1")), focusedSource: sim))
        XCTAssertTrue(NativeSimulatorPolicy.permits(.setView(surface: .terminal, fullscreen: nil), focusedSource: sim))
    }
}
