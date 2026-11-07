import XCTest
@testable import RdevCore

final class AV1ReferenceStateTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000
    private func sent(_ state: inout AV1ReferenceState, _ token: ReferenceToken, wire: UInt64 = 0,
                      now: UInt64 = 0, rtt: UInt64? = nil, complete: Bool = true) {
        state.didSend(token: token, result: ReferenceSendResult(rtpTimestamp: UInt32(truncatingIfNeeded: wire),
            wireFrameNumber: wire, complete: complete), nowNs: now, rttNs: rtt)
    }
    private func established() throws -> AV1ReferenceState {
        var state = AV1ReferenceState(epoch: "a")
        let token = try XCTUnwrap(state.prepareFrame(frameID: 0, nowNs: 0, intent: .independentKeyframe).candidate)
        sent(&state, token)
        XCTAssertEqual(state.acknowledge(token: token, recoveryID: nil, nowNs: 0), .promote(token))
        return state
    }
    func testCandidateIntervalAndProtectionUntilReceipt() throws {
        var state = try established()
        let confirmed = state.confirmed
        XCTAssertNil(state.prepareFrame(frameID: 1, nowNs: second - 1, intent: nil).candidate)
        let candidate = try XCTUnwrap(state.prepareFrame(frameID: 2, nowNs: second, intent: nil).candidate)
        XCTAssertNotEqual(candidate.slot, confirmed?.slot)
        XCTAssertEqual(state.confirmed, confirmed)
        XCTAssertEqual(state.acknowledge(token: candidate, recoveryID: nil, nowNs: second), .none)
        sent(&state, candidate, wire: 2, now: second)
        XCTAssertEqual(state.acknowledge(token: candidate, recoveryID: nil, nowNs: second), .promote(candidate))
        XCTAssertEqual(state.acknowledge(token: candidate, recoveryID: nil, nowNs: second), .none)
    }
    func testExpiredGenerationCannotPromoteReusedSlot() throws {
        var state = try established()
        let old = try XCTUnwrap(state.prepareFrame(frameID: 1, nowNs: second, intent: nil).candidate)
        sent(&state, old, wire: 1, now: second)
        XCTAssertTrue(state.advance(nowNs: 6 * second - 1).isEmpty)
        XCTAssertEqual(state.advance(nowNs: 6 * second), [.expire(old)])
        let new = try XCTUnwrap(state.prepareFrame(frameID: 2, nowNs: 6 * second, intent: nil).candidate)
        XCTAssertEqual(new.slot, old.slot)
        XCTAssertGreaterThan(new.slotGeneration, old.slotGeneration)
        sent(&state, new, wire: 2, now: 6 * second)
        let forged = ReferenceToken(epoch: new.epoch, frameID: new.frameID, slot: new.slot, slotGeneration: old.slotGeneration)
        XCTAssertEqual(state.acknowledge(token: forged, recoveryID: nil, nowNs: 6 * second), .none)
        XCTAssertEqual(state.acknowledge(token: old, recoveryID: nil, nowNs: 6 * second), .none)
        XCTAssertEqual(state.acknowledge(token: new, recoveryID: nil, nowNs: 6 * second), .promote(new))
    }
    func testWatchdogStartsAfterCompleteSend() throws {
        for (rtt, wait): (UInt64?, UInt64) in [(50_000_000, 500_000_000), (800_000_000, 2_000_000_000), (nil, 1_000_000_000)] {
            var state = try established()
            let plan = state.prepareFrame(frameID: 1, nowNs: 1, intent: .repairEstablishedStream, nextWireFrameNumber: 1)
            let token = try XCTUnwrap(plan.recovery)
            XCTAssertTrue(state.advance(nowNs: 10 * second).isEmpty)
            sent(&state, token, wire: 1, now: 10 * second, rtt: rtt)
            XCTAssertTrue(state.advance(nowNs: 10 * second + wait - 1).isEmpty)
            XCTAssertEqual(state.advance(nowNs: 10 * second + wait), [.retryRecovery])
            XCTAssertEqual(state.acknowledge(token: token, recoveryID: plan.recoveryID, nowNs: 13 * second), .none)
        }
    }
    func testOneAttemptAndOnlyItsReceiptCompletesIt() throws {
        var state = try established()
        let plan = state.prepareFrame(frameID: 1, nowNs: 1, intent: .repairEstablishedStream, nextWireFrameNumber: 1)
        let token = try XCTUnwrap(plan.recovery)
        XCTAssertNil(state.prepareFrame(frameID: 2, nowNs: 2, intent: .repairEstablishedStream, nextWireFrameNumber: 2).recovery)
        sent(&state, token, wire: 1)
        XCTAssertEqual(state.acknowledge(token: token, recoveryID: "wrong", nowNs: 3), .none)
        XCTAssertEqual(state.acknowledge(token: token, recoveryID: plan.recoveryID, nowNs: 3), .completeAttempt(plan.recoveryID!))
        XCTAssertTrue(state.advance(nowNs: 3 * second).isEmpty)
    }
    func testPartialSendRetriesAndDoesNotConfirm() throws {
        var state = try established()
        let plan = state.prepareFrame(frameID: 1, nowNs: 1, intent: .repairEstablishedStream, nextWireFrameNumber: 1)
        let token = try XCTUnwrap(plan.recovery)
        sent(&state, token, complete: false)
        XCTAssertEqual(state.acknowledge(token: token, recoveryID: plan.recoveryID, nowNs: 2), .none)
        XCTAssertEqual(state.advance(nowNs: 2), [.retryRecovery])
    }
    func testWireDistanceUsesFullCountersAndRequiresKnownSenderPosition() throws {
        for (distance, independent): (UInt64?, Bool) in [(255, false), (256, true), (0, true), (nil, true)] {
            var state = try established()
            let plan = state.prepareFrame(frameID: 1000, nowNs: 1, intent: .repairEstablishedStream, nextWireFrameNumber: distance)
            XCTAssertEqual(plan.forceIndependent, independent)
        }
        var state = AV1ReferenceState(epoch: "wrap")
        let anchor = try XCTUnwrap(state.prepareFrame(frameID: 65535, nowNs: 0, intent: .independentKeyframe).candidate)
        sent(&state, anchor, wire: 65535)
        _ = state.acknowledge(token: anchor, recoveryID: nil, nowNs: 0)
        XCTAssertNotNil(state.prepareFrame(frameID: 65536, nowNs: 1, intent: .repairEstablishedStream, nextWireFrameNumber: 65536).recovery)
    }
    func testResetAndIndependentKeyframeRevokeOldReceipts() throws {
        var state = try established()
        let old = try XCTUnwrap(state.confirmed)
        let key = state.prepareFrame(frameID: 1, nowNs: 1, intent: .independentKeyframe)
        XCTAssertTrue(key.forceIndependent)
        XCTAssertNil(state.confirmed)
        XCTAssertEqual(state.acknowledge(token: old, recoveryID: nil, nowNs: 2), .none)
        let pending = try XCTUnwrap(key.candidate)
        state.reset(epoch: "b")
        sent(&state, pending)
        XCTAssertEqual(state.acknowledge(token: pending, recoveryID: nil, nowNs: 2), .none)
        XCTAssertNil(state.confirmed)
    }
    func testRecoveryCancelsCandidateAndRefreshesSixNormalSlots() throws {
        var state = try established()
        let candidate = try XCTUnwrap(state.prepareFrame(frameID: 1, nowNs: second, intent: nil).candidate)
        sent(&state, candidate, wire: 1)
        let repair = state.prepareFrame(frameID: 2, nowNs: second + 1, intent: .repairEstablishedStream, nextWireFrameNumber: 2)
        XCTAssertEqual(repair.referenceIDs, [0])
        XCTAssertLessThan(try XCTUnwrap(repair.recovery).slot, 6, "recovery identity must name an actually refreshed ordinary slot")
        XCTAssertEqual(repair.refreshSlotMask & 63, 63)
        XCTAssertEqual(repair.refreshSlotMask & (1 << state.confirmed!.slot), 0)
        XCTAssertEqual(state.acknowledge(token: candidate, recoveryID: nil, nowNs: second + 2), .none)
    }
    func testFailedInitialSendRearmsIndependentFrame() throws {
        var state = AV1ReferenceState(epoch: "a")
        let first = try XCTUnwrap(state.prepareFrame(frameID: 0, nowNs: 0, intent: nil).candidate)
        sent(&state, first, complete: false)
        XCTAssertTrue(state.prepareFrame(frameID: 1, nowNs: 1, intent: nil).forceIndependent)
    }
    func testSeparateSourcesDoNotShareAnchors() throws {
        let first = try established()
        var second = AV1ReferenceState(epoch: "a")
        XCTAssertEqual(second.acknowledge(token: first.confirmed!, recoveryID: nil, nowNs: 0), .none)
        XCTAssertNil(second.confirmed)
    }
    func testTimedOutRepairRetriesRetainedAnchorBeforeGivingUp() throws {
        var state = try established()
        for n: UInt64 in 1...3 {
            let plan = state.prepareFrame(frameID: n, nowNs: n * second, intent: .repairEstablishedStream, nextWireFrameNumber: n)
            XCTAssertFalse(plan.forceIndependent)
            XCTAssertEqual(plan.referenceIDs, [0])
            let token = try XCTUnwrap(plan.recovery)
            sent(&state, token, wire: n, now: n * second, rtt: 0)
            let effects = state.advance(nowNs: n * second + 500_000_000)
            XCTAssertEqual(effects.contains(.escalateKeyframe), n == 3)
        }
        XCTAssertTrue(state.prepareFrame(frameID: 4, nowNs: 4 * second, intent: .repairEstablishedStream, nextWireFrameNumber: 4).forceIndependent)
    }

    func testSuccessfulRetryResetsBudgetAndLateReceiptCannotCompleteIt() throws {
        var state = try established()
        let first = state.prepareFrame(frameID: 1, nowNs: 1, intent: .repairEstablishedStream, nextWireFrameNumber: 1)
        sent(&state, try XCTUnwrap(first.recovery), wire: 1, now: 1, complete: false)
        XCTAssertEqual(state.advance(nowNs: 2), [.retryRecovery])
        let second = state.prepareFrame(frameID: 2, nowNs: 3, intent: .repairEstablishedStream, nextWireFrameNumber: 2)
        XCTAssertNotEqual(first.recoveryID, second.recoveryID)
        sent(&state, try XCTUnwrap(second.recovery), wire: 2, now: 3)
        XCTAssertEqual(state.acknowledge(token: first.recovery!, recoveryID: first.recoveryID, nowNs: 4), .none)
        XCTAssertEqual(state.acknowledge(token: second.recovery!, recoveryID: second.recoveryID, nowNs: 4), .completeAttempt(second.recoveryID!))
        for n: UInt64 in 3...5 {
            let plan = state.prepareFrame(frameID: n, nowNs: n, intent: .repairEstablishedStream, nextWireFrameNumber: n)
            XCTAssertNotNil(plan.recovery)
            sent(&state, plan.recovery!, wire: n, now: n, complete: false)
            XCTAssertEqual(state.advance(nowNs: n), n == 5 ? [.escalateKeyframe] : [.retryRecovery])
        }
    }

}
