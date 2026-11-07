import CAOMBridge

/// Numeric codec controls only. Source/epoch/receipt ownership belongs to the host.
public struct AV1ReferenceControl: Equatable, Sendable {
    public let referenceSlots: [UInt8]
    public let enabledReferences: UInt8
    public let refreshSlotMask: UInt8
    public let recovery: Bool
    public enum ValidationError: Error { case invalidMapping }
    public init(referenceSlots: [UInt8], enabledReferences: UInt8, refreshSlotMask: UInt8, recovery: Bool) throws {
        guard referenceSlots.count == 7, referenceSlots.allSatisfy({ $0 < 8 }), enabledReferences < 128,
              !recovery || enabledReferences.nonzeroBitCount == 1 else { throw ValidationError.invalidMapping }
        let mapped = referenceSlots.reduce(UInt8(0)) { $0 | (1 << $1) }
        // A true keyframe refreshes all slots independently of the reference mapping.
        guard (enabledReferences == 0 && refreshSlotMask == 255) || refreshSlotMask & ~mapped == 0 else {
            throw ValidationError.invalidMapping
        }
        self.referenceSlots = referenceSlots; self.enabledReferences = enabledReferences
        self.refreshSlotMask = refreshSlotMask; self.recovery = recovery
    }
    var bridge: llv_aom_reference_plan {
        var plan = llv_aom_reference_plan()
        withUnsafeMutableBytes(of: &plan.reference_slots) { bytes in
            for i in 0..<7 { bytes[i] = referenceSlots[i] }
        }
        plan.enabled_references = enabledReferences
        plan.refresh_slot_mask = refreshSlotMask
        plan.recovery = recovery ? 1 : 0
        return plan
    }
}
