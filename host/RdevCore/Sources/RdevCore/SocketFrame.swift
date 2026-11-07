import Foundation

/// **THE MESSAGE-SOCKET TRANSPORT'S WIRE** (protocol/datachannels.md, "Over a message socket"): ONE
/// BYTE naming the logical channel, then exactly the bytes a WebRTC data channel of that name
/// carries. The client's FIRST frame is a `hello` on the meta channel. protocol/fixtures/
/// socket-frames.json — a third implementation — is what this and protocol/'s `socket-frame.ts`
/// both answer to.
public enum SocketChannel: UInt8, Sendable, CaseIterable {
    case meta = 0, control = 1, input = 2, terminal = 3, bulk = 4
}

public enum SocketFrame {
    public static func encode(_ channel: SocketChannel, _ payload: Data) -> Data {
        var frame = Data(capacity: payload.count + 1)
        frame.append(channel.rawValue)
        frame.append(payload)
        return frame
    }

    /// Nil for an empty frame or a byte that names no channel. The payload is REBASED to index 0: a
    /// `Data` slice keeps its parent's indices, and everything downstream — `unwrapMessage`, the JSON
    /// parser — reads `payload[0]` as the first byte.
    public static func decode(_ frame: Data) -> (channel: SocketChannel, payload: Data)? {
        guard let first = frame.first, let channel = SocketChannel(rawValue: first) else { return nil }
        return (channel, Data(frame.dropFirst()))
    }
}

/// The client's first frame: its stable id and its join intent (docs/sources-and-focus.md, "The join
/// intent"). Unknown fields are ignored; every known one must be exactly right, or the hello is refused.
public struct SocketHello: Equatable, Sendable {
    public static let version = 1
    public let client: String
    public let intent: JoinIntent

    public init(client: String, intent: JoinIntent) { self.client = client; self.intent = intent }

    public static func parse(_ payload: Data) -> SocketHello? {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let o = object as? [String: Any], o["t"] as? String == "hello" else { return nil }
        // THE NUMBER 1 — not "1", and not `true`, which JSONSerialization hands back as an NSNumber that
        // reads as 1. A CFBoolean is how the two are told apart.
        guard let v = o["v"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(),
              v.doubleValue == Double(version) else { return nil }
        guard let client = o["client"] as? String, isClientID(client),
              let raw = o["intent"] as? String, let intent = JoinIntent(rawValue: raw) else { return nil }
        return SocketHello(client: client, intent: intent)
    }

    /// 1–64 characters of `[A-Za-z0-9_-]`, counted in SCALARS — a `String`'s `count` is graphemes.
    public static func isClientID(_ s: String) -> Bool {
        let scalars = s.unicodeScalars
        return (1...64).contains(scalars.count) && scalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }
}
