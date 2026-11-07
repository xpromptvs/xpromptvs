import Foundation
import CoreFoundation

public struct ReferenceToken: Equatable, Hashable, Sendable {
    public let epoch: String
    public let frameID: UInt64
    public let slot: UInt8
    public let slotGeneration: UInt64
    public init(epoch: String, frameID: UInt64, slot: UInt8, slotGeneration: UInt64) {
        self.epoch = epoch; self.frameID = frameID; self.slot = slot; self.slotGeneration = slotGeneration
    }
}
public enum RecoveryIntent: Equatable, Sendable { case independentKeyframe, repairEstablishedStream }
public struct ReferenceAttemptOutcome: Equatable, Sendable {
    public enum Kind: String, Sendable { case sent, presented, failed, cancelled }
    public let epoch: String
    public let recoveryID: String
    public let kind: Kind
    public init(epoch: String, recoveryID: String, kind: Kind) {
        self.epoch = epoch; self.recoveryID = recoveryID; self.kind = kind
    }
}

/// Strict, bounded control metadata. A frame identity is never parsed through Double.
public struct AV1ReferenceMessage: Equatable, Sendable {
    public enum Tag: String, Sendable {
        case bind = "av1-ref-bind", bound = "av1-ref-bound", frame = "av1-ref-frame"
        case ack = "av1-ref-ack", reset = "av1-ref-reset"
    }
    public enum Purpose: String, Sendable { case candidate, recovery }
    public let tag: Tag
    public let source: String
    public let epoch: String
    public let frameID: UInt64?
    public let slot: UInt8?
    public let slotGeneration: UInt64?
    public let rtpTimestamp: UInt32?
    public let purpose: Purpose?
    public let recoveryID: String?
    public let trackID: String?
    public let reason: String?
    public var token: ReferenceToken? {
        guard let frameID, let slot, let slotGeneration else { return nil }
        return ReferenceToken(epoch: epoch, frameID: frameID, slot: slot, slotGeneration: slotGeneration)
    }
    public static func decode(_ object: [String: Any]) -> Self? {
        guard let raw = object["t"] as? String, let tag = Tag(rawValue: raw),
              let source = bounded(object["source"]), let epoch = bounded(object["epoch"]) else { return nil }
        if tag == .bind || tag == .bound || tag == .reset {
            let trackID = bounded(object["trackId"])
            if object["trackId"] != nil && trackID == nil { return nil }
            let reason = object["reason"] as? String
            if object["reason"] != nil && (tag != .reset || reason != "timestamps-unavailable") { return nil }
            return Self(tag: tag, source: source, epoch: epoch, frameID: nil, slot: nil,
                        slotGeneration: nil, rtpTimestamp: nil, purpose: nil, recoveryID: nil, trackID: trackID, reason: reason)
        }
        guard let frameID = decimal(object["frameId"]), let generation = decimal(object["slotGeneration"]),
              let slot = integer(object["slot"], max: 7), let timestamp = integer(object["rtpTimestamp"], max: UInt64(UInt32.max)),
              let rawPurpose = object["purpose"] as? String, let purpose = Purpose(rawValue: rawPurpose) else { return nil }
        let recoveryID = bounded(object["recoveryId"])
        if purpose == .recovery { guard recoveryID != nil else { return nil } }
        else if object["recoveryId"] != nil { return nil }
        return Self(tag: tag, source: source, epoch: epoch, frameID: frameID, slot: UInt8(slot),
                    slotGeneration: generation, rtpTimestamp: UInt32(timestamp), purpose: purpose, recoveryID: recoveryID, trackID: nil, reason: nil)
    }
    public static func capability(_ value: Any?) -> Int? { integer(value, max: 1) == 1 ? 1 : nil }
    private static func bounded(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s.utf8.count <= 128 else { return nil }; return s
    }
    private static func decimal(_ value: Any?) -> UInt64? {
        guard let s = value as? String, !s.isEmpty, s.utf8.count <= 20,
              s.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), s == "0" || s.first != "0" else { return nil }
        return UInt64(s)
    }
    private static func integer(_ value: Any?, max: UInt64) -> UInt64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d <= Double(max), d.rounded(.towardZero) == d else { return nil }
        return UInt64(d)
    }
}
