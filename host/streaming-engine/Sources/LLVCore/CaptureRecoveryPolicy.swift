public enum CaptureRecoveryMode: String, Codable, Equatable, Sendable {
    case nackRTX = "nack-rtx"
    case off
    case nackRTXFlexFEC = "nack-rtx-flexfec"
}

public enum CaptureRTXAgeMode: String, Codable, Equatable, Sendable {
    case fixed
    case rtt
}

public enum CaptureFlexFECPolicy: String, CaseIterable, Codable, Equatable, Sendable {
    case adaptive
    case off
    case low
    case medium
    case high
}

public struct CaptureRecoveryPolicyUpdate: Equatable, Sendable {
    public let sequence: UInt64
    public let tier: CaptureFlexFECPolicy
    public let mediaBitrateBitsPerSecond: Int

    public init(
        sequence: UInt64,
        tier: CaptureFlexFECPolicy,
        mediaBitrateBitsPerSecond: Int
    ) {
        self.sequence = sequence
        self.tier = tier
        self.mediaBitrateBitsPerSecond = mediaBitrateBitsPerSecond
    }
}

