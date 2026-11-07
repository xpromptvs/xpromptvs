/// Pure decisions, owned by the serialized encoder path. Slots 6/7 are anchors;
/// the codec policy owns ordinary prediction in slots 0...5.
public struct ReferenceSendResult: Equatable, Sendable {
    public let rtpTimestamp: UInt32
    public let wireFrameNumber: UInt64
    public let complete: Bool
    public init(rtpTimestamp: UInt32, wireFrameNumber: UInt64, complete: Bool) {
        self.rtpTimestamp = rtpTimestamp; self.wireFrameNumber = wireFrameNumber; self.complete = complete
    }
}
public struct ReferenceFramePlan: Equatable, Sendable {
    public var candidate: ReferenceToken?
    public var recovery: ReferenceToken?
    public var referenceIDs: [UInt64] = []
    /// Reserved-slot writes, plus all six ordinary slots on recovery. Normal codec
    /// policy adds its own ordinary refresh bit; it must never add reserved bits.
    public var refreshSlotMask: UInt8 = 0
    public var forceIndependent = false
    public var recoveryID: String?
    public init(candidate: ReferenceToken? = nil, recovery: ReferenceToken? = nil,
                referenceIDs: [UInt64] = [], refreshSlotMask: UInt8 = 0,
                forceIndependent: Bool = false, recoveryID: String? = nil) {
        self.candidate = candidate; self.recovery = recovery; self.referenceIDs = referenceIDs
        self.refreshSlotMask = refreshSlotMask; self.forceIndependent = forceIndependent; self.recoveryID = recoveryID
    }
}
public enum ReferenceStateEffect: Equatable, Sendable {
    case none, promote(ReferenceToken), expire(ReferenceToken), escalateKeyframe, retryRecovery, completeAttempt(String)
}
public struct AV1ReferenceState: Sendable {
    private struct Candidate: Sendable {
        let token: ReferenceToken
        let created: UInt64
        var sent: ReferenceSendResult?
    }
    private struct Attempt: Sendable {
        let token: ReferenceToken
        let id: String
        var sentAt: UInt64?
        var timeout: UInt64 = 0
    }
    public private(set) var epoch: String
    public private(set) var confirmed: ReferenceToken?
    private var confirmedWire: UInt64?
    private var pending: Candidate?
    private var attempt: Attempt?
    private var generations = [UInt64](repeating: 0, count: 8)
    private var lastCandidateAt: UInt64?
    private var attemptNumber: UInt64 = 0
    private var needsIndependent = true
    private var unsuccessfulAttempts = 0
    public private(set) var independentReason = "initial"
    private var queued: [ReferenceStateEffect] = []
    public init(epoch: String) { self.epoch = epoch }

    public mutating func reset(epoch: String) {
        self.epoch = epoch
        confirmed = nil; confirmedWire = nil; pending = nil; attempt = nil
        lastCandidateAt = nil; needsIndependent = true; queued = []; unsuccessfulAttempts = 0; independentReason = "reset"
        // Generations deliberately survive even a caller accidentally reusing an epoch.
    }
    private func elapsed(_ now: UInt64, _ then: UInt64) -> UInt64 { now >= then ? now - then : 0 }
    private mutating func token(frameID: UInt64, slot: UInt8) -> ReferenceToken {
        let index = Int(slot)
        precondition(generations[index] < UInt64.max, "reference generation exhausted: recreate encoder")
        generations[index] += 1
        return ReferenceToken(epoch: epoch, frameID: frameID, slot: slot, slotGeneration: generations[index])
    }
    private mutating func expire(now: UInt64) {
        if let candidate = pending, elapsed(now, candidate.created) >= 5_000_000_000 {
            pending = nil; queued.append(.expire(candidate.token))
        }
        if let live = attempt, let sentAt = live.sentAt, elapsed(now, sentAt) >= live.timeout {
            failRecovery()
        }
    }
    /// Repair loss leaves the reserved anchor intact. Only three unsuccessful attempts
    /// may use it before independent recovery handles an unobservable decoder reset.
    public mutating func failRecovery() {
        attempt = nil; pending = nil
        if confirmed != nil && unsuccessfulAttempts < 3 {
            queued.append(.retryRecovery)
        } else {
            needsIndependent = true
            independentReason = confirmed == nil ? "no-confirmed-anchor" : "retry-exhausted"
            queued.append(.escalateKeyframe)
        }
    }
    public mutating func advance(nowNs: UInt64) -> [ReferenceStateEffect] {
        expire(now: nowNs)
        let result = queued; queued = []; return result
    }
    public mutating func prepareFrame(frameID: UInt64, nowNs: UInt64, intent: RecoveryIntent?,
                                     nextWireFrameNumber: UInt64? = nil) -> ReferenceFramePlan {
        expire(now: nowNs)
        if intent == .independentKeyframe { needsIndependent = true; if independentReason != "retry-exhausted" { independentReason = "independent-request" } }
        if intent == .repairEstablishedStream && !needsIndependent && attempt == nil {
            if let anchor = confirmed, let wire = confirmedWire, let next = nextWireFrameNumber,
               next > wire, next - wire <= 255 {
                pending = nil
                let repair = token(frameID: frameID, slot: 0)
                precondition(attemptNumber < UInt64.max)
                attemptNumber += 1
                unsuccessfulAttempts += 1
                let id = String(attemptNumber)
                attempt = Attempt(token: repair, id: id)
                return ReferenceFramePlan(recovery: repair, referenceIDs: [anchor.frameID],
                    refreshSlotMask: 63, recoveryID: id)
            }
            needsIndependent = true
            independentReason = confirmed == nil ? "no-confirmed-anchor" : "anchor-wire-distance"
        }
        if needsIndependent {
            confirmed = nil; confirmedWire = nil; pending = nil; attempt = nil
            unsuccessfulAttempts = 0
            needsIndependent = false
            let key = token(frameID: frameID, slot: 6)
            pending = Candidate(token: key, created: nowNs)
            lastCandidateAt = nowNs
            return ReferenceFramePlan(candidate: key, refreshSlotMask: 255, forceIndependent: true)
        }
        if attempt == nil && pending == nil && lastCandidateAt.map({ elapsed(nowNs, $0) >= 1_000_000_000 }) != false {
            let candidate = token(frameID: frameID, slot: confirmed?.slot == 6 ? 7 : 6)
            pending = Candidate(token: candidate, created: nowNs); lastCandidateAt = nowNs
            return ReferenceFramePlan(candidate: candidate, refreshSlotMask: 1 << candidate.slot)
        }
        return ReferenceFramePlan()
    }
    public mutating func didSend(token: ReferenceToken, result: ReferenceSendResult, nowNs: UInt64, rttNs: UInt64?) {
        expire(now: nowNs)
        if pending?.token == token {
            if result.complete { pending?.sent = result }
            else { pending = nil; if confirmed == nil { needsIndependent = true } }
        }
        guard attempt?.token == token, attempt?.sentAt == nil else { return }
        guard result.complete else {
            failRecovery(); return
        }
        let timeout: UInt64
        if let rttNs { timeout = rttNs >= 500_000_000 ? 2_000_000_000 : max(500_000_000, rttNs * 4) }
        else { timeout = 1_000_000_000 }
        attempt?.sentAt = nowNs; attempt?.timeout = timeout
    }
    public mutating func acknowledge(token: ReferenceToken, recoveryID: String?, nowNs: UInt64) -> ReferenceStateEffect {
        expire(now: nowNs)
        if let live = attempt, live.token == token, live.sentAt != nil, recoveryID == live.id {
            attempt = nil; unsuccessfulAttempts = 0; return .completeAttempt(live.id)
        }
        guard recoveryID == nil, let candidate = pending, candidate.token == token,
              let sent = candidate.sent else { return .none }
        confirmed = token; confirmedWire = sent.wireFrameNumber; pending = nil
        return .promote(token)
    }
}
