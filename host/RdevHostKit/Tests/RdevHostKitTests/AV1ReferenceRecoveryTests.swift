import XCTest
import CoreVideo
import RdevCore
@testable import RdevHostKit

final class AV1ReferenceRecoveryTests: XCTestCase {
    private final class Encoder: VideoEncoding {
        var codec: NegotiatedCodec { .av1 }
        var requests: [RecoveryIntent] = []
        func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64) {}
        func addSink(_ sink: any VideoTrackSink) {}
        func removeSink(_ sink: any VideoTrackSink) {}
        func removeAllSinks() {}
        func requestKeyframe() { requests.append(.independentKeyframe) }
        func requestRecovery(_ intent: RecoveryIntent) { requests.append(intent) }
        func setFps(_ value: Int) {}
        func setBitrate(_ value: Int) {}
        func setCrop(_ value: CropRect) {}
        func invalidate() {}
    }
    func testHubRejectsRetiredAndPassivePeersAndKeepsLegacyRecoveryIndependent() {
        let encoder = Encoder()
        let hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: encoder)
        let retired = PionPeer(clientId: "driver", turn: nil)
        let current = PionPeer(clientId: "driver", turn: nil)
        let passive = PionPeer(clientId: "passive", turn: nil)
        defer { retired.close(); current.close(); passive.close() }
        hub.register(clientId: "driver", peer: retired)
        hub.rebindPeer(clientId: "driver", peer: current)
        hub.register(clientId: "passive", peer: passive)
        hub.installVideoSlotForTests(clientId: "driver", sourceID: "test", slot: 0)
        hub.requestReferenceRecovery(peer: retired, slot: 0, intent: .repairEstablishedStream)
        hub.requestReferenceRecovery(peer: passive, slot: 0, intent: .repairEstablishedStream)
        XCTAssertTrue(encoder.requests.isEmpty)
        hub.requestReferenceRecovery(peer: current, slot: 0, intent: .repairEstablishedStream)
        XCTAssertEqual(encoder.requests, [.independentKeyframe], "a peer with no acknowledged-reference capability uses legacy recovery")
    }

    final class Rig {
        var now: UInt64 = 0
        var messages: [[String: Any]] = []
        var fallback = 0
        var retries = 0
        var outcomes: [ReferenceAttemptOutcome] = []
        lazy var controller = AV1ReferenceRecovery(source: "win:1", now: { [unowned self] in now },
            send: { [unowned self] in messages.append($0) },
            requestIndependent: { [unowned self] in fallback += 1 },
            outcome: { [unowned self] in outcomes.append($0) },
            requestRepair: { [unowned self] in retries += 1 })
        init() { controller.setConsumer(connectionID: "driver", trackID: "track-1", eligible: true) }
        func prepare(_ id: UInt64, force: Bool = false) -> ReferenceFramePlan {
            controller.prepare(epoch: "encoder-1", frameID: id, force: force, nextWireFrameNumber: id)
        }
        func bound(_ connection: String = "driver", track: String = "track-1") {
            controller.handleReceipt(AV1ReferenceMessage.decode(["t": "av1-ref-bound", "source": "win:1", "epoch": "encoder-1", "trackId": track])!, connectionID: connection)
        }
        func sent(_ plan: ReferenceFramePlan, timestamp: UInt32 = 42, complete: Bool = true) {
            controller.didSend(token: (plan.candidate ?? plan.recovery)!, recoveryID: plan.recoveryID,
                result: ReferenceSendResult(rtpTimestamp: timestamp, wireFrameNumber: (plan.candidate ?? plan.recovery)!.frameID, complete: complete), rttNs: nil)
        }
        func ack(_ plan: ReferenceFramePlan, connection: String = "driver", timestamp: UInt32 = 42) {
            let token = (plan.candidate ?? plan.recovery)!
            var msg: [String: Any] = ["t": "av1-ref-ack", "source": "win:1", "epoch": token.epoch,
                "frameId": String(token.frameID), "slot": Int(token.slot), "slotGeneration": String(token.slotGeneration),
                "rtpTimestamp": timestamp, "purpose": plan.recoveryID == nil ? "candidate" : "recovery"]
            if let id = plan.recoveryID { msg["recoveryId"] = id }
            controller.handleReceipt(AV1ReferenceMessage.decode(msg)!, connectionID: connection)
        }
    }
    func testEligibilityRequiresRemoteSingleAV1RTPConsumerAndCapability() {
        XCTAssertTrue(AV1ReferenceRecovery.canEnable(capability: 1, codec: .av1, remote: true, rtp: true, consumers: 1, descriptor: true))
        XCTAssertFalse(AV1ReferenceRecovery.canEnable(capability: nil, codec: .av1, remote: true, rtp: true, consumers: 1, descriptor: true))
        XCTAssertFalse(AV1ReferenceRecovery.canEnable(capability: 1, codec: .h265, remote: true, rtp: true, consumers: 1, descriptor: true))
        XCTAssertFalse(AV1ReferenceRecovery.canEnable(capability: 1, codec: .av1, remote: false, rtp: true, consumers: 1, descriptor: true))
        XCTAssertFalse(AV1ReferenceRecovery.canEnable(capability: 1, codec: .av1, remote: true, rtp: false, consumers: 1, descriptor: true))
        XCTAssertFalse(AV1ReferenceRecovery.canEnable(capability: 1, codec: .av1, remote: true, rtp: true, consumers: 2, descriptor: true))
        XCTAssertFalse(AV1ReferenceRecovery.canEnable(capability: 1, codec: .av1, remote: true, rtp: true, consumers: 1, descriptor: false))
    }
    func testResetDisablesUnsupportedReceiverAndCallbacksCanReadController() {
        var controller: AV1ReferenceRecovery!
        var unsupported = 0, fallback = 0, sends = 0
        controller = AV1ReferenceRecovery(source: "win:1", send: { _ in
            XCTAssertTrue(controller.isEligible); sends += 1
        }, requestIndependent: {
            _ = controller.currentEpoch; fallback += 1
        }, outcome: { _ in _ = controller.currentEpoch }, unsupported: {
            XCTAssertFalse(controller.isEligible); unsupported += 1
        })
        controller.setConsumer(connectionID: "driver", trackID: "track", eligible: true)
        _ = controller.prepare(epoch: "e", frameID: 1, force: true, nextWireFrameNumber: 1)
        let reset = AV1ReferenceMessage.decode(["t": "av1-ref-reset", "source": "win:1", "epoch": "e", "reason": "timestamps-unavailable"])!
        controller.handleReceipt(reset, connectionID: "old-driver")
        XCTAssertTrue(controller.isEligible)
        controller.handleReceipt(reset, connectionID: "driver")
        XCTAssertEqual(unsupported, 1); XCTAssertEqual(fallback, 1)
        controller.handleReceipt(reset, connectionID: "driver")
        XCTAssertEqual(unsupported, 1); XCTAssertEqual(sends, 1)
        controller.invalidate()
    }

    func testDelayedSendCannotAnnounceAnExpiredCandidate() {
        let r = Rig(), plan = r.prepare(1, force: true)
        r.bound()
        r.now = 5_000_000_001
        r.sent(plan)
        XCTAssertEqual(r.messages.compactMap { $0["t"] as? String }, ["av1-ref-bind"])
    }
    func testBindingMustMatchDriverAndTrackBeforeAnyNotice() {
        let r = Rig(), first = Rig()
        let plan = r.prepare(1, force: true)
        r.sent(plan)
        XCTAssertEqual(r.messages.compactMap { $0["t"] as? String }, ["av1-ref-bind"])
        r.bound("passive"); r.bound(track: "old-track")
        XCTAssertEqual(r.messages.count, 1)
        r.bound()
        XCTAssertEqual(r.messages.last?["t"] as? String, "av1-ref-frame")
        r.ack(plan, connection: "passive"); r.ack(plan, timestamp: 43)
        r.controller.request(.repairEstablishedStream)
        XCTAssertTrue(r.prepare(2).forceIndependent)
        XCTAssertTrue(first.messages.isEmpty, "another source/client controller is independent")
    }
    func testPresentationPromotesAndRecoveryWaitsForItsOwnReceipt() {
        let r = Rig(), plan = r.prepare(1, force: true)
        r.bound(); r.sent(plan); r.ack(plan)
        r.controller.request(.repairEstablishedStream)
        let recovery = r.prepare(2)
        XCTAssertEqual(recovery.referenceIDs, [1]); XCTAssertFalse(recovery.forceIndependent)
        r.sent(recovery, timestamp: 43)
        r.ack(plan)
        XCTAssertFalse(r.outcomes.contains { $0.kind == .presented })
        r.ack(recovery, timestamp: 43)
        XCTAssertEqual(r.outcomes.last?.kind, .presented)
        r.now = 3_000_000_000; r.controller.tick()
        XCTAssertEqual(r.fallback, 0)
    }
    func testTimeoutAndPartialSendDeferRetryUntilDebouncePermission() {
        for complete in [false, true] {
            let r = Rig(), first = r.prepare(1, force: true)
            r.bound(); r.sent(first); r.ack(first)
            r.controller.request(.repairEstablishedStream)
            let recovery = r.prepare(2); r.sent(recovery, complete: complete)
            r.now = 1_000_000_000; r.controller.tick()
            XCTAssertEqual(r.fallback, 0); XCTAssertEqual(r.retries, 1)
            let waiting = r.prepare(3)
            XCTAssertFalse(waiting.forceIndependent); XCTAssertNil(waiting.recovery, "retry cannot bypass debounce")
            r.controller.request(.repairEstablishedStream)
            let retry = r.prepare(4)
            XCTAssertFalse(retry.forceIndependent); XCTAssertEqual(retry.referenceIDs, [1])
            XCTAssertNotNil(retry.recovery)
            r.ack(recovery)
            XCTAssertFalse(r.outcomes.contains { $0.kind == .presented })
        }
    }
    func testDriverReplacementAndIneligibleClientsCannotAcknowledge() {
        let r = Rig(), old = r.prepare(1, force: true)
        r.bound(); r.sent(old)
        r.controller.setConsumer(connectionID: "next", trackID: "track-2", eligible: false)
        r.ack(old)
        r.controller.request(.repairEstablishedStream)
        XCTAssertTrue(r.prepare(2).forceIndependent)
        XCTAssertFalse(r.controller.isEligible)
        r.controller.invalidate()
        let count = r.messages.count; r.controller.tick(); r.bound()
        XCTAssertEqual(r.messages.count, count)
    }
    func testUnchangedConsumerPreservesBindingButEncoderEpochDoesNot() {
        let r = Rig(), first = r.prepare(1, force: true)
        r.bound(); r.sent(first); r.ack(first)
        r.controller.setConsumer(connectionID: "driver", trackID: "track-1", eligible: true)
        r.controller.request(.repairEstablishedStream)
        XCTAssertFalse(r.prepare(2).forceIndependent)
        let reset = r.controller.prepare(epoch: "encoder-2", frameID: 1, force: false, nextWireFrameNumber: 3)
        XCTAssertTrue(reset.forceIndependent)
        XCTAssertEqual(r.messages.last?["epoch"] as? String, "encoder-2")
    }
    func testFailedTransportWritesPreserveAnchorAndEventuallyFallBack() {
        let r = Rig(), first = r.prepare(1, force: true)
        r.bound(); r.sent(first); r.ack(first)
        for n: UInt64 in 2...4 {
            r.controller.request(.repairEstablishedStream)
            let plan = r.prepare(n)
            XCTAssertEqual(plan.referenceIDs, [1])
            r.controller.deliveryFailed()
            XCTAssertEqual(r.fallback, n == 4 ? 1 : 0)
        }
        XCTAssertEqual(r.retries, 2)
        r.controller.request(.independentKeyframe)
        XCTAssertTrue(r.prepare(5).forceIndependent)
    }

}
