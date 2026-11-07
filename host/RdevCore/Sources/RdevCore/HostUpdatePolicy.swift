import Foundation
public enum HostUpdatePolicy {
    public static func mayRequest(chain: E2EVerify.VerifiedChain?, allowed: Bool) -> Bool {
        guard allowed, let chain else { return false }
        if chain.leaf.issuerKind == .root { return chain.capabilities.canEnroll }
        // The native app certifies its own renderer with a signed LOCAL, connect-only grant.
        // A guest paired remotely has a REMOTE binding even when its owner and capabilities
        // are identical. Locality is the owner's signed assertion, never a client hello flag.
        guard chain.grants.count == 2, chain.capabilities == .connectOnly,
              case .local = chain.leaf.binding else { return false }
        let owner = chain.grants[0]
        return owner.issuerKind == .root && owner.capabilities.canEnroll
            && chain.leaf.issuerID == owner.id
    }
}
public struct HostUpdateRequester: Sendable {
    public let deviceID: [UInt8]
    public let rootID: [UInt8]
    private let authorityDeviceIDs: Set<[UInt8]>
    public func isAuthorized(root:[UInt8]?,revoked:Set<[UInt8]>) -> Bool {
        root==rootID && authorityDeviceIDs.isDisjoint(with: revoked)
    }
    public init?(chain: E2EVerify.VerifiedChain?) {
        guard HostUpdatePolicy.mayRequest(chain: chain, allowed: true), let chain else { return nil }
        deviceID = E2EIdentity.deviceID(chain.leaf.device)
        rootID = chain.leaf.rootID
        authorityDeviceIDs = Set(chain.grants.map { E2EIdentity.deviceID($0.device) })
    }
}
