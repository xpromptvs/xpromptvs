/// Capability follows the live connection object. Keeping only its address permits a deallocated
/// connection's ObjectIdentifier to authorize a later allocation at that same address.
final class WorkspaceConnectionCapability {
    private(set) weak var peer: (any ClientConnection)?
    init(_ peer: any ClientConnection) { self.peer = peer }
    func matches(_ candidate: any ClientConnection) -> Bool { peer === candidate }
}
