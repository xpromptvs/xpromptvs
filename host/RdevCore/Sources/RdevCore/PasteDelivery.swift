import Foundation

public enum PasteStep: Equatable, Sendable {
    /// Append the piece's bytes to item `item`.
    case write(item: Int)
    /// Abandon the delivery.
    case fail(PasteError)
}

/// ONE DELIVERY'S RECEIVE STATE (§3) — pure, so every way a sender can get it wrong is a unit test. Items
/// arrive in order, each from `seq` 0, consecutively, never past the size its `paste-begin` declared.
public struct PasteDeliveryState: Sendable {
    public let begin: PasteBegin
    /// The item now being received.
    public private(set) var item = 0
    private var nextSeq = 0
    private var received = 0
    private var lastActivity: Double

    public init(begin: PasteBegin, now: Double) {
        self.begin = begin
        self.lastActivity = now
    }

    public mutating func piece(item i: Int, seq: Int, count: Int, now: Double) -> PasteStep {
        let items = begin.items
        if i == item + 1, item < items.count, received == items[item].size, seq == 0 {
            item = i; nextSeq = 0; received = 0
        }
        guard i == item, i < items.count, seq == nextSeq, count > 0, received + count <= items[i].size else {
            return .fail(.malformed)
        }
        received += count
        nextSeq += 1
        lastActivity = now
        return .write(item: i)
    }

    public func complete() -> Bool {
        item == begin.items.count - 1 && received == begin.items[item].size
    }

    public func stalled(now: Double) -> Bool { now - lastActivity > PasteLimits.stallSeconds }
}
