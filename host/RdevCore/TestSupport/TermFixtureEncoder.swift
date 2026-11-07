import Foundation
import RdevCore

/// TEST ONLY: deterministic production-codec input for cross-language fixtures.
/// Product ordering/admission belongs exclusively to SharedTermPacer.
public final class TermFixtureEncoder {
    private let encoder = try! TermZstdEncoder()
    private let ceiling: Int
    private let epoch: UInt64
    private var sequence: UInt64 = 0
    private var tabs: Set<TermTabID> = []
    public init(maxMessageBytes: Int = 8192, epoch: UInt64 = 1) { ceiling = maxMessageBytes; self.epoch = epoch }
    public func start() -> [Data] {
        [TermWireMessage.start(epoch: epoch, compressed: try! encoder.flush(Data(0..<32))).encoded()]
    }
    public func output(_ tab: TermTabID, _ bytes: [UInt8]) -> [Data] {
        guard tabs.contains(tab), !bytes.isEmpty else { return [] }
        return records(tab, nil, bytes, (.output,.output))
    }
    public func snapshot(_ tab: TermTabID, size: TermGridSize, bytes: [UInt8], historyFollows: Bool = false) -> [Data] {
        tabs.insert(tab)
        return records(tab, size, bytes, historyFollows ? (.screenChunk,.screenEnd) : (.snapshotChunk,.snapshotEnd))
    }
    public func history(_ tab: TermTabID, size: TermGridSize, bytes: [UInt8]) -> [Data] {
        guard tabs.contains(tab), !bytes.isEmpty else { return [] }
        return records(tab, size, bytes, (.historyChunk,.historyEnd))
    }
    public func closed(_ tab: TermTabID) -> [Data] {
        tabs.remove(tab); return records(tab, nil, [], (.closed,.closed))
    }
    private func records(_ tab: TermTabID, _ size: TermGridSize?, _ bytes: [UInt8],
                         _ kinds: (TermFrameKind,TermFrameKind)) -> [Data] {
        guard let batch = TermRawBatch(tab: tab.wire, size: size, bytes: bytes, kinds: kinds, messageCeiling: ceiling) else { return [] }
        return (0..<batch.recordCount).map {
            let raw = batch.record(at: $0)
            let result = TermWireMessage.data(epoch: epoch, sequence: sequence, rawLength: UInt32(raw.count),
                                              compressed: try! encoder.flush(raw)).encoded()
            sequence += 1; return result
        }
    }
}
