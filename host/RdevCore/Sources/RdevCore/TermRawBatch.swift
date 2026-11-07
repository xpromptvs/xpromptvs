import Foundation

/// Immutable raw emission. Queue descriptors share this single compact backing;
/// only the scheduler's selected record is materialized as a wire-sized Data.
/// Construct ONLY inside the queue's reserved admission closure.
public final class TermRawBatch: @unchecked Sendable {
    public let tab: String
    public let recordCount: Int
    public let retainedBytes: Int
    private let id: [UInt8]
    private let payload: Data
    private let size: TermGridSize?
    private let kinds: (TermFrameKind, TermFrameKind)
    private let room: Int

    public init?(tab: String, size: TermGridSize?, bytes: [UInt8],
                 kinds: (TermFrameKind, TermFrameKind), messageCeiling: Int) {
        let id = Array(tab.utf8)
        let header = 2 + id.count + (size == nil ? 0 : 4)
        let room = messageCeiling - 128 - header
        guard !id.isEmpty, id.count <= 255, room > 0,
              messageCeiling <= TermWireMessage.maximumBytes,
              kinds.0 != .wireStart, kinds.1 != .wireStart else { return nil }
        let needsSize = kinds.0 != .output && kinds.0 != .closed
        let endNeedsSize = kinds.1 != .output && kinds.1 != .closed
        guard needsSize == (size != nil), endNeedsSize == needsSize else { return nil }
        self.tab = tab; self.id = id; self.size = size; self.kinds = kinds; self.room = room
        // Array -> Data makes one compact owned copy, never a slice retaining a larger buffer.
        payload = Data(bytes)
        recordCount = max(1, bytes.count / room + (bytes.count % room == 0 ? 0 : 1))
        retainedBytes = bytes.count + id.count
    }

    public func record(at index: Int) -> Data {
        precondition(index >= 0 && index < recordCount)
        let start = index * room
        let end = min(start + room, payload.count)
        var result = Data([index == recordCount - 1 ? kinds.1.rawValue : kinds.0.rawValue, UInt8(id.count)])
        result.append(contentsOf: id)
        if let size {
            let cols = min(max(size.cols, 0), 65535), rows = min(max(size.rows, 0), 65535)
            result.append(contentsOf: [UInt8(cols >> 8), UInt8(cols & 255), UInt8(rows >> 8), UInt8(rows & 255)])
        }
        result.append(payload[start..<end])
        return result
    }
}
