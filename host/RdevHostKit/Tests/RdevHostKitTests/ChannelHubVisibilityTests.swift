import CoreVideo
import XCTest
import RdevCore
@testable import RdevHostKit

/// Counts the sinks attached — each attach forces an IDR on a real encoder.
private final class SinkCounter: VideoEncoding, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var attached: Int { lock.withLock { n } }
    var codec: NegotiatedCodec { .av1 }
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64) {}
    func addSink(_ s: any VideoTrackSink) { lock.withLock { n += 1 } }
    func removeSink(_ s: any VideoTrackSink) {}
    func removeAllSinks() {}
    func requestKeyframe() {}
    func setFps(_ v: Int) {}
    func setBitrate(_ v: Int) {}
    func setCrop(_ v: CropRect) {}
    func invalidate() {}
}

/// The sources' side of the pause: every `setHidden` the hub asked of them, in order. The rest of the
/// delegate is inert — nothing is subscribed.
private final class SourceRates: SimControlDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []
    var hiddenCalls: [Bool] { lock.withLock { calls } }
    /// Whether the sources are at the hidden rate now: the last thing they were told.
    var sourcesHidden: Bool { lock.withLock { calls.last ?? false } }
    func setHidden(_ hidden: Bool) { lock.withLock { calls.append(hidden) } }
    func reconcileAudio() {}

    func listSources(forClient clientId: String) {}
    func requestThumbs(forClient clientId: String) {}
    func openWindow(sourceID: String, requestedBy clientId: String) -> Bool { false }
    func closeWindow(sourceID: String, land: Bool, requestedBy clientId: String) {}
    func minimizeWindow(sourceID: String, land: Bool, requestedBy clientId: String) {}
    func restoreWindow(sourceID: String, requestedBy clientId: String) -> Bool { false }
    func setWindowPosition(sourceID: String, x: Double, y: Double, requestedBy clientId: String) {}
    func setView(surface: SessionSurface?, fullscreen: String??, requestedBy clientId: String) {}
    func moveTab(_ tab: String, before: String?) -> [String]? { nil }
    func renameWindow(sourceID: String, name: String, requestedBy clientId: String) {}
    func syncTerminalTabs(_ ids: [String]) {}
    func reconcile(driverPrefs: ClientPrefs) {}
    func applyRecoveryPolicy(mediaBitrateBps: UInt32, budgetBps: UInt32) -> Bool { false }
    func ensureEncoder(sourceID: String, codec: NegotiatedCodec) {}
    func setSourceView(sourceID: String, scale: Double?, crop: CropRect?, requestedBy clientId: String) {}
    func resetViewerDerived() {}
    func codecPrefForSource(_ sourceID: String) -> CodecPref { .auto }
    func setRecoveryOverride(bp: Int?) {}
    func setPlayoutDelay(minMs: Int?, maxMs: Int?) {}
    func focusSource(sourceID: String, requestedBy clientId: String) {}
    func pasteTarget(sourceID: String) -> InputInjector? { nil }
    func setSourceAudio(sourceID: String, enabled: Bool, requestedBy clientId: String) {}
    func setSourceSize(sourceID: String, w: Int, h: Int, requestedBy clientId: String) {}
    func simAction(sourceID: String, action: SimAction, requestedBy clientId: String) {}
    func announceCurtainChange() {}
    func sendViewSet(toClient clientId: String) {}
    func offerStatePayloads() -> [Data] { [] }
    func sendSourceStatus(toClient clientId: String) {}
    func subscribedSourceIDs() -> [String] { [] }
    func encoderForSource(_ id: String) -> VideoEncoding? { nil }
    func audioEncoderForSource(_ id: String) -> AudioEncoding? { nil }
    func onClientGone() {}
    func onClientBack() {}
    func endSession() {}
}

/// The MEDIA half of the lost-resume shape (docs/sources-and-focus.md, "A rebuilt driver voids the
/// media pause"): a page hidden past the hold whose `set-visibility` visible went into a dead control
/// channel came back by REBUILD, and the host still believed it hidden — its video at 1 fps, sinks
/// dropped. Driven through the hub's REAL entry points with real, never-connected PionPeers.
final class ChannelHubVisibilityTests: XCTestCase {
    private var peers: [PionPeer] = []
    private var hub: ChannelHub!
    private var rates: SourceRates!
    private var encoder: SinkCounter!

    override func setUp() {
        encoder = SinkCounter()
        hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: encoder,
                         terminalPauseHold: .milliseconds(50), mediaPauseHold: .milliseconds(50))
        rates = SourceRates()
        hub.simDelegate = rates
    }

    override func tearDown() {
        hub.mediaHoldHookForTests = nil
        hub.simDelegate = nil
        for p in peers { p.close() }
        peers = []
    }

    private func peer(_ id: String) -> PionPeer {
        let p = PionPeer(clientId: id, turn: nil)
        peers.append(p)
        return p
    }

    private func send(_ p: PionPeer, _ json: String) {
        hub.pionPeer(p, didReceive: wrapMessage(Data(json.utf8)), on: .control)
    }

    private func hidden(_ p: PionPeer, _ h: Bool) { send(p, #"{"t":"set-visibility","hidden":\#(h)}"#) }

    /// Past the hold, with margin.
    private func pastTheHold() { Thread.sleep(forTimeInterval: 0.25) }

    func testARebuildVoidsAnAppliedPause() {
        let a = peer("a"), a2 = peer("a")
        hub.register(clientId: "a", peer: a)
        hidden(a, true)
        pastTheHold()
        XCTAssertTrue(hub.isMediaPaused, "precondition: the pause applied")
        XCTAssertTrue(rates.sourcesHidden, "precondition: the sources went to the hidden rate")

        // The page came back while its control channel was dead: the visible report is LOST, and the
        // client comes back by rebuild.
        hub.rebindPeer(clientId: "a", peer: a2)
        XCTAssertFalse(hub.isMediaPaused, "a rebuilt driver is a new page lifetime: the pause goes")
        XCTAssertFalse(rates.sourcesHidden, "and the sources return to the visible rate")
    }

    func testAHiddenPageThatRebuildsPausesAgainWhenItSaysSo() {
        let a = peer("a"), a2 = peer("a")
        hub.register(clientId: "a", peer: a)
        hidden(a, true)
        pastTheHold()
        hub.rebindPeer(clientId: "a", peer: a2)
        // The client re-states its visibility on every control open; this page is still hidden.
        hidden(a2, true)
        pastTheHold()
        XCTAssertTrue(hub.isMediaPaused, "the re-statement pauses again")
        XCTAssertTrue(rates.sourcesHidden)
        hidden(a2, false)
        XCTAssertFalse(hub.isMediaPaused)
        XCTAssertFalse(rates.sourcesHidden)
    }

    func testARebuildInsideTheHoldCancelsThePendingPause() {
        let a = peer("a"), a2 = peer("a")
        hub.register(clientId: "a", peer: a)
        hidden(a, true)
        hub.rebindPeer(clientId: "a", peer: a2)   // before the hold elapses
        pastTheHold()
        XCTAssertFalse(hub.isMediaPaused, "a pause scheduled for the old connection must not land on the new one")
        XCTAssertEqual(rates.hiddenCalls, [], "the sources were never re-rated")
    }

    func testAVisibilityReportFromARetiredConnectionIsDropped() {
        let a = peer("a"), a2 = peer("a")
        hub.register(clientId: "a", peer: a)
        hub.rebindPeer(clientId: "a", peer: a2)
        hidden(a, true)                            // the OLD connection, still draining
        pastTheHold()
        XCTAssertFalse(hub.isMediaPaused, "only the driver's CURRENT connection states its visibility")
    }

    func testAPassiveClientsVisibilityIsIgnored() {
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        hidden(b, true)
        pastTheHold()
        XCTAssertFalse(hub.isMediaPaused, "the pause is the driver's")
    }

    func testAClaimVoidsTheOutgoingDriversPause() {
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        hidden(a, true)
        pastTheHold()
        XCTAssertTrue(hub.isMediaPaused, "precondition")
        send(b, #"{"t":"claim-control"}"#)
        XCTAssertFalse(hub.isMediaPaused, "the incoming driver is not the page that went hidden")
        XCTAssertFalse(rates.sourcesHidden)
    }

    func testAPromotionVoidsTheDepartedDriversPause() {
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        hidden(a, true)
        pastTheHold()
        hub.unregister(clientId: "a")               // b is promoted
        XCTAssertFalse(hub.isMediaPaused, "the promoted driver states its own visibility; the old one's goes")
        XCTAssertFalse(rates.sourcesHidden)
    }

    func testADriverLeavingWithNoReplacementKeepsTheSourcesAtTheHiddenRate() {
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        hidden(a, true)
        pastTheHold()
        hub.unregister(clientId: "a")
        XCTAssertTrue(rates.sourcesHidden, "nobody is watching: nothing to restore the rate for")
    }

    /// Blocks the hold at `phase` until `release` is signalled; `entered` is signalled when it gets there.
    private func holdTheHold(at phase: ChannelHub.MediaHoldPhase) -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        hub.mediaHoldHookForTests = { p in
            guard p == phase else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        return (entered, release)
    }

    /// Review A finding 1: a void landing WHILE a hold applies its effects. Before the fix the void
    /// cleared the flag and restored the rate, then the hold's `setHidden(true)` landed after it —
    /// SimManager keeps the last call — and the session sat at 1 fps with `mediaPaused` false, which
    /// no later visible report could undo. The last writer must be the current state.
    func testAVoidDuringAnInFlightHoldLeavesTheVisibleRate() {
        let a = peer("a"), a2 = peer("a")
        hub.register(clientId: "a", peer: a)
        let (entered, release) = holdTheHold(at: .applying)
        hidden(a, true)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the hold reached its effects")
        let voided = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { self.hub.rebindPeer(clientId: "a", peer: a2); voided.signal() }
        Thread.sleep(forTimeInterval: 0.1)             // the void is running (or waiting its turn)
        release.signal()
        XCTAssertEqual(voided.wait(timeout: .now() + 5), .success, "the void finished (no deadlock)")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(hub.isMediaPaused)
        XCTAssertFalse(rates.sourcesHidden, "the sources end at the visible rate, as the flag says")
    }

    /// The hold's generation guard: a hold that STARTED running, superseded before it checked,
    /// applies nothing (`DispatchWorkItem.cancel` cannot stop it any more).
    func testAHoldSupersededAfterItStartedAppliesNothing() {
        let a = peer("a"), a2 = peer("a")
        hub.register(clientId: "a", peer: a)
        let (entered, release) = holdTheHold(at: .willApply)
        hidden(a, true)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        hub.rebindPeer(clientId: "a", peer: a2)       // the void: nothing applied yet, the generation moves
        release.signal()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(hub.isMediaPaused, "a superseded hold must not apply")
        XCTAssertEqual(rates.hiddenCalls, [], "the sources were never re-rated")
    }

    /// Review A finding 2: an encoder becoming ready (a codec rebuild, a late `codec-resolved`) while
    /// the pause is in force attached a sink — and forced an IDR — for a page nobody is looking at.
    /// The resume attaches it.
    func testNoSinkIsAttachedWhileThePauseIsInForce() {
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        hub.installVideoSlotForTests(clientId: "a", sourceID: "test", slot: 0)
        hidden(a, true)
        pastTheHold()
        XCTAssertTrue(hub.isMediaPaused, "precondition")
        let before = encoder.attached
        hub.encoderReady(sourceID: "test")
        XCTAssertEqual(encoder.attached, before, "no sink (and no IDR) while the page is hidden")
        hidden(a, false)
        XCTAssertEqual(encoder.attached, before + 1, "the resume attaches it")
    }
}
