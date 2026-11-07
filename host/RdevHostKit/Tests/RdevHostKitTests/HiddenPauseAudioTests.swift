import CoreVideo
import XCTest
import RdevCore
@testable import RdevHostKit

private final class NullVideo: VideoEncoding, @unchecked Sendable {
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

/// Which sinks are attached right now.
private final class AttachedAudio: AudioEncoding, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks = Set<ObjectIdentifier>()
    var attached: Int { lock.withLock { sinks.count } }
    func encode(_ frame: AudioFraming.Frame) {}
    func addSink(_ s: any AudioTrackSink) { _ = lock.withLock { sinks.insert(ObjectIdentifier(s)) } }
    func removeSink(_ s: any AudioTrackSink) { _ = lock.withLock { sinks.remove(ObjectIdentifier(s)) } }
    func removeAllSinks() { lock.withLock { sinks.removeAll() } }
    func setBitrate(_ v: Int) {}
    func invalidate() {}
}

/// `AttachedAudio` with a one-shot barrier inside `addSink`, BEFORE it records the sink: the
/// election has already decided to attach, and the barrier holds it there. `removed` is signalled on
/// every `removeSink`, which is how the pause's `pauseVideo` shows up.
private final class BarrierAudio: AudioEncoding, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks = Set<ObjectIdentifier>()
    private var barrier: (() -> Void)?
    let removed = DispatchSemaphore(value: 0)
    var attached: Int { lock.withLock { sinks.count } }
    func arm(_ body: @escaping () -> Void) { lock.withLock { barrier = body } }
    func encode(_ frame: AudioFraming.Frame) {}
    func addSink(_ s: any AudioTrackSink) {
        let b: (() -> Void)? = lock.withLock { defer { barrier = nil }; return barrier }
        b?()
        _ = lock.withLock { sinks.insert(ObjectIdentifier(s)) }
    }
    func removeSink(_ s: any AudioTrackSink) {
        _ = lock.withLock { sinks.remove(ObjectIdentifier(s)) }
        removed.signal()
    }
    func removeAllSinks() { lock.withLock { sinks.removeAll() } }
    func setBitrate(_ v: Int) {}
    func invalidate() {}
}

/// The hidden-tab pause drops a client's AUDIO sinks with its video ones (`pauseVideo`). On the
/// product path nothing put them back: `resumeVideo` → `encoderReady` re-attaches audio only on the
/// headless path, and the ownership election (`SimManager.reconcileAudio`) never ran on visible — so
/// sound stayed off until the next subscribe, unsubscribe or audio toggle (review A2, 2026-09-27).
/// The resume re-runs the election: the carrier comes back; a yielded sibling and a muted source stay
/// silent. Real SimManager and ChannelHub; streams installed without ScreenCaptureKit.
final class HiddenPauseAudioTests: XCTestCase {
    private var peers: [PionPeer] = []

    override func tearDown() {
        for p in peers { p.close() }
        peers = []
    }

    func testAShownPageGetsItsCarriersAudioBackAndNothingElse() {
        let hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: NullVideo(),
                             terminalPauseHold: .milliseconds(50), mediaPauseHold: .milliseconds(50))
        let sim = SimManager(makeEncoder: { _, _, _, _ in NullVideo() }, channelHub: hub,
                             defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                             bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000)
        hub.simDelegate = sim
        hub.isVideoSubscribed = { true }                  // the product path, not the headless one
        defer { hub.simDelegate = nil }
        let a = PionPeer(clientId: "a", turn: nil); peers.append(a)
        hub.register(clientId: "a", peer: a)
        func send(_ json: String) { hub.pionPeer(a, didReceive: wrapMessage(Data(json.utf8)), on: .control) }

        let carrier = AttachedAudio(), sibling = AttachedAudio(), muted = AttachedAudio()
        hub.installVideoSlotForTests(clientId: "a", sourceID: "win:1", slot: 0, audioSlot: 1)
        hub.installVideoSlotForTests(clientId: "a", sourceID: "win:2", slot: 2, audioSlot: 3)
        hub.installVideoSlotForTests(clientId: "a", sourceID: "win:3", slot: 4, audioSlot: 5)
        sim.installStreamForTests(sourceID: "win:1", target: .window(1), ownerPID: 100, audioEncoder: carrier)
        sim.installStreamForTests(sourceID: "win:2", target: .window(2), ownerPID: 100, audioEncoder: sibling)
        sim.installStreamForTests(sourceID: "win:3", target: .window(3), ownerPID: 200, audioEncoder: muted)
        sim.setSourceAudio(sourceID: "win:3", enabled: false, requestedBy: "a")
        XCTAssertEqual([carrier.attached, sibling.attached, muted.attached], [1, 0, 0],
                       "precondition: the first subscriber of pid 100 carries; its sibling yields; win:3 is muted")

        send(#"{"t":"set-visibility","hidden":true}"#)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertTrue(hub.isMediaPaused, "precondition")
        XCTAssertEqual([carrier.attached, sibling.attached, muted.attached], [0, 0, 0], "hidden: no audio at all")

        send(#"{"t":"set-visibility","hidden":false}"#)
        XCTAssertEqual(carrier.attached, 1, "shown: the carrier's audio comes back")
        XCTAssertEqual(sibling.attached, 0, "a yielded sibling stays silent")
        XCTAssertEqual(muted.attached, 0, "a muted source stays silent")
    }

    /// The election must not attach audio to a client whose pause is in force (a subscribe or an
    /// audio toggle while the page is hidden): the resume does that.
    func testTheElectionAttachesNoAudioWhileThePauseIsInForce() {
        let hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: NullVideo(),
                             terminalPauseHold: .milliseconds(50), mediaPauseHold: .milliseconds(50))
        let sim = SimManager(makeEncoder: { _, _, _, _ in NullVideo() }, channelHub: hub,
                             defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                             bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000)
        hub.simDelegate = sim
        hub.isVideoSubscribed = { true }
        defer { hub.simDelegate = nil }
        let a = PionPeer(clientId: "a", turn: nil); peers.append(a)
        hub.register(clientId: "a", peer: a)
        func send(_ json: String) { hub.pionPeer(a, didReceive: wrapMessage(Data(json.utf8)), on: .control) }
        send(#"{"t":"set-visibility","hidden":true}"#)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertTrue(hub.isMediaPaused, "precondition")

        let enc = AttachedAudio()
        hub.installVideoSlotForTests(clientId: "a", sourceID: "win:1", slot: 0, audioSlot: 1)
        sim.installStreamForTests(sourceID: "win:1", target: .window(1), ownerPID: 100, audioEncoder: enc)
        XCTAssertEqual(enc.attached, 0, "no audio to a hidden page")
        send(#"{"t":"set-visibility","hidden":false}"#)
        XCTAssertEqual(enc.attached, 1, "the resume attaches it")
    }

    /// THE ELECTION'S ATTACH IS ORDERED WITH THE PAUSE (deferred item, 2026-09-27). `reconcileAudio`
    /// read `deliversMedia` and then attached, both OFF the media queue — so a pause that applied
    /// between the two dropped the (not yet attached) sink, and the attach then landed on a client
    /// whose pause was in force, where it stayed until the resume. The barrier sits inside `addSink`,
    /// after the decision: the hidden report is made there and the barrier waits for the pause's
    /// `removeSink`. Before the fix that arrives (the pause ran in the gap) and the sink is attached
    /// afterwards; after it, the pause cannot run until the election has finished, so the barrier
    /// times out, and the pause then removes what the election attached.
    func testAPauseStartingDuringTheElectionIsNotOvertakenByItsAttach() {
        let hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: NullVideo(),
                             terminalPauseHold: .milliseconds(50), mediaPauseHold: .milliseconds(0))
        let sim = SimManager(makeEncoder: { _, _, _, _ in NullVideo() }, channelHub: hub,
                             defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                             bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000)
        hub.simDelegate = sim
        hub.isVideoSubscribed = { true }
        defer { hub.simDelegate = nil }
        let a = PionPeer(clientId: "a", turn: nil); peers.append(a)
        hub.register(clientId: "a", peer: a)

        let enc = BarrierAudio()
        hub.installVideoSlotForTests(clientId: "a", sourceID: "win:1", slot: 0, audioSlot: 1)
        sim.installStreamForTests(sourceID: "win:1", target: .window(1), ownerPID: 100, audioEncoder: enc)
        sim.setSourceAudio(sourceID: "win:1", enabled: false, requestedBy: "a")
        XCTAssertEqual(enc.attached, 0, "precondition: muted")
        while enc.removed.wait(timeout: .now()) == .success {}   // drain the mute's own removals

        var pauseRanInTheGap = false
        enc.arm {
            hub.setVisibility(clientId: "a", hidden: true)   // schedules the hold; takes no media queue
            pauseRanInTheGap = enc.removed.wait(timeout: .now() + 1) == .success
        }
        let unmuted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            sim.setSourceAudio(sourceID: "win:1", enabled: true, requestedBy: "a")
            unmuted.signal()
        }
        XCTAssertEqual(unmuted.wait(timeout: .now() + 5), .success, "the unmute finished (no deadlock)")
        let deadline = Date().addingTimeInterval(5)
        while !hub.isMediaPaused && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(hub.isMediaPaused, "precondition: the pause applied")
        XCTAssertFalse(pauseRanInTheGap, "the pause must not run between the election's decision and its attach")
        // `mediaPaused` is set before `pauseVideo`'s removal: wait for the removal itself.
        XCTAssertEqual(enc.removed.wait(timeout: .now() + 5), .success, "the pause dropped the audio sink")
        XCTAssertEqual(enc.attached, 0, "no audio sink on a paused client")
    }

    /// TWO ELECTIONS APPLY IN THE ORDER THEIR INPUTS CHANGED (review finding 3, 2026-09-27). The
    /// election snapshotted carriers, mutes and encoders under `SimManager.lock` and only THEN entered
    /// the media queue, so a mute whose election was overtaken by the unmute's applied its stale
    /// "muted" snapshot last — the source stayed silent with the client's mute set empty. The hook
    /// holds the mute's election just before the queue; the unmute runs to completion meanwhile.
    func testAnOvertakenElectionDoesNotApplyAStaleSnapshot() {
        let hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: NullVideo(),
                             terminalPauseHold: .milliseconds(50), mediaPauseHold: .milliseconds(50))
        let sim = SimManager(makeEncoder: { _, _, _, _ in NullVideo() }, channelHub: hub,
                             defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                             bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000)
        hub.simDelegate = sim
        hub.isVideoSubscribed = { true }
        defer { hub.simDelegate = nil; sim.electionWillEnterMediaQueueForTests = nil }
        let a = PionPeer(clientId: "a", turn: nil); peers.append(a)
        hub.register(clientId: "a", peer: a)

        let enc = AttachedAudio()
        hub.installVideoSlotForTests(clientId: "a", sourceID: "win:1", slot: 0, audioSlot: 1)
        sim.installStreamForTests(sourceID: "win:1", target: .window(1), ownerPID: 100, audioEncoder: enc)
        XCTAssertEqual(enc.attached, 1, "precondition: the carrier is attached")

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let armed = NSLock()
        var once = true
        sim.electionWillEnterMediaQueueForTests = {
            let first: Bool = armed.withLock { defer { once = false }; return once }
            guard first else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        let muted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            sim.setSourceAudio(sourceID: "win:1", enabled: false, requestedBy: "a")
            muted.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the mute's election is held")
        sim.setSourceAudio(sourceID: "win:1", enabled: true, requestedBy: "a")   // overtakes it
        release.signal()
        XCTAssertEqual(muted.wait(timeout: .now() + 5), .success, "the mute's election finished")
        XCTAssertEqual(enc.attached, 1, "the unmute is the latest state: the carrier stays attached")
    }

    /// DRAGGING A WINDOW'S TAB MUST NOT MOVE ITS APPLICATION'S AUDIO (review I1, 2026-10-01): the election
    /// read `streamed`, which a move reorders, so the NEXT election (any mute, subscribe or resume) moved
    /// the carrier to the sibling dragged in front of it — and the view-set's yielded/muted reporting with it.
    func testMovingAWindowsTabLeavesItsApplicationsCarrierAlone() {
        let hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: NullVideo(),
                             terminalPauseHold: .milliseconds(50), mediaPauseHold: .milliseconds(50))
        let sim = SimManager(makeEncoder: { _, _, _, _ in NullVideo() }, channelHub: hub,
                             defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                             bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000)
        hub.simDelegate = sim
        hub.isVideoSubscribed = { true }
        defer { hub.simDelegate = nil }
        let a = PionPeer(clientId: "a", turn: nil); peers.append(a)
        hub.register(clientId: "a", peer: a)

        let first = AttachedAudio(), second = AttachedAudio()
        hub.installVideoSlotForTests(clientId: "a", sourceID: "win:1", slot: 0, audioSlot: 1)
        hub.installVideoSlotForTests(clientId: "a", sourceID: "win:2", slot: 2, audioSlot: 3)
        sim.installStreamForTests(sourceID: "win:1", target: .window(1), ownerPID: 100, audioEncoder: first)
        sim.installStreamForTests(sourceID: "win:2", target: .window(2), ownerPID: 100, audioEncoder: second)
        XCTAssertEqual([first.attached, second.attached], [1, 0], "precondition: the first opened carries")

        XCTAssertNotNil(sim.moveTab("win:2", before: "win:1"), "precondition: the bar moved")
        sim.reconcileAudio()                                // the next election, whatever runs it
        XCTAssertEqual([first.attached, second.attached], [1, 0], "the carrier is still the first OPENED")
    }
}

