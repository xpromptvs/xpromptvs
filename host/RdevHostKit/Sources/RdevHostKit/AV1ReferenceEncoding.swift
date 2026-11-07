import Foundation
import LLVCore
import RdevCore

/// Travels beside encoded bytes, never through a second media transport.
public struct AV1ReferenceFrameMetadata: Equatable, Sendable {
    public let epoch: String
    public let frameID: UInt64
    public let dependencies: [UInt64]
    public let refreshSlotMask: UInt8
    public let token: ReferenceToken?
    public let recoveryID: String?

    var wireObject: [String: Any] {
        var object: [String: Any] = ["v": 1, "epoch": epoch, "frameId": String(frameID),
            "dependencies": dependencies.map(String.init), "refreshSlotMask": Int(refreshSlotMask)]
        if let token {
            object["token"] = ["epoch": token.epoch, "frameId": String(token.frameID),
                "slot": Int(token.slot), "slotGeneration": String(token.slotGeneration)]
        }
        if let recoveryID { object["recoveryId"] = recoveryID }
        return object
    }
}

/// Codec slot contents are committed only when encoding succeeds. The two anchor slots
/// are never enabled for ordinary prediction; their only use is an explicit repair.
/// The six-slot rolling policy is a qualification candidate, not enabled by default.
struct AV1ReferenceEncoding {
    struct Prepared {
        let control: AV1ReferenceControl
        let metadata: AV1ReferenceFrameMetadata
        let independent: Bool
    }
    enum PlanError: Error { case missingReference, invalidToken }
    private var slots = [UInt64?](repeating: nil, count: 8)
    mutating func reset() { slots = [UInt64?](repeating: nil, count: 8) }

    func prepare(_ plan: ReferenceFramePlan, epoch: String, frameID: UInt64) throws -> Prepared {
        let token = plan.candidate ?? plan.recovery
        if let token {
            guard token.epoch == epoch, token.frameID == frameID, token.slot < 8 else { throw PlanError.invalidToken }
        }
        let mapping: [UInt8]
        let enabled: UInt8
        let refresh: UInt8
        if plan.forceIndependent {
            mapping = Array(0...6); enabled = 0; refresh = 255
        } else if plan.recovery != nil {
            guard plan.referenceIDs.count == 1,
                  let anchor = (6...7).first(where: { slots[$0] == plan.referenceIDs[0] }) else { throw PlanError.missingReference }
            mapping = [UInt8(anchor), 0, 1, 2, 3, 4, 5]
            enabled = 1; refresh = 63
        } else {
            guard slots.prefix(6).allSatisfy({ $0 != nil }) else { throw PlanError.missingReference }
            let next = Int((frameID - 1) % 6)
            mapping = (1...6).map { UInt8((next + 6 - $0) % 6) } + [plan.candidate?.slot ?? 7]
            // WebKit's EncodedFrame::kMaxFrameReferences is five. Keep six storage slots,
            // but predict only from the five newest mapped frames; declaring fewer than
            // libaom can actually use would instead produce silently corrupt recovery.
            enabled = 31; refresh = (1 << UInt8(next)) | plan.refreshSlotMask
        }
        let dependencies = plan.forceIndependent ? [] : try Set(mapping.enumerated().compactMap { index, slot -> UInt64? in
            guard enabled & (1 << index) != 0 else { return nil }
            guard let id = slots[Int(slot)] else { throw PlanError.missingReference }
            return id
        }).sorted()
        return Prepared(control: try AV1ReferenceControl(referenceSlots: mapping, enabledReferences: enabled,
            refreshSlotMask: refresh, recovery: plan.recovery != nil),
            metadata: AV1ReferenceFrameMetadata(epoch: epoch, frameID: frameID, dependencies: dependencies,
                refreshSlotMask: refresh, token: token, recoveryID: plan.recoveryID), independent: plan.forceIndependent)
    }
    mutating func commit(_ prepared: Prepared) {
        for slot in 0..<8 where prepared.metadata.refreshSlotMask & (1 << slot) != 0 {
            slots[slot] = prepared.metadata.frameID
        }
    }
}
