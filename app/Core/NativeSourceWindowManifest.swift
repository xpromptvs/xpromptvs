import Foundation

/// The parent's complete presentation membership. Source IDs remain opaque here; the native bridge
/// validates each against RdevCore's source parser and the actual remote owner before accepting it.
public struct NativeSourceWindowManifest: Decodable, Equatable, Sendable {
    public struct AudioStatus: Decodable, Equatable, Sendable {
        public enum State: String, Decodable, Sendable { case muted, yielded }
        public let state: State
        public let title: String
    }
    public struct Source: Decodable, Equatable, Sendable {
        public enum Kind: String, Decodable, Sendable { case window, display, simulator }
        public let source: String
        public let kind: Kind
        public let title: String
        public let minimized: Bool
        public let width: Double?
        public let height: Double?
        public let audioStatus: AudioStatus?
    }
    public let generation: UInt64
    public let revision: UInt64
    public let driving: Bool
    public let focused: String?
    public let theme: String
    public let sources: [Source]

    public static func parse(_ raw: Any) -> NativeSourceWindowManifest? {
        guard let object = raw as? [String: Any], object.keys.contains("focused"),
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 1_048_576,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.generation > 0, value.generation <= 9_007_199_254_740_991,
              value.revision <= 9_007_199_254_740_991,
              ["dark", "light"].contains(value.theme) else { return nil }
        var ids = Set<String>()
        for source in value.sources {
            guard (source.audioStatus?.title.utf8.count ?? 0) <= 1024 else { return nil }
            guard !source.source.isEmpty, source.source.utf8.count <= 256,
                  source.title.utf8.count <= 1024, ids.insert(source.source).inserted else { return nil }
            for size in [source.width, source.height].compactMap({ $0 }) {
                guard size.isFinite, size > 0, size <= 32768 else { return nil }
            }
        }
        if let focused = value.focused {
            guard value.sources.contains(where: { $0.source == focused && !$0.minimized }) else { return nil }
        }
        return value
    }
}
