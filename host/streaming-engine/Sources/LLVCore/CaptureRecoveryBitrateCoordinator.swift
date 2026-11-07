import Foundation

public enum CaptureRecoveryBitrateCoordinatorError: Error, Equatable, Sendable {
    case invalidSequence
    case invalidBitrate(Int)
    case invalidTier(CaptureFlexFECPolicy)
    case sequenceConflict(sequence: UInt64)
    case staleSequence(latest: UInt64, received: UInt64)
    case sequenceWrapped(latest: UInt64, received: UInt64)
}

public final class CaptureRecoveryBitrateCoordinator: @unchecked Sendable {
    public typealias BitrateSetter = @Sendable (Int) throws -> Void

    private let lock = NSLock()
    private let setter: BitrateSetter
    private var latestSequence: UInt64 = 0
    private var latest: CaptureRecoveryPolicyUpdate?

    public init(setter: @escaping BitrateSetter) {
        self.setter = setter
    }

    public var latestUpdate: CaptureRecoveryPolicyUpdate? {
        lock.withLock { latest }
    }

    public func apply(_ update: CaptureRecoveryPolicyUpdate) throws {
        try lock.withLock {
            guard update.sequence != 0 else {
                throw CaptureRecoveryBitrateCoordinatorError.invalidSequence
            }
            guard update.mediaBitrateBitsPerSecond > 0 else {
                throw CaptureRecoveryBitrateCoordinatorError.invalidBitrate(
                    update.mediaBitrateBitsPerSecond
                )
            }
            guard update.tier != .adaptive else {
                throw CaptureRecoveryBitrateCoordinatorError.invalidTier(update.tier)
            }
            if let latest {
                if update.sequence == latestSequence {
                    guard update == latest else {
                        throw CaptureRecoveryBitrateCoordinatorError.sequenceConflict(
                            sequence: update.sequence
                        )
                    }
                    return
                }
                guard latestSequence != UInt64.max else {
                    throw CaptureRecoveryBitrateCoordinatorError.sequenceWrapped(
                        latest: latestSequence,
                        received: update.sequence
                    )
                }
                guard update.sequence > latestSequence else {
                    throw CaptureRecoveryBitrateCoordinatorError.staleSequence(
                        latest: latestSequence,
                        received: update.sequence
                    )
                }
            }

            try setter(update.mediaBitrateBitsPerSecond)
            latestSequence = update.sequence
            latest = update
        }
    }
}
