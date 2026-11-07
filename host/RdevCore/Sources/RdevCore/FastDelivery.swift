import Foundation

/// Pure generation-scoped delivery state. Its owner serializes access and applies effects outside hub locks.
public final class FastDelivery {
    public enum Effect: Equatable { case transmit(FastData.Record), deliver(UInt8, Data), failed(String) }
    public enum SendResult: Equatable { case accepted([Effect]), full, invalid }
    private static let messageMax = 1048576, payloadMax = 2097152, window = 2105344, messageCountMax = 2048
    private struct Pending { let start: UInt64; let bytes: Data }
    private final class Stream {
        var sent: UInt64 = 0, acked: UInt64 = 0, next: UInt64 = 0, lastAck: UInt64 = 0
        var pending: [Pending] = []; var ackAt: Double?
        var ring: [UInt8] = [], occupied: [UInt8] = []
        var header = 0, headerBytes = 0, messageAt = 0
        var message: Data?
    }
    private let generation: Data
    private let streams = [Stream(), Stream(), Stream()]
    private var failed = false
    public init(generation: Data) { precondition(generation.count == 16); self.generation = generation }
    public func send(_ stream: UInt8, message: Data, nowMs: Double) -> SendResult {
        guard !failed, stream <= 2, (1...Self.messageMax).contains(message.count) else { return .invalid }
        let s = streams[Int(stream)]
        guard bufferedAmount(stream) + message.count <= Self.payloadMax, s.pending.count < Self.messageCountMax,
              s.sent - s.acked + UInt64(message.count + 4) <= UInt64(Self.window) else { return .full }
        let (end, overflow) = s.sent.addingReportingOverflow(UInt64(message.count + 4)); guard !overflow else { return .invalid }
        var bytes = Data(); for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: message.count >> shift)) }; bytes.append(message)
        let start = s.sent; s.sent = end; s.pending.append(Pending(start: start, bytes: bytes))
        return .accepted(records(stream, start: start, bytes: bytes).map(Effect.transmit))
    }
    private func records(_ stream: UInt8, start: UInt64, bytes: Data) -> [FastData.Record] {
        let normalized = Data(bytes); var result: [FastData.Record] = []
        for i in stride(from: 0, to: normalized.count, by: FastData.recordMax) {
            result.append(.init(kind: .data, generation: generation, stream: stream, value: start + UInt64(i), bytes: normalized.subdata(in: i..<min(i + FastData.recordMax, normalized.count))))
        }; return result
    }
    public func replay(_ stream: UInt8) -> [FastData.Record] {
        guard !failed, stream <= 2 else { return [] }; let s = streams[Int(stream)]
        return s.pending.flatMap { p in
            let skip = Int(s.acked > p.start ? s.acked - p.start : 0)
            return records(stream, start: p.start + UInt64(skip), bytes: p.bytes.dropFirst(skip))
        }
    }
    public func bufferedAmount(_ stream: UInt8) -> Int {
        guard stream <= 2 else { return 0 }; let s = streams[Int(stream)]
        return s.pending.reduce(0) { n, p in
            let accepted = s.acked > p.start ? Int(s.acked - p.start) : 0
            return n + p.bytes.count - 4 - min(p.bytes.count - 4, max(0, accepted - 4))
        }
    }
    public func receiveOffsets() -> [UInt64] { streams.map(\.next) }
    private func ack(_ stream: UInt8) -> Effect {
        let s = streams[Int(stream)]; s.ackAt = nil; s.lastAck = s.next
        return .transmit(.init(kind: .ack, generation: generation, stream: stream, value: s.next))
    }
    private func fail(_ reason: String) -> [Effect] { failed = true; return [.failed(reason)] }
    /// RTC already repairs below this layer. Batch small progress there to avoid making every
    /// delivery ACK another repaired lane message; 2 KiB progress releases the shared terminal pacer's spare budget: its
    /// 4 KiB allowance reserves a full 2 KiB message before compression. A 4 KiB
    /// ACK threshold is unreachable for shorter compressed records and stalls on the timer.
    public func receive(_ r: FastData.Record, nowMs: Double, ackDelayMs: Double = 20) -> [Effect] {
        guard !failed, r.generation == generation else { return [] }
        guard r.stream <= 2 else { return fail("invalid-record") }; let s = streams[Int(r.stream)]
        if r.kind == .ack {
            guard r.value <= s.sent else { return fail("ack-beyond-sent") }
            if r.value > s.acked { s.acked = r.value; s.pending.removeAll { $0.start + UInt64($0.bytes.count) <= s.acked } }
            return []
        }
        guard r.kind == .data else { return [] }
        guard (1...FastData.recordMax).contains(r.bytes.count) else { return fail("invalid-record") }
        let (end, overflow) = r.value.addingReportingOverflow(UInt64(r.bytes.count))
        guard !overflow, end <= s.next || end - s.next <= UInt64(Self.window) else { return fail("receive-window") }
        if end <= s.next { return [ack(r.stream)] }
        let gap = r.value > s.next
        if s.ring.isEmpty { s.ring = [UInt8](repeating: 0, count: Self.window); s.occupied = s.ring }
        let skip = Int(s.next > r.value ? s.next - r.value : 0), bytes = [UInt8](r.bytes)
        var pos = Int((r.value + UInt64(skip)) % UInt64(Self.window))
        for i in skip..<bytes.count {
            if s.occupied[pos] != 0 && s.ring[pos] != bytes[i] { return fail("conflicting-overlap") }
            s.ring[pos] = bytes[i]; s.occupied[pos] = 1; pos = (pos + 1) % Self.window
        }
        var effects: [Effect] = []; pos = Int(s.next % UInt64(Self.window))
        while s.occupied[pos] != 0 {
            let byte = s.ring[pos]; s.occupied[pos] = 0; s.next += 1; pos = (pos + 1) % Self.window
            if s.message == nil {
                s.header = s.header * 256 + Int(byte); s.headerBytes += 1
                if s.headerBytes == 4 {
                    guard (1...Self.messageMax).contains(s.header) else { return effects + fail("invalid-message-length") }
                    s.message = Data(count: s.header); s.messageAt = 0; s.header = 0; s.headerBytes = 0
                }
            } else {
                s.message![s.messageAt] = byte; s.messageAt += 1
                if s.messageAt == s.message!.count { effects.append(.deliver(r.stream, s.message!)); s.message = nil }
            }
        }
        if gap || (ackDelayMs > 20 && s.next - s.lastAck >= 2048) { effects.append(ack(r.stream)) } else if s.ackAt == nil { s.ackAt = nowMs + ackDelayMs }
        return effects
    }
    public func poll(nowMs: Double) -> [Effect] {
        guard !failed else { return [] }; var effects: [Effect] = []
        for stream in UInt8(0)...UInt8(2) { if let deadline = streams[Int(stream)].ackAt, nowMs >= deadline { effects.append(ack(stream)) } }
        return effects
    }
}
