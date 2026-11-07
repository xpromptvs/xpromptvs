import Foundation

public enum ReleaseChannel: String, Codable, Sendable { case staging, `public` }
public struct ReleaseIdentity: Equatable, Codable, Sendable {
    public let channel: ReleaseChannel
    public let build: Int
    public let version: String
    public let revision: String
    public let published: Bool
    public enum Comparison: String { case older, equal, newer, unknown; case channelMismatch = "channel-mismatch" }
    public static func buildNumber(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue > 0, n.doubleValue <= 9_007_199_254_740_991,
              n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.intValue
    }
    public static func parse(_ object: Any) -> Self? {
        guard let o = object as? [String: Any], let c = o["channel"] as? String, let channel = ReleaseChannel(rawValue: c),
              let build = buildNumber(o["build"]), let version = o["version"] as? String, !version.isEmpty, version.count <= 64,
              let revision = o["revision"] as? String, !revision.isEmpty, revision.count <= 128,
              let p = o["published"] as? NSNumber, CFGetTypeID(p) == CFBooleanGetTypeID() else { return nil }
        return Self(channel: channel, build: build, version: version, revision: revision, published: p.boolValue)
    }
    public var object: [String: Any] { ["channel":channel.rawValue,"build":build,"version":version,"revision":revision,"published":published] }
    public static func compare(host: Self?, client: Self?) -> Comparison {
        guard let host, let client else { return .unknown }
        guard host.channel == client.channel else { return .channelMismatch }
        return host.build < client.build ? .older : host.build > client.build ? .newer : .equal
    }
    public static func bundled(_ bundle: Bundle = .main) -> Self? {
        guard let url = bundle.url(forResource: "release", withExtension: "json"),
              let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parse(o)
    }
}
public struct HostUpdateRequest: Equatable, Sendable {
    public let requestId: UUID
    public let minimumBuild: Int
    public static func parse(_ object: Any) -> Self? {
        guard let o = object as? [String: Any], Set(o.keys).isSubset(of: ["t","requestId","minimumBuild"]),
              o["t"] as? String == "host-update-request", let id = o["requestId"] as? String, id.count == 36,
              let uuid = UUID(uuidString: id), let build = ReleaseIdentity.buildNumber(o["minimumBuild"]) else { return nil }
        return Self(requestId: uuid, minimumBuild: build)
    }
}
