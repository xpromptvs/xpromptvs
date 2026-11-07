import Foundation

public enum TermAdmission: Equatable, Sendable { case accepted, retired, overloaded, invalid }

/// Admission accounting, serialized by the owning wire. A batch's entire backing
/// stays charged until its final descriptor leaves, including canceled history.
public final class TermRawQueue {
    public private(set) var retainedBytes = 0
    public private(set) var recordCount = 0
    private let maximumBytes: Int
    private let maximumRecords: Int
    private var retired = false
    private var batches: [ObjectIdentifier: (batch: TermRawBatch, remaining: Int)] = [:]

    public init(maximumBytes: Int = 64 * 1024 * 1024, maximumRecords: Int = 65_536) {
        precondition(maximumBytes >= 0 && maximumRecords >= 0)
        self.maximumBytes = maximumBytes; self.maximumRecords = maximumRecords
    }

    public func admit(rawBytes: Int, recordCount count: Int,
                      build: () -> TermRawBatch?) -> (TermAdmission, TermRawBatch?) {
        guard !retired else { return (.retired, nil) }
        guard rawBytes >= 0, count > 0 else { return (.invalid, nil) }
        guard rawBytes <= maximumBytes - retainedBytes,
              count <= maximumRecords - recordCount else {
            retire()
            return (.overloaded, nil)
        }
        // Reserve before invoking the allocating closure.
        retainedBytes += rawBytes; recordCount += count
        guard let batch = build(), batch.retainedBytes == rawBytes,
              batch.recordCount == count, batches[ObjectIdentifier(batch)] == nil else {
            retainedBytes -= rawBytes; recordCount -= count
            return (.invalid, nil)
        }
        batches[ObjectIdentifier(batch)] = (batch, count)
        return (.accepted, batch)
    }

    public func releaseRecord(of batch: TermRawBatch) {
        let key = ObjectIdentifier(batch)
        guard var entry = batches[key] else { return }
        entry.remaining -= 1; recordCount -= 1
        if entry.remaining == 0 {
            retainedBytes -= entry.batch.retainedBytes
            batches[key] = nil
        } else { batches[key] = entry }
    }

    public func retire() {
        retired = true
        batches.removeAll(); retainedBytes = 0; recordCount = 0
    }
}
