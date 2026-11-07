import CoreVideo
import XCTest
import RdevCore
@testable import RdevHostKit

/// A spy injector that records what it was asked to do.
private final class SpyInjector: InputInjector, @unchecked Sendable {
    var released = 0
    /// Recorded so a caller that drops the button is visible here rather than only at the CGEvent.
    var buttons: [MouseButton] = []
    func inject(touchNormalizedX x: Double, y: Double, phase: String, button: MouseButton) {
        buttons.append(button)
    }
    func releaseKeys() { released += 1 }
}

/// The minimum a ChannelHub needs to exist. `TerminalManager` starts no PTY until a driver asks for one,
/// so constructing the real hub is cheap and this asserts the REAL method rather than a restatement
/// of it — the distinction this repo has been burned by nine times.
private final class StubEncoder: VideoEncoding, @unchecked Sendable {
    var codec: NegotiatedCodec { .av1 }
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64) {}
    func addSink(_ s: any VideoTrackSink) {}
    func removeSink(_ s: any VideoTrackSink) {}
    func removeAllSinks() {}
    func requestKeyframe() {}
    func setFps(_ v: Int) {}
    func setBitrate(_ v: Int) {}
    func setCrop(_ v: CropRect) {}
    func invalidate() {}
}

final class InjectorReleaseTests: XCTestCase {
    private func makeHub() -> ChannelHub {
        ChannelHub(terminals: TerminalManager(cols: 80, rows: 24),
                   injector: nil, encoder: StubEncoder())
    }

    /// Focus moving to another window, and a source being unsubscribed, BOTH arrive here as a
    /// `setInjector`. Without releasing the OUTGOING injector, a key held when focus changed stays
    /// held on a window nobody is driving any more — and on macOS a held ⌘ turns every subsequent
    /// keystroke into a chord.
    func testSwappingTheInjectorReleasesTheOutgoingOne() {
        let hub = makeHub()
        let first = SpyInjector()
        let second = SpyInjector()
        hub.setInjector(first)
        hub.setInjector(second)
        XCTAssertEqual(first.released, 1)
        XCTAssertEqual(second.released, 0)   // the incoming injector is holding nothing yet
    }

    func testClearingTheInjectorAlsoReleases() {
        let hub = makeHub()
        let only = SpyInjector()
        hub.setInjector(only)
        hub.setInjector(nil)
        XCTAssertEqual(only.released, 1)
    }

    /// Re-setting the SAME injector is not a routing change. Releasing there would drop the keys of
    /// a window the user is still driving — `attach` re-commits the same injector on a codec rebuild.
    func testReSettingTheSameInjectorDoesNotRelease() {
        let hub = makeHub()
        let only = SpyInjector()
        hub.setInjector(only)
        hub.setInjector(only)
        XCTAssertEqual(only.released, 0)
    }

    /// CONTROL CHANGING HANDS between two LIVE clients releases what the outgoing driver was holding.
    ///
    /// Nothing else does it on this path. The old driver stays connected, so `unregister` never runs;
    /// it is no longer active, so the keyups it sends are refused; and ⌘ swallows the ones it would
    /// have sent anyway. The injector is shared, so a ⌘ left down turns every keystroke of the
    /// INCOMING driver into a chord, and a glide the outgoing driver launched keeps posting scroll
    /// into the new driver's session.
    ///
    /// `ActiveClientTracker.claim` producing this effect is asserted in `ActiveClientTrackerTests`;
    /// this is the other half — that the hub acts on it.
    func testAClaimReleasesTheOutgoingDriversInput() {
        let hub = makeHub()
        let inj = SpyInjector()
        hub.setInjector(inj)
        XCTAssertEqual(inj.released, 0, "precondition: routing input to a fresh injector releases nothing")

        hub.apply(ActiveClientEffects(activate: "b", deactivate: "a", broadcastState: true))
        XCTAssertEqual(inj.released, 1)
    }

    /// The NEGATIVE CONTROL, and the reason the rule is keyed on `deactivate` rather than on
    /// `activate`: a first client becoming the driver, or a departing one auto-promoting the last
    /// remaining client, has nobody holding anything to release. Without this arm, "release on every
    /// effect" would pass the test above while stamping on a driver nothing had displaced.
    func testActivationWithoutADeactivationReleasesNothing() {
        let hub = makeHub()
        let inj = SpyInjector()
        hub.setInjector(inj)
        let before = inj.released

        hub.apply(ActiveClientEffects(activate: "a", deactivate: nil, broadcastState: true))
        XCTAssertEqual(inj.released, before)
    }
}
