import Foundation
import RdevCore

/// One source's policy. Encoding may enter prepare() while holding encLock; all
/// effects run after this object's lock is released. Production effects enqueue
/// work and never wait for the control transport or reenter the encoder.
final class AV1ReferenceRecovery: @unchecked Sendable {
    static func canEnable(capability: Int?, codec: NegotiatedCodec, remote: Bool, rtp: Bool,
                          consumers: Int, descriptor: Bool) -> Bool {
        capability == 1 && codec == .av1 && remote && rtp && consumers == 1 && descriptor
    }
    var currentEpoch: String { lock.withLock { state.epoch } }

    private struct Expected {
        let recoveryID: String?
        var sent: ReferenceSendResult?
        var notified = false
    }
    private struct Effects {
        var messages: [[String: Any]] = []
        var outcomes: [ReferenceAttemptOutcome] = []
        var fallback = false
        var retry = false
    }
    private let lock = NSLock()
    private let source: String
    private let now: () -> UInt64
    private let send: ([String: Any]) -> Void
    private let requestIndependent: () -> Void
    private let requestRepair: () -> Void
    private let outcome: (ReferenceAttemptOutcome) -> Void
    private let unsupported: () -> Void
    private var state = AV1ReferenceState(epoch: "")
    private var connectionID = "", trackID = ""
    private var eligible = false, invalid = false, bound = false, waitingForIndependent = false
    private var waitingForRepair = false
    private var intent: RecoveryIntent?
    private var expected: [ReferenceToken: Expected] = [:]
    var isEligible: Bool { lock.withLock { eligible && !invalid } }

    init(source: String, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         send: @escaping ([String: Any]) -> Void, requestIndependent: @escaping () -> Void,
         outcome: @escaping (ReferenceAttemptOutcome) -> Void, requestRepair: @escaping () -> Void = {}, unsupported: @escaping () -> Void = {}) {
        self.source = source; self.now = now; self.send = send; self.requestRepair = requestRepair
        self.requestIndependent = requestIndependent; self.outcome = outcome; self.unsupported = unsupported
    }
    private func perform(_ effects: Effects) {
        for message in effects.messages { send(message) }
        for value in effects.outcomes { outcome(value) }
        if effects.fallback { requestIndependent() } else if effects.retry { requestRepair() }
    }
    private func revoke(_ kind: ReferenceAttemptOutcome.Kind, effects: inout Effects) {
        for (token, record) in expected {
            if let id = record.recoveryID { effects.outcomes.append(.init(epoch: token.epoch, recoveryID: id, kind: kind)) }
        }
        expected.removeAll()
    }
    func setConsumer(connectionID: String, trackID: String, eligible: Bool) {
        var effects = Effects()
        lock.lock()
        if self.connectionID != connectionID || self.trackID != trackID || self.eligible != eligible {
            revoke(.cancelled, effects: &effects)
            self.connectionID = connectionID; self.trackID = trackID; self.eligible = eligible
            bound = false; waitingForIndependent = false; waitingForRepair = false; intent = .independentKeyframe
            state.reset(epoch: "")
        }
        lock.unlock(); perform(effects)
    }
    func request(_ value: RecoveryIntent) {
        lock.withLock {
            guard !invalid else { return }
            if value == .independentKeyframe { intent = value; waitingForIndependent = false; waitingForRepair = false }
            else if intent == nil && !waitingForIndependent { intent = value; waitingForRepair = false }
        }
    }
    private func fallback(_ effects: inout Effects) {
        guard !waitingForIndependent else { return }
        revoke(.failed, effects: &effects)
        waitingForIndependent = true; waitingForRepair = false; intent = nil; effects.fallback = true
        if ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1" { print("[av1-ref] fallback source=\(source) reason=\(state.independentReason)") }
    }
    private func advance(_ effects: inout Effects) {
        for value in state.advance(nowNs: now()) {
            switch value {
            case .expire(let token): expected[token] = nil
            case .retryRecovery:
                if !waitingForIndependent && !waitingForRepair {
                    revoke(.failed, effects: &effects)
                    waitingForRepair = true; intent = nil; effects.retry = true
                }
            case .escalateKeyframe: fallback(&effects)
            default: break
            }
        }
    }
    func prepare(epoch: String, frameID: UInt64, force: Bool, nextWireFrameNumber: UInt64?) -> ReferenceFramePlan {
        var effects = Effects()
        lock.lock()
        guard eligible && !invalid else { lock.unlock(); return ReferenceFramePlan(forceIndependent: true) }
        if state.epoch != epoch {
            revoke(.cancelled, effects: &effects); state.reset(epoch: epoch)
            bound = false; waitingForIndependent = false; waitingForRepair = false; intent = .independentKeyframe
            effects.messages.append(["t": "av1-ref-bind", "source": source, "epoch": epoch, "trackId": trackID])
        }
        advance(&effects)
        if force { intent = .independentKeyframe; waitingForIndependent = false; waitingForRepair = false }
        // A failed send may leave normal traffic undecodable. Sending another keyframe
        // before the host's deferred debounce permits it would create a feedback storm.
        if waitingForIndependent || waitingForRepair { lock.unlock(); perform(effects); return ReferenceFramePlan() }
        let plan = state.prepareFrame(frameID: frameID, nowNs: now(), intent: intent, nextWireFrameNumber: nextWireFrameNumber)
        intent = nil
        if plan.forceIndependent || plan.recovery != nil { revoke(.cancelled, effects: &effects) }
        if plan.forceIndependent && ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1" { print("[av1-ref] independent source=\(source) reason=\(state.independentReason)") }
        if let token = plan.candidate ?? plan.recovery { expected[token] = Expected(recoveryID: plan.recoveryID) }
        lock.unlock(); perform(effects); return plan
    }
    private func notify(_ token: ReferenceToken, effects: inout Effects) {
        guard bound, var record = expected[token], !record.notified, let result = record.sent else { return }
        var message: [String: Any] = ["t": "av1-ref-frame", "source": source, "epoch": token.epoch,
            "frameId": String(token.frameID), "slot": Int(token.slot), "slotGeneration": String(token.slotGeneration),
            "rtpTimestamp": result.rtpTimestamp, "purpose": record.recoveryID == nil ? "candidate" : "recovery"]
        if let id = record.recoveryID { message["recoveryId"] = id }
        record.notified = true; expected[token] = record; effects.messages.append(message)
    }
    func didSend(token: ReferenceToken, recoveryID: String?, result: ReferenceSendResult, rttNs: UInt64?) {
        var effects = Effects()
        lock.lock()
        guard eligible && !invalid, token.epoch == state.epoch else { lock.unlock(); return }
        advance(&effects)
        guard let record = expected[token], record.recoveryID == recoveryID else { lock.unlock(); perform(effects); return }
        state.didSend(token: token, result: result, nowNs: now(), rttNs: rttNs)
        if result.complete {
            expected[token]?.sent = result; notify(token, effects: &effects)
            if let id = recoveryID { effects.outcomes.append(.init(epoch: token.epoch, recoveryID: id, kind: .sent)) }
        } else if recoveryID != nil { /* state queues a bounded retry or escalation below */ }
        else if state.confirmed == nil { fallback(&effects) }
        else { expected[token] = nil }
        advance(&effects)
        lock.unlock(); perform(effects)
    }
    func handleReceipt(_ message: AV1ReferenceMessage, connectionID: String) {
        var effects = Effects(), becameUnsupported = false
        lock.lock()
        guard eligible && !invalid, self.connectionID == connectionID, message.source == source, message.epoch == state.epoch else { lock.unlock(); return }
        advance(&effects)
        switch message.tag {
        case .bound:
            if message.trackID == trackID {
                bound = true
                for token in Array(expected.keys) { notify(token, effects: &effects) }
            }
        case .ack:
            if bound, let token = message.token, let record = expected[token], record.notified,
               record.recoveryID == message.recoveryID, record.sent?.rtpTimestamp == message.rtpTimestamp,
               (record.recoveryID == nil) == (message.purpose == .candidate) {
                switch state.acknowledge(token: token, recoveryID: message.recoveryID, nowNs: now()) {
                case .promote: expected[token] = nil
                case .completeAttempt(let id):
                    expected[token] = nil; effects.outcomes.append(.init(epoch: token.epoch, recoveryID: id, kind: .presented))
                default: break
                }
            }
        case .reset:
            bound = false; state.reset(epoch: state.epoch); fallback(&effects)
            if message.reason == "timestamps-unavailable" { eligible = false; becameUnsupported = true }
        default: break
        }
        lock.unlock(); perform(effects)
        if becameUnsupported { unsupported() }
    }
    func tick() {
        var effects = Effects()
        lock.lock(); if eligible && !invalid { advance(&effects) }; lock.unlock()
        perform(effects)
    }
    /// A send failure damages delivery, not the retained encoder/decoder anchor.
    func deliveryFailed() {
        var effects = Effects()
        lock.lock()
        if eligible && !invalid && !waitingForIndependent && !waitingForRepair {
            state.failRecovery(); advance(&effects)
        }
        lock.unlock(); perform(effects)
    }
    func continuityLost() {
        var effects = Effects()
        lock.lock()
        if eligible && !invalid { state.reset(epoch: state.epoch); fallback(&effects) }
        lock.unlock(); perform(effects)
    }
    func invalidate() {
        var effects = Effects()
        lock.lock(); invalid = true; eligible = false; revoke(.cancelled, effects: &effects); lock.unlock()
        perform(effects)
    }
}
