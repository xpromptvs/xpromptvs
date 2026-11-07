import Foundation
public enum HostUpdatePhase: String, Codable, Sendable {
    case checking, downloading, verifying, restarting, succeeded, failed, cancelled
    case rolledBack = "rolled-back"
    public var terminal: Bool { [.succeeded,.failed,.cancelled,.rolledBack].contains(self) }
}
public struct HostUpdateState: Sendable {
    public private(set) var requestID: String?
    public private(set) var owner: String?
    public private(set) var phase: HostUpdatePhase = .checking
    public init() {}
    public mutating func begin(id: String, owner: String) -> Bool {
        if let requestID { return requestID == id && self.owner == owner }
        requestID = id; self.owner = owner; phase = .checking; return true
    }
    public mutating func advance(_ phase: HostUpdatePhase) { if !self.phase.terminal && self.phase != .restarting { self.phase = phase } }
    public mutating func commit(allowed: Bool, authorized: Bool) -> Bool {
        guard requestID != nil, !phase.terminal, phase != .restarting else { return false }
        guard allowed && authorized else { phase = .cancelled; return false }
        phase = .restarting; return true
    }
    public mutating func cancel() { if phase != .restarting && !phase.terminal { phase = .cancelled } }
    public mutating func finish(_ phase: HostUpdatePhase) { if !self.phase.terminal && phase.terminal { self.phase = phase } }
}
public struct HostUpdateJournal: Codable, Sendable {
    public var token: String
    public var requestID: String
    public var owner: String
    public var installed: String
    public var channel: String
    public var targetBuild: Int
    public var oldPID: Int32
    public var oldLaunch: Double
    public var profile: String?
    public var wasSharing: Bool
    public var phase: String
    public var error: String?
    public var environment: [String:String]?
    public var pairingCarrier: String?
    public var caskVersion: String?
    public var artifactSHA256: String?
    public var artifactURL: String?
    public init(token: String, requestID: String, owner: String, installed: String, channel: String, targetBuild: Int, oldPID: Int32, oldLaunch: Double, profile: String?, wasSharing: Bool, phase: String) {
        self.token=token; self.requestID=requestID; self.owner=owner; self.installed=installed
        self.channel=channel; self.targetBuild=targetBuild; self.oldPID=oldPID; self.oldLaunch=oldLaunch; self.profile=profile; self.wasSharing=wasSharing; self.phase=phase
    }
    public func write(to url: URL) throws { try JSONEncoder().encode(self).write(to:url,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path) }
    public static func read(_ url: URL) throws -> Self { try JSONDecoder().decode(Self.self,from:Data(contentsOf:url)) }
}
